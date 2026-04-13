# Imagify — Optimisation d'images

TRIGGER when: user says "/imagify", "optimiser images", "convertir webp", "convertir avif", "compresser images", "imagify"

## Description

Skill d'optimisation d'images combinant l'API Imagify (compression intelligente) et des outils locaux (cwebp, ffmpeg) pour la conversion WebP/AVIF. Couvre le pipeline complet d'optimisation pour le web.

## API Imagify — Reference

### Authentification
```
Header: Authorization: token <API_KEY>
Base URL: https://app.imagify.io/api
```

La cle API peut etre :
- Variable d'environnement `IMAGIFY_API_KEY`
- Passee en argument par l'utilisateur
- Definie dans un fichier `.env` du projet

### Endpoint principal : POST /api/upload/

Optimise une image avec compression intelligente.

```bash
curl -s "https://app.imagify.io/api/upload/" \
  -H "Authorization: token $IMAGIFY_API_KEY" \
  -F "image=@chemin/vers/image.jpg" \
  -F 'data={"aggressive":true,"keep_exif":false}'
```

**Parametres `data` (JSON string) :**

| Parametre | Type | Default | Description |
|-----------|------|---------|-------------|
| `normal` | bool | false | Compression lossless (pas de perte visible) |
| `aggressive` | bool | true | Compression intelligente (equilibre qualite/taille) |
| `ultra` | bool | false | Compression maximale (plus de perte, gains max) |
| `keep_exif` | bool | false | Conserver les metadonnees EXIF |
| `resize.width` | int | - | Largeur cible en pixels |
| `resize.height` | int | - | Hauteur cible en pixels |
| `resize.percentage` | int | - | Redimensionner en % de l'original |

**Un seul niveau de compression a la fois** (`normal`, `aggressive`, ou `ultra`).

**Reponse succes (200) :**
```json
{
  "code": 200,
  "success": true,
  "image": "https://storage.imagify.io/imagify/xxxxx/image.jpg",
  "original_size": 245000,
  "new_size": 98000,
  "percent": 60
}
```

**Codes erreur :**
| Code | Signification |
|------|--------------|
| 200 | Succes |
| 400 | Requete invalide |
| 402 | Quota depasse |
| 403 | Cle API invalide |
| 415 | Format non supporte |
| 422 | Image deja optimisee (pas de gain supplementaire) |
| 500 | Erreur serveur Imagify |

### Limites
- Taille max par fichier : 32 Mo
- Quota mesure en Mo d'images originales envoyees
- Pas de rate limit documente mais respecter ~2 req/sec en bulk
- Formats acceptes : JPG, PNG, GIF, WebP, PDF

### Ce que l'API ne fait PAS
- Pas de conversion WebP/AVIF (plugin WordPress uniquement)
- Pas de bulk endpoint (boucler image par image)
- Pas de crop/rotate
- Pas de conversion de format (PNG → JPG)

## Conversion WebP — Outil local (cwebp)

```bash
# Conversion simple
cwebp -q 82 input.jpg -o output.webp

# Conversion lossless
cwebp -lossless input.png -o output.webp

# Avec resize
cwebp -q 82 -resize 1200 0 input.jpg -o output.webp
```

**Options importantes :**
| Option | Description | Recommandation |
|--------|-------------|----------------|
| `-q 82` | Qualite (0-100) | 80-85 pour photos, 90 pour texte |
| `-lossless` | Sans perte | Pour PNG avec transparence |
| `-resize W H` | Redimensionner (0 = auto) | Max 1920px pour hero images |
| `-mt` | Multi-thread | Toujours utiliser |
| `-metadata none` | Supprimer metadonnees | Toujours sauf besoin EXIF |

**Prerequis :** `brew install webp` ou `apt install webp`

## Conversion AVIF — Outil local (ffmpeg)

```bash
# Conversion simple
ffmpeg -i input.jpg -c:v libaom-av1 -crf 32 -b:v 0 -an -y output.avif

# Qualite haute (CRF plus bas = meilleure qualite)
ffmpeg -i input.jpg -c:v libaom-av1 -crf 28 -b:v 0 -an -y output.avif

# Avec resize
ffmpeg -i input.jpg -vf "scale=1200:-1" -c:v libaom-av1 -crf 32 -b:v 0 -an -y output.avif
```

**Options :**
| Option | Description | Recommandation |
|--------|-------------|----------------|
| `-crf 28-35` | Qualite (plus bas = mieux) | 30-32 pour photos web |
| `-b:v 0` | Bitrate variable | Toujours |
| `-an` | Pas d'audio | Toujours pour images |
| `scale=W:-1` | Resize (auto hauteur) | Max 1920px |

**Prerequis :** `brew install ffmpeg` ou `apt install ffmpeg`

## Instructions pour l'agent

Quand l'utilisateur demande d'optimiser des images, suivre ce workflow :

### 1. AUDIT — Analyser avant d'agir

```bash
# Lister toutes les images du projet avec leurs tailles
find <path> -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.gif" \) -exec ls -lh {} \; | sort -k5 -h -r

# Compter par format
echo "JPG: $(find <path> -name '*.jpg' -o -name '*.jpeg' | wc -l)"
echo "PNG: $(find <path> -name '*.png' | wc -l)"
echo "WebP: $(find <path> -name '*.webp' | wc -l)"
echo "AVIF: $(find <path> -name '*.avif' | wc -l)"

# Taille totale
du -sh <path>

# Verifier les dimensions
sips -g pixelWidth -g pixelHeight <image>  # macOS
identify <image>  # ImageMagick
```

Presenter un rapport a l'utilisateur AVANT de lancer l'optimisation :
- Nombre d'images par format
- Taille totale
- Images > 500 Ko (prioritaires)
- Images sans equivalent WebP
- Estimation du quota Imagify necessaire

### 2. OPTIMISER via Imagify API

Pour chaque image JPG/PNG :

```bash
#!/bin/bash
# Optimiser une image via Imagify
API_KEY="${IMAGIFY_API_KEY}"
IMAGE="$1"
LEVEL="${2:-aggressive}"  # normal, aggressive, ultra

# Construire le JSON data
case "$LEVEL" in
  normal)     DATA='{"normal":true,"keep_exif":false}' ;;
  aggressive) DATA='{"aggressive":true,"keep_exif":false}' ;;
  ultra)      DATA='{"ultra":true,"keep_exif":false}' ;;
esac

# Appel API
RESPONSE=$(curl -s -w "\n%{http_code}" "https://app.imagify.io/api/upload/" \
  -H "Authorization: token $API_KEY" \
  -F "image=@$IMAGE" \
  -F "data=$DATA")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
  # Telecharger l'image optimisee
  OPTIMIZED_URL=$(echo "$BODY" | jq -r '.image')
  PERCENT=$(echo "$BODY" | jq -r '.percent')
  NEW_SIZE=$(echo "$BODY" | jq -r '.new_size')
  
  # Remplacer l'original par l'optimise
  curl -s "$OPTIMIZED_URL" -o "$IMAGE"
  echo "OK: $IMAGE — ${PERCENT}% reduit (${NEW_SIZE} octets)"
elif [ "$HTTP_CODE" = "422" ]; then
  echo "SKIP: $IMAGE — deja optimisee"
elif [ "$HTTP_CODE" = "402" ]; then
  echo "ERREUR: Quota Imagify depasse"
  exit 1
else
  echo "ERREUR ($HTTP_CODE): $IMAGE — $BODY"
fi
```

### 3. CONVERTIR en WebP

```bash
# Convertir une image en WebP (a cote de l'original)
convert_to_webp() {
  local INPUT="$1"
  local QUALITY="${2:-82}"
  local OUTPUT="${INPUT%.*}.webp"
  
  if [ -f "$OUTPUT" ]; then
    echo "SKIP: $OUTPUT existe deja"
    return
  fi
  
  cwebp -q "$QUALITY" -mt -metadata none "$INPUT" -o "$OUTPUT" 2>/dev/null
  
  if [ -f "$OUTPUT" ]; then
    ORIG_SIZE=$(stat -f%z "$INPUT" 2>/dev/null || stat -c%s "$INPUT")
    NEW_SIZE=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT")
    PERCENT=$(( (ORIG_SIZE - NEW_SIZE) * 100 / ORIG_SIZE ))
    echo "WebP: $OUTPUT — ${PERCENT}% plus leger"
  else
    echo "ERREUR: conversion WebP echouee pour $INPUT"
  fi
}
```

### 4. CONVERTIR en AVIF

```bash
# Convertir une image en AVIF (a cote de l'original)
convert_to_avif() {
  local INPUT="$1"
  local CRF="${2:-32}"
  local OUTPUT="${INPUT%.*}.avif"
  
  if [ -f "$OUTPUT" ]; then
    echo "SKIP: $OUTPUT existe deja"
    return
  fi
  
  ffmpeg -i "$INPUT" -c:v libaom-av1 -crf "$CRF" -b:v 0 -an -y "$OUTPUT" 2>/dev/null
  
  if [ -f "$OUTPUT" ]; then
    ORIG_SIZE=$(stat -f%z "$INPUT" 2>/dev/null || stat -c%s "$INPUT")
    NEW_SIZE=$(stat -f%z "$OUTPUT" 2>/dev/null || stat -c%s "$OUTPUT")
    PERCENT=$(( (ORIG_SIZE - NEW_SIZE) * 100 / ORIG_SIZE ))
    echo "AVIF: $OUTPUT — ${PERCENT}% plus leger"
  else
    echo "ERREUR: conversion AVIF echouee pour $INPUT"
  fi
}
```

### 5. PIPELINE COMPLET

Quand l'utilisateur demande le pipeline complet (`/imagify full <path>`) :

1. **Audit** : lister et analyser toutes les images
2. **Demander confirmation** a l'utilisateur avec l'estimation du quota
3. **Optimiser** chaque JPG/PNG via Imagify API (mode `aggressive` par defaut)
4. **Convertir en WebP** chaque image optimisee (qualite 82)
5. **Convertir en AVIF** chaque image optimisee (CRF 32)
6. **Rapport final** : tableau avant/apres avec gains par image et total

### 6. GENERER le .htaccess pour servir WebP/AVIF

Si le projet utilise Apache, generer les regles de rewrite :

```apache
# Servir WebP/AVIF si le navigateur les supporte
<IfModule mod_rewrite.c>
  RewriteEngine On
  
  # AVIF (priorite)
  RewriteCond %{HTTP_ACCEPT} image/avif
  RewriteCond %{REQUEST_FILENAME} \.(jpe?g|png)$
  RewriteCond %{REQUEST_FILENAME}.avif -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.avif [T=image/avif,L]
  
  # WebP (fallback)
  RewriteCond %{HTTP_ACCEPT} image/webp
  RewriteCond %{REQUEST_FILENAME} \.(jpe?g|png)$
  RewriteCond %{REQUEST_FILENAME}.webp -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.webp [T=image/webp,L]
</IfModule>

# Types MIME
<IfModule mod_mime.c>
  AddType image/webp .webp
  AddType image/avif .avif
</IfModule>
```

Note : cette approche garde le meme nom de fichier dans le HTML (`image.jpg`) et sert automatiquement la version WebP ou AVIF selon le navigateur. Pas besoin de modifier le HTML.

### 7. GENERER les balises `<picture>` (alternative)

Si le projet utilise des composants (Astro, React, etc.) :

```html
<picture>
  <source srcset="image.avif" type="image/avif">
  <source srcset="image.webp" type="image/webp">
  <img src="image.jpg" alt="Description" width="800" height="600" loading="lazy">
</picture>
```

## Regles importantes

- **TOUJOURS auditer avant d'optimiser** — presenter le rapport a l'utilisateur
- **TOUJOURS demander confirmation** avant de modifier des fichiers
- **TOUJOURS garder les originaux** sauf demande explicite de remplacement
- **Respecter le quota** : calculer la taille totale avant d'envoyer a Imagify
- **Limiter le debit** : max 2 requetes/seconde vers l'API Imagify
- **Verifier les prerequis** (cwebp, ffmpeg) avant de lancer les conversions
- La conversion AVIF est LENTE (~5-10s par image avec ffmpeg) — prevenir l'utilisateur
- Pour les PNG avec transparence, utiliser `cwebp -lossless` (pas `-q`)
