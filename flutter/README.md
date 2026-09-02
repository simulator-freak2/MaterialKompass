# MaterialKompass

Gemeinsamer Flutter-Client für Web, Windows, macOS, Linux, Android und iOS.
Passkey-Anmeldung steht auf Web, Windows, macOS, Android und iOS zur Verfügung. Linux
verwendet den Passwort-/TOTP-Fallback.

## Lokaler Start

Erforderlich sind Flutter 3.35 oder neuer und Dart 3.9 oder neuer.

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:3001
```

Native Release-Builds erhalten die produktive HTTPS-Adresse ebenfalls über
`API_BASE_URL`. Die plattformspezifischen Paket-Skripte liegen im übergeordneten
Verzeichnis `packaging/`.

iOS- und macOS-Builds erfordern Xcode auf macOS. Eine installierbare iOS-Version
benötigt zusätzlich Apple-Code-Signing und ein passendes Provisioning Profile.
Für native Passkeys muss dieses Provisioning Profile Associated Domains erlauben;
die produktive Domain liefert außerdem die Apple- und Android-Zuordnungsdateien aus.
Die vollständigen Variablen und Prüfschritte stehen im übergeordneten `README.md`.
Quelle, Version und Prüfsumme der selbst gehosteten Browserbrücke stehen in
`web/PASSKEYS_JS.md`.
