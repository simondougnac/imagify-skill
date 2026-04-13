#!/bin/bash
# =============================================================================
# imagify.sh v2 — Optimisation d'images via API Imagify + WebP/AVIF local
# =============================================================================
#
# Commands:
#   audit     <path>                    Analyser les images sans modifier
#   optimize  <path> [level]            Optimiser via Imagify (normal|aggressive|ultra)
#   webp      <path> [quality]          Convertir en WebP (0-100, defaut 82)
#   avif      <path> [crf]              Convertir en AVIF (20-50, defaut 32)
#   full      <path> [level]            Pipeline complet: optimize + webp + avif
#   resize    <path> [max_width]        Redimensionner les images > max_width (defaut 1920)
#   picture   <path>                    Generer les balises <picture> HTML
#   htaccess  <path>                    Generer les regles .htaccess WebP/AVIF
#   clean     <path>                    Supprimer tous les WebP/AVIF generes
#   restore   <path>                    Restaurer les originaux depuis le backup
#   quota                               Verifier le quota Imagify
#
# Options globales:
#   --dry-run         Simuler sans modifier
#   --no-backup       Ne pas sauvegarder les originaux
#   --max-width=N     Redimensionner si largeur > N px (defaut: desactive)
#   --report=FILE     Exporter le rapport en JSON
#   --exclude=PATTERN Exclure les fichiers matchant le pattern
# =============================================================================

set -euo pipefail

API_KEY="${IMAGIFY_API_KEY:-}"
API_URL="https://app.imagify.io/api"
DELAY=0.5
DRY_RUN=false
NO_BACKUP=false
MAX_WIDTH=0
REPORT_FILE=""
EXCLUDE_PATTERN=""
BACKUP_DIR=""

# ── COULEURS ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── REPORT DATA ──
declare -a REPORT_ENTRIES=()

# ── PARSE OPTIONS ──
POSITIONAL_ARGS=()
parse_options() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run)      DRY_RUN=true ;;
      --no-backup)    NO_BACKUP=true ;;
      --max-width=*)  MAX_WIDTH="${arg#*=}" ;;
      --report=*)     REPORT_FILE="${arg#*=}" ;;
      --exclude=*)    EXCLUDE_PATTERN="${arg#*=}" ;;
      *)              POSITIONAL_ARGS+=("$arg") ;;
    esac
  done
}

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
    printf "%.1f Mo" "$(echo "scale=1; $bytes / 1048576" | bc)"
  elif (( bytes >= 1024 )); then
    echo "$(( bytes / 1024 )) Ko"
  else
    echo "${bytes} o"
  fi
}

# Detecter si un PNG a de la transparence (canal alpha)
has_transparency() {
  local file="$1"
  local ext="${file##*.}"
  local ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  if [[ "$ext_lower" != "png" ]]; then
    return 1  # pas un PNG → pas de transparence
  fi

  # Methode 1: sips (macOS)
  if command -v sips >/dev/null 2>&1; then
    local has_alpha=$(sips -g hasAlpha "$file" 2>/dev/null | grep -o "yes" || true)
    if [[ "$has_alpha" == "yes" ]]; then
      return 0  # a de la transparence
    fi
  fi

  # Methode 2: identify (ImageMagick)
  if command -v identify >/dev/null 2>&1; then
    local channels=$(identify -verbose "$file" 2>/dev/null | grep -c "Alpha" || true)
    if (( channels > 0 )); then
      return 0
    fi
  fi

  # Methode 3: file header — PNG avec type 4 ou 6 = alpha
  local color_type=$(xxd -s 25 -l 1 -p "$file" 2>/dev/null || true)
  if [[ "$color_type" == "04" || "$color_type" == "06" ]]; then
    return 0
  fi

  return 1  # pas de transparence detectee
}

# Obtenir les dimensions d'une image
get_dimensions() {
  local file="$1"
  if command -v sips >/dev/null 2>&1; then
    local w=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}')
    local h=$(sips -g pixelHeight "$file" 2>/dev/null | awk '/pixelHeight/{print $2}')
    echo "${w}x${h}"
  elif command -v identify >/dev/null 2>&1; then
    identify -format "%wx%h" "$file" 2>/dev/null
  else
    echo "?x?"
  fi
}

# Obtenir la largeur uniquement
get_width() {
  local file="$1"
  if command -v sips >/dev/null 2>&1; then
    sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/{print $2}'
  elif command -v identify >/dev/null 2>&1; then
    identify -format "%w" "$file" 2>/dev/null
  else
    echo "0"
  fi
}

find_images() {
  local path="$1"
  local types="${2:-jpg,jpeg,png,gif}"

  IFS=',' read -ra EXTS <<< "$types"
  local find_args=""
  for i in "${!EXTS[@]}"; do
    if [ "$i" -gt 0 ]; then find_args="$find_args -o"; fi
    find_args="$find_args -iname *.${EXTS[$i]}"
  done

  if [ -n "$EXCLUDE_PATTERN" ]; then
    eval "find \"$path\" -type f \( $find_args \)" | grep -v "$EXCLUDE_PATTERN" | sort
  else
    eval "find \"$path\" -type f \( $find_args \)" | sort
  fi
}

check_api_key() {
  if [ -z "$API_KEY" ]; then
    if [ -f ".env" ] && grep -q "IMAGIFY_API_KEY" .env; then
      API_KEY=$(grep "IMAGIFY_API_KEY" .env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    fi
  fi
  if [ -z "$API_KEY" ]; then
    echo -e "${RED}ERREUR: Cle API Imagify manquante${NC}"
    echo "  export IMAGIFY_API_KEY=votre_cle"
    echo "  ou ajouter IMAGIFY_API_KEY=votre_cle dans .env"
    exit 1
  fi
}

check_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v jq >/dev/null 2>&1 || missing+=("jq (brew install jq)")
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}ERREUR: Dependances manquantes: ${missing[*]}${NC}"
    exit 1
  fi
}

# Creer un backup de l'image avant modification
backup_image() {
  local file="$1"
  if $NO_BACKUP; then return; fi

  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$(dirname "$file")/.imagify-backup-$(date +%Y%m%d_%H%M%S)"
  fi

  local rel_path="${file#*/}"
  local backup_path="$BACKUP_DIR/$rel_path"
  mkdir -p "$(dirname "$backup_path")"

  if [ ! -f "$backup_path" ]; then
    cp "$file" "$backup_path"
  fi
}

# Ajouter une entree au rapport
add_report() {
  local file="$1" action="$2" original_size="$3" new_size="$4" format="$5" status="$6"
  REPORT_ENTRIES+=("{\"file\":\"$file\",\"action\":\"$action\",\"original_size\":$original_size,\"new_size\":$new_size,\"format\":\"$format\",\"status\":\"$status\"}")
}

# Ecrire le rapport JSON
write_report() {
  if [ -z "$REPORT_FILE" ]; then return; fi

  local total_original=0 total_new=0
  echo "[" > "$REPORT_FILE"
  for i in "${!REPORT_ENTRIES[@]}"; do
    if [ "$i" -gt 0 ]; then echo "," >> "$REPORT_FILE"; fi
    echo "  ${REPORT_ENTRIES[$i]}" >> "$REPORT_FILE"
  done
  echo "]" >> "$REPORT_FILE"
  echo -e "${GREEN}Rapport exporte: ${REPORT_FILE}${NC}"
}

# ── AUDIT ──

cmd_audit() {
  local path="${1:-.}"

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║          AUDIT IMAGES — IMAGIFY v2           ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Dossier: ${BLUE}$path${NC}"
  echo ""

  # Compter par format
  local jpg_count=$(find "$path" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | wc -l | tr -d ' ')
  local png_count=$(find "$path" -type f -iname "*.png" | wc -l | tr -d ' ')
  local gif_count=$(find "$path" -type f -iname "*.gif" | wc -l | tr -d ' ')
  local webp_count=$(find "$path" -type f -iname "*.webp" | wc -l | tr -d ' ')
  local avif_count=$(find "$path" -type f -iname "*.avif" | wc -l | tr -d ' ')
  local svg_count=$(find "$path" -type f -iname "*.svg" | wc -l | tr -d ' ')
  local total=$(( jpg_count + png_count + gif_count ))

  echo -e "  ${BOLD}Format       Nombre${NC}"
  echo -e "  ─────────────────────"
  echo -e "  JPG/JPEG     ${jpg_count}"
  echo -e "  PNG          ${png_count}"
  echo -e "  GIF          ${gif_count}"
  echo -e "  WebP         ${webp_count}"
  echo -e "  AVIF         ${avif_count}"
  echo -e "  SVG          ${svg_count} ${DIM}(non optimisable)${NC}"
  echo -e "  ─────────────────────"
  echo -e "  ${YELLOW}Optimisables ${total}${NC}"
  echo ""

  # Taille totale
  local total_bytes=0
  while IFS= read -r img; do
    total_bytes=$(( total_bytes + $(filesize "$img") ))
  done < <(find_images "$path")

  echo -e "  Taille totale: ${YELLOW}$(human_size $total_bytes)${NC}"
  echo -e "  Quota Imagify: ${YELLOW}$(human_size $total_bytes)${NC} (= taille originale)"
  echo ""

  # PNG avec transparence
  echo -e "  ${BOLD}PNG avec transparence (a NE PAS envoyer a Imagify) :${NC}"
  local transparent_count=0
  while IFS= read -r img; do
    if has_transparency "$img"; then
      transparent_count=$(( transparent_count + 1 ))
      local dim=$(get_dimensions "$img")
      echo -e "    ${YELLOW}⚠${NC}  $(basename "$img") ${DIM}(${dim}, $(human_size $(filesize "$img")))${NC}"
    fi
  done < <(find "$path" -type f -iname "*.png" | sort)
  if [ "$transparent_count" -eq 0 ]; then
    echo -e "    ${GREEN}Aucun PNG transparent${NC}"
  fi
  echo ""

  # Images > 500 Ko
  echo -e "  ${BOLD}Images > 500 Ko (prioritaires) :${NC}"
  local big_count=0
  while IFS= read -r img; do
    local size=$(filesize "$img")
    if (( size > 512000 )); then
      big_count=$(( big_count + 1 ))
      local dim=$(get_dimensions "$img")
      echo -e "    ${RED}●${NC}  $(human_size $size)  ${dim}  $(basename "$img")"
    fi
  done < <(find_images "$path")
  if [ "$big_count" -eq 0 ]; then
    echo -e "    ${GREEN}Aucune${NC}"
  fi
  echo ""

  # Images trop larges (> 1920px)
  echo -e "  ${BOLD}Images > 1920px de large (a redimensionner) :${NC}"
  local oversized=0
  while IFS= read -r img; do
    local w=$(get_width "$img")
    if [ -n "$w" ] && [ "$w" != "?" ] && (( w > 1920 )); then
      oversized=$(( oversized + 1 ))
      echo -e "    ${YELLOW}●${NC}  ${w}px  $(basename "$img")"
    fi
  done < <(find_images "$path")
  if [ "$oversized" -eq 0 ]; then
    echo -e "    ${GREEN}Aucune${NC}"
  fi
  echo ""

  # WebP/AVIF manquants
  local missing_webp=0 missing_avif=0
  while IFS= read -r img; do
    [ ! -f "${img%.*}.webp" ] && missing_webp=$(( missing_webp + 1 ))
    [ ! -f "${img%.*}.avif" ] && missing_avif=$(( missing_avif + 1 ))
  done < <(find_images "$path")

  echo -e "  ${BOLD}Couverture formats :${NC}"
  echo -e "    WebP:  $(( total - missing_webp ))/${total} ${DIM}(${missing_webp} manquants)${NC}"
  echo -e "    AVIF:  $(( total - missing_avif ))/${total} ${DIM}(${missing_avif} manquants)${NC}"
  echo ""

  # Outils
  echo -e "  ${BOLD}Outils :${NC}"
  command -v cwebp >/dev/null 2>&1 && echo -e "    ${GREEN}✓${NC} cwebp" || echo -e "    ${RED}✗${NC} cwebp ${DIM}(brew install webp)${NC}"
  command -v ffmpeg >/dev/null 2>&1 && echo -e "    ${GREEN}✓${NC} ffmpeg" || echo -e "    ${RED}✗${NC} ffmpeg ${DIM}(brew install ffmpeg)${NC}"
  command -v jq >/dev/null 2>&1 && echo -e "    ${GREEN}✓${NC} jq" || echo -e "    ${RED}✗${NC} jq ${DIM}(brew install jq)${NC}"
  command -v sips >/dev/null 2>&1 && echo -e "    ${GREEN}✓${NC} sips" || echo -e "    ${DIM}  sips (macOS only)${NC}"
  echo ""

  $DRY_RUN && echo -e "  ${DIM}Mode dry-run actif${NC}"
}

# ── RESIZE ──

cmd_resize() {
  local path="${1:-.}"
  local max_w="${2:-1920}"

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║       RESIZE (max ${max_w}px)                     ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local resized=0 skipped=0
  while IFS= read -r img; do
    local w=$(get_width "$img")
    if [ -z "$w" ] || [ "$w" = "?" ] || (( w <= max_w )); then
      skipped=$(( skipped + 1 ))
      continue
    fi

    local orig_size=$(filesize "$img")
    printf "  %s (%spx → %spx) ... " "$(basename "$img")" "$w" "$max_w"

    if $DRY_RUN; then
      echo -e "${YELLOW}dry-run${NC}"
      continue
    fi

    backup_image "$img"

    if command -v sips >/dev/null 2>&1; then
      sips --resampleWidth "$max_w" "$img" --out "$img" >/dev/null 2>&1
    elif command -v convert >/dev/null 2>&1; then
      convert "$img" -resize "${max_w}x>" "$img"
    else
      echo -e "${RED}pas d'outil de resize${NC}"
      continue
    fi

    local new_size=$(filesize "$img")
    local saved=$(( orig_size - new_size ))
    local pct=$(( saved * 100 / orig_size ))
    resized=$(( resized + 1 ))
    echo -e "${GREEN}-${pct}% ($(human_size $new_size))${NC}"
    add_report "$img" "resize" "$orig_size" "$new_size" "original" "ok"
  done < <(find_images "$path")

  echo ""
  echo -e "  Redimensionnees: ${GREEN}${resized}${NC}  Ignorees: ${DIM}${skipped}${NC}"
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
    *) echo -e "${RED}Niveau invalide: $level${NC}"; exit 1 ;;
  esac

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║     OPTIMISATION IMAGIFY — ${level}            ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then
    images=("$path")
  else
    while IFS= read -r img; do images+=("$img"); done < <(find_images "$path")
  fi

  local count=${#images[@]}
  echo -e "  Images: ${YELLOW}${count}${NC}"
  echo ""

  local total_original=0 total_optimized=0 success=0 skipped=0 errors=0 transparent_skipped=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local original_size=$(filesize "$img")
    total_original=$(( total_original + original_size ))

    # Detecter PNG transparent → skip Imagify
    if has_transparency "$img"; then
      transparent_skipped=$(( transparent_skipped + 1 ))
      total_optimized=$(( total_optimized + original_size ))
      printf "  [%d/%d] %-40s ${YELLOW}PNG transparent — skip Imagify${NC}\n" "$num" "$count" "$(basename "$img")"
      add_report "$img" "optimize" "$original_size" "$original_size" "png-alpha" "skipped"
      continue
    fi

    printf "  [%d/%d] %-40s %s ... " "$num" "$count" "$(basename "$img")" "$(human_size $original_size)"

    if $DRY_RUN; then
      total_optimized=$(( total_optimized + original_size ))
      echo -e "${YELLOW}dry-run${NC}"
      continue
    fi

    backup_image "$img"

    # Resize avant envoi si --max-width actif
    if (( MAX_WIDTH > 0 )); then
      local w=$(get_width "$img")
      if [ -n "$w" ] && [ "$w" != "?" ] && (( w > MAX_WIDTH )); then
        if command -v sips >/dev/null 2>&1; then
          sips --resampleWidth "$MAX_WIDTH" "$img" --out "$img" >/dev/null 2>&1
        fi
      fi
    fi

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

      curl -s "$OPTIMIZED_URL" -o "$img"
      total_optimized=$(( total_optimized + NEW_SIZE ))
      success=$(( success + 1 ))
      echo -e "${GREEN}-${PERCENT}% ($(human_size $NEW_SIZE))${NC}"
      add_report "$img" "optimize" "$original_size" "$NEW_SIZE" "imagify-$level" "ok"
    elif [ "$HTTP_CODE" = "422" ]; then
      total_optimized=$(( total_optimized + original_size ))
      skipped=$(( skipped + 1 ))
      echo -e "${DIM}deja optimisee${NC}"
      add_report "$img" "optimize" "$original_size" "$original_size" "imagify" "already-optimized"
    elif [ "$HTTP_CODE" = "402" ]; then
      echo -e "${RED}QUOTA DEPASSE${NC}"
      echo -e "  ${RED}Arret. ${success} images traitees sur ${count}.${NC}"
      add_report "$img" "optimize" "$original_size" "$original_size" "imagify" "over-quota"
      break
    else
      total_optimized=$(( total_optimized + original_size ))
      errors=$(( errors + 1 ))
      echo -e "${RED}erreur ${HTTP_CODE}${NC}"
      add_report "$img" "optimize" "$original_size" "$original_size" "imagify" "error-$HTTP_CODE"
    fi

    sleep "$DELAY"
  done

  echo ""
  echo -e "  ${BOLD}Rapport :${NC}"
  echo -e "    Optimisees:       ${GREEN}${success}${NC}"
  [ "$transparent_skipped" -gt 0 ] && echo -e "    PNG transparents: ${YELLOW}${transparent_skipped}${NC} ${DIM}(exclus d'Imagify)${NC}"
  [ "$skipped" -gt 0 ] && echo -e "    Deja optimisees:  ${DIM}${skipped}${NC}"
  [ "$errors" -gt 0 ] && echo -e "    Erreurs:          ${RED}${errors}${NC}"

  if [ "$total_original" -gt 0 ]; then
    local saved=$(( total_original - total_optimized ))
    local pct=$(( saved * 100 / total_original ))
    echo ""
    echo -e "    Avant:  $(human_size $total_original)"
    echo -e "    Apres:  $(human_size $total_optimized)"
    echo -e "    ${BOLD}Gain:   ${GREEN}$(human_size $saved) (-${pct}%)${NC}"
  fi
  echo ""
}

# ── WEBP ──

cmd_webp() {
  local path="${1:-.}"
  local quality="${2:-82}"

  if ! command -v cwebp >/dev/null 2>&1; then
    echo -e "${RED}ERREUR: cwebp non installe (brew install webp)${NC}"; exit 1
  fi

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║          CONVERSION WEBP (q=${quality})              ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then images=("$path")
  else while IFS= read -r img; do images+=("$img"); done < <(find_images "$path"); fi

  local count=${#images[@]} converted=0 skipped=0 total_saved=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local output="${img%.*}.webp"

    if [ -f "$output" ]; then
      # Verifier si le WebP est plus recent que l'original
      if [ "$output" -nt "$img" ]; then
        skipped=$(( skipped + 1 ))
        continue
      fi
    fi

    local orig_size=$(filesize "$img")

    if $DRY_RUN; then
      printf "  [%d/%d] %-40s ${YELLOW}dry-run${NC}\n" "$num" "$count" "$(basename "${img%.*}.webp")"
      continue
    fi

    # PNG transparent → lossless pour preserver l'alpha
    local ext_lower=$(echo "${img##*.}" | tr '[:upper:]' '[:lower:]')
    if [[ "$ext_lower" == "png" ]] && has_transparency "$img"; then
      cwebp -lossless -mt -metadata none "$img" -o "$output" 2>/dev/null
    else
      cwebp -q "$quality" -mt -metadata none "$img" -o "$output" 2>/dev/null
    fi

    if [ -f "$output" ]; then
      local new_size=$(filesize "$output")
      # Si le WebP est plus gros que l'original, le supprimer
      if (( new_size >= orig_size )); then
        rm -f "$output"
        printf "  [%d/%d] %-40s ${DIM}WebP plus gros — ignore${NC}\n" "$num" "$count" "$(basename "$img")"
        add_report "$img" "webp" "$orig_size" "$orig_size" "webp" "larger-skipped"
        continue
      fi
      local saved=$(( orig_size - new_size ))
      local pct=$(( saved * 100 / orig_size ))
      total_saved=$(( total_saved + saved ))
      converted=$(( converted + 1 ))
      printf "  [%d/%d] %-40s ${GREEN}-${pct}%% (%s → %s)${NC}\n" "$num" "$count" "$(basename "$output")" "$(human_size $orig_size)" "$(human_size $new_size)"
      add_report "$img" "webp" "$orig_size" "$new_size" "webp" "ok"
    else
      printf "  [%d/%d] %-40s ${RED}echec${NC}\n" "$num" "$count" "$(basename "$img")"
    fi
  done

  echo ""
  echo -e "  Converties: ${GREEN}${converted}${NC}  Ignorees: ${DIM}${skipped}${NC}  Gain: ${GREEN}$(human_size $total_saved)${NC}"
  echo ""
}

# ── AVIF ──

cmd_avif() {
  local path="${1:-.}"
  local crf="${2:-32}"

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo -e "${RED}ERREUR: ffmpeg non installe (brew install ffmpeg)${NC}"; exit 1
  fi

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║          CONVERSION AVIF (crf=${crf})             ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  local images=()
  if [ -f "$path" ]; then images=("$path")
  else while IFS= read -r img; do images+=("$img"); done < <(find_images "$path"); fi

  local count=${#images[@]} converted=0 skipped=0 total_saved=0 alpha_skipped=0

  for i in "${!images[@]}"; do
    local img="${images[$i]}"
    local num=$(( i + 1 ))
    local output="${img%.*}.avif"

    # Skip PNG transparent → AVIF ne gere pas bien la transparence via libsvtav1
    if has_transparency "$img"; then
      alpha_skipped=$(( alpha_skipped + 1 ))
      printf "  [%d/%d] %-40s ${YELLOW}PNG transparent — skip AVIF${NC}\n" "$num" "$count" "$(basename "$img")"
      continue
    fi

    if [ -f "$output" ] && [ "$output" -nt "$img" ]; then
      skipped=$(( skipped + 1 ))
      continue
    fi

    local orig_size=$(filesize "$img")

    if $DRY_RUN; then
      printf "  [%d/%d] %-40s ${YELLOW}dry-run${NC}\n" "$num" "$count" "$(basename "${img%.*}.avif")"
      continue
    fi

    printf "  [%d/%d] %-40s " "$num" "$count" "$(basename "$img")"

    ffmpeg -i "$img" -c:v libsvtav1 -crf "$crf" -preset 6 -an -y "$output" 2>/dev/null

    if [ -f "$output" ]; then
      local new_size=$(filesize "$output")
      if (( new_size >= orig_size )); then
        rm -f "$output"
        echo -e "${DIM}AVIF plus gros — ignore${NC}"
        continue
      fi
      local saved=$(( orig_size - new_size ))
      local pct=$(( saved * 100 / orig_size ))
      total_saved=$(( total_saved + saved ))
      converted=$(( converted + 1 ))
      echo -e "${GREEN}-${pct}% ($(human_size $orig_size) → $(human_size $new_size))${NC}"
      add_report "$img" "avif" "$orig_size" "$new_size" "avif" "ok"
    else
      echo -e "${RED}echec${NC}"
    fi
  done

  echo ""
  echo -e "  Converties: ${GREEN}${converted}${NC}  Ignorees: ${DIM}${skipped}${NC}  Alpha skip: ${YELLOW}${alpha_skipped}${NC}  Gain: ${GREEN}$(human_size $total_saved)${NC}"
  echo ""
}

# ── FULL PIPELINE ──

cmd_full() {
  local path="${1:-.}"
  local level="${2:-aggressive}"

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║       PIPELINE COMPLET — IMAGIFY v2          ║${NC}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""

  cmd_audit "$path"

  if ! $DRY_RUN; then
    echo -e "  ${YELLOW}Lancer l'optimisation complete ? (o/N)${NC}"
    read -r confirm
    if [[ "$confirm" != "o" && "$confirm" != "O" && "$confirm" != "oui" ]]; then
      echo "  Annule."; exit 0
    fi
  fi

  echo ""

  # Etape 0: Resize si --max-width
  if (( MAX_WIDTH > 0 )); then
    echo -e "  ${BOLD}━━━ ETAPE 0/3 : Resize (max ${MAX_WIDTH}px) ━━━${NC}"
    cmd_resize "$path" "$MAX_WIDTH"
  fi

  echo -e "  ${BOLD}━━━ ETAPE 1/3 : Compression Imagify (${level}) ━━━${NC}"
  cmd_optimize "$path" "$level"

  echo -e "  ${BOLD}━━━ ETAPE 2/3 : Conversion WebP ━━━${NC}"
  cmd_webp "$path"

  echo -e "  ${BOLD}━━━ ETAPE 3/3 : Conversion AVIF ━━━${NC}"
  cmd_avif "$path"

  write_report

  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║            PIPELINE TERMINE                   ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
}

# ── PICTURE TAGS ──

cmd_picture() {
  local path="${1:-.}"

  echo -e "${CYAN}${BOLD}Balises <picture> generees :${NC}"
  echo ""

  while IFS= read -r img; do
    local base="${img%.*}"
    local ext="${img##*.}"
    local name=$(basename "$base")
    local dir=$(dirname "$img")
    local rel="${img}"  # chemin relatif

    local dim=$(get_dimensions "$img")
    local w=$(echo "$dim" | cut -d'x' -f1)
    local h=$(echo "$dim" | cut -d'x' -f2)

    echo "<picture>"
    [ -f "${base}.avif" ] && echo "  <source srcset=\"${base}.avif\" type=\"image/avif\">"
    [ -f "${base}.webp" ] && echo "  <source srcset=\"${base}.webp\" type=\"image/webp\">"
    echo "  <img src=\"${rel}\" alt=\"\" width=\"${w}\" height=\"${h}\" loading=\"lazy\">"
    echo "</picture>"
    echo ""
  done < <(find_images "$path")
}

# ── HTACCESS ──

cmd_htaccess() {
  local path="${1:-.}"
  local output="$path/.htaccess-webp-avif"

  cat > "$output" << 'HTACCESS'
# ============================================
# WEBP / AVIF — Auto-serve (imagify-skill v2)
# ============================================

<IfModule mod_rewrite.c>
  RewriteEngine On

  # AVIF (priorite)
  RewriteCond %{HTTP_ACCEPT} image/avif
  RewriteCond %{DOCUMENT_ROOT}/$1.avif -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.avif [T=image/avif,L]

  # WebP (fallback)
  RewriteCond %{HTTP_ACCEPT} image/webp
  RewriteCond %{DOCUMENT_ROOT}/$1.webp -f
  RewriteRule ^(.+)\.(jpe?g|png)$ $1.webp [T=image/webp,L]
</IfModule>

<IfModule mod_mime.c>
  AddType image/webp .webp
  AddType image/avif .avif
</IfModule>

<IfModule mod_headers.c>
  <FilesMatch "\.(jpe?g|png)$">
    Header append Vary Accept
  </FilesMatch>
</IfModule>
HTACCESS

  echo -e "${GREEN}Genere: ${output}${NC}"
}

# ── CLEAN ──

cmd_clean() {
  local path="${1:-.}"

  local webp_count=$(find "$path" -type f -iname "*.webp" | wc -l | tr -d ' ')
  local avif_count=$(find "$path" -type f -iname "*.avif" | wc -l | tr -d ' ')

  echo -e "  Fichiers a supprimer: ${YELLOW}${webp_count} WebP + ${avif_count} AVIF${NC}"

  if $DRY_RUN; then
    echo -e "  ${YELLOW}dry-run — rien supprime${NC}"
    return
  fi

  echo -e "  ${YELLOW}Confirmer la suppression ? (o/N)${NC}"
  read -r confirm
  if [[ "$confirm" != "o" && "$confirm" != "O" ]]; then
    echo "  Annule."; return
  fi

  find "$path" -type f \( -iname "*.webp" -o -iname "*.avif" \) -delete
  echo -e "  ${GREEN}Supprime: ${webp_count} WebP + ${avif_count} AVIF${NC}"
}

# ── RESTORE ──

cmd_restore() {
  local path="${1:-.}"

  local backup=$(find "$path" -maxdepth 1 -type d -name ".imagify-backup-*" | sort -r | head -1)
  if [ -z "$backup" ]; then
    echo -e "${RED}Aucun backup trouve dans ${path}${NC}"
    exit 1
  fi

  echo -e "  Backup trouve: ${BLUE}${backup}${NC}"
  local file_count=$(find "$backup" -type f | wc -l | tr -d ' ')
  echo -e "  Fichiers: ${YELLOW}${file_count}${NC}"

  if $DRY_RUN; then
    echo -e "  ${YELLOW}dry-run — rien restaure${NC}"
    return
  fi

  echo -e "  ${YELLOW}Restaurer les originaux ? (o/N)${NC}"
  read -r confirm
  if [[ "$confirm" != "o" && "$confirm" != "O" ]]; then
    echo "  Annule."; return
  fi

  cp -r "$backup"/* "$path"/
  echo -e "  ${GREEN}${file_count} fichiers restaures${NC}"
}

# ── QUOTA ──

cmd_quota() {
  check_api_key
  check_deps

  echo -e "  Verification quota Imagify..."

  # Test avec une petite image valide
  local tmp=$(mktemp /tmp/imagify-test-XXXXXX.jpg)
  # Creer un JPEG minimal valide (1x1 pixel rouge)
  printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a\x1f\x1e\x1d\x1a\x1c\x1c $.\x27 ",#\x1c\x1c(7),01444\x1f\x27444444444444\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\xff\xda\x00\x08\x01\x01\x00\x00?\x00T\xdb\x9e\xa7\xff\xd9' > "$tmp"

  RESPONSE=$(curl -s -w "\n%{http_code}" "$API_URL/upload/" \
    -H "Authorization: token $API_KEY" \
    -F "image=@$tmp" \
    -F 'data={"normal":true}' 2>/dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  rm -f "$tmp"

  case "$HTTP_CODE" in
    200|422) echo -e "  ${GREEN}✓ Cle valide — quota disponible${NC}" ;;
    402)     echo -e "  ${RED}✗ Quota depasse${NC}" ;;
    403)     echo -e "  ${RED}✗ Cle API invalide ou expiree${NC}" ;;
    *)       echo -e "  ${YELLOW}? Reponse HTTP ${HTTP_CODE}${NC}" ;;
  esac
}

# ── MAIN ──

COMMAND="${1:-help}"
shift 2>/dev/null || true

# Parse options et recuperer les arguments positionnels
parse_options "$@"
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

case "$COMMAND" in
  audit)    cmd_audit "$@" ;;
  optimize) cmd_optimize "$@" ;;
  webp)     cmd_webp "$@" ;;
  avif)     cmd_avif "$@" ;;
  full)     cmd_full "$@" ;;
  resize)   cmd_resize "$@" ;;
  picture)  cmd_picture "$@" ;;
  htaccess) cmd_htaccess "$@" ;;
  clean)    cmd_clean "$@" ;;
  restore)  cmd_restore "$@" ;;
  quota)    cmd_quota ;;
  help|--help|-h)
    echo -e "${BOLD}imagify.sh v2${NC} — Optimisation d'images"
    echo ""
    echo -e "${BOLD}Usage:${NC} imagify.sh <command> <path> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  audit     <path>              Analyser les images"
    echo "  optimize  <path> [level]      Compresser via Imagify (normal|aggressive|ultra)"
    echo "  webp      <path> [quality]    Convertir en WebP (defaut: 82)"
    echo "  avif      <path> [crf]        Convertir en AVIF (defaut: 32)"
    echo "  full      <path> [level]      Pipeline complet (optimize + webp + avif)"
    echo "  resize    <path> [max_width]  Redimensionner (defaut: 1920px)"
    echo "  picture   <path>              Generer balises <picture> HTML"
    echo "  htaccess  <path>              Generer regles Apache WebP/AVIF"
    echo "  clean     <path>              Supprimer WebP/AVIF generes"
    echo "  restore   <path>              Restaurer originaux depuis backup"
    echo "  quota                         Verifier quota Imagify"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --dry-run           Simuler sans modifier"
    echo "  --no-backup         Ne pas sauvegarder les originaux"
    echo "  --max-width=N       Resize avant optimisation (px)"
    echo "  --report=FILE       Exporter rapport JSON"
    echo "  --exclude=PATTERN   Exclure fichiers (grep pattern)"
    echo ""
    echo -e "${BOLD}Env:${NC}"
    echo "  IMAGIFY_API_KEY     Cle API Imagify"
    ;;
  *)
    echo -e "${RED}Commande inconnue: $COMMAND${NC}"
    echo "Utiliser: imagify.sh help"
    exit 1
    ;;
esac

write_report 2>/dev/null || true
