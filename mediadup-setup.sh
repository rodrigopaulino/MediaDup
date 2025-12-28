#!/usr/bin/env bash
# mediadup-setup.sh
# Setup installer for mediadup-full.sh
# Usage: sudo ./mediadup-setup.sh
set -euo pipefail

DEST="/usr/local/bin/mediadup"
SRC_LOCAL="./mediadup-full.sh"   # if you run setup from same folder
PKGS=(exiftool dcraw ffmpeg ImageMagick sqlite3 parallel jq file)

if [ "$(id -u)" -ne 0 ]; then
  echo "This setup script should be run with sudo (to install system packages and copy binary)."
  echo "You may be prompted for your password."
fi

install_pkgs_macports() {
  if ! command -v port >/dev/null 2>&1; then
    echo "MacPorts (port) not found. Install MacPorts from https://www.macports.org/install.php and rerun this setup."
    exit 1
  fi

  echo "Installing dependencies with MacPorts..."
  for pkg in "${PKGS[@]}"; do
    if port installed "$pkg" 2>/dev/null | grep -q "(active)"; then
      echo "  $pkg already installed."
    else
      echo "  Installing $pkg..."
      port install "$pkg"
    fi
  done
}

install_pkgs_macports

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
mkdir -p "${HOME}/.cache/mediadup" "${HOME}/.config/mediadup"

echo "Setup complete."
echo "Run 'mediadup' for CLI usage. Common commands:"
echo "  mediadup compare fileA fileB"
echo "  mediadup compare-pixels imageA imageB"
echo "  mediadup hash file"
echo "Example duplicate scan:"
echo "  mediadup find-duplicates ~/Pictures --jobs $(nproc 2>/dev/null || echo 4) --action print --cache-db ${HOME}/.mediadup_cache.db"

