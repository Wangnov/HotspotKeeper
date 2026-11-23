#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUILD="$ROOT/build/HotspotKeeper.app"
APP_INSTALL="$HOME/Applications/HotspotKeeper.app"
CLI_LINK="$HOME/.local/bin/hotspot-keeper"

UNIVERSAL=0
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --no-install) INSTALL=0 ;;
  esac
done

rm -rf "$APP_BUILD"
mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"

COMMON_FLAGS=(
  -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter
  -mmacosx-version-min=14.0
  -framework AppKit
  -framework Foundation
  -framework SystemConfiguration
  -framework CoreWLAN
  -framework IOKit
)

if [[ "$UNIVERSAL" -eq 1 ]]; then
  clang -arch arm64  "${COMMON_FLAGS[@]}" "$ROOT/Sources/main.m" -o "$ROOT/build/HotspotKeeper-arm64"
  clang -arch x86_64 "${COMMON_FLAGS[@]}" "$ROOT/Sources/main.m" -o "$ROOT/build/HotspotKeeper-x86_64"
  lipo -create -output "$APP_BUILD/Contents/MacOS/HotspotKeeper" \
    "$ROOT/build/HotspotKeeper-arm64" "$ROOT/build/HotspotKeeper-x86_64"
  rm -f "$ROOT/build/HotspotKeeper-arm64" "$ROOT/build/HotspotKeeper-x86_64"
else
  clang "${COMMON_FLAGS[@]}" "$ROOT/Sources/main.m" -o "$APP_BUILD/Contents/MacOS/HotspotKeeper"
fi

cp "$ROOT/Resources/Info.plist" "$APP_BUILD/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_BUILD/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP_BUILD"

if [[ "$INSTALL" -eq 1 ]]; then
  mkdir -p "$HOME/Applications" "$HOME/.local/bin"
  rm -rf "$APP_INSTALL"
  ditto "$APP_BUILD" "$APP_INSTALL"
  ln -sf "$APP_INSTALL/Contents/MacOS/HotspotKeeper" "$CLI_LINK"
  echo "Installed: $APP_INSTALL"
  echo "CLI link:  $CLI_LINK"
else
  echo "Built:     $APP_BUILD"
fi
