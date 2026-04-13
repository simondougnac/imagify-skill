#!/bin/bash
# =============================================================================
# imagify.sh — Optimisation d'images via API Imagify + WebP/AVIF local
# Usage: ./imagify.sh <command> <path> [options]
#
# Commands:
#   audit    <path>              Analyser les images sans modifier
#   optimize <path> [level]      Optimiser via Imagify (normal|aggressive|ultra)
#   webp     <path> [quality]    Convertir en WebP (qualite 0-100, defaut 82)
#   avif     <path> [crf]        Convertir en AVIF (CRF 20-50, defaut 32)
#   full     <path> [level]      Pipeline complet: optimize + webp + avif
#   quota                        Verifier le quota Imagify
#   htaccess <path>              Generer les regles .htaccess WebP/AVIF
# =============================================================================

set -euo pipefail

API_KEY="${IMAGIFY_API_KEY:-}"
API_URL="https://app.imagify.io/api"
DELAY=0.5  # secondes entre chaque requete API

# ── COULEURS ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── FONCTIONS UTILITAIRES ──

filesize() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f%z "$1" 2>/dev/null || echo 0
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

human_size() {
  local bytes=$1
  if (( bytes >= 1048576 )); then
    echo "$(( bytes / 1048576 )) Mo"
  elif (( bytes >= 1024 )); then
    echo "$(( bytes / 1024 )) Ko"
  else
    echo "${bytes} o"
  fi
}

find_images() {
  local path="$1"
  local types="${2:-jpg,jpeg,png,gif}"
  local find_args=""

  IFS=',' read -ra EXTS <<< "$types"
  for i in "${!EXTS[@]}"; do
    if [ "$i" -gt 0 ]; then find_args="$find_args -o"; fi
    find_args="$find_args -iname *.${EXTS[$i]}"
  done

  eval "find \"$path\" -type f \( $find_args \)" | sort
}

check_api_key() {
  if [ -z "$API_KEY" ]; then
    # Chercher dans .env
    if [ -f ".env" ] && grep -q "IMAGIFY_API_KEY" .env; then
      API_KEY=$(grep "IMAGIFY_API_KEY" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
  fi

  if [ -z "$API_KEY" ]; then
    echo -e "${RED}ERREUR: Cle API Imagify manquante${NC}"
    echo "Definir via: export IMAGIFY_API_KEY=votre_cle"
    echo "Ou ajouter IMAGIFY_API_KEY=votre_cle dans .env"
    exit 1
  fi
}

check_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1 || missing+=("jq")

  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}ERREUR: Dependances manquantes: ${missing[*]}${NC}"
    exit 1
  fi
}

# ── AUDIT ──

cmd_audit() {
  local path="${1:-.}"

  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║         AUDIT IMAGES — IMAGIFY           ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "Dossier: ${BLUE}$path${NC}"
  echo ""

  # Compter par format
  local jpg_count=$(find "$path" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
  local png_count=$(find "$path" -type f -iname "*.png" | wc -l | tr -d ' ')
  local gif_count=$(find "$path" -type f -iname "*.gif" | wc -l | tr -d ' ')
  local webp_count=$(find "$path" -type f -iname "*.webp" | wc -l | tr -d ' ')
  local avif_count=$(find "$path" -type f -iname "*.avif" | wc -l | tr -d ' ')
  local svg_count=$(find "$path" -type f -iname "*.svg" | wc -l | tr -d ' ')
  local total=$(( jpg_count + png_count + gif_count ))

  echo -e "${BLUE}Format       Nombre${NC}"
  echo "─────────────────────"
  echo -e "JPG/JPEG     ${jpg_count}"
  echo -e "PNG          ${png_count}"
  echo -e "GIF          ${gif_count}"
  echo -e "WebP         ${webp_count}"
  echo -e "AVIF         ${avif_count}"
  echo -e "SVG          ${svg_count}"
  echo "─────────────────────"
  echo -e "${YELLOW}Optimisables ${total}${NC}"
  echo ""

  # Taille totale des optimisables
  local total_bytes=0
  while IFS= read -r img; do
    local size=$(filesize "$img")
    total_bytes=$(( total_bytes + size ))
  done < <(find_images "$path")

  echo -e "Taille totale optimisable: ${YELLOW}$(human_size $total_bytes)${NC}"
  echo -e "Quota Imagify necessaire:  ${YELLOW}$(human_size $total_bytes)${NC} (= taille originale)"
  echo ""

  # Images > 500 Ko (prioritaires)
  echo -e "${RED}Images > 500 Ko (prioritaires) :${NC}"
  local big_count=0
  while IFS= read -r img; do
    local size=$(filesize "$img")
    if (( size > 512000 )); then
      big_count=$(( big_count + 1 ))
      echo -e "  ${RED}$(human_size $size)${NC}  $img"
    fi
  done < <(find_images "$path")

  if [ "$big_count" -eq 0 ]; then
    echo -e "  ${GREEN}Aucune image > 500 Ko${NC}"
  fi
  echo ""

  # Images sans WebP
  local missing_webp=0
  while IFS= read -r img; do
    local webp_path="${img%.*}.webp"
    if [ ! -f "$webp_path" ]; then
      missing_webp=$(( missing_webp + 1 ))
    fi
  done < <(find_images "$path")

  echo -e "Images sans WebP:  ${YELLOW}${missing_webp}${NC} / ${total}"

  # Images sans AVIF
  local missing_avif=0
  while IFS= read -r img; do
    local avif_path="${img%.*}.avif"
    if [ ! -f "$avif_path" ]; then
      missing_avif=$(( missing_avif + 1 ))
    fi
  done < <(find_images "$path")

  echo -e "Images sans AVIF:  ${YELLOW}${missing_avif}${NC} / ${total}"
  echo ""

  # Verifier les outils disponibles
  echo -e "${BLUE}Outils disponibles :${NC}"
  command -v cwebp >/dev/null 2>&1 && echo -e "  ${GREEN}cwebp${NC}  — conversion WebP" || echo -e "  ${RED}cwebp${NC}  — MANQUANT (brew install webp)"
  command -v ffmpeg >/dev/null 2>&1 && echo -e "  ${GREEN}ffmpeg${NC} — conversion AVIF" || echo -e "  ${RED}ffmpeg${NC} — MANQUANT (brew install ffmpeg)"
  command -v jq >/dev/null 2>&1 && echo -e "  ${GREEN}jq${NC}     — parsing JSON" || echo -e "  ${RED}jq${NC}     — MANQUANT (brew install jq)"
  echo ""
}

# ── OPTIMIZE (Imagify API) ──

cmd_optimize() {
  local path="${1:-.}"
  local level="${2:-aggressive}"

  check_api_key
  check_deps

  case "$level" in
    normal)     DATA='{"normal":true,"keep_exif":false}' ;;
    aggressive) DATA='{"aggressive":true,"keep_exif":false}' ;;
    ultra)      DATA='{"ultra":true,"keep_exif":false}' ;;
    *)
      echo -e "${RED}Niveau invalide: $level (normal|aggressive|ultra)${NC}"
      exit 1
      ;;
  esac

  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║      OPTIMISATION IMAGIFY — ${level}      ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then
    images=("$path")
  else
    while IFS= read -r img; do
      images+=("$img")
    done < <(find_images "$path")
  fi

  local count=${#images[@]}
  echo -e "Images a optimiser: ${YELLOW}${count}${NC}"
  echo ""

  local total_original=0
  local total_optimized=0
  local success=0
  local skipped=0
  local errors=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local original_size=$(filesize "$img")
    total_original=$(( total_original + original_size ))

    printf "[%d/%d] %s (%s) ... " "$num" "$count" "$(basename "$img")" "$(human_size $original_size)"

    # Appel API
    RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL/upload/" \
      -H "Authorization: token $API_KEY" \
      -F "image=@$img" \
      -F "data=$DATA" 2>/dev/null)

    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "200" ]; then
      OPTIMIZED_URL=$(echo "$BODY" | jq -r '.image')
      PERCENT=$(echo "$BODY" | jq -r '.percent')
      NEW_SIZE=$(echo "$BODY" | jq -r '.new_size')

      # Telecharger l'image optimisee
      curl -s "$OPTIMIZED_URL" -o "$img"

      total_optimized=$(( total_optimized + NEW_SIZE ))
      success=$(( success + 1 ))
      echo -e "${GREEN}-${PERCENT}% ($(human_size $NEW_SIZE))${NC}"
    elif [ "$HTTP_CODE" = "422" ]; then
      total_optimized=$(( total_optimized + original_size ))
      skipped=$(( skipped + 1 ))
      echo -e "${YELLOW}deja optimisee${NC}"
    elif [ "$HTTP_CODE" = "402" ]; then
      echo -e "${RED}QUOTA DEPASSE${NC}"
      echo -e "${RED}Arret de l'optimisation. ${success} images traitees sur ${count}.${NC}"
      break
    else
      total_optimized=$(( total_optimized + original_size ))
      errors=$(( errors + 1 ))
      echo -e "${RED}erreur ${HTTP_CODE}${NC}"
    fi

    sleep "$DELAY"
  done

  echo ""
  echo -e "${BLUE}═══ RAPPORT ═══${NC}"
  echo -e "  Reussies:  ${GREEN}${success}${NC}"
  echo -e "  Ignorees:  ${YELLOW}${skipped}${NC}"
  echo -e "  Erreurs:   ${RED}${errors}${NC}"

  if [ "$total_original" -gt 0 ]; then
    local saved=$(( total_original - total_optimized ))
    local pct=$(( saved * 100 / total_original ))
    echo ""
    echo -e "  Avant:  $(human_size $total_original)"
    echo -e "  Apres:  $(human_size $total_optimized)"
    echo -e "  Gain:   ${GREEN}$(human_size $saved) (-${pct}%)${NC}"
  fi
  echo ""
}

# ── WEBP ──

cmd_webp() {
  local path="${1:-.}"
  local quality="${2:-82}"

  if ! command -v cwebp >/dev/null 2>&1; then
    echo -e "${RED}ERREUR: cwebp non installe. Installer avec: brew install webp${NC}"
    exit 1
  fi

  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       CONVERSION WEBP (q=${quality})            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then
    images=("$path")
  else
    while IFS= read -r img; do
      images+=("$img")
    done < <(find_images "$path")
  fi

  local count=${#images[@]}
  local converted=0
  local skipped=0
  local total_saved=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local output="${img%.*}.webp"

    if [ -f "$output" ]; then
      skipped=$(( skipped + 1 ))
      printf "[%d/%d] %s — ${YELLOW}existe deja${NC}\n" "$num" "$count" "$(basename "$output")"
      continue
    fi

    local orig_size=$(filesize "$img")

    # PNG avec transparence → lossless
    local ext="${img##*.}"
    local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" == "png" ]]; then
      cwebp -lossless -mt -metadata none "$img" -o "$output" 2>/dev/null
    else
      cwebp -q "$quality" -mt -metadata none "$img" -o "$output" 2>/dev/null
    fi

    if [ -f "$output" ]; then
      local new_size=$(filesize "$output")
      local saved=$(( orig_size - new_size ))
      local pct=$(( saved * 100 / orig_size ))
      total_saved=$(( total_saved + saved ))
      converted=$(( converted + 1 ))
      printf "[%d/%d] %s — ${GREEN}-${pct}%% (%s → %s)${NC}\n" "$num" "$count" "$(basename "$output")" "$(human_size $orig_size)" "$(human_size $new_size)"
    else
      printf "[%d/%d] %s — ${RED}echec${NC}\n" "$num" "$count" "$(basename "$img")"
    fi
  done

  echo ""
  echo -e "${BLUE}═══ RAPPORT WEBP ═══${NC}"
  echo -e "  Converties: ${GREEN}${converted}${NC}"
  echo -e "  Ignorees:   ${YELLOW}${skipped}${NC}"
  echo -e "  Gain total: ${GREEN}$(human_size $total_saved)${NC}"
  echo ""
}

# ── AVIF ──

cmd_avif() {
  local path="${1:-.}"
  local crf="${2:-32}"

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${RED}ERREUR: ffmpeg non installe. Installer avec: brew install ffmpeg${NC}"
    exit 1
  fi

  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║       CONVERSION AVIF (crf=${crf})           ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo -e "${YELLOW}Note: la conversion AVIF est lente (~5-10s par image)${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then
    images=("$path")
  else
    while IFS= read -r img; do
      images+=("$img")
    done < <(find_images "$path")
  fi

  local count=${#images[@]}
  local converted=0
  local skipped=0
  local total_saved=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local output="${img%.*}.avif"

    if [ -f "$output" ]; then
      skipped=$(( skipped + 1 ))
      printf "[%d/%d] %s — ${YELLOW}existe deja${NC}\n" "$num" "$count" "$(basename "$output")"
      continue
    fi

    local orig_size=$(filesize "$img")

    printf "[%d/%d] %s ... " "$num" "$count" "$(basename "$img")"

    ffmpeg -i "$img" -c:v libsvtav1 -crf "$crf" -preset 6 -an -y "$output" 2>/dev/null

    if [ -f "$output" ]; then
      local new_size=$(filesize "$output")
      local saved=$(( orig_size - new_size ))
      local pct=$(( saved * 100 / orig_size ))
      total_saved=$(( total_saved + saved ))
      converted=$(( converted + 1 ))
      echo -e "${GREEN}-${pct}% ($(human_size $orig_size) → $(human_size $new_size))${NC}"
    else
      echo -e "${RED}echec${NC}"
    fi
  done

  echo ""
  echo -e "${BLUE}═══ RAPPORT AVIF ═══${NC}"
  echo -e "  Converties: ${GREEN}${converted}${NC}"
  echo -e "  Ignorees:   ${YELLOW}${skipped}${NC}"
  echo -e "  Gain total: ${GREEN}$(human_size $total_saved)${NC}"
  echo ""
}

# ── FULL PIPELINE ──

cmd_full() {
  local path="${1:-.}"
  local level="${2:-aggressive}"

  echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     PIPELINE COMPLET — IMAGIFY + W/A     ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  cmd_audit "$path"

  echo -e "${YELLOW}Lancer l'optimisation complete ? (o/N)${NC}"
  read -r confirm
  if [[ "$confirm" != "o" && "$confirm" != "O" && "$confirm" != "oui" ]]; then
    echo "Annule."
    exit 0
  fi

  echo ""
  echo -e "${BLUE}━━━ ETAPE 1/3 : Compression Imagify (${level}) ━━━${NC}"
  cmd_optimize "$path" "$level"

  echo -e "${BLUE}━━━ ETAPE 2/3 : Conversion WebP ━━━${NC}"
  cmd_webp "$path"

  echo -e "${BLUE}━━━ ETAPE 3/3 : Conversion AVIF ━━━${NC}"
  cmd_avif "$path"

  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         PIPELINE TERMINE                  ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
}

# ── QUOTA ──

cmd_quota() {
  check_api_key
  check_deps

  echo -e "${CYAN}Verification du quota Imagify...${NC}"

  # L'API n'a pas d'endpoint quota documente, on fait un test avec une image minimale
  # On cree un pixel PNG temporaire
  local tmp=$(mktemp /tmp/imagify-test-XXXXXX.png)
  printf '\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90\x77\x53\xde\x00\x00\x00\x0c\x49\x44\x41\x54\x08\xd7\x63\xf8\xcf\xc0\x00\x00\x00\x02\x00\x01\xe2\x21\xbc\x33\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82' > "$tmp"

  RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL/upload/" \
    -H "Authorization: token $API_KEY" \
    -F "image=@$tmp" \
    -F 'data={"normal":true}' 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  rm -f "$tmp"

  case "$HTTP_CODE" in
    200|422)
      echo -e "${GREEN}Cle API valide — quota disponible${NC}"
      ;;
    402)
      echo -e "${RED}Quota depasse — plus de credit disponible${NC}"
      ;;
    403)
      echo -e "${RED}Cle API invalide ou expiree${NC}"
      ;;
    *)
      echo -e "${YELLOW}Reponse inattendue: HTTP ${HTTP_CODE}${NC}"
      BODY=$(echo "$RESPONSE" | sed '$d')
      echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
      ;;
  esac
}

# ── HTACCESS ──

cmd_htaccess() {
  local path="${1:-.}"
  local output="$path/.htaccess-webp-avif"

  cat > "$output" << 'HTACCESS'
# ============================================
# WEBP / AVIF — Auto-serve par le navigateur
# Genere par imagify-skill
# ============================================

<IfModule mod_rewrite.c>
  RewriteEngine On

  # Servir AVIF si supporte (priorite haute)
  RewriteCond %{HTTP_ACCEPT} image/avif
  RewriteCond %{REQUEST_FILENAME} \.(jpe?g|png)$
  RewriteCond %{REQUEST_FILENAME}\.avif -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.$2.avif [T=image/avif,L]

  # Servir WebP si supporte (fallback)
  RewriteCond %{HTTP_ACCEPT} image/webp
  RewriteCond %{REQUEST_FILENAME} \.(jpe?g|png)$
  RewriteCond %{REQUEST_FILENAME}\.webp -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.$2.webp [T=image/webp,L]
</IfModule>

<IfModule mod_mime.c>
  AddType image/webp .webp
  AddType image/avif .avif
</IfModule>

# Vary header pour le cache CDN
<IfModule mod_headers.c>
  <FilesMatch "\.(jpe?g|png)$">
    Header append Vary Accept
  </FilesMatch>
</IfModule>
HTACCESS

  echo -e "${GREEN}Genere: ${output}${NC}"
  echo "Ajouter le contenu a votre .htaccess principal ou l'inclure."
}

# ── MAIN ──

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
  audit)    cmd_audit "$@" ;;
  optimize) cmd_optimize "$@" ;;
  webp)     cmd_webp "$@" ;;
  avif)     cmd_avif "$@" ;;
  full)     cmd_full "$@" ;;
  quota)    cmd_quota ;;
  htaccess) cmd_htaccess "$@" ;;
  help|--help|-h)
    echo "Usage: imagify.sh <command> <path> [options]"
    echo ""
    echo "Commands:"
    echo "  audit    <path>            Analyser les images"
    echo "  optimize <path> [level]    Optimiser via Imagify (normal|aggressive|ultra)"
    echo "  webp     <path> [quality]  Convertir en WebP (defaut: 82)"
    echo "  avif     <path> [crf]      Convertir en AVIF (defaut: 32)"
    echo "  full     <path> [level]    Pipeline complet"
    echo "  quota                      Verifier le quota"
    echo "  htaccess <path>            Generer les regles Apache"
    echo ""
    echo "Variables d'environnement:"
    echo "  IMAGIFY_API_KEY            Cle API Imagify"
    ;;
  *)
    echo -e "${RED}Commande inconnue: $COMMAND${NC}"
    echo "Utiliser: imagify.sh help"
    exit 1
    ;;
esac
