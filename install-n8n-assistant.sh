#!/usr/bin/env bash
# =============================================================================
#  install-n8n-assistant.sh — Wayhost / ITNET Technologies
#  Ajoute à un n8n Docker Compose existant :
#    - la sandbox n8n (sandbox-api + runner Docker-in-Docker, mTLS)
#    - la recherche web (SearXNG)
#    - la configuration n8n Assistant + Agents (sandbox partagée, knowledge base)
#
#  Rejouable sans risque (idempotent). Ne modifie jamais le compose d'origine.
#
#  Usage :
#    sudo bash install-n8n-assistant.sh [options]
#
#  Options :
#    --check              Diagnostic seul, ne change rien
#    --uninstall          Retire la sandbox et SearXNG, restaure la config n8n
#    --ui-config          Ne pas injecter la config dans n8n (à saisir dans l'UI)
#    --no-searxng         Ne pas installer SearXNG
#    --ai-key KEY         Clé LLM (Anthropic/OpenAI/OpenRouter). Aussi : AI_API_KEY
#    --ai-model P/M       Modèle, ex. anthropic/claude-opus-5-5. Aussi : AI_MODEL
#    --container NAME     Conteneur n8n (sinon détection automatique)
#    --sandbox-version V  Version du sandbox service (défaut 1.8.1)
#    --yes                Pas de confirmation interactive
#
#  Codes de sortie : 0 OK · 1 pré-requis · 2 installation · 3 vérification
#  Dernière ligne toujours :  RESULT: OK | RESULT: WARN <...> | RESULT: FAIL <...>
# =============================================================================
set -uo pipefail

SANDBOX_VERSION="${SANDBOX_VERSION:-1.8.1}"
MIN_N8N_VERSION="2.32.3"
MARK_BEGIN="# >>> wayhost-n8n-assistant >>>"
MARK_END="# <<< wayhost-n8n-assistant <<<"
ADDON_FILE="compose.sandbox.yml"
WRAPPER="n8n-compose"

MODE="install"; UI_CONFIG=0; WITH_SEARXNG=1; ASSUME_YES=0
AI_KEY="${AI_API_KEY:-}"; AI_MODEL="${AI_MODEL:-}"; CONTAINER=""
WARNINGS=()

# ---------- sortie ----------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
[ -t 1 ] || { c_ok=; c_warn=; c_err=; c_b=; c_0=; }
step() { echo; echo "${c_b}==> $*${c_0}"; }
ok()   { echo "  ${c_ok}✔${c_0} $*"; }
warn() { echo "  ${c_warn}!${c_0} $*"; WARNINGS+=("$*"); }
fail() { local code="$1"; shift; echo "  ${c_err}✘${c_0} $*"; echo; echo "RESULT: FAIL $*"; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --uninstall) MODE="uninstall" ;;
    --ui-config) UI_CONFIG=1 ;;
    --no-searxng) WITH_SEARXNG=0 ;;
    --ai-key) AI_KEY="${2:-}"; shift ;;
    --ai-model) AI_MODEL="${2:-}"; shift ;;
    --container) CONTAINER="${2:-}"; shift ;;
    --sandbox-version) SANDBOX_VERSION="${2:-}"; shift ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) fail 1 "Option inconnue : $1" ;;
  esac
  shift
done

# ---------- 1. Pré-requis ----------
step "Pré-requis"
[ "$(id -u)" -eq 0 ] || fail 1 "Lancer avec sudo (accès Docker requis)."
command -v docker >/dev/null || fail 1 "Docker introuvable."
docker compose version >/dev/null 2>&1 || fail 1 "Docker Compose v2 introuvable."
command -v openssl >/dev/null || fail 1 "openssl introuvable (apt install openssl)."
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), Compose v2, openssl"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
cpus=$(nproc 2>/dev/null || echo 1)
[ "$mem_mb" -ge 3500 ] && ok "RAM ${mem_mb} Mo" || warn "RAM ${mem_mb} Mo : 4 Go conseillés pour n8n + sandbox"
[ "$cpus" -ge 2 ] && ok "${cpus} vCPU" || warn "${cpus} vCPU : 2 minimum conseillés"

# ---------- 2. Détection de n8n ----------
step "Détection de l'installation n8n"
if [ -z "$CONTAINER" ]; then
  found=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /(^|\/)n8nio\/n8n(:|$)/ {print $1}')
  [ "$(echo "$found" | grep -c .)" -le 1 ] || fail 1 "Plusieurs conteneurs n8n ($(echo $found)) : relancer avec --container NOM"
  CONTAINER="$found"
fi
[ -n "$CONTAINER" ] || fail 1 "Aucun conteneur n8n (image n8nio/n8n) en cours d'exécution."
label() { docker inspect "$CONTAINER" --format "{{ index .Config.Labels \"$1\" }}" 2>/dev/null; }
WORKDIR=$(label com.docker.compose.project.working_dir)
PROJECT=$(label com.docker.compose.project)
SERVICE=$(label com.docker.compose.service)
CONFIG_FILES=$(label com.docker.compose.project.config_files)
[ -n "$WORKDIR" ] && [ -n "$PROJECT" ] || fail 1 "n8n ($CONTAINER) n'est pas géré par Docker Compose : installation non supportée par ce script."
ok "Conteneur $CONTAINER · projet '$PROJECT' · service '$SERVICE'"
ok "Dossier $WORKDIR"

BASE_ARGS=()
IFS=',' read -r -a _files <<< "$CONFIG_FILES"
for f in "${_files[@]}"; do
  [ "$(basename "$f")" = "$ADDON_FILE" ] && continue
  [ -f "$f" ] || fail 1 "Fichier compose introuvable : $f"
  BASE_ARGS+=(-f "$f")
done
[ ${#BASE_ARGS[@]} -gt 0 ] || fail 1 "Impossible de déterminer le fichier compose de n8n."
ok "Compose d'origine : ${BASE_ARGS[*]}"
cd "$WORKDIR" || fail 1 "Accès impossible à $WORKDIR"

DC_BASE=(docker compose -p "$PROJECT" "${BASE_ARGS[@]}")
DC=("${DC_BASE[@]}" -f "$WORKDIR/$ADDON_FILE")

nets=$(docker inspect "$CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')
if echo " $nets " | grep -q " ${PROJECT}_default "; then
  ok "Réseau ${PROJECT}_default"
else
  [ "$MODE" = "check" ] && warn "n8n n'est pas sur ${PROJECT}_default ($nets)" \
    || fail 1 "n8n n'est pas sur le réseau ${PROJECT}_default ($nets) : réseau personnalisé non supporté, escalader."
fi

N8N_VERSION=$(docker exec "$CONTAINER" n8n --version 2>/dev/null | tr -d '\r' | tail -n1)
if [ -n "$N8N_VERSION" ]; then
  if [ "$(printf '%s\n%s\n' "$MIN_N8N_VERSION" "$N8N_VERSION" | sort -V | head -n1)" = "$MIN_N8N_VERSION" ]; then
    ok "n8n $N8N_VERSION"
  else
    warn "n8n $N8N_VERSION < $MIN_N8N_VERSION : mettre n8n à jour pour l'Assistant et les Agents"
  fi
else
  warn "Version de n8n non détectée"
fi

disabled=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^N8N_DISABLED_MODULES=//p')
if echo "$disabled" | grep -qE '(^|,)(instance-ai|agents)(,|$)'; then
  warn "N8N_DISABLED_MODULES='$disabled' désactive instance-ai ou agents : à retirer du compose d'origine"
fi

# ---------- fonctions utilitaires ----------
gen() { openssl rand -hex 32; }
env_get() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -n1; }
env_set() { # remplace ou ajoute KEY=VALUE dans le bloc marqué
  local k="$1" v="$2"
  if grep -q "^$k=" .env; then
    K="$k" V="$v" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]} index($0, k"=")==1 {print k"="v; next} {print}' .env > .env.tmp && cat .env.tmp > .env && rm -f .env.tmp
  else
    K="$k" V="$v" B="$MARK_BEGIN" E="$MARK_END" awk '
      BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]; b=ENVIRON["B"]; e=ENVIRON["E"]; done=0}
      $0==e && !done {print k"="v; done=1}
      {print}' .env > .env.tmp && cat .env.tmp > .env && rm -f .env.tmp
  fi
}
health_from_n8n() { "${DC[@]}" exec -T "$SERVICE" wget -qO- -T 5 "$1" 2>/dev/null; }

# ---------- MODE check ----------
if [ "$MODE" = "check" ]; then
  step "Diagnostic"
  [ -f "$ADDON_FILE" ] && ok "$ADDON_FILE présent" || { echo; echo "RESULT: FAIL sandbox non installée"; exit 3; }
  for s in sandbox-api sandbox-runner-1 searxng; do
    st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${PROJECT}-${s}-1" 2>/dev/null || echo absent)
    echo "  - $s : $st"
  done
  h=$(health_from_n8n http://sandbox-api:8080/healthz)
  [ "$h" = '{"status":"ok"}' ] && ok "sandbox-api joignable depuis n8n" || warn "sandbox-api ne répond pas depuis n8n ($h)"
  if docker ps --format '{{.Names}}' | grep -qx "${PROJECT}-searxng-1"; then
    n=$(health_from_n8n "http://searxng:8080/search?q=n8n&format=json" | grep -o '"url"' | wc -l)
    [ "$n" -gt 0 ] && ok "SearXNG : $n résultats" || warn "SearXNG ne renvoie aucun résultat"
  fi
  docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q '^N8N_SANDBOX_SERVICE_URL=' \
    && ok "Config sandbox injectée dans n8n" || warn "Config sandbox absente de n8n (mode UI ?)"
  echo
  [ ${#WARNINGS[@]} -eq 0 ] && echo "RESULT: OK" || echo "RESULT: WARN ${#WARNINGS[@]} point(s) à vérifier"
  exit 0
fi

# ---------- MODE uninstall ----------
if [ "$MODE" = "uninstall" ]; then
  step "Désinstallation"
  if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
    read -r -p "  Retirer la sandbox et SearXNG de '$PROJECT' ? [o/N] " a; case "$a" in o|O|y|Y) ;; *) echo "RESULT: FAIL annulé"; exit 1;; esac
  fi
  if [ -f "$ADDON_FILE" ]; then
    "${DC[@]}" rm -sf sandbox-runner-1 sandbox-api sandbox-certs searxng >/dev/null 2>&1
    mv "$ADDON_FILE" "$ADDON_FILE.removed.$(date +%Y%m%d%H%M%S)"
  fi
  docker volume rm "${PROJECT}_sandbox-tls" >/dev/null 2>&1 || true
  if [ -f .env ]; then
    cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
    B="$MARK_BEGIN" E="$MARK_END" awk 'BEGIN{b=ENVIRON["B"];e=ENVIRON["E"]} $0==b{skip=1} !skip{print} $0==e{skip=0}' .env > .env.tmp && cat .env.tmp > .env && rm -f .env.tmp
  fi
  rm -f "$WRAPPER"
  "${DC_BASE[@]}" up -d "$SERVICE" >/dev/null 2>&1 || warn "Redémarrage de n8n à vérifier"
  ok "Sandbox retirée, n8n redémarré avec sa configuration d'origine"
  echo; echo "RESULT: OK"; exit 0
fi

# ---------- 3. Confirmation ----------
step "Plan"
echo "  - Ajout de sandbox-api, sandbox-runner-1 (privilégié, Docker-in-Docker)$( [ $WITH_SEARXNG = 1 ] && echo ', searxng') au projet '$PROJECT'"
[ "$UI_CONFIG" -eq 0 ] && echo "  - Injection de la config Assistant/Agents dans le service '$SERVICE' (redémarrage court de n8n)" \
                       || echo "  - Config à saisir dans l'UI n8n (pas de redémarrage de n8n)"
echo "  - Aucun port publié ; Traefik désactivé sur ces conteneurs ; compose d'origine inchangé"
echo "  ⚠ Le runner est privilégié : réservé aux VPS dédiés au client, jamais sur un hôte partagé."
if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
  read -r -p "  Continuer ? [o/N] " a; case "$a" in o|O|y|Y) ;; *) echo "RESULT: FAIL annulé"; exit 1;; esac
fi

# ---------- 4. Secrets (.env) ----------
step "Secrets"
touch .env; chmod 600 .env
cp .env ".env.bak.$(date +%Y%m%d%H%M%S)"
grep -qxF "$MARK_BEGIN" .env || printf '\n%s\n%s\n' "$MARK_BEGIN" "$MARK_END" >> .env

API_KEY=$(env_get SANDBOX_API_KEYS); API_KEY=${API_KEY:-$(gen)}
REG=$(env_get SANDBOX_RUNNER_REGISTRATION_TOKEN); REG=${REG:-$(gen)}
RUNNER=$(env_get SANDBOX_RUNNER_API_KEYS); RUNNER=${RUNNER:-$(gen)}
SEARX=$(env_get SEARXNG_SECRET); SEARX=${SEARX:-$(gen)}

env_set N8N_SANDBOX_VERSION "$SANDBOX_VERSION"
env_set SANDBOX_API_KEYS "$API_KEY"
env_set N8N_SANDBOX_SERVICE_API_KEY "$API_KEY"
env_set SANDBOX_API_RUNNER_REGISTRATION_TOKEN "$REG"
env_set SANDBOX_RUNNER_REGISTRATION_TOKEN "$REG"
env_set SANDBOX_API_RUNNER_API_KEY "$RUNNER"
env_set SANDBOX_RUNNER_API_KEYS "$RUNNER"
env_set SEARXNG_SECRET "$SEARX"
[ -n "$AI_KEY" ] && env_set N8N_INSTANCE_AI_MODEL_API_KEY "$AI_KEY"
[ -n "$AI_MODEL" ] && env_set N8N_INSTANCE_AI_MODEL "$AI_MODEL"
ok "Secrets en place (.env sauvegardé, droits 600)"

# ---------- 5. Fichiers compose ----------
step "Fichiers"
[ -f "$ADDON_FILE" ] && cp "$ADDON_FILE" "$ADDON_FILE.bak.$(date +%Y%m%d%H%M%S)"
{
cat <<'EOF'
# Généré par install-n8n-assistant.sh (Wayhost). Ne pas exposer ces services.
volumes:
  sandbox-tls:

services:
  sandbox-certs:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:${N8N_SANDBOX_VERSION}
    labels: [traefik.enable=false]
    user: '0:0'
    entrypoint: ['sh', '-c']
    command:
      - >
        bootstrap-mtls.sh --out-dir /tls --api-san sandbox-api
        --control-san-prefix sandbox-runner --world-readable &&
        chown -R sandbox-api:sandbox-api /tls/api && chmod -R a+rX /tls
    environment:
      NUM_RUNNERS: '1'
    volumes:
      - sandbox-tls:/tls

  sandbox-api:
    image: ghcr.io/n8n-io/n8n-sandbox-service-api:${N8N_SANDBOX_VERSION}
    labels: [traefik.enable=false]
    restart: unless-stopped
    depends_on:
      sandbox-certs:
        condition: service_completed_successfully
    environment:
      # Mêmes secrets que la stack officielle (env_file .env), sans exposer le reste du .env
      SANDBOX_API_KEYS: ${SANDBOX_API_KEYS}
      SANDBOX_API_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_API_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_API_RUNNER_API_KEY: ${SANDBOX_API_RUNNER_API_KEY}
      SANDBOX_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_RUNNER_API_KEYS: ${SANDBOX_RUNNER_API_KEYS}
      SANDBOX_API_GRPC_TLS_CERT_FILE: /tls/api/grpc-server.crt
      SANDBOX_API_GRPC_TLS_KEY_FILE: /tls/api/grpc-server.key
      SANDBOX_API_GRPC_TLS_CLIENT_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CA_FILE: /tls/api/ca.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/api/control-grpc-api-client.crt
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/api/control-grpc-api-client.key
      SANDBOX_API_RUNNER_CONTROL_GRPC_TLS_SERVER_NAME: sandbox-runner-1
    volumes:
      - sandbox-tls:/tls:ro
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://localhost:8080/healthz']
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s

  sandbox-runner-1:
    image: ghcr.io/n8n-io/n8n-sandbox-service-runner-dind:${N8N_SANDBOX_VERSION}
    labels: [traefik.enable=false]
    restart: unless-stopped
    privileged: true
    depends_on:
      sandbox-api:
        condition: service_healthy
    environment:
      # Mêmes secrets que la stack officielle (env_file .env), sans exposer le reste du .env
      SANDBOX_API_KEYS: ${SANDBOX_API_KEYS}
      SANDBOX_API_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_API_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_API_RUNNER_API_KEY: ${SANDBOX_API_RUNNER_API_KEY}
      SANDBOX_RUNNER_REGISTRATION_TOKEN: ${SANDBOX_RUNNER_REGISTRATION_TOKEN}
      SANDBOX_RUNNER_API_KEYS: ${SANDBOX_RUNNER_API_KEYS}
      SANDBOX_RUNNER_API_GRPC_ADDR: sandbox-api:9090
      SANDBOX_RUNNER_HTTP_BASE_URL: https://sandbox-runner-1:8080
      SANDBOX_RUNNER_CONTROL_GRPC_LISTEN_ADDR: ':9091'
      SANDBOX_RUNNER_CONTROL_GRPC_ADVERTISE_ADDR: sandbox-runner-1:9091
      SANDBOX_RUNNER_ID: runner-1
      SANDBOX_RUNNER_DOCKER_SANDBOX_IMAGE: ghcr.io/n8n-io/n8n-sandbox-service-sandbox:${N8N_SANDBOX_VERSION}
      SANDBOX_RUNNER_REGISTRATION_GRPC_CA_FILE: /tls/runner/ca.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_CERT_FILE: /tls/runner/grpc-client.crt
      SANDBOX_RUNNER_REGISTRATION_GRPC_KEY_FILE: /tls/runner/grpc-client.key
      SANDBOX_RUNNER_REGISTRATION_GRPC_SERVER_NAME: sandbox-api
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CERT_FILE: /tls/runner/control-grpc-server.crt
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_KEY_FILE: /tls/runner/control-grpc-server.key
      SANDBOX_RUNNER_CONTROL_GRPC_TLS_CLIENT_CA_FILE: /tls/runner/ca.crt
    volumes:
      - sandbox-tls:/tls:ro
EOF
if [ "$WITH_SEARXNG" -eq 1 ]; then
cat <<'EOF'

  searxng:
    image: ghcr.io/searxng/searxng:latest
    labels: [traefik.enable=false]
    restart: unless-stopped
    environment:
      SEARXNG_SECRET: ${SEARXNG_SECRET}
    volumes:
      - ./searxng-settings.yml:/etc/searxng/settings.yml:ro
EOF
fi
if [ "$UI_CONFIG" -eq 0 ]; then
cat <<EOF

  ${SERVICE}:
    environment:
      N8N_INSTANCE_AI_SANDBOX_ENABLED: 'true'
      N8N_INSTANCE_AI_SANDBOX_PROVIDER: n8n-sandbox
      N8N_INSTANCE_AI_SANDBOX_API_URL: http://sandbox-api:8080
      N8N_SANDBOX_SERVICE_URL: http://sandbox-api:8080
      N8N_SANDBOX_SERVICE_API_KEY: \${N8N_SANDBOX_SERVICE_API_KEY}
      N8N_AGENTS_AI_SANDBOX_ENABLED: 'true'
EOF
[ "$WITH_SEARXNG" -eq 1 ] && echo "      N8N_INSTANCE_AI_SEARXNG_URL: http://searxng:8080"
[ -n "$(env_get N8N_INSTANCE_AI_MODEL_API_KEY)" ] && echo "      N8N_INSTANCE_AI_MODEL_API_KEY: \${N8N_INSTANCE_AI_MODEL_API_KEY}"
[ -n "$(env_get N8N_INSTANCE_AI_MODEL)" ] && echo "      N8N_INSTANCE_AI_MODEL: \${N8N_INSTANCE_AI_MODEL}"
fi
} > "$ADDON_FILE"

if [ "$WITH_SEARXNG" -eq 1 ]; then
cat > searxng-settings.yml <<'EOF'
use_default_settings: true
search:
  formats:
    - html
    - json
outgoing:
  request_timeout: 8.0
  max_request_timeout: 15.0
EOF
fi

{
  echo '#!/bin/sh'
  echo '# Toujours utiliser ce wrapper pour gérer n8n + sandbox (ex. ./n8n-compose ps, ./n8n-compose pull)'
  printf 'cd "%s" && exec docker compose -p "%s"' "$WORKDIR" "$PROJECT"
  for a in "${BASE_ARGS[@]}"; do printf ' %q' "$a"; done
  printf ' -f %q "$@"\n' "$WORKDIR/$ADDON_FILE"
} > "$WRAPPER"
chmod 750 "$WRAPPER"

"${DC[@]}" config -q 2>/tmp/n8n-assistant-config.err || { cat /tmp/n8n-assistant-config.err; fail 2 "compose invalide après ajout"; }
ok "$ADDON_FILE, searxng-settings.yml et ./$WRAPPER écrits ; configuration valide"

# ---------- 6. Démarrage ----------
step "Démarrage (téléchargement des images au premier lancement)"
svc=(sandbox-certs sandbox-api sandbox-runner-1); [ "$WITH_SEARXNG" -eq 1 ] && svc+=(searxng)
"${DC[@]}" up -d "${svc[@]}" || fail 2 "échec du démarrage de la sandbox"
for _ in $(seq 1 60); do
  hs=$(docker inspect -f '{{.State.Health.Status}}' "$("${DC[@]}" ps -q sandbox-api)" 2>/dev/null)
  [ "$hs" = "healthy" ] && break; sleep 3
done
[ "${hs:-}" = "healthy" ] || { "${DC[@]}" logs --tail 30 sandbox-certs sandbox-api; fail 2 "sandbox-api n'est pas healthy"; }
ok "sandbox-api healthy"
if [ "$UI_CONFIG" -eq 0 ]; then
  "${DC[@]}" up -d "$SERVICE" || fail 2 "échec du redémarrage de n8n"
  for _ in $(seq 1 40); do health_from_n8n http://localhost:5678/healthz >/dev/null && break; sleep 3; done
  ok "n8n redémarré avec la config Assistant/Agents"
fi

# ---------- 7. Vérifications ----------
step "Vérifications"
FAILED=0
h=$(health_from_n8n http://sandbox-api:8080/healthz)
[ "$h" = '{"status":"ok"}' ] && ok "n8n → sandbox-api : $h" || { warn "n8n ne joint pas sandbox-api ($h)"; FAILED=1; }

if "${DC[@]}" logs sandbox-runner-1 2>&1 | grep -qiE 'error|fatal|must be set'; then
  warn "Erreurs dans les logs du runner : ./$WRAPPER logs --tail 30 sandbox-runner-1"
else
  ok "Runner démarré sans erreur"
fi

for c in sandbox-api sandbox-runner-1 searxng; do
  id=$("${DC[@]}" ps -q "$c" 2>/dev/null); [ -n "$id" ] || continue
  [ -z "$(docker port "$id" 2>/dev/null)" ] || { warn "$c publie un port sur l'hôte !"; FAILED=1; }
done
ok "Aucun port de sandbox publié sur l'hôte"

if [ "$WITH_SEARXNG" -eq 1 ]; then
  n=0
  for _ in 1 2 3 4; do
    n=$(health_from_n8n "http://searxng:8080/search?q=n8n+workflow&format=json" | grep -o '"url"' | wc -l)
    [ "$n" -gt 0 ] && break; sleep 5
  done
  [ "$n" -gt 0 ] && ok "SearXNG : $n résultats" || warn "SearXNG ne renvoie aucun résultat (sortie réseau du VPS ? préférer Brave Search)"
fi

# ---------- 8. Récapitulatif ----------
step "Étapes restantes dans l'interface n8n (compte owner/admin)"
if [ "$UI_CONFIG" -eq 1 ]; then
  echo "  1. Settings > Agents > Shared sandbox > Add sandbox > n8n Sandbox"
  echo "       Service URL : http://sandbox-api:8080"
  echo "       API key     : sudo grep '^SANDBOX_API_KEYS=' $WORKDIR/.env"
  [ "$WITH_SEARXNG" -eq 1 ] && echo "  2. Réglages IA > identifiant SearXNG : http://searxng:8080"
else
  echo "  1. Sandbox et recherche web : déjà configurées (« Found in server configuration »)"
fi
[ -n "$(env_get N8N_INSTANCE_AI_MODEL_API_KEY)" ] \
  && echo "  - Clé IA : déjà fournie" \
  || echo "  - Clé IA : à saisir dans les réglages IA de n8n (Anthropic, OpenAI ou OpenRouter)"
echo "  - Settings > Agents : vérifier que « Enable Agents » est activé"
echo "  - Test : demander à l'Assistant « cherche la dernière version de n8n puis exécute un script qui affiche 2+2 »"
echo "  - Gestion future : $WORKDIR/$WRAPPER <commande>   (ex. ps, logs, pull, up -d)"

echo
if [ "$FAILED" -ne 0 ]; then echo "RESULT: FAIL vérifications : ${WARNINGS[*]}"; exit 3
elif [ ${#WARNINGS[@]} -gt 0 ]; then echo "RESULT: WARN ${WARNINGS[*]}"; exit 0
else echo "RESULT: OK"; exit 0; fi
