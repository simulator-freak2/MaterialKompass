#!/usr/bin/env bash
set -euo pipefail

API_BASE_URL="${1:-https://materialkompass.org}"
VERSION="${2:-1.4.2}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_ROOT="$REPOSITORY_ROOT/flutter"
PACKAGE_ROOT="$FLUTTER_ROOT/build/linux-package"
RELEASE_FILE="$REPOSITORY_ROOT/releases/MaterialKompass-Linux.deb"

flutter --version >/dev/null
command -v dpkg-deb >/dev/null || { echo "dpkg-deb fehlt." >&2; exit 1; }

cd "$FLUTTER_ROOT"
flutter pub get
flutter build linux --release --dart-define="API_BASE_URL=$API_BASE_URL"

if [[ "$PACKAGE_ROOT" != "$FLUTTER_ROOT/build/linux-package" ]]; then
  echo "Unerwarteter Paketpfad: $PACKAGE_ROOT" >&2
  exit 1
fi
rm -rf -- "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT/DEBIAN" "$PACKAGE_ROOT/opt/materialkompass" \
  "$PACKAGE_ROOT/usr/bin" "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps"

cp -a "$FLUTTER_ROOT/build/linux/x64/release/bundle/." "$PACKAGE_ROOT/opt/materialkompass/"
cp "$FLUTTER_ROOT/web/icons/Icon-512.png" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/512x512/apps/materialkompass.png"

cat > "$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: materialkompass
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: MaterialKompass
Depends: libgtk-3-0, libblkid1, liblzma5, libsecret-1-0
Description: Lokale Materialverwaltung mit zentralem MaterialKompass-Backend
EOF

cat > "$PACKAGE_ROOT/usr/bin/materialkompass" <<'EOF'
#!/usr/bin/env sh
exec /opt/materialkompass/materialkompass "$@"
EOF
chmod 0755 "$PACKAGE_ROOT/usr/bin/materialkompass"

cat > "$PACKAGE_ROOT/usr/share/applications/materialkompass.desktop" <<'EOF'
[Desktop Entry]
Name=MaterialKompass
Comment=Materialverwaltung
Exec=/usr/bin/materialkompass
Icon=materialkompass
Terminal=false
Type=Application
Categories=Office;Utility;
EOF

mkdir -p "$(dirname -- "$RELEASE_FILE")"
dpkg-deb --root-owner-group --build "$PACKAGE_ROOT" "$RELEASE_FILE"
echo "Installer: $RELEASE_FILE"
