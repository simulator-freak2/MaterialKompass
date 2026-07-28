#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${1:-https://materialkompass.org}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_ROOT="$REPOSITORY_ROOT/flutter"
RELEASE_FILE="$REPOSITORY_ROOT/releases/MaterialKompass-iOS-unsigned.zip"
APP_PATH="$FLUTTER_ROOT/build/ios/iphoneos/Runner.app"

command -v flutter >/dev/null
command -v ditto >/dev/null

cd "$FLUTTER_ROOT"
flutter pub get
flutter build ios --release --no-codesign \
  --dart-define="API_BASE_URL=$API_BASE_URL"

mkdir -p "$(dirname -- "$RELEASE_FILE")"
rm -f -- "$RELEASE_FILE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_FILE"
echo "Nicht signierter Prüf-Build: $RELEASE_FILE"
