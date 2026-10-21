# MaterialKompass Authenticator

Eigenständige 2FA-App für Android-Telefone, Android-Tablets und moderne Browser. Sie
erzeugt standardisierte TOTP-Codes (RFC 6238) und empfängt Login-Freigaben direkt vom
selbst gehosteten MaterialKompass-Backend. Firebase, Google Push, Microsoft, Okta und
andere externe Zustelldienste werden nicht verwendet.

## Sicherheitsmodell

- TOTP-Secrets und Push-Geräteschlüssel liegen im geschützten App-Speicher.
- Die QR-Kopplung ist einmalig und nach fünf Minuten ungültig.
- Push-Freigaben gelten höchstens zwei Minuten und verwenden Nummernabgleich.
- Android hält eine sichtbare, lokale Hintergrundverbindung zum eigenen Server.
- Nur HTTPS-Server werden akzeptiert; HTTP ist ausschließlich in Debug-Builds erlaubt.
- Die Web-App empfängt Freigaben nur, solange sie geöffnet ist.

Apple erlaubt eine zuverlässige Hintergrundzustellung auf iPhone und iPad nur über
APNs. Weil dieses Projekt keine US-Push-Anbieter einsetzen darf, wird kein irreführender
iOS-Hintergrundmodus angeboten. Auf iPhone/iPad kann die installierbare Web-App für TOTP
und für Freigaben im geöffneten Zustand verwendet werden.

## Entwicklung

```text
flutter pub get
flutter test
flutter run
```

Für einen produktiven Android-Build muss `android/key.properties` auf einen dauerhaft
verwahrten Release-Key zeigen. Danach erzeugt
`packaging/android/build_authenticator.ps1` die signierte APK.
