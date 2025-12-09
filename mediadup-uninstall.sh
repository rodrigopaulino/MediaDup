#!/usr/bin/env bash
# uninstall-mediadup.sh
# Safely uninstall the mediadup tool and (optionally) packages installed by setup.
#
# Usage:
#   sudo ./uninstall-mediadup.sh                 # interactive, remove mediadup files
#   sudo ./uninstall-mediadup.sh --dry-run       # show what would be removed
#   sudo ./uninstall-mediadup.sh --remove-packages --yes
#
# Notes:
#  - By default only removes files installed by mediadup (binary, config, cache, DB).
#  - --remove-packages attempts to remove packages: exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file
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
LOCAL_BIN_SRC="/usr/local/bin/mediadup-full.sh" # if present as separate file
# any other known locations we used
ALT_BIN="/usr/local/bin/mediadup-full.sh"

PKGS=(exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file)

usage() {
  cat <<EOF
uninstall-mediadup.sh — remove mediadup and optional packages

Options:
  --dry-run           Show what would be removed, do not delete anything.
  --remove-packages   Also attempt to uninstall system packages installed by the setup script.
  --yes               Skip confirmation prompts (use with care).
  -h, --help          Show this help.

Examples:
  sudo ./uninstall-mediadup.sh
  sudo ./uninstall-mediadup.sh --dry-run
  sudo ./uninstall-mediadup.sh --remove-packages --yes
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

echo "=== mediadup uninstall utility ==="
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
declare -a to_remove_sudo_cmds

# binary
if [ -f "$BIN_PATH" ]; then
  to_remove_files+=("$BIN_PATH")
else
  echo "Binary not found at $BIN_PATH"
fi

if [ -f "$ALT_BIN" ]; then
  to_remove_files+=("$ALT_BIN")
fi

# user config/cache/db
if [ -d "$CONFIG_DIR" ]; then
  to_remove_dirs+=("$CONFIG_DIR")
fi
if [ -d "$CACHE_DIR" ]; then
  to_remove_dirs+=("$CACHE_DIR")
fi
if [ -f "$DEFAULT_DB" ]; then
  to_remove_files+=("$DEFAULT_DB")
fi

# logs/state
STATE_DIR="${HOME}/.local/state/mediadup"
if [ -d "$STATE_DIR" ]; then
  to_remove_dirs+=("$STATE_DIR")
fi

# system-wide share (if any)
SHARE_DIR="/usr/local/share/mediadup"
if [ -d "$SHARE_DIR" ]; then
  to_remove_dirs+=("$SHARE_DIR")
fi

echo "Planned removals:"
for f in "${to_remove_files[@]}"; do echo "  FILE: $f"; done
for d in "${to_remove_dirs[@]}"; do echo "  DIR:  $d"; done

if [ "$REMOVE_PKGS" -eq 1 ]; then
  echo
  echo "Packages to remove (if found): ${PKGS[*]}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "Dry-run mode. Exiting without deleting anything."
  exit 0
fi

if ! confirm "Proceed with deletion of the listed items?"; then
  echo "Aborted by user."
  exit 0
fi

# remove files (user-owned)
for f in "${to_remove_files[@]}"; do
  if [ -f "$f" ]; then
    echo "Removing file: $f"
    if [ "$(dirname "$f")" = "/usr/local/bin" ]; then
      # requires sudo
      if [ "$DRY_RUN" -eq 0 ]; then
        sudo rm -f "$f"
      fi
    else
      rm -f "$f"
    fi
  fi
done

# remove dirs
for d in "${to_remove_dirs[@]}"; do
  if [ -d "$d" ]; then
    echo "Removing directory: $d"
    if [[ "$d" == /usr/local/* || "$d" == /usr/share/* ]]; then
      if [ "$DRY_RUN" -eq 0 ]; then
        sudo rm -rf "$d"
      fi
    else
      rm -rf "$d"
    fi
  fi
done

# optionally remove packages
if [ "$REMOVE_PKGS" -eq 1 ]; then
  echo
  echo "Detecting package manager..."
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
    echo "Using apt to remove packages (dry-run will not remove)."
    if [ "$AUTO_YES" -eq 0 ]; then
      echo "Note: apt will be invoked with --purge -y; this will remove packages and their configuration."
    fi
    # build list of packages that are installed
    INSTALLED=()
    for pkg in "${PKGS[@]}"; do
      if dpkg -s "$pkg" >/dev/null 2>&1; then INSTALLED+=("$pkg"); fi
    done
    if [ "${#INSTALLED[@]}" -eq 0 ]; then
      echo "No listed packages appear installed via apt."
    else
      echo "Packages installed to be removed: ${INSTALLED[*]}"
      if confirm "Proceed to apt remove these packages?"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          sudo apt-get remove --purge -y "${INSTALLED[@]}"
          sudo apt-get autoremove -y
        fi
      else
        echo "Skipping package removal."
      fi
    fi

  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    PKG_MGR="yum"
    PM=$(command -v dnf >/dev/null 2>&1 && echo dnf || echo yum)
    INSTALLED=()
    for pkg in "${PKGS[@]}"; do
      if rpm -q "$pkg" >/dev/null 2>&1; then INSTALLED+=("$pkg"); fi
    done
    if [ "${#INSTALLED[@]}" -eq 0 ]; then
      echo "No listed packages appear installed via rpm/yum."
    else
      echo "Packages installed to be removed: ${INSTALLED[*]}"
      if confirm "Proceed to remove via $PM?"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          sudo $PM remove -y "${INSTALLED[@]}"
        fi
      else
        echo "Skipping package removal."
      fi
    fi

  elif command -v brew >/dev/null 2>&1; then
    PKG_MGR="brew"
    INSTALLED=()
    for pkg in "${PKGS[@]}"; do
      # brew package names may differ; test by brew list
      if brew list --formula | grep -xq "$pkg"; then INSTALLED+=("$pkg"); fi
    done
    if [ "${#INSTALLED[@]}" -eq 0 ]; then
      echo "No listed packages appear installed via brew (exact-name match)."
    else
      echo "Packages installed to be removed (brew): ${INSTALLED[*]}"
      if confirm "Proceed to brew uninstall these packages?"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          for pkg in "${INSTALLED[@]}"; do
            brew uninstall "$pkg" || true
          done
        fi
      else
        echo "Skipping package removal."
      fi
    fi

  else
    echo "No known package manager detected (apt/yum/brew). Please remove packages manually if desired:"
    echo "  ${PKGS[*]}"
  fi
fi

echo
echo "Uninstall complete."
echo "If you removed the sqlite DB and cache, you have removed mediadup state. Any other artifacts (e.g., duplicates moved to trash) remain where created."
echo "If you want a complete system purge, consider running an additional 'sudo updatedb' if your locate/db is stale (optional)."
