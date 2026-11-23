# Activer l'Assistant et les Agents de n8n sur votre serveur Wayhost

Votre n8n Wayhost est prêt, mais l'Assistant et les Agents ont besoin d'un module en plus : la **sandbox**, l'espace sécurisé où ils exécutent du code. Votre agent IA peut l'installer pour vous en 5 minutes environ.

## Ce qu'il vous faut
- Votre n8n installé par Wayhost
- Un agent IA qui peut utiliser un terminal : Claude Code, Cursor, Codex…
- L'adresse IP de votre serveur et votre accès SSH (dans votre espace client Wayhost)

## Étape 1 : copiez ce message dans votre agent IA

```
Mon n8n est hébergé chez Wayhost sur le serveur <ADRESSE_IP> (utilisateur ubuntu).
Installe la sandbox n8n pour activer l'Assistant et les Agents, en suivant
exactement les instructions de https://raw.githubusercontent.com/Tgnima/n8n-sandbaox-installation/main/AGENT.md
```

Remplacez seulement `<ADRESSE_IP>` par l'adresse de votre serveur.

## Étape 2 : validez quand l'agent vous le demande

Avant toute modification, l'agent vous explique ce qu'il va faire. Répondez « oui ». n8n redémarre environ 30 secondes pendant l'installation.

## Étape 3 : ajoutez votre clé IA dans n8n

1. Ouvrez n8n, puis les **réglages IA**.
2. Collez votre clé Anthropic, OpenAI ou OpenRouter.
3. Testez en demandant à l'Assistant : *« cherche la dernière version de n8n puis exécute un script qui affiche 2+2 »*.

C'est terminé. La sandbox et la recherche web sont déjà configurées, vous n'avez rien d'autre à régler.

---

**Un souci ?** Demandez à votre agent : *« lance le diagnostic de la sandbox n8n »*. Si le problème continue, contactez le support Wayhost en joignant le résultat.

**Revenir en arrière ?** Demandez à votre agent : *« désinstalle la sandbox n8n »*.
