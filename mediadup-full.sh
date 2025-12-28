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
HOME_CONFIG="${HOME}/.config/mediadup"
CACHE_DIR="${HOME}/.cache/mediadup"
DEFAULT_CACHE_DB="${HOME}/.mediadup_cache.db"
SKIPPED_LOG="${CACHE_DIR}/skipped_inputs.log"

mkdir -p "$HOME_CONFIG" "$CACHE_DIR"

# ---------------------------
# Utilities
# ---------------------------
err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }
cpu_count() { sysctl -n hw.ncpu; }

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

log_skipped_input() {
  # reason, path
  local reason="$1"; local path="$2"
  printf "%s\t%s\t%s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$reason" "$path" >> "$SKIPPED_LOG"
}

skip_token_message() {
  case "$1" in
    __SKIPPED_NOTFILE__) echo "Path is not a regular file (likely a folder)." ;;
    __UNSUPPORTED__) echo "Unsupported media format." ;;
    __MISSING__) echo "File is missing." ;;
    __ERR__) echo "Unexpected hashing error." ;;
    *) echo "Unknown hashing failure." ;;
  esac
}

is_logged_skip_token() {
  case "$1" in
    __SKIPPED_NOTFILE__|__UNSUPPORTED__) return 0 ;;
    *) return 1 ;;
  esac
}

is_skip_token() {
  case "$1" in
    __SKIPPED_NOTFILE__|__UNSUPPORTED__|__MISSING__) return 0 ;;
    *) return 1 ;;
  esac
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
  exiftool -q -q -all= -o "$outfile" "$infile"
}

normalize_dng_raw() {
  # extract pure linear raw sensor data
  local infile="$1"; local outfile="$2"
  dcraw -4 -D -c "$infile" > "$outfile"
}

normalize_video_streams() {
  # args: infile outprefix
  local infile="$1"; local out="$2"
  ffmpeg -y -v error -i "$infile" -map 0:v:0 -c copy "${out}_video.bin" 2>/dev/null || true
  ffmpeg -y -v error -i "$infile" -map 0:a:0 -c copy "${out}_audio.bin" 2>/dev/null || true
}

compute_normalized_hash() {
  # prints a single-line hash for a file (or special tag)
  local file="$1"
  if [ ! -f "$file" ]; then
    if [ -e "$file" ]; then
      log_skipped_input "not-regular-file" "$file"
      echo "__SKIPPED_NOTFILE__"
    else
      echo "__MISSING__"
    fi
    return 1
  fi
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
      log_skipped_input "unsupported-extension:${e:-unknown}" "$file"
      echo "__UNSUPPORTED__"
      return 1
      ;;
  esac
}

# ---------------------------
# Cache (sqlite) helpers
# ---------------------------
init_cache_db() {
  local db="$1"
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
  if [ -f "$db" ]; then
    local path_sql
    path_sql=$(printf "%s" "$path" | sed "s/'/''/g")
    sqlite3 "$db" "SELECT hash FROM filehash WHERE path = '$path_sql' AND mtime = $mtime AND size = $size LIMIT 1;"
  fi
}

store_cached_hash() {
  local db="$1"; local path="$2"; local mtime="$3"; local size="$4"; local hash="$5"
  local path_sql hash_sql
  path_sql=$(printf "%s" "$path" | sed "s/'/''/g")
  hash_sql=$(printf "%s" "$hash" | sed "s/'/''/g")
  sqlite3 "$db" "INSERT OR REPLACE INTO filehash(path, mtime, size, hash, updated_at) VALUES('$path_sql', $mtime, $size, '$hash_sql', strftime('%s','now'));" 2>/dev/null || true
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
  if [ "$root" != "/" ]; then root="${root%/}"; fi
  if [ -z "$root" ]; then
    err "path missing"
    return 2
  fi
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
  local global_tmp
  global_tmp=$(mktemp -d "${CACHE_DIR}/global.XXXX")
  local output="${global_tmp}/hashes.txt"; : > "$output"

  printf "%s\n" "${files[@]}" | parallel --will-cite --jobs "$jobs" --bar --line-buffer "$(which "$0")" worker "$cache_db" {} > "$output"

  # Build groups
  declare -A groups
  while IFS= read -r line; do
    hashpart="${line%%|*}"
    path="${line#*|}"
    case "$hashpart" in
      __ERR__|__MISSING__|__UNSUPPORTED__|__SKIPPED_NOTFILE__|NOVIDEO-NOAUDIO) continue ;;
    esac

    if [ -z "${groups[$hashpart]+set}" ]; then
      groups["$hashpart"]="$path"
    else
      groups["$hashpart"]+=$'\n'"$path"
    fi
  done < "$output"

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
    if is_skip_token "$hash1"; then
      return 3
    fi
    return 2
  fi
  if ! hash2=$(compute_normalized_hash "$f2"); then
    if [ -n "$out_h2" ]; then printf -v "$out_h2" '%s' "$hash2"; fi
    if is_skip_token "$hash2"; then
      return 3
    fi
    return 2
  fi
  if [ -n "$out_h1" ]; then printf -v "$out_h1" '%s' "$hash1"; fi
  if [ -n "$out_h2" ]; then printf -v "$out_h2" '%s' "$hash2"; fi
  if [ "$hash1" = "$hash2" ]; then
    return 0
  fi
  return 1
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
      elif [ "$rc" -eq 3 ]; then
        local token path msg suffix=""
        token=""
        path=""
        if is_skip_token "$h1"; then token="$h1"; path="$1"; fi
        if [ -z "$token" ] && is_skip_token "$h2"; then token="$h2"; path="$2"; fi
        msg=$(skip_token_message "$token")
        if is_logged_skip_token "$token"; then
          suffix=" See ${SKIPPED_LOG}."
        fi
        if [ -z "$path" ]; then path="one of the provided paths"; fi
        err "Compare skipped for $path: $msg${suffix}"
        exit 2
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
    local out suffix=""
    if ! out=$(compute_normalized_hash "$1"); then
      local msg
      msg=$(skip_token_message "$out")
      if is_logged_skip_token "$out"; then
        suffix=" See ${SKIPPED_LOG}."
      fi
      err "Hash skipped for $1: $msg${suffix}"
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
