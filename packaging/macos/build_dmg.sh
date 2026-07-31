#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${1:-https://materialkompass.org}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_ROOT="$REPOSITORY_ROOT/flutter"
RELEASE_FILE="$REPOSITORY_ROOT/releases/MaterialKompass-macOS.dmg"
APP_PATH="$FLUTTER_ROOT/build/macos/Build/Products/Release/MaterialKompass.app"

command -v flutter >/dev/null
command -v hdiutil >/dev/null
SIGNED_BUILD=false
if [[ -n "${MACOS_SIGNING_IDENTITY:-}" && -n "${APPLE_ID:-}" \
  && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  command -v codesign >/dev/null
  command -v xcrun >/dev/null
  SIGNED_BUILD=true
fi

cd "$FLUTTER_ROOT"
flutter pub get
flutter build macos --release --dart-define="API_BASE_URL=$API_BASE_URL"

if [[ "$SIGNED_BUILD" == true ]]; then
  codesign --force --deep --options runtime --timestamp \
    --sign "$MACOS_SIGNING_IDENTITY" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

mkdir -p "$(dirname -- "$RELEASE_FILE")"
rm -f -- "$RELEASE_FILE"
hdiutil create -volname "MaterialKompass" -srcfolder "$APP_PATH" \
  -ov -format UDZO "$RELEASE_FILE"
if [[ "$SIGNED_BUILD" == true ]]; then
  codesign --force --timestamp --sign "$MACOS_SIGNING_IDENTITY" "$RELEASE_FILE"
  xcrun notarytool submit "$RELEASE_FILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
  xcrun stapler staple "$RELEASE_FILE"
  xcrun stapler validate "$RELEASE_FILE"
else
  echo "WARNUNG: macOS-DMG wurde ohne Signatur und Notarisierung erzeugt."
fi
echo "Installer: $RELEASE_FILE"
