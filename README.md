# MaterialKompass

MaterialKompass ist eine interne Materialverwaltungssoftware für eine DLRG-Ortsgruppe.

## Aktueller Stand

- Backend-API mit Express und JWT-Login
- Nutzer- und Rollenverwaltung mit E-Mail-Verifizierung und Passwort-Reset
- Administratives Anlegen, Suchen, Bearbeiten, Deaktivieren und Löschen von Accounts
- Selbstverwaltung von E-Mail, Passwort und Account-Löschung
- Automatische Sperre nach fünf Fehlversuchen und Sitzungsablauf nach 60 Minuten
- DSGVO-Lebenszyklus: Deaktivierung nach 24, Löschung nach 36 Monaten ohne Login
- Vollständige, transaktionale MariaDB-Persistenz für alle Anwendungsdaten
- Flutter-Web-Startseite mit Login und Dashboard
- Seed-Daten für Rollen, Benutzer, Standorte, Kategorien und Material
- Globale, in der Software änderbare Kategorien mit Haupt- und Unterkategorien
- Inventarverwaltung für Einzel- und Mengenartikel mit automatischen Inventarnummern
- Einheitliche Inventarnummern `Gliederungsnummer-Hauptkategorie-Unterkategorie-Laufnummer`; die Gliederungsnummer ist über `GLIEDERUNGSNUMMER` konfigurierbar (Standard `10050035`)
- Aus-/Rückgabe, Umbuchung, Archiv und vollständiger Bewegungsverlauf
- Prüfungen, Mängel, Dokumente sowie XLSX-/ODS-Import und -Export
- Barcode-/QR-Code-Anzeige, Handscanner- und Webkamera-Unterstützung
- Vollständige Beschaffung mit Anträgen, allgemeinen Kategorien und Brutto-Preisen
- Beantragtes Budget auf Vorgangsebene ohne Einzelpreise im Antrag
- Freigabeworkflow mit einer Freigabe durch Vorsitz oder Schatzmeister
- Lieferanten- und Angebotsvergleich, teilbare Bestellungen und Budgetgrenzen
- Teil-/Mehrfachlieferungen, Beanstandungen und geprüfte Inventarübernahme
- Beschaffungsdokumente sowie XLSX-, ODS- und PDF-Ausgabe

## Verzeichnisstruktur

- backend/ – REST-Backend
- backend/src/db/schema.sql – MariaDB-/MySQL-Schema
- flutter/ – Flutter-Web-/Desktop-Frontend

## Lokale Ausführung

### Backend

```bash
cd backend
npm install
node server.js
```

MariaDB ist auch für die lokale Ausführung erforderlich. Vor dem Start müssen
mindestens `DB_HOST`, `DB_USER` und `DB_PASSWORD` gesetzt sein; ohne Datenbank startet
das Backend bewusst nicht, damit keine Änderungen nur im Arbeitsspeicher landen.

Das Backend lauscht standardmäßig auf `0.0.0.0:3001` und stellt dieselbe JSON-API für
Windows, Linux, Android, iOS und macOS bereit. Für eine lokale App muss
`API_BASE_URL` auf die aus Sicht des Geräts erreichbare Adresse zeigen:

- Windows, Linux und macOS: `http://localhost:3001` bei Ausführung auf demselben Rechner
- Android-Emulator: `http://10.0.2.2:3001`
- iOS-Simulator: `http://127.0.0.1:3001`
- physisches Mobilgerät: `http://<LAN-IP-des-Backend-Rechners>:3001`
- Produktion auf allen Plattformen: eine öffentliche `https://`-Adresse

Native Apps senden keinen Browser-Origin und können direkt zugreifen. Flutter Web muss
mit seiner exakten Herkunft in `CORS_ORIGIN` stehen; mehrere Werte werden mit Kommas
getrennt. `GET /health` dient als Healthcheck, `GET /api/info` liefert API- und
Client-Kompatibilitätsinformationen. Unbekannte Routen und Serverfehler antworten
einheitlich als JSON mit einer `requestId`.

Alternativ ist das Backend auf Windows, Linux und macOS mit Docker ausführbar:

```bash
cd backend
docker build -t materialkompass-backend .
docker run --env-file .env -p 3001:3001 materialkompass-backend
```

### GitHub-basierte Server-Bereitstellung

Die produktive Installation wird aus dem GitHub-Repository aktualisiert. Beim ersten
Setup wird das Repository geklont und die nicht versionierte Server-Konfiguration
angelegt:

```bash
cd /opt
git clone https://github.com/simulator-freak2/MaterialKompass.git materialkompass
cd /opt/materialkompass
cp backend/.env.example .env
nano .env
docker compose up -d --build
```

Geheimnisse mit Dollarzeichen müssen in `.env` in einfache Anführungszeichen gesetzt
werden, beispielsweise `DB_PASSWORD='ein$Passwort'`. Die Datei `.env` wird durch
`.gitignore` ausgeschlossen und darf niemals committed werden.
Vor der Übernahme einer vorhandenen Docker-Installation muss `docker volume ls` geprüft
und deren bestehender Volume-Name als `DB_VOLUME_NAME` in `.env` eingetragen werden.
Dadurch verwendet Compose die vorhandene Datenbank weiter.

Spätere Aktualisierungen benötigen nur:

```bash
cd /opt/materialkompass
git pull --ff-only
docker compose up -d --build --remove-orphans
docker compose ps
docker compose logs --tail=100 backend
curl --fail http://127.0.0.1:3001/health
```

MariaDB-Daten liegen im benannten Docker-Volume `materialkompass_db` und bleiben beim
Neuaufbau des Backend-Containers erhalten. Das Schema wird bei einer leeren Datenbank
automatisch angelegt; Migrationen für bestehende Datenbanken werden weiterhin gezielt
aus `backend/src/db/migrations` ausgeführt.

Für den Produktivbetrieb wird `backend/.env.example` als Vorlage verwendet. Besonders
`JWT_SECRET`, `INITIAL_ADMIN_PASSWORD`, `APP_BASE_URL`, `CORS_ORIGIN`, die MariaDB-
und die IONOS-SMTP-Werte müssen als Server-Umgebungsvariablen gesetzt werden. Der
erste Administrator lautet `admin@materialkompass.org`; das einmalige Startpasswort
muss direkt nach der ersten Anmeldung geändert werden.

In Produktion muss `JWT_SECRET` mindestens 32 zufällige Zeichen enthalten und
`APP_BASE_URL` HTTPS verwenden. `TRUST_PROXY` darf nur auf die tatsächliche Anzahl
vorgeschalteter Proxy-Hops gesetzt werden; ohne Reverse Proxy bleibt der Wert leer.

Ein vorhandenes MariaDB-System wird mit den SQL-Dateien in
`backend/src/db/migrations` erweitert. Die Tabelle für die fachlichen Snapshots wird
beim Backend-Start zusätzlich mit `CREATE TABLE IF NOT EXISTS` abgesichert. Bei einer
Neuinstallation enthält `backend/src/db/schema.sql` bereits das vollständige Schema.

### Flutter

```bash
cd flutter
flutter pub get
flutter run -d chrome
```

Die Web-API ist beim Build konfigurierbar:

```bash
flutter build web --dart-define=API_BASE_URL=https://materialkompass.org
```

Die Webanwendung muss auf `materialkompass.org` so ausgeliefert werden, dass Hash-Routen
für `/#/verify-email` und `/#/password-reset` an Flutter gehen. Das Backend braucht für
den IONOS-Versand typischerweise `SMTP_HOST=smtp.ionos.de`, Port 587 und TLS über
STARTTLS (`SMTP_SECURE=false`).

### Installierbare Apps und automatische Update-Prüfung

Der Flutter-Client ist nativ für Windows, Linux und Android eingerichtet. Alle drei Apps
laden ihre Anwendungsdaten über dieselbe REST-API. Beim Start und danach alle sechs
Stunden fragt die App automatisch `GET /api/client-updates/<plattform>` ab. Ein neues
Release wird über den Sicherheitsdialog des Betriebssystems geöffnet; eine konfigurierte
Mindestversion erzwingt das Update, ohne Betriebssystem-Schutzmechanismen zu umgehen.

Bei der Docker-Bereitstellung erwartet `compose.yaml` diese Release-Dateien:

```text
releases/MaterialKompass-Windows.zip
releases/MaterialKompass-Linux.tar.gz
releases/MaterialKompass-Android.apk
```

Das Verzeichnis wird schreibgeschützt nach `/app/downloads` in den Backend-Container
eingebunden. Abweichende Pfade können mit `DOWNLOAD_WINDOWS_PATH`,
`DOWNLOAD_LINUX_PATH` und `DOWNLOAD_ANDROID_PATH` konfiguriert werden.
`CLIENT_<PLATTFORM>_VERSION` bezeichnet die aktuelle, `CLIENT_<PLATTFORM>_MIN_VERSION`
die kleinste noch zulässige Version. `CLIENT_UPDATE_NOTES` enthält optionale Hinweise.
Release-Binärdateien und Signaturschlüssel werden nicht in Git eingecheckt.

Die Desktop-Pakete müssen auf dem jeweiligen Zielsystem mit der produktiven API-Adresse
gebaut werden. Vom Repository-Stamm aus beispielsweise:

```powershell
cd flutter
flutter build windows --release --dart-define=API_BASE_URL=https://materialkompass.org
cd ..
Compress-Archive -Path flutter\build\windows\x64\runner\Release\* -DestinationPath releases\MaterialKompass-Windows.zip -Force
```

```bash
cd flutter
flutter build linux --release --dart-define=API_BASE_URL=https://materialkompass.org
cd ..
tar -czf releases/MaterialKompass-Linux.tar.gz -C flutter/build/linux/x64/release/bundle .
```

Android wird als signiertes APK gebaut. Vor einem produktiven Release muss in
`flutter/android/app/build.gradle.kts` eine eigene Release-Signatur statt des
Entwicklungszertifikats konfiguriert werden. Anschließend:

```bash
cd flutter
flutter build apk --release --dart-define=API_BASE_URL=https://materialkompass.org
cp build/app/outputs/flutter-apk/app-release.apk ../releases/MaterialKompass-Android.apk
```

Nach dem Kopieren werden die passenden `CLIENT_*_VERSION`-Werte in `.env` erhöht und
der Backend-Container neu gestartet. Release-Builds akzeptieren ausschließlich eine
HTTPS-API-Adresse. Android verlangt bei direkter APK-Verteilung einmalig die Freigabe
„Unbekannte Apps installieren“; alternativ kann dasselbe APK/AAB über einen verwalteten
App-Store verteilt werden.

## Geplante Erweiterungen

Die Basis deckt Auth, Nutzer, Rollen, Standorte, Kategorien, Material, Kleidung, Mängel,
Beschaffung, Dokumente, Berichte und Dashboard ab. Alle Anwendungsdaten werden
verpflichtend in MariaDB gespeichert. Nutzer und Rollen liegen in normalisierten
Tabellen; die veränderlichen fachlichen Sammlungen werden pro Schreibanfrage als
konsistenter, transaktionaler Snapshot persistiert.
