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
- Prüfungen, vollständiges Mängelmanagement, Dokumente sowie XLSX-/ODS-Import und -Export
- Barcode-/QR-Code-Anzeige, Handscanner- und Webkamera-Unterstützung
- ZPL-Etikettendruck über LAN für Zebra-Drucker unter Windows und Android
- Vollständige Beschaffung mit Anträgen, allgemeinen Kategorien und Brutto-Preisen
- Beantragtes Budget auf Vorgangsebene ohne Einzelpreise im Antrag
- Freigabeworkflow mit einer Freigabe durch Vorsitz oder Schatzmeister
- Lieferanten- und Angebotsvergleich, teilbare Bestellungen und Budgetgrenzen
- Teil-/Mehrfachlieferungen, Beanstandungen und geprüfte Inventarübernahme
- Beschaffungsdokumente sowie XLSX-, ODS- und PDF-Ausgabe

## Mängelmanagement

Inventar und Kleidung besitzen einen gemeinsamen, rollenbasierten Mängelworkflow:

- Statusfolge `Neu → In Prüfung → Zugewiesen → In Bearbeitung → Behoben → Geprüft/Geschlossen`
- Automatische Mangelnummern im Format `M-JJJJ-NNNN`, Prioritäten, Teilmengen,
  Schadensart, Ursache, Gefährdung, Einsatzsicherheit, Verantwortliche, Fristen und Kosten
- Kommentare, Checklisten, Folgeaufgaben, JPEG-/PNG-Nachweise und ein vollständiger Änderungsverlauf
- Bilder können bereits beim Erfassen ausgewählt werden; Gefährdungsstufe,
  Einsatzbereitschaft sowie Kontaktname, E-Mail und Telefon sind direkt hinterlegbar
- Verknüpfungen zu Prüfungen, Reparaturen, Beschaffungen und Aussonderungen sowie
  Kennzeichnung von Wiederholungen und Duplikaten
- Fehlgeschlagene Inventar- und Kleidungsprüfungen erzeugen automatisch einen Mangel
- Betroffene Artikel werden auf `Defekt` gesetzt; Rücknahmen bleiben möglich, neue
  Ausgaben werden bis zum geprüften Abschluss gesperrt
- In-App-Benachrichtigungen für neue Mängel und Eskalationen an den Vorsitz
- Listenansicht mit Suche und Filtern sowie XLSX-, ODS-, CSV-, PDF- und Druckausgabe
- Geschlossene Mängel werden archiviert und zwei Kalenderjahre nach der Archivierung
  automatisch gelöscht

Materialwarte verwalten Inventarmängel, Kleiderwarte Kleidungsmängel. Die einzelnen
Aktionen werden zusätzlich über die Berechtigungen `defects.report`, `defects.edit`,
`defects.assign`, `defects.close`, `defects.archive`, `defects.delete` und
`defects.export` gesteuert. „Löschen“ verschiebt einen geschlossenen Eintrag dabei
zunächst revisionssicher ins Archiv; die endgültige Löschung erfolgt automatisch.

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

Für die Verarbeitung unzustellbarer Adressbestätigungen wird zusätzlich das Postfach
`noreply@materialkompass.org` per IMAP geöffnet. Bei IONOS werden dafür
`IMAP_HOST=imap.ionos.de`, Port 993 und eine direkte TLS-Verbindung
(`IMAP_SECURE=true`) verwendet. Beim ersten erfolgreichen Verbindungsaufbau merkt sich
das Backend den aktuellen UID-Stand, sodass vorhandene Nachrichten nicht verarbeitet
werden. Danach prüft es das Postfach beim Start und standardmäßig alle fünf Minuten.

Nur endgültige Zustellfehler, die einer von MaterialKompass versandten
E-Mail-Adressbestätigung zugeordnet werden können, werden als vollständige `.eml`
weitergeleitet. Empfänger ist der aktive Ersteller des Kontos; fehlt dieser, erhalten
alle aktiven Admins und Accounts mit `users.write` den Rückläufer. Erst nach
erfolgreicher Weiterleitung wird die ursprüngliche Nachricht endgültig aus dem
Postfach gelöscht. Nicht zuordenbare und temporäre Rückmeldungen bleiben unangetastet.

Nicht bestätigte, durch die Nutzerverwaltung ausgelöste Adressbestätigungen erscheinen
nach 24 Stunden für alle Admins und Accounts mit `users.write` auf dem Dashboard.
Adressänderungen durch den Kontoinhaber selbst erzeugen diese Dashboard-Warnung nicht.
Vor dem Deployment auf einer vorhandenen Datenbank muss
`backend/src/db/migrations/20260726_email_verification_monitoring.sql` ausgeführt
werden.

### Fest installierbare Apps und automatische Updates

Der Flutter-Client ist nativ für Windows, Linux und Android eingerichtet. Alle drei Apps
laden ihre Anwendungsdaten über dieselbe REST-API. Beim Start und danach alle sechs
Stunden fragt die App automatisch `GET /api/client-updates/<plattform>` ab. Bei einem
neuen Release lädt MaterialKompass den Installer selbst in ein temporäres Verzeichnis,
zeigt den Fortschritt an, prüft Größe und SHA-256 und startet anschließend direkt den
System-Installer. Ein Browser oder manuelles Suchen im Download-Ordner ist nicht nötig.
Eine konfigurierte Mindestversion erzwingt das Update.

Die abschließende Sicherheitsfreigabe bleibt beim Betriebssystem: Windows verlangt je
nach Signatur/SmartScreen eine Bestätigung, Linux die Administratorfreigabe und Android
die Bestätigung des Paket-Installers. Diese Dialoge dürfen normale Apps nicht umgehen.

Bei der Docker-Bereitstellung erwartet `compose.yaml` diese Release-Dateien:

```text
releases/MaterialKompass-Windows.exe
releases/MaterialKompass-Linux.deb
releases/MaterialKompass-Android.apk
```

Das Verzeichnis wird schreibgeschützt nach `/app/downloads` in den Backend-Container
eingebunden. Abweichende Pfade können mit `DOWNLOAD_WINDOWS_PATH`,
`DOWNLOAD_LINUX_PATH` und `DOWNLOAD_ANDROID_PATH` konfiguriert werden.
`CLIENT_<PLATTFORM>_VERSION` bezeichnet die aktuelle, `CLIENT_<PLATTFORM>_MIN_VERSION`
die kleinste noch zulässige Version. `CLIENT_UPDATE_NOTES` enthält optionale Hinweise.
Release-Binärdateien und Signaturschlüssel werden nicht in Git eingecheckt.

Die Installer werden auf dem jeweiligen Zielsystem mit der produktiven API-Adresse
gebaut. Windows benötigt Flutter, Visual Studio mit C++-Desktop-Tools und Inno Setup 6:

```powershell
.\packaging\windows\build_installer.ps1 -ApiBaseUrl https://materialkompass.org -Version 1.0.0
```

```bash
bash packaging/linux/build_deb.sh https://materialkompass.org 1.0.0
```

Android wird als signiertes APK gebaut. `flutter/android/key.properties` muss auf den
dauerhaften Release-Key verweisen; Updates lassen sich nur installieren, wenn sie mit
demselben Schlüssel wie die bereits installierte App signiert sind. Anschließend:

```bash
.\packaging\android\build_installer.ps1 -ApiBaseUrl https://materialkompass.org
```

Nach dem Kopieren werden die passenden `CLIENT_*_VERSION`-Werte in `.env` erhöht und
der Backend-Container neu gestartet. Release-Builds akzeptieren ausschließlich eine
HTTPS-API-Adresse. Die erste Installation erfolgt durch Öffnen des jeweiligen EXE-,
DEB- oder APK-Installers. Danach übernimmt die App die Update-Downloads selbst.

Der GitHub-Workflow `.github/workflows/client-installers.yml` erzeugt alle drei Installer
manuell als Build-Artefakte. Für Android müssen zuvor die Repository-Secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` und
`ANDROID_KEY_PASSWORD` gesetzt werden. Windows-Installer sollten vor öffentlicher
Verteilung zusätzlich mit einem Code-Signing-Zertifikat signiert werden.

### Etikettendruck

Windows und Android können Etiketten im Format 50,8 × 25,4 mm mit 203 dpi direkt
per ZPL über eine LAN-Verbindung drucken. In Inventar, Kleiderkammer und
Beschaffungsübernahme stehen Vorschau, Mehrfachdruck und lokal gespeicherte
Druckereinstellungen zur Verfügung. Unterstützt werden mehrere Drucker mit getrennten
Standardeinstellungen für Inventar und Kleidung, Port 9100, Geschwindigkeit,
Schwärzungsgrad und Testdruck.

Als Anschlussart kann neben dem direkten LAN-Druck auch eine lokal installierte
Windows-Druckerwarteschlange gewählt werden. Dabei übergibt MaterialKompass das
vollständige ZPL als RAW-Druckauftrag an den Windows-Spooler. Unter Android kann
alternativ die Zebra-App PrintConnect als Druckertreiber verwendet werden; Druckerwahl
und Kopplung erfolgen dann in PrintConnect. Die Android-App muss dafür PrintConnect
installiert haben.

Der Druck ist den Rollen Materialwart, Kleiderwart und Vorsitz vorbehalten. Die
Webanwendung bietet bewusst keinen direkten Netzwerkdruck. Fehlgeschlagene Aufträge
können während der laufenden App-Sitzung zwischengespeichert und manuell erneut
gestartet werden; beim Schließen der App werden sie verworfen.

## Geplante Erweiterungen

Die Basis deckt Auth, Nutzer, Rollen, Standorte, Kategorien, Material, Kleidung, Mängel,
Beschaffung, Dokumente, Berichte und Dashboard ab. Alle Anwendungsdaten werden
verpflichtend in MariaDB gespeichert. Nutzer und Rollen liegen in normalisierten
Tabellen; die veränderlichen fachlichen Sammlungen werden pro Schreibanfrage als
konsistenter, transaktionaler Snapshot persistiert.
