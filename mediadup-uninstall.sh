#!/usr/bin/env bash
# mediadup-uninstall.sh
# Safely uninstall the MediaDup tool and (optionally) packages installed by setup.
#
# Usage:
#   sudo ./mediadup-uninstall.sh                 # interactive, remove MediaDup files
#   sudo ./mediadup-uninstall.sh --dry-run       # show what would be removed
#   sudo ./mediadup-uninstall.sh --remove-packages --yes
#
# Notes:
#  - By default only removes files installed by MediaDup (binary, config, cache, DB).
#  - --remove-packages attempts to remove packages via MacPorts: exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file
#  - Removing system packages may affect other software — review the dry-run carefully.
set -euo pipefail

DRY_RUN=0
REMOVE_PKGS=0
AUTO_YES=0

# paths installed by the setup script we provided earlier
BIN_PATH="/usr/local/bin/mediadup"
CACHE_DIR="${HOME}/.cache/mediadup"
CONFIG_DIR="${HOME}/.config/mediadup"
DEFAULT_DB="${HOME}/.mediadup_cache.db"

PKGS=(exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file)

usage() {
  cat <<EOF
mediadup-uninstall.sh — remove MediaDup and optional packages

Options:
  --dry-run           Show what would be removed, do not delete anything.
  --remove-packages   Also attempt to uninstall system packages installed by the setup script.
  --yes               Skip confirmation prompts (use with care).
  -h, --help          Show this help.

Examples:
  sudo ./mediadup-uninstall.sh
  sudo ./mediadup-uninstall.sh --dry-run
  sudo ./mediadup-uninstall.sh --remove-packages --yes
EOF
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --remove-packages) REMOVE_PKGS=1; shift ;;
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

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN] No files will be deleted."
fi

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

# Prepare list of file operations
declare -a to_remove_files
declare -a to_remove_dirs

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
else
  echo "  FILE: (none)"
fi
if [ "${#to_remove_dirs[@]}" -gt 0 ]; then
  for d in "${to_remove_dirs[@]}"; do echo "  DIR:  $d"; done
else
  echo "  DIR:  (none)"
fi
if [ "$REMOVE_PKGS" -eq 1 ]; then
  echo
  echo "MacPorts packages to remove (if found): ${PKGS[*]}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry-run mode. Exiting without deleting anything."
  exit 0
fi

echo

if ! confirm "Proceed with deletion of the listed items?"; then
  echo "Aborted by user."
  exit 0
fi

# remove files (user-owned)
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

# remove dirs
if [ "${#to_remove_dirs[@]}" -gt 0 ]; then
  for d in "${to_remove_dirs[@]}"; do
    if [ -d "$d" ]; then
      echo "Removing directory: $d"
      rm -rf "$d"
    fi
  done
fi

# optionally remove packages
if [ "$REMOVE_PKGS" -eq 1 ]; then
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
    if confirm "Proceed to uninstall these packages via MacPorts?"; then
      for pkg in "${INSTALLED[@]}"; do
        echo "Uninstalling $pkg via MacPorts..."
        port uninstall "$pkg" || true
      done
    else
      echo "Skipping package removal."
    fi
  fi
fi

echo
echo "Uninstall complete."
echo "If you removed the sqlite DB and cache, you have removed MediaDup state. Any other artifacts (e.g., duplicates moved to trash) remain where created."
