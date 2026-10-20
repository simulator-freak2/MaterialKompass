#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${1:-https://materialkompass.org}"
VERSION="${2:-1.5.1}"
BUILD_NUMBER="${3:-1}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_ROOT="$REPOSITORY_ROOT/flutter"
RELEASE_FILE="$REPOSITORY_ROOT/releases/MaterialKompass-iOS-unsigned.zip"
APP_PATH="$FLUTTER_ROOT/build/ios/iphoneos/Runner.app"

command -v flutter >/dev/null
command -v ditto >/dev/null

cd "$FLUTTER_ROOT"
flutter pub get
FIREBASE_DEFINES=()
for name in FIREBASE_API_KEY FIREBASE_APP_ID FIREBASE_MESSAGING_SENDER_ID FIREBASE_PROJECT_ID; do
  if [[ -n "${!name:-}" ]]; then FIREBASE_DEFINES+=("--dart-define=$name=${!name}"); fi
done
flutter build ios --release --no-codesign \
  --build-name="$VERSION" --build-number="$BUILD_NUMBER" \
  --dart-define="API_BASE_URL=$API_BASE_URL" "${FIREBASE_DEFINES[@]}"

mkdir -p "$(dirname -- "$RELEASE_FILE")"
rm -f -- "$RELEASE_FILE"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$RELEASE_FILE"
echo "Nicht signierter Prüf-Build: $RELEASE_FILE"
