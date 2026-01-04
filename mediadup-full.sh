#!/usr/bin/env bash
# mediadup-full.sh
# Complete metadata-insensitive media deduper + comparator
#
# Features:
#  - Normalize & hash images (png/gif/jpg/jpeg), DNG (raw), videos (mp4/mov)
#  - Use exiftool, dcraw, ffmpeg, imagemagick compare
#  - SQLite cache keyed by path+mtime+size
#  - Parallel worker pool
#  - find-duplicates subcommand with actions: print|hardlink|symlink|move|none
#  - compare & compare-pixels & hash single file
#
# Usage:
#   ./mediadup-full.sh find-duplicates /path [--cache-db path] [--jobs N] [--action print|hardlink|symlink|move|none] [--trash-dir path]
#   ./mediadup-full.sh compare file1 file2
#   ./mediadup-full.sh compare-pixels file1 file2
#   ./mediadup-full.sh hash file
# NOTE: destructive actions (hardlink/symlink/move) modify files. Use --action print first.
set -euo pipefail
IFS=$'\n\t'

PROG="$(basename "$0")"
CACHE_DIR="${HOME}/.cache/mediadup"
DEFAULT_CACHE_DB="${HOME}/.mediadup_cache.db"
SKIPPED_LOG="${CACHE_DIR}/skipped_inputs.log"
DEBUG="${MEDIADUP_DEBUG:-0}"
LAST_NORMALIZER_ERR=""

mkdir -p "$CACHE_DIR"

# ---------------------------
# Utilities
# ---------------------------
err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }
cpu_count() { sysctl -n hw.ncpu; }
format_debug_payload() {
  printf "%s" "$*" | tr '\n\r\t' '   '
}

log_skipped_input() {
  # reason, path, [detail]
  local reason="$1"; local path="$2"; local extra="${3:-}"
  local stamp
  stamp="$(date +'%Y-%m-%d %H:%M:%S')"
  if [ "$DEBUG" -eq 1 ] && [ -n "$extra" ]; then
    local cleaned
    cleaned=$(format_debug_payload "$extra")
    printf "%s\t%s\t%s\t%s\n" "$stamp" "$reason" "$path" "$cleaned" >> "$SKIPPED_LOG"
  else
    printf "%s\t%s\t%s\n" "$stamp" "$reason" "$path" >> "$SKIPPED_LOG"
  fi
}
abs_path() {
  local target="$1";
  (cd "$target" >/dev/null 2>&1 && pwd)
}
progress_tick() {
  local current="$1"; local total="$2"; local label="$3"
  local width=${#total}
  if [ "$width" -lt 1 ]; then width=1; fi
  printf "\r%s (%*d/%d)" "$label" "$width" "$current" "$total" >&2
}

# ---------------------------
# Dependency checks
# ---------------------------
REQUIRED_CMDS=(exiftool dcraw ffmpeg sqlite3 parallel jq compare)
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING_CMDS+=("$cmd")
  fi
done
if [ "${#MISSING_CMDS[@]}" -gt 0 ]; then
  err "Missing required commands: ${MISSING_CMDS[*]}"
  exit 1
fi

# ---------------------------
# Cache (sqlite) helpers
# ---------------------------
init_cache_db() {
  local db="$1"
  sqlite3 "$db" <<'SQL' >/dev/null 2>&1 || true
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
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
  if [ -f "$db" ]; then
    local path_sql
    path_sql=$(printf "%s" "$path" | sed "s/'/''/g")
    sqlite3 -cmd ".timeout 5000" "$db" "SELECT hash FROM filehash WHERE path = '$path_sql' AND mtime = $mtime AND size = $size LIMIT 1;"
  fi
}

store_cached_hash() {
  local db="$1"; local path="$2"; local mtime="$3"; local size="$4"; local hash="$5"
  local path_sql hash_sql
  path_sql=$(printf "%s" "$path" | sed "s/'/''/g")
  hash_sql=$(printf "%s" "$hash" | sed "s/'/''/g")
  sqlite3 -cmd ".timeout 5000" "$db" "INSERT OR REPLACE INTO filehash(path, mtime, size, hash, updated_at) VALUES('$path_sql', $mtime, $size, '$hash_sql', strftime('%s','now'));" 2>/dev/null || true
}

# ---------------------------
# Normalization & hashing helpers
# ---------------------------
ext() { echo "${1##*.}" | tr '[:upper:]' '[:lower:]'; }

hash_file() {
  openssl dgst -sha256 "$1" | awk '{print $2}'
}

normalize_raster() {
  # args: infile outfile
  local infile="$1"; local outfile="$2"
  LAST_NORMALIZER_ERR=""
  local err_file err_msgs=()

  err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
  if exiftool -q -q -all= -o "$outfile" "$infile" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi
  err_msgs+=("exiftool:$(format_debug_payload "$(cat "$err_file")")")
  rm -f "$err_file"

  # Some assets are mislabeled (extension ≠ file signature). Try ImageMagick
  # to sniff the true format and re-emit metadata-free bytes.
  local magick_cmd=""; local -a identify_cmd=()
  if command -v magick >/dev/null 2>&1; then
    magick_cmd="magick"
    identify_cmd=(magick identify)
  elif command -v convert >/dev/null 2>&1; then
    magick_cmd="convert"
    if command -v identify >/dev/null 2>&1; then
      identify_cmd=(identify)
    fi
  fi

  if [ -n "$magick_cmd" ]; then
    local detected_fmt="" fmt_lower=""
    if [ ${#identify_cmd[@]} -gt 0 ]; then
      err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
      if detected_fmt=$("${identify_cmd[@]}" -quiet -format '%m' "$infile[0]" 2>"$err_file"); then
        fmt_lower=$(printf '%s' "$detected_fmt" | tr '[:upper:]' '[:lower:]')
      else
        err_msgs+=("identify:$(format_debug_payload "$(cat "$err_file")")")
      fi
      rm -f "$err_file"
    fi

    if [ -n "$fmt_lower" ]; then
      err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
      if "$magick_cmd" "$infile[0]" -strip "${fmt_lower}:$outfile" 2>"$err_file"; then
        rm -f "$err_file"
        return 0
      fi
      err_msgs+=("${magick_cmd}:${fmt_lower}:$(format_debug_payload "$(cat "$err_file")")")
      rm -f "$err_file"
    fi

    err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
    if "$magick_cmd" "$infile[0]" -strip png:"$outfile" 2>"$err_file"; then
      rm -f "$err_file"
      return 0
    fi
    err_msgs+=("${magick_cmd}:png:$(format_debug_payload "$(cat "$err_file")")")
    rm -f "$err_file"
  fi

  LAST_NORMALIZER_ERR=$(format_debug_payload "${err_msgs[*]}")
  return 1
}

normalize_dng_raw() {
  # extract pure linear raw sensor data
  local infile="$1"; local outfile="$2"
  LAST_NORMALIZER_ERR=""
  local err_file
  err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
  if dcraw -4 -D -c "$infile" > "$outfile" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi
  LAST_NORMALIZER_ERR=$(format_debug_payload "dcraw:$(cat "$err_file")")
  rm -f "$err_file"
  return 1
}

normalize_video_streams() {
  # args: infile outprefix
  local infile="$1"; local out="$2"
  LAST_NORMALIZER_ERR=""
  local err_file err_msgs=()

  err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
  if ffmpeg -y -v error -i "$infile" -map 0:v:0 -c copy -f data "${out}_video.bin" 2>"$err_file"; then
    rm -f "$err_file"
  else
    err_msgs+=("ffmpeg-video:$(format_debug_payload "$(cat "$err_file")")")
    rm -f "$err_file"
    rm -f "${out}_video.bin"
  fi

  err_file=$(mktemp "${CACHE_DIR}/norm.XXXX")
  if ffmpeg -y -v error -i "$infile" -map 0:a:0 -c copy -f data "${out}_audio.bin" 2>"$err_file"; then
    rm -f "$err_file"
  else
    err_msgs+=("ffmpeg-audio:$(format_debug_payload "$(cat "$err_file")")")
    rm -f "$err_file"
    rm -f "${out}_audio.bin"
  fi

  if [ ${#err_msgs[@]} -gt 0 ]; then
    LAST_NORMALIZER_ERR=$(format_debug_payload "${err_msgs[*]}")
  else
    LAST_NORMALIZER_ERR=""
  fi
}

compute_normalized_hash() {
  # prints a single-line hash for a file (or special tag)
  local file="$1"
  LAST_NORMALIZER_ERR=""
  if [ ! -f "$file" ]; then
    if [ -e "$file" ]; then
      log_skipped_input "not-regular-file" "$file" "$LAST_NORMALIZER_ERR"
    else
      log_skipped_input "missing-file" "$file" "$LAST_NORMALIZER_ERR"
    fi
    exit 2
  fi
  if [ ! -r "$file" ]; then
    log_skipped_input "unreadable-file" "$file" "permission-denied"
    exit 2
  fi
  if [ ! -s "$file" ]; then
    log_skipped_input "zero-byte-file" "$file" "empty-input"
    exit 2
  fi
  local e=$(ext "$file")
  tmpd=$(mktemp -d "${CACHE_DIR}/tmp.XXXX")
  trap 'rm -rf "$tmpd"' EXIT

  case "$e" in
    png|gif|jpg|jpeg)
      if normalize_raster "$file" "$tmpd/norm.img"; then
        hash_file "$tmpd/norm.img"
      else
        log_skipped_input "normalize-raster-failed" "$file" "$LAST_NORMALIZER_ERR"
        exit 2
      fi
      ;;
    dng)
      if normalize_raster "$file" "$tmpd/norm.raw"; then
        hash_file "$tmpd/norm.raw"
      else
        log_skipped_input "normalize-dng-failed" "$file" "$LAST_NORMALIZER_ERR"
        exit 2
      fi
      ;;
    mp4|mov)
      normalize_video_streams "$file" "$tmpd/stream"
      if [ -f "$tmpd/stream_video.bin" ]; then
        hv=$(hash_file "$tmpd/stream_video.bin")
      else hv="NOVIDEO"; fi
      if [ -f "$tmpd/stream_audio.bin" ]; then
        ha=$(hash_file "$tmpd/stream_audio.bin")
      else ha="NOAUDIO"; fi
      if [ "$hv" = "NOVIDEO" ] && [ "$ha" = "NOAUDIO" ]; then
        log_skipped_input "video-no-streams" "$file" "$LAST_NORMALIZER_ERR"
        exit 2
      fi
      LAST_NORMALIZER_ERR=""
      echo "${hv}-${ha}"
      ;;
    *)
      log_skipped_input "unsupported-extension:${e:-unknown}" "$file" "$LAST_NORMALIZER_ERR"
      exit 2
      ;;
  esac
}

# ---------------------------
# Worker (invoked as subcommand 'worker')
# ---------------------------
worker_main() {
  # args: cache_db file
  local cache_db="$1"; local file="$2"
  if [ ! -f "$file" ]; then
    if [ -e "$file" ]; then
      log_skipped_input "not-regular-file" "$file"
    else
      log_skipped_input "missing-file" "$file"
    fi
    exit 2
  fi

  local size mtime
  size=$(stat -f%z "$file"); mtime=$(stat -f%m "$file")

  # attempt cache lookup
  if [ -n "$cache_db" ] && [ -f "$cache_db" ]; then
    cached=$(get_cached_hash "$cache_db" "$file" "$mtime" "$size")
    if [ -n "$cached" ]; then
      echo "$cached|$file";
      exit 0
    fi
  fi

  local result
  if result=$(compute_normalized_hash "$file" 2>/dev/null); then
    if [ -n "$cache_db" ]; then
      store_cached_hash "$cache_db" "$file" "$mtime" "$size" "$result" || true
    fi
    echo "$result|$file"
    exit 0
  else
    rc=$?
    if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
      log_skipped_input "hashing-error" "$file"
    fi
    exit 2
  fi
}

# ---------------------------
# Find duplicates (main)
# ---------------------------
find_duplicates_main() {
  local root="$1"
  if [ "$root" != "/" ]; then root="${root%/}"; fi
  if [ -z "$root" ] || [ ! -d "$root" ]; then
    err "path missing"
    return 2
  fi
  root=$(abs_path "$root")
  local cache_db="${CACHE_DB:-$DEFAULT_CACHE_DB}"
  local jobs="${JOBS:-$(cpu_count)}"
  local action="${ACTION:-print}"
  local trashdir="${TRASH_DIR:-${HOME}/.Trash/mediadup}"

  mkdir -p "$trashdir"
  init_cache_db "$cache_db" || true

  info "Scanning for media under: $root"
  # build list
  mapfile -t files < <(find "$root" -xdev -type f \( -iname "*.png" -o -iname "*.gif" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.dng" -o -iname "*.mp4" -o -iname "*.mov" \) -print 2>/dev/null)
  local total=${#files[@]}
  if [ "$total" -eq 0 ]; then info "No media files found."; return 0; fi
  info "Found $total media files. Starting hashing with $jobs jobs..."

  # prepare temp and output
  global_tmp=$(mktemp -d "${CACHE_DIR}/global.XXXX")
  local output="${global_tmp}/hashes.txt"; : > "$output"
  trap 'rm -rf "$global_tmp"' EXIT

  printf "%s\n" "${files[@]}" | parallel --will-cite --jobs "$jobs" --bar --line-buffer "$(which "$0")" worker "$cache_db" {} > "$output" || true

  # Build groups
  declare -A groups
  while IFS= read -r line; do
    hashpart="${line%%|*}"
    path="${line#*|}"

    if [ -z "${groups[$hashpart]+set}" ]; then
      groups["$hashpart"]="$path"
    else
      groups["$hashpart"]+=$'\n'"$path"
    fi
  done < "$output"

  local total_groups=${#groups[@]}
  local processed_groups=0
  if [ "$total_groups" -gt 0 ]; then
    progress_tick 0 "$total_groups" "Organizing duplicate groups"
  fi

  # Save a JSON-ish results file for dashboard/TUI
  local results_json="${CACHE_DIR}/last_scan.json"
  if [ -f "$results_json" ]; then
    local stamp backup_json
    stamp=$(date -r "$results_json" +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S)
    backup_json="${results_json%.json}_${stamp}.json"
    if ! mv "$results_json" "$backup_json"; then
      err "Failed to rotate previous results file ($results_json)"
    fi
  fi
  echo "[]" > "$results_json"
  local group_count=0
  local total_reclaim=0

  for h in "${!groups[@]}"; do
    processed_groups=$((processed_groups+1))
    progress_tick "$processed_groups" "$total_groups" "Organizing duplicate groups"

    # split newline-delimited paths into an array
    mapfile -t arr < <(printf '%s\n' "${groups[$h]}")
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

      # perform action
      case "$action" in
        print)
          echo
          echo "=== Duplicate group (hash: $h) ==="
          for p in "${arr[@]}"; do echo "  $p"; done
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
      local files_json
      if ! files_json=$(printf '%s\n' "${arr[@]}" | jq -R . | jq -s .); then
        err "Failed to encode duplicate file list for $h"
        continue
      fi

      if jq -c --arg h "$h" --argjson cnt "${#arr[@]}" --arg keep "${arr[0]}" --argjson files "$files_json" \
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

  if [ "$total_groups" -gt 0 ]; then
    printf "\rOrganizing duplicate groups complete (%d/%d)\n" "$processed_groups" "$total_groups" >&2
  fi

  # runtime summary
  echo "Scan complete: found $group_count duplicate groups"
  reclaim_human=$(gnumfmt --to=iec --suffix=B "$total_reclaim" 2>/dev/null || true)
  echo "Estimated recoverable: $reclaim_human"
  # write stats file for dashboard
  cat > "${CACHE_DIR}/stats.json" <<EOF
{
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
  rm -f "$tmp1" "$tmp2"
  normalize_raster "$f1" "$tmp1"
  normalize_raster "$f2" "$tmp2"
  out=$(compare -metric RMSE "$tmp1" "$tmp2" null: 2>&1) || true
  echo "RMSE = $out (0 = identical)"
  rm -f "$tmp1" "$tmp2"
}

compare_hashes_cmd() {
  local f1="$1" f2="$2" out_h1="$3" out_h2="$4"
  local hash1 hash2
  if ! hash1=$(compute_normalized_hash "$f1"); then
    if [ -n "$out_h1" ]; then printf -v "$out_h1" '%s' "$hash1"; fi
    exit 2
  fi
  if ! hash2=$(compute_normalized_hash "$f2"); then
    if [ -n "$out_h2" ]; then printf -v "$out_h2" '%s' "$hash2"; fi
    exit 2
  fi
  if [ -n "$out_h1" ]; then printf -v "$out_h1" '%s' "$hash1"; fi
  if [ -n "$out_h2" ]; then printf -v "$out_h2" '%s' "$hash2"; fi
  if [ "$hash1" = "$hash2" ]; then
    exit 0
  fi
  exit 1
}

# ---------------------------
# Command dispatch
# ---------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --debug)
      DEBUG=1
      export MEDIADUP_DEBUG=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -lt 1 ]; then
  cat <<EOF
$PROG — media dedupe tool (complete)
Usage:
  $PROG [--debug] find-duplicates <path> [--cache-db PATH] [--jobs N] [--action print|hardlink|symlink|move|none] [--trash-dir PATH]
  $PROG [--debug] compare <file1> <file2>
  $PROG [--debug] compare-pixels <file1> <file2>
  $PROG [--debug] hash <file>
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
    # parse optional flags
    while [ $# -gt 0 ]; do
      case "$1" in
        --cache-db) CACHE_DB="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        --trash-dir) TRASH_DIR="$2"; shift 2 ;;
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
        local path=""
        if [ -z "$h1" ]; then
          path="$1"
        elif [ -z "$h2" ]; then
          path="$2"
        fi
        if [ -z "$path" ]; then path="one of the provided paths"; fi
        err "Compare skipped for $path: See ${SKIPPED_LOG}."
        exit 2
      fi
    fi
    ;;

  compare-pixels)
    if [ $# -ne 2 ]; then err "compare-pixels needs two images"; exit 2; fi
    compare_pixels_cmd "$1" "$2"
    ;;

  hash)
    if [ $# -ne 1 ]; then err "hash needs a file"; exit 2; fi
    local out
    if ! out=$(compute_normalized_hash "$1"); then
      err "Hash skipped for $1: See ${SKIPPED_LOG}."
      exit 2
    fi
    echo "$out"
    ;;

  *)
    err "Unknown command: $cmd"
    exit 2
    ;;
esac

# End of mediadup-full.sh
