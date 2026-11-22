#!/usr/bin/env bash
set -euo pipefail

REPO="Wangnov/HotspotKeeper"
APP_INSTALL="$HOME/Applications/HotspotKeeper.app"
CLI_LINK="$HOME/.local/bin/hotspot-keeper"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Installing HotspotKeeper..."

if command -v clang >/dev/null 2>&1 && [[ "${HOTSPOT_KEEPER_FROM_SOURCE:-0}" == "1" ]]; then
  git clone --depth 1 "https://github.com/$REPO.git" "$TMP_DIR/repo"
  (cd "$TMP_DIR/repo" && chmod +x build.sh && ./build.sh)
else
  ZIP_URL="https://github.com/$REPO/releases/latest/download/HotspotKeeper-macos-universal.zip"
  echo "Downloading latest release from $ZIP_URL ..."
  if curl -fsSL "$ZIP_URL" -o "$TMP_DIR/HotspotKeeper.zip"; then
    ditto -xk "$TMP_DIR/HotspotKeeper.zip" "$TMP_DIR/extract"
    mkdir -p "$HOME/Applications" "$HOME/.local/bin"
    rm -rf "$APP_INSTALL"
    ditto "$TMP_DIR/extract/HotspotKeeper.app" "$APP_INSTALL"
    xattr -dr com.apple.quarantine "$APP_INSTALL" 2>/dev/null || true
    ln -sf "$APP_INSTALL/Contents/MacOS/HotspotKeeper" "$CLI_LINK"
  else
    echo "Release archive unavailable; building from source..."
    git clone --depth 1 "https://github.com/$REPO.git" "$TMP_DIR/repo"
    (cd "$TMP_DIR/repo" && chmod +x build.sh && ./build.sh)
  fi
fi

"$CLI_LINK" --install-login
echo ""
echo "Done! HotspotKeeper is now running in your menu bar."
echo "Run 'hotspot-keeper --list' to see nearby Instant Hotspot devices."
