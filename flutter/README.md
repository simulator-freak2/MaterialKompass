# MaterialKompass

Gemeinsamer Flutter-Client für Web, Windows, macOS, Linux, Android und iOS.

## Lokaler Start

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:3001
```

Native Release-Builds erhalten die produktive HTTPS-Adresse ebenfalls über
`API_BASE_URL`. Die plattformspezifischen Paket-Skripte liegen im übergeordneten
Verzeichnis `packaging/`.

iOS- und macOS-Builds erfordern Xcode auf macOS. Eine installierbare iOS-Version
benötigt zusätzlich Apple-Code-Signing und ein passendes Provisioning Profile.
