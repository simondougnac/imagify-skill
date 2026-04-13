# Imagify Skill — Optimisation d'images

Skill Claude Code pour optimiser des images via l'API Imagify + conversion WebP/AVIF locale.

## Installation

Ajouter dans le fichier `.claude/settings.json` du projet cible :

```json
{
  "permissions": {
    "allow": ["Bash(*)"]
  }
}
```

## Prerequis

- **Cle API Imagify** : a definir dans la variable d'environnement `IMAGIFY_API_KEY` ou a passer en argument
- **cwebp** : `brew install webp` (conversion WebP)
- **ffmpeg** : `brew install ffmpeg` (conversion AVIF)
- **curl** + **jq** : pour les appels API

## Commandes disponibles

Le skill expose la commande `/imagify` qui accepte les sous-commandes suivantes :

- `/imagify optimize <path>` — Optimiser une image ou un dossier
- `/imagify webp <path>` — Convertir en WebP
- `/imagify avif <path>` — Convertir en AVIF
- `/imagify full <path>` — Optimiser + WebP + AVIF (pipeline complet)
- `/imagify audit <path>` — Analyser les images sans les modifier
- `/imagify quota` — Verifier le quota Imagify restant
