# Architektur von MaterialKompass

Dieses Dokument ist der Einstieg für alle, die den Code zum ersten Mal lesen
oder ändern. Es beschreibt Verantwortlichkeiten und Abläufe; die fachlichen
Funktionen stehen im [README](README.md).

## Das System in einem Satz

Eine Flutter-App stellt die Bedienoberfläche bereit, ein Express-Backend prüft
Anmeldung und Berechtigungen und speichert die Fachdaten in MariaDB.

```text
Flutter (Web, Windows, macOS, Linux, Android, iOS)
  -> HTTPS + JSON + JWT
Express-API
  -> UserStore / PersistenceCoordinator
MariaDB
```

`JWT` ist das Anmeldetoken. Nach dem Login sendet die App es bei geschützten
Anfragen im HTTP-Header `Authorization: Bearer …`.

## Wo gehört eine Änderung hin?

| Aufgabe | Einstiegspunkt |
| --- | --- |
| App-Start, Login-Zustand, Navigation | `flutter/lib/main.dart`, `flutter/lib/pages/dashboard_page.dart` |
| Beschaffung | `flutter/lib/pages/procurement_page.dart`, `backend/src/procurement.js` |
| Inventar | `flutter/lib/pages/inventory_page.dart`, `backend/src/inventory.js` |
| Kleiderkammer | `flutter/lib/pages/wardrobe_page.dart`, Routen in `backend/src/app.js` |
| Mängel | `flutter/lib/pages/defects_page.dart`, `backend/src/defects.js` |
| Nutzer, Rollen, Anmeldung | `backend/src/user-management.js`, Authentifizierung in `backend/src/app.js` |
| Konto-2-FA und Login-Challenges | `backend/src/user-mfa.js`, `backend/src/mfa-security.js`, `backend/src/totp.js` |
| Passkey-Zeremonien und Credential-Index | `backend/src/passkeys.js`, `flutter/lib/services/passkey_service.dart` |
| Dienstgeräte und Gerätesitzungen | `backend/src/service-devices.js`, `flutter/lib/pages/service_device_*.dart` |
| Offline-Snapshot und Synchronisation | `backend/src/offline-sync.js`, `flutter/lib/services/offline_*.dart` |
| Datenbanktabellen und Migrationen | `backend/src/db/schema.sql`, `backend/src/db/migrations/` |
| Daten speichern | `backend/src/persistence-coordinator.js`, `backend/src/db/user-store.js` |
| HTTP-Transport der App | `flutter/lib/services/app_http_client.dart` |
| Authentifizierte JSON-Anfragen | `flutter/lib/services/authenticated_api_client.dart` |
| Request-Limits | `backend/src/request-rate-limiter.js` |

## Backend-Ablauf

`backend/server.js` verbindet die Datenbank, lädt den gespeicherten Stand und
erstellt anschließend die Express-App aus `backend/src/app.js`.

Eine typische Anfrage durchläuft diese Stationen:

1. Allgemeine Middleware ergänzt Request-ID und Sicherheitsheader.
2. CORS, Größenlimits und JSON-Prüfungen verwerfen ungültige Eingaben früh.
3. `request-rate-limiter.js` begrenzt Anmeldung, öffentliche Zugriffe und
   schreibende Anfragen unabhängig voneinander.
4. Die Authentifizierung prüft das JWT; die Fachroute prüft anschließend die
   benötigte Berechtigung.
5. Ein Fachmodul validiert und verändert die Daten.
6. `persistence-coordinator.js` serialisiert erfolgreiche Änderungen.
7. `user-store.js` schreibt nur tatsächlich veränderte Sammlungen in einer
   Datenbanktransaktion.
8. Fehler erreichen die zentrale JSON-Fehlerbehandlung samt Request-ID.

Große optionale Bibliotheken für Tabellen, PDF, Bilder, OCR und E-Mail werden
erst beim passenden Fachvorgang geladen. Deshalb sollen sie nicht wieder als
direkte Top-Level-Imports in `app.js` oder `defect-email-ingestion.js` landen.

## Flutter-Ablauf

`flutter/lib/main.dart` startet mit Anmeldung oder Dashboard. Die Fachseiten
werden vom Dashboard verzögert geladen, damit schwächere Geräte nicht sofort
den gesamten Anwendungscode laden und verarbeiten müssen.

Die Netzwerkschicht hat drei bewusst getrennte Ebenen:

- `api_client.dart`: öffentliche Anmelde- und Bestätigungsabläufe; in Tests
  kann ein eigener HTTP-Client eingesetzt werden.
- `app_http_client.dart`: gemeinsamer, ressourcenschonender Transport mit
  Timeout und wiederverwendeten Verbindungen. Lesezugriffe verwenden bei
  Verbindungsfehlern den verschlüsselten Snapshot. Ausdrücklich freigegebene
  Fachänderungen werden mit eindeutiger Befehls-ID offline vorgemerkt.
- `authenticated_api_client.dart`: ergänzt JWT, JSON-Konvertierung und
  einheitliche, deutschsprachige Fehler für angemeldete Fachseiten.

Bei aktivierter Konto-2-FA liefert der erste Faktor kein Anwendungs-JWT, sondern eine
fünf Minuten gültige, serverseitig einmal verwendbare Challenge. Erst TOTP oder ein
noch unbenutzter Wiederherstellungscode schließt die Anmeldung ab. TOTP-Geheimnisse
liegen AES-256-GCM-verschlüsselt, Wiederherstellungscodes nur als Prüfsummen vor.
Änderungen an Faktor oder Richtlinie fließen in die JWT-Sicherheitsversion ein.

Passkeys verwenden WebAuthn mit discoverable Credentials und verpflichtender lokaler
Nutzerprüfung. Registrierungs- und Anmelde-Challenges liegen nur gehasht, einmal
verwendbar, zeitlich begrenzt und größenbeschränkt im Arbeitsspeicher. Das Backend
ordnet Credential-IDs über einen Map-Index in konstanter Zeit einem Konto zu und
persistiert ausschließlich öffentliche Schlüssel und WebAuthn-Metadaten in
`user_passkeys`. Eine erfolgreiche Passkey-Zeremonie gilt selbst als starke Anmeldung;
TOTP wird dabei nicht zusätzlich verlangt.

Schreibzugriffe werden nicht blind automatisch wiederholt. Nur die in
`offline_http.dart` aufgeführten Vorgänge dürfen in die Warteschlange. Das
Backend speichert erfolgreiche Antworten pro Benutzer, Gerät und Befehls-ID,
sodass ein Retry dieselbe Ausgabe nicht zweimal bucht.

Ein Dienstgerät besitzt zusätzlich zu einem persönlichen Benutzer-JWT eine
widerrufbare Gerätekennung. Der Systemzugang ist kein Datenbankbenutzer und
erhält ein fünf Minuten gültiges, gerätegebundenes JWT ohne normale Rollen.
Seine wenigen Routen liegen ausschließlich unter `/api/device/`.

## Regeln für verständliche Änderungen

- Eine Datei soll eine klar benennbare Verantwortung haben. Wiederholt sich
  Infrastrukturcode in mehreren Fachseiten oder Routen, gehört er in einen
  Service beziehungsweise ein Hilfsmodul.
- Fachbegriffe bleiben deutsch und entsprechen der Oberfläche. Technische
  Begriffe und Schnittstellen folgen den üblichen englischen Namen.
- Funktionen benennen das Ergebnis oder die Wirkung (`load…`, `create…`,
  `validate…`) und vermeiden Abkürzungen, wenn diese nicht allgemein bekannt
  sind.
- Kommentare erklären Gründe und Sicherheitsregeln, nicht den unmittelbar
  sichtbaren Programmtext.
- Neue Backend-Funktionen erhalten mindestens einen Test für Erfolg und einen
  relevanten Fehlerfall. Flutter-Logik außerhalb reiner Darstellung wird nach
  Möglichkeit in testbare Services ausgelagert.
- Eine Änderung ist erst fertig, wenn Formatierung, statische Analyse und die
  betroffenen Tests erfolgreich sind.

## Lokale Qualitätsprüfung

Backend:

```bash
cd backend
npm test
```

Flutter:

```bash
cd flutter
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --release
```

Die unterstützte Node-Version steht in `backend/package.json`. Hinweise zu
Build-Größe, schwachen Geräten und Plattformgrenzen stehen in
[PERFORMANCE.md](PERFORMANCE.md).
