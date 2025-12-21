#!/usr/bin/env bash
# mediadup-setup.sh
# Setup installer for mediadup-full.sh
# Usage: sudo ./mediadup-setup.sh
set -euo pipefail

PROG="$(basename "$0")"
DEST="/usr/local/bin/mediadup"
SRC_LOCAL="./mediadup-full.sh"   # if you run setup from same folder
CACHE_DIR="${HOME}/.cache/mediadup"
CONFIG_DIR="${HOME}/.config/mediadup"

if [ "$(id -u)" -ne 0 ]; then
  echo "This setup script should be run with sudo (to install system packages and copy binary)."
  echo "You may be prompted for your password."
fi

# Detect package manager
install_pkgs_debian() {
  apt update
  apt install -y exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file
}
install_pkgs_redhat() {
  yum install -y epel-release
  yum install -y perl-Image-ExifTool dcraw ffmpeg ImageMagick sqlite sqlite-devel parallel pv fzf dialog jq file
}
install_pkgs_mac() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Please install Homebrew first."
    exit 1
  fi
  brew install exiftool dcraw ffmpeg imagemagick sqlite parallel pv fzf dialog jq
}

echo "Installing dependencies..."
if command -v apt-get >/dev/null 2>&1; then
  install_pkgs_debian
elif command -v yum >/dev/null 2>&1; then
  install_pkgs_redhat
elif command -v brew >/dev/null 2>&1; then
  install_pkgs_mac
else
  echo "Unknown package manager. Please install required packages manually:"
  echo "exiftool dcraw ffmpeg imagemagick sqlite3 parallel pv fzf dialog jq file"
  exit 1
fi

# Copy main script into /usr/local/bin/mediadup
if [ -f "$SRC_LOCAL" ]; then
  cp "$SRC_LOCAL" "$DEST"
  chmod +x "$DEST"
  echo "Copied $SRC_LOCAL -> $DEST"
else
  # try to download from current directory? just fail gracefully
  echo "Local mediadup-full.sh not found in current directory. Place mediadup-full.sh here and rerun."
  exit 1
fi

# create config/cache dirs for the invoking user (not root)
USER_HOME=$(eval echo "~$SUDO_USER")
if [ -z "$USER_HOME" ]; then USER_HOME="$HOME"; fi
mkdir -p "${USER_HOME}/.cache/mediadup" "${USER_HOME}/.config/mediadup"
cp -n "${USER_HOME}/.config/mediadup/theme.conf" "${USER_HOME}/.config/mediadup/theme.conf" 2>/dev/null || true

echo "Setup complete."
echo "Run 'mediadup' (or sudo -u $SUDO_USER mediadup tui) to start the TUI."
echo "Example quick scan:"
echo "  mediadup find-duplicates ~/Pictures --jobs $(nproc 2>/dev/null || echo 4) --action print --cache-db ${USER_HOME}/.mediadup_cache.db"

