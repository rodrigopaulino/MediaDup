#!/usr/bin/env bash
# mediadup-uninstall.sh
# Safely uninstall the MediaDup tool and (optionally) packages installed by setup.
#
# Usage:
#   sudo ./mediadup-uninstall.sh                 # interactive, remove MediaDup files
#   sudo ./mediadup-uninstall.sh --yes           # non-interactive, remove everything
#
# Notes:
#  - Removes MediaDup files plus supporting MacPorts packages unless you answer "no" at the relevant prompts.
#  - Packages removed: exiftool dcraw ffmpeg imagemagick sqlite3 parallel jq file
#  - Removing system packages may affect other software — review the prompts carefully.
set -euo pipefail

AUTO_YES=0

# paths installed by the setup script we provided earlier
BIN_PATH="/usr/local/bin/mediadup"
CACHE_DIR="${HOME}/.cache/mediadup"
CONFIG_DIR="${HOME}/.config/mediadup"
DEFAULT_DB="${HOME}/.mediadup_cache.db"

PKGS=(exiftool dcraw ffmpeg imagemagick sqlite3 parallel jq file)

usage() {
  cat <<EOF
mediadup-uninstall.sh — remove MediaDup and optional packages

Options:
  --yes               Skip confirmation prompts (use with care).
  -h, --help          Show this help.

Examples:
  sudo ./mediadup-uninstall.sh
  sudo ./mediadup-uninstall.sh --yes
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

echo "=== MediaDup uninstall utility ==="
echo "Binary:    $BIN_PATH"
echo "Config dir: $CONFIG_DIR"
echo "Cache dir: $CACHE_DIR"
echo "Cache DB:  $DEFAULT_DB"
echo

confirm() {
  if [ "$AUTO_YES" -eq 1 ]; then
    return 0
  fi
  read -r -p "$1 [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

prune_leaves_loop() {
  local pass=1
  while true; do
    local -a leaves=()
    while IFS= read -r leaf; do
      [ -n "$leaf" ] && leaves+=("$leaf")
    done < <(port echo leaves 2>/dev/null | awk '{print $1}')
    if [ "${#leaves[@]}" -eq 0 ]; then
      if [ "$pass" -eq 1 ]; then
        echo "No MacPorts leaf packages detected."
      else
        echo "No more leaf packages remain."
      fi
      break
    fi
    echo "Leaf uninstall pass $pass: ${leaves[*]}"
    if ! port uninstall leaves; then
      echo "port uninstall leaves reported an error; stopping leaf cleanup." >&2
      break
    fi
    pass=$((pass+1))
  done
}

# Prepare list of file operations
declare -a to_remove_files=()
declare -a to_remove_dirs=()

# binary
if [ -f "$BIN_PATH" ]; then
  to_remove_files+=("$BIN_PATH")
fi
if [ -f "$DEFAULT_DB" ]; then
  to_remove_files+=("$DEFAULT_DB")
fi
if [ -d "$CONFIG_DIR" ]; then
  to_remove_dirs+=("$CONFIG_DIR")
fi
if [ -d "$CACHE_DIR" ]; then
  to_remove_dirs+=("$CACHE_DIR")
fi

echo "Planned removals:"
if [ "${#to_remove_files[@]}" -gt 0 ]; then
  for f in "${to_remove_files[@]}"; do echo "  FILE: $f"; done
  if ! confirm "Remove the listed files?"; then
    echo "Skipping file removal."
    to_remove_files=()
  fi
else
  echo "  FILE: (none)"
fi

if [ "${#to_remove_files[@]}" -gt 0 ]; then
  for f in "${to_remove_files[@]}"; do
    if [ -f "$f" ]; then
      echo "Removing file: $f"
      if [ "$(dirname "$f")" = "/usr/local/bin" ]; then
        # requires sudo
        sudo rm -f "$f"
      else
        rm -f "$f"
      fi
    fi
  done
fi

if [ "${#to_remove_dirs[@]}" -gt 0 ]; then
  for d in "${to_remove_dirs[@]}"; do echo "  DIR:  $d"; done
  if ! confirm "Remove the listed directories?"; then
    echo "Skipping directory removal."
    to_remove_dirs=()
  fi
else
  echo "  DIR:  (none)"
fi

if [ "${#to_remove_dirs[@]}" -gt 0 ]; then
  for d in "${to_remove_dirs[@]}"; do
    if [ -d "$d" ]; then
      echo "Removing directory: $d"
      rm -rf "$d"
    fi
  done
fi

echo
INSTALLED=()
for pkg in "${PKGS[@]}"; do
  if port installed "$pkg" 2>/dev/null | grep -q "(active)"; then
    INSTALLED+=("$pkg")
  fi
done

if [ "${#INSTALLED[@]}" -eq 0 ]; then
  echo "No listed packages are active in MacPorts."
else
  echo "Active MacPorts packages to uninstall: ${INSTALLED[*]}"
  if confirm "Uninstall these packages via MacPorts?"; then
    for pkg in "${INSTALLED[@]}"; do
      echo "Uninstalling $pkg via MacPorts..."
      port uninstall "$pkg" || true
    done
  else
    echo "Skipping package removal."
  fi
fi

if port echo leaves 2>/dev/null | grep -q '\S'; then
  if confirm "Run 'port uninstall leaves' repeatedly to prune unused dependencies?"; then
    prune_leaves_loop
  else
    echo "Skipping leaf dependency cleanup."
  fi
else
  echo "No MacPorts leaf packages detected."
fi

echo
echo "Uninstall complete."
echo "If you removed the sqlite DB and cache, you have removed MediaDup state. Any other artifacts (e.g., duplicates moved to trash) remain where created."
