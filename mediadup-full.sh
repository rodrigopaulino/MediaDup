#!/usr/bin/env bash
# mediadup-full.sh
# Complete metadata-insensitive media deduper + comparator + TUI + dashboard
#
# Features:
#  - Normalize & hash images (png/gif/jpg/jpeg), DNG (raw), videos (mp4/mov)
#  - Use exiftool, dcraw, ffmpeg, imagemagick compare
#  - SQLite cache keyed by path+mtime+size
#  - Parallel worker pool (GNU parallel if available, fallback xargs -P)
#  - find-duplicates subcommand with actions: print|hardlink|symlink|move|none
#  - compare & compare-pixels & hash single file
#  - mediadup tui: interactive menu (dialog + fzf)
#  - Dashboard: htop-like live refresh (reads state files written by scans)
#  - Themes: Solarized/Dracula/Nord/Classic (saved at ~/.config/mediadup/theme.conf)
#
# Usage:
#   ./mediadup-full.sh find-duplicates /path [--cache-db path] [--jobs N] [--action print|hardlink|symlink|move|none] [--trash-dir path]
#   ./mediadup-full.sh compare file1 file2
#   ./mediadup-full.sh compare-pixels file1 file2
#   ./mediadup-full.sh hash file
#   ./mediadup-full.sh tui
#
# NOTE: destructive actions (hardlink/symlink/move) modify files. Use --action print first.
set -euo pipefail
IFS=$'\n\t'

PROG="$(basename "$0")"
HOME_CONFIG="${HOME}/.config/mediadup"
CACHE_DIR="${HOME}/.cache/mediadup"
DEFAULT_CACHE_DB="${HOME}/.mediadup_cache.db"

mkdir -p "$HOME_CONFIG" "$CACHE_DIR"

# ---------------------------
# Utilities
# ---------------------------
err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }
which_or_warn() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing: $1"
    return 1
  fi
  return 0
}
cpu_count() {
  if command -v nproc >/dev/null 2>&1; then nproc; elif command -v sysctl >/dev/null 2>&1; sysctl -n hw.ncpu; else echo 1; fi
}

# ---------------------------
# Theme handling
# ---------------------------
THEME_CONF="${HOME_CONFIG}/theme.conf"
default_theme() {
  cat > "$THEME_CONF" <<'EOF'
name=Solarized
bg=#002b36
text=#93a1a1
highlight=#268bd2
accent=#b58900
warn=#cb4b16
EOF
}
if [ ! -f "$THEME_CONF" ]; then default_theme; fi
load_theme() {
  # Export simple color vars (terminal color codes will be approximated)
  name=$(awk -F= '/^name=/ {print $2}' "$THEME_CONF")
  THEME_NAME="$name"
}
load_theme

# ---------------------------
# Normalization & hashing helpers
# ---------------------------
ext() { echo "${1##*.}" | tr '[:upper:]' '[:lower:]'; }

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else openssl dgst -sha256 "$1" | awk '{print $2}'; fi
}

normalize_raster() {
  # args: infile outfile
  local infile="$1"; local outfile="$2"
  if command -v exiftool >/dev/null 2>&1; then
    exiftool -q -q -all= -o "$outfile" "$infile"
  else
    # fallback copy (no metadata stripping)
    cp "$infile" "$outfile"
  fi
}

normalize_dng_raw() {
  # extract pure linear raw sensor data
  local infile="$1"; local outfile="$2"
  if command -v dcraw >/dev/null 2>&1; then
    dcraw -4 -D -c "$infile" > "$outfile"
  else
    # fallback: copy (less reliable)
    cp "$infile" "$outfile"
  fi
}

normalize_video_streams() {
  # args: infile outprefix
  local infile="$1"; local out="$2"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -y -v error -i "$infile" -map 0:v:0 -c copy "${out}_video.bin" 2>/dev/null || true
    ffmpeg -y -v error -i "$infile" -map 0:a:0 -c copy "${out}_audio.bin" 2>/dev/null || true
  else
    # fallback copy
    cp "$infile" "${out}_container.bin"
  fi
}

compute_normalized_hash() {
  # prints a single-line hash for a file (or special tag)
  local file="$1"
  if [ ! -f "$file" ]; then echo "__MISSING__"; return 1; fi
  local e=$(ext "$file")
  local tmpd
  tmpd=$(mktemp -d "${CACHE_DIR}/tmp.XXXX")
  trap 'rm -rf "$tmpd"' RETURN

  case "$e" in
    png|gif|jpg|jpeg)
      normalize_raster "$file" "$tmpd/norm.img"
      hash_file "$tmpd/norm.img"
      ;;
    dng)
      normalize_dng_raw "$file" "$tmpd/norm.raw"
      hash_file "$tmpd/norm.raw"
      ;;
    mp4|mov)
      normalize_video_streams "$file" "$tmpd/stream"
      if [ -f "$tmpd/stream_video.bin" ]; then
        hv=$(hash_file "$tmpd/stream_video.bin")
      else hv="NOVIDEO"; fi
      if [ -f "$tmpd/stream_audio.bin" ]; then
        ha=$(hash_file "$tmpd/stream_audio.bin")
      else ha="NOAUDIO"; fi
      echo "${hv}-${ha}"
      ;;
    *)
      echo "__UNSUPPORTED__"
      ;;
  esac
}

# ---------------------------
# Cache (sqlite) helpers
# ---------------------------
init_cache_db() {
  local db="$1"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    return 1
  fi
  sqlite3 "$db" <<'SQL' >/dev/null 2>&1 || true
BEGIN;
CREATE TABLE IF NOT EXISTS filehash (
  path TEXT PRIMARY KEY,
  mtime INTEGER,
  size INTEGER,
  hash TEXT,
  updated_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_mtime_size ON filehash(mtime,size);
COMMIT;
SQL
}

get_cached_hash() {
  local db="$1"; local path="$2"; local mtime="$3"; local size="$4"
  if command -v sqlite3 >/dev/null 2>&1 && [ -f "$db" ]; then
    sqlite3 "$db" "SELECT hash FROM filehash WHERE path = $(printf '%q' "$path") AND mtime = $mtime AND size = $size LIMIT 1;"
  fi
}

store_cached_hash() {
  local db="$1"; local path="$2"; local mtime="$3"; local size="$4"; local hash="$5"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$db" <<SQL 2>/dev/null || true
INSERT OR REPLACE INTO filehash(path, mtime, size, hash, updated_at)
VALUES($(printf '%q' "$path"), $mtime, $size, $(printf '%q' "$hash"), strftime('%s','now'));
SQL
  fi
}

# ---------------------------
# Worker (invoked as subcommand 'worker')
# ---------------------------
worker_main() {
  # args: cache_db file
  local cache_db="$1"; local file="$2"
  if [ ! -f "$file" ]; then echo "__MISSING__|$file"; exit 0; fi
  local size mtime
  if stat --version >/dev/null 2>&1; then
    size=$(stat -c%s "$file"); mtime=$(stat -c%Y "$file")
  else
    size=$(stat -f%z "$file"); mtime=$(stat -f%m "$file")
  fi

  # attempt cache lookup
  if [ -n "$cache_db" ] && [ -f "$cache_db" ]; then
    cached=$(get_cached_hash "$cache_db" "$file" "$mtime" "$size")
    if [ -n "$cached" ]; then
      echo "$cached|$file"; exit 0
    fi
  fi

  local result
  result=$(compute_normalized_hash "$file" 2>/dev/null) || result="__ERR__"
  if [ -n "$result" ] && [ "$result" != "__ERR__" ]; then
    # store
    if [ -n "$cache_db" ]; then
      store_cached_hash "$cache_db" "$file" "$mtime" "$size" "$result" || true
    fi
  fi

  echo "$result|$file"
  exit 0
}

# ---------------------------
# Find duplicates (main)
# ---------------------------
find_duplicates_main() {
  local root="$1"
  local cache_db="${CACHE_DB:-$DEFAULT_CACHE_DB}"
  local jobs="${JOBS:-$(cpu_count)}"
  local action="${ACTION:-print}"
  local trashdir="${TRASH_DIR:-${HOME}/.Trash/mediadup}"
  local use_pv="${USE_PV:-0}"

  mkdir -p "$trashdir"
  init_cache_db "$cache_db" || true

  info "Scanning for media under: $root"
  # build list
  mapfile -t files < <(find "$root" -xdev -type f \( -iname "*.png" -o -iname "*.gif" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.dng" -o -iname "*.mp4" -o -iname "*.mov" \) -print 2>/dev/null)
  local total=${#files[@]}
  if [ "$total" -eq 0 ]; then info "No media files found."; return 0; fi
  info "Found $total media files. Starting hashing with $jobs jobs..."

  # prepare temp and output
  local global_tmp
  global_tmp=$(mktemp -d "${CACHE_DIR}/global.XXXX")
  local output="${global_tmp}/hashes.txt"; : > "$output"

  if command -v parallel >/dev/null 2>&1; then
    # use GNU parallel
    printf "%s\n" "${files[@]}" | parallel --jobs "$jobs" --bar --line-buffer "$(readlink -f "$0")" worker "$cache_db" {} > "$output"
  else
    # fallback xargs -P
    if command -v pv >/dev/null 2>&1 && [ "$use_pv" -eq 1 ]; then
      printf "%s\n" "${files[@]}" | pv -N files -s "$total" -l | xargs -I{} -n1 -P "$jobs" bash -c "$(readlink -f "$0") worker \"$cache_db\" \"{}\"" >> "$output"
    else
      printf "%s\n" "${files[@]}" | xargs -I{} -n1 -P "$jobs" bash -c "$(readlink -f "$0") worker \"$cache_db\" \"{}\"" >> "$output"
    fi
  fi

  # Build groups
  declare -A groups
  while IFS= read -r line; do
    hashpart="${line%%|*}"
    path="${line#*|}"
    case "$hashpart" in
      __ERR__|__MISSING__|__UNSUPPORTED__|NOVIDEO-NOAUDIO) continue ;;
    esac

    if [ -z "${groups[$hashpart]+set}" ]; then
      groups["$hashpart"]="$path"
    else
      groups["$hashpart"]+=$'\n'"$path"
    fi
  done < "$output"

  # Save a JSON-ish results file for dashboard/TUI
  local results_json="${CACHE_DIR}/last_scan.json"
  echo "[]" > "$results_json"
  local group_count=0
  local total_reclaim=0

  for h in "${!groups[@]}"; do
    # split into array
    IFS=$'\n' read -rd '' -a arr <<< "${groups[$h]}"
    if [ "${#arr[@]}" -gt 1 ]; then
      group_count=$((group_count+1))
      # estimate reclaimable size: sum sizes except first
      keep="${arr[0]}"
      size_reclaim_group=0
      for ((i=1;i<${#arr[@]};i++)); do
        p="${arr[$i]}"
        s=0
        if [ -f "$p" ]; then
          if stat --version >/dev/null 2>&1; then s=$(stat -c%s "$p"); else s=$(stat -f%z "$p"); fi
        fi
        size_reclaim_group=$((size_reclaim_group + s))
      done
      total_reclaim=$((total_reclaim + size_reclaim_group))

      # print group
      echo
      echo "=== Duplicate group (hash: $h) ==="
      for p in "${arr[@]}"; do echo "  $p"; done

      # perform action
      case "$action" in
        print)
          echo "Suggestion: keep '${arr[0]}', consider replacing others."
          ;;
        hardlink)
          base="${arr[0]}"
          for ((i=1;i<${#arr[@]};i++)); do
            dup="${arr[$i]}"
            if [ -f "$dup" ]; then
              rm -f "$dup" && ln "$base" "$dup" && echo "Hardlinked $dup -> $base" || err "Failed to hardlink $dup"
            fi
          done
          ;;
        symlink)
          base="${arr[0]}"
          for ((i=1;i<${#arr[@]};i++)); do
            dup="${arr[$i]}"
            if [ -f "$dup" ]; then
              mv "$dup" "${dup}.mediadup.bak" && ln -s "$base" "$dup" && rm -f "${dup}.mediadup.bak" && echo "Symlinked $dup -> $base" || err "Failed symlink $dup"
            fi
          done
          ;;
        move)
          base="${arr[0]}"
          mkdir -p "$trashdir"
          for ((i=1;i<${#arr[@]};i++)); do
            dup="${arr[$i]}"
            if [ -f "$dup" ]; then
              mv "$dup" "$trashdir/" && echo "Moved $dup -> $trashdir/" || err "Failed move $dup"
            fi
          done
          ;;
        none) ;;
        *)
          err "Unknown action: $action"
          ;;
      esac

      # append to results_json: simple line-oriented JSON array
      # we append manual JSON chunk
      if jq -c --arg h "$h" --argjson cnt "${#arr[@]}" --arg keep "${arr[0]}" --argfile files <(printf '%s\n' "${arr[@]}" | jq -R . | jq -s .) \
        '. + [ {hash:$h, count:$cnt, keep:$keep, files:$files} ]' "$results_json" > "${results_json}.tmp"; then
        mv "${results_json}.tmp" "$results_json"
      else
        log_msg="$(date +'%Y-%m-%d %H:%M:%S')\tFailed to update $results_json for hash $h"
        err "$log_msg"
        printf '%s\n' "$log_msg" >> "${CACHE_DIR}/activity.log" || true
        rm -f "${results_json}.tmp" || true
      fi
    fi
  done

  # runtime summary
  echo
  echo "Scan complete: found $group_count duplicate groups"
  reclaim_human=$(numfmt --to=iec --suffix=B "$total_reclaim" 2>/dev/null || echo "${total_reclaim} bytes")
  echo "Estimated recoverable: $reclaim_human"
  # write stats file for dashboard
  cat > "${CACHE_DIR}/stats.json" <<EOF
{
  "pending": 0,
  "active": 0,
  "total": $total,
  "duplicate_groups": $group_count,
  "space_reclaimable_bytes": $total_reclaim
}
EOF
}

# ---------------------------
# pixel diff (ImageMagick compare)
# ---------------------------
compare_pixels_cmd() {
  local f1="$1" f2="$2"
  local tmp1 tmp2
  tmp1=$(mktemp "${CACHE_DIR}/p1.XXXX") ; tmp2=$(mktemp "${CACHE_DIR}/p2.XXXX")
  normalize_raster "$f1" "$tmp1"
  normalize_raster "$f2" "$tmp2"
  if command -v compare >/dev/null 2>&1; then
    out=$(compare -metric RMSE "$tmp1" "$tmp2" null: 2>&1) || true
    echo "RMSE = $out (0 = identical)"
  else
    err "ImageMagick 'compare' not found."
    return 2
  fi
  rm -f "$tmp1" "$tmp2"
}

# ---------------------------
# TUI (dialog + fzf) and Dashboard (simple ncurses-like)
# ---------------------------
tui_main() {
  # ensure dialog and fzf
  if ! command -v dialog >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1; then
    err "TUI requires 'dialog' and 'fzf'. Please install them."
    exit 2
  fi

  while true; do
    CHOICE=$(dialog --clear --stdout --title "MediaDup TUI" --menu "Choose an action" 20 70 10 \
      1 "Compare two files (metadata-insensitive)" \
      2 "Compare images (pixel diff)" \
      3 "Compute normalized hash" \
      4 "Scan folder for duplicates" \
      5 "View last scan results" \
      6 "Dashboard (live)" \
      7 "Settings: theme" \
      8 "Exit")
    case "$CHOICE" in
      1) ui_compare ;;
      2) ui_compare_pixels ;;
      3) ui_hash ;;
      4) ui_scan ;;
      5) ui_view_results ;;
      6) ui_dashboard ;;
      7) ui_theme_choice ;;
      8) clear; exit 0 ;;
      *) break ;;
    esac
  done
}

pick_file_fzf() {
  local start="${1:-.}"
  local pick
  pick=$(find "$start" -type f 2>/dev/null | fzf --height=40% --preview 'file --mime {} 2>/dev/null' --border --prompt="Select file: ")
  echo "$pick"
}

# shared compare helper for CLI and TUI (prints into provided var names)
compare_hashes_cmd() {
  local f1="$1" f2="$2" out_h1="$3" out_h2="$4"
  local h1 h2
  h1=$(compute_normalized_hash "$f1") || return $?
  h2=$(compute_normalized_hash "$f2") || return $?
  if [ -n "$out_h1" ]; then printf -v "$out_h1" '%s' "$h1"; fi
  if [ -n "$out_h2" ]; then printf -v "$out_h2" '%s' "$h2"; fi
  if [ "$h1" = "$h2" ]; then
    return 0
  fi
  return 1
}

ui_compare() {
  local f1 f2 h1 h2 rc
  f1=$(pick_file_fzf "$PWD") || return
  f2=$(pick_file_fzf "$PWD") || return
  dialog --infobox "Normalizing and comparing..." 5 50
  if compare_hashes_cmd "$f1" "$f2" h1 h2; then
    dialog --msgbox "Files are identical (ignoring metadata)\n\nHash: $h1" 10 60
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      dialog --msgbox "Files differ (ignoring metadata)\n\n$h1\n$h2" 12 70
    else
      dialog --msgbox "Comparison failed (exit $rc)" 8 50
      return $rc
    fi
  fi
}

ui_compare_pixels() {
  local f1 f2
  f1=$(pick_file_fzf "$PWD") || return
  f2=$(pick_file_fzf "$PWD") || return
  dialog --infobox "Computing pixel difference..." 4 50
  out=$(compare_pixels_cmd "$f1" "$f2" 2>&1) || true
  dialog --msgbox "$out" 10 70
}

ui_hash() {
  local f
  f=$(pick_file_fzf "$PWD") || return
  dialog --infobox "Computing normalized hash..." 4 50
  out=$(compute_normalized_hash "$f" 2>&1)
  dialog --msgbox "Hash:\n$out" 8 70
}

ui_scan() {
  local dir
  dir=$(dialog --stdout --dselect "$PWD/" 20 60) || return
  # ask options
  local jobs action trash
  jobs=$(dialog --stdout --inputbox "Parallel jobs (CPU count default)" 8 40 "$(cpu_count)") || return
  action=$(dialog --stdout --menu "Action after finding duplicates" 10 60 5 \
    print "Print suggestions (safe)" \
    hardlink "Replace duplicates with hardlinks" \
    symlink "Replace duplicates with symlinks" \
    move "Move duplicates to trash dir" \
    none "No action (just list)") || return
  trash=$(dialog --stdout --inputbox "Trash dir (when action=move)" 8 60 "${HOME}/.Trash/mediadup") || return

  # run scan (write stats.json to cache)
  dialog --infobox "Running scan (this may take a while)..." 5 50
  # set globals
  CACHE_DB="${DEFAULT_CACHE_DB}"
  JOBS="$jobs"
  ACTION="$action"
  TRASH_DIR="$trash"
  USE_PV=0
  # call scan (in foreground)
  "$0" find-duplicates "$dir" --cache-db "$CACHE_DB" --jobs "$JOBS" --action "$ACTION" --trash-dir "$TRASH_DIR" | tee "${CACHE_DIR}/last_scan_output.txt"
  dialog --msgbox "Scan finished. Results saved to ${CACHE_DIR}/last_scan.json and last_scan_output.txt" 10 60
}

ui_view_results() {
  if [ ! -f "${CACHE_DIR}/last_scan.json" ]; then
    dialog --msgbox "No previous scan results found." 8 40; return
  fi
  dialog --textbox "${CACHE_DIR}/last_scan_output.txt" 30 80
}

ui_theme_choice() {
  CHOICE=$(dialog --colors --stdout --menu "Pick theme" 18 78 6 \
    Solarized "\Z6Calm text\Z0  \Z4highlight\Z0  \Z3accent\Z0" \
    Dracula "\Z7Midnight text\Z0  \Z2neon highlight\Z0  \Z5magenta pop\Z0" \
    Nord "\Z7Fjord text\Z0  \Z6frost highlight\Z0  \Z2moss accent\Z0" \
    Classic "\Z2Retro console\Z0  \Zb\Z2bright prompt\Z0  \Z3amber warn\Z0" \
    Reset "\Z7Reset to default palette\Z0")
  case "$CHOICE" in
    Solarized)
      cat > "$THEME_CONF" <<'EOF'
name=Solarized
bg=#002b36
text=#93a1a1
highlight=#268bd2
accent=#b58900
warn=#cb4b16
EOF
      ;;
    Dracula)
      cat > "$THEME_CONF" <<'EOF'
name=Dracula
bg=#282a36
text=#f8f8f2
highlight=#50fa7b
accent=#ff79c6
warn=#ff5555
EOF
      ;;
    Nord)
      cat > "$THEME_CONF" <<'EOF'
name=Nord
bg=#2e3440
text=#d8dee9
highlight=#88c0d0
accent=#a3be8c
warn=#bf616a
EOF
      ;;
    Classic)
      cat > "$THEME_CONF" <<'EOF'
name=Classic
bg=black
text=green
highlight=brightgreen
accent=yellow
warn=red
EOF
      ;;
    Reset)
      default_theme
      ;;
  esac
  load_theme
  dialog --msgbox "Theme set to $(awk -F= '/^name=/ {print $2}' $THEME_CONF)" 6 40
}

# ---------------------------
# Dashboard (htop-like)
# ---------------------------
ui_dashboard() {
  # minimal ncurses-like live view
  while true; do
    clear
    load_theme
    echo -e "\e[1;36mMEDIA DUPLICATION DASHBOARD — Theme: $THEME_NAME\e[0m"
    echo "────────────────────────────────────────────────────────────────"
    # system stats
    if [ -f /proc/stat ]; then
      # compute simple CPU usage snapshot
      cpu_line1=$(awk '/^cpu /{print $0}' /proc/stat)
      sleep 0.5
      cpu_line2=$(awk '/^cpu /{print $0}' /proc/stat)
      read -r _ a1 b1 c1 d1 e1 _ <<<"$cpu_line1"
      read -r _ a2 b2 c2 d2 e2 _ <<<"$cpu_line2"
      idle1=$d1; idle2=$d2
      total1=$((a1+b1+c1+d1+e1)); total2=$((a2+b2+c2+d2+e2))
      cpu_usage=$((100*( (total2-total1) - (idle2-idle1) ) / (total2-total1) ))
    else
      cpu_usage=0
    fi
    mem_info=$(free -m | awk '/Mem/ {printf "%s/%s MB", $3,$2}')
    echo "CPU: ${cpu_usage}%   MEM: ${mem_info}"
    # mediadup stats.json
    if [ -f "${CACHE_DIR}/stats.json" ]; then
      pending=$(jq -r '.pending // 0' "${CACHE_DIR}/stats.json")
      active=$(jq -r '.active // 0' "${CACHE_DIR}/stats.json")
      total_files=$(jq -r '.total // 0' "${CACHE_DIR}/stats.json")
      dup_groups=$(jq -r '.duplicate_groups // 0' "${CACHE_DIR}/stats.json")
      reclaim_bytes=$(jq -r '.space_reclaimable_bytes // 0' "${CACHE_DIR}/stats.json")
    else
      pending=0; active=0; total_files=0; dup_groups=0; reclaim_bytes=0
    fi
    reclaim_h=$(numfmt --to=iec --suffix=B "$reclaim_bytes" 2>/dev/null || echo "${reclaim_bytes}B")
    echo "Queue: ${pending} pending  | Workers: ${active} active  | Total scanned: ${total_files}"
    echo "Duplicate groups: ${dup_groups}  | Recoverable: ${reclaim_h}"
    echo "────────────────────────────────────────────────────────────────"
    echo "Recent activity:"
    if [ -f "${CACHE_DIR}/activity.log" ]; then
      tail -n 8 "${CACHE_DIR}/activity.log" || true
    else
      echo "(no activity logged yet)"
    fi
    echo "────────────────────────────────────────────────────────────────"
    echo "Press Q to quit, R to refresh, S to open TUI menu"
    # non-blocking read
    read -t 1 -n 1 k || k=''
    case "$k" in
      q|Q) clear; return ;;
      r|R) continue ;;
      s|S) tui_main; return ;;
    esac
  done
}

# ---------------------------
# Command dispatch
# ---------------------------
if [ $# -lt 1 ]; then
  cat <<EOF
$PROG — media dedupe tool (complete)
Usage:
  $PROG find-duplicates <path> [--cache-db PATH] [--jobs N] [--action print|hardlink|symlink|move|none] [--trash-dir PATH]
  $PROG compare <file1> <file2>
  $PROG compare-pixels <file1> <file2>
  $PROG hash <file>
  $PROG tui
  $PROG worker <cache_db> <file>   # internal (used by parallel)
EOF
  exit 1
fi

cmd="$1"; shift

case "$cmd" in
  worker)
    worker_main "$@"
    ;;

  find-duplicates)
    # parse options
    if [ $# -lt 1 ]; then err "path missing"; exit 2; fi
    ROOT="$1"; shift
    # defaults
    CACHE_DB="$DEFAULT_CACHE_DB"
    JOBS="$(cpu_count)"
    ACTION="print"
    TRASH_DIR="${HOME}/.Trash/mediadup"
    USE_PV=0
    # parse optional flags
    while [ $# -gt 0 ]; do
      case "$1" in
        --cache-db) CACHE_DB="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        --trash-dir) TRASH_DIR="$2"; shift 2 ;;
        --use-pv) USE_PV="$2"; shift 2 ;;
        *) err "Unknown option: $1"; exit 2 ;;
      esac
    done
    find_duplicates_main "$ROOT"
    ;;

  compare)
    if [ $# -ne 2 ]; then err "compare needs two filenames"; exit 2; fi
    h1=""; h2=""
    if compare_hashes_cmd "$1" "$2" h1 h2; then
      echo "IDENTICAL (ignoring metadata) — $h1"
      exit 0
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then
        echo "DIFFER — $h1 vs $h2"
        exit 1
      else
        err "Comparison failed (exit $rc)"
        exit "$rc"
      fi
    fi
    ;;

  compare-pixels)
    if [ $# -ne 2 ]; then err "compare-pixels needs two images"; exit 2; fi
    compare_pixels_cmd "$1" "$2"
    ;;

  hash)
    if [ $# -ne 1 ]; then err "hash needs a file"; exit 2; fi
    compute_normalized_hash "$1"
    ;;

  tui)
    tui_main
    ;;

  *)
    err "Unknown command: $cmd"
    exit 2
    ;;
esac

# End of mediadup-full.sh
