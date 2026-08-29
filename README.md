# MaterialKompass

Hinweise zum datenschutzkonformen Produktivbetrieb, Pflichtangaben und offenen
organisatorischen Maßnahmen stehen in [LEGAL_COMPLIANCE.md](LEGAL_COMPLIANCE.md).

MaterialKompass ist eine interne Materialverwaltungssoftware für eine DLRG-Ortsgruppe.

Neue Entwickler beginnen mit der [Architekturübersicht](ARCHITECTURE.md). Sie zeigt
die wichtigsten Abläufe, Verantwortlichkeiten und den richtigen Einstiegspunkt für
Änderungen.

## Aktueller Stand

- Backend-API mit Express und JWT-Login
- Nutzer- und Rollenverwaltung mit E-Mail-Verifizierung und Passwort-Reset
- Kontobezogene TOTP-Zwei-Faktor-Authentifizierung mit administrativer Pflicht,
  Einrichtungsfrist und einmal verwendbaren Wiederherstellungscodes
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
- Lieferanten mit strukturierter Pflichtadresse und auswählbaren EU-Adressvorschlägen,
  Angebotsvergleich, teilbare Bestellungen und Budgetgrenzen
- Teil-/Mehrfachlieferungen, Beanstandungen und geprüfte Inventarübernahme
- Beschaffungsdokumente sowie XLSX-, ODS- und PDF-Ausgabe
- Administrativ aktivierte Dienstgeräte mit gerätegebundenem Systemzugang,
  persönlicher Anmeldung, QR-/USB-NFC-Zugängen, optionalem TOTP/NFC-Faktor,
  IP-Netzregeln und sofortigem Widerruf
- Verschlüsselter nativer Offlinebetrieb für Materiallager, Kleiderkammer,
  Mängel und Dashboard mit sicher wiederholbarer Synchronisation

## Dienstgeräte

Admins verwalten Dienstgeräte unter **Nutzerverwaltung → Dienstgeräte**. Ein
Gerät wird dort mit Standort, Halle/Raum, Geräte-Inventarnummer, dokumentarischer
MAC-Adresse, verantwortlicher Person, organisatorischen Fachbereichen und einem
eigenen Gerätepasswort vorbereitet. Anschließend aktiviert ein Admin den
konkreten nativen Client einmalig über die normale Loginseite. Webbrowser können
nicht als Dienstgerät aktiviert werden. Die ausgegebene Gerätekennung wird im
geschützten Schlüsselspeicher des Betriebssystems abgelegt; serverseitig liegt
nur ihr Hash.

Auf einem aktivierten Gerät sind zwei Sitzungsarten verfügbar:

- Der **Systemzugang** wird mit Gerätepasswort oder einem einzeln widerrufbaren
  System-QR-Code geöffnet. Er erreicht ausschließlich die redigierte Suche, die
  Mängelerstellung und den codegeschützten Zugriff auf eine einzelne Meldung.
- **Persönliche Konten** behalten ihre Rollen und Rechte aus der
  Nutzerverwaltung. Passwort, bestehender persönlicher QR-Code oder eine am
  Gerät registrierte USB-NFC-Karte können als erster Faktor dienen.

TOTP oder eine benannte USB-NFC-Karte können je Gerät für beide Sitzungsarten
als zusätzlicher Faktor verlangt werden. IP-Adressen und IPv4-/IPv6-CIDR-Netze
lassen sich ebenfalls pro Gerät begrenzen. Eine Sperrung oder ein Schlüsselreset
macht bestehende Gerätesitzungen unmittelbar ungültig.

## Zwei-Faktor-Authentifizierung für Konten

Persönliche Konten richten TOTP unter **Mein Account → Zwei-Faktor-Authentifizierung**
mit einer üblichen Authenticator-App ein. Nach der Bestätigung werden zehn einmal
verwendbare Wiederherstellungscodes angezeigt. Diese Codes werden nur bei der
Erstellung ausgegeben und serverseitig ausschließlich gehasht gespeichert.

Admins entscheiden in der Nutzerverwaltung pro Konto, ob 2-FA freiwillig oder
verpflichtend ist. Wird die Pflicht für ein noch nicht eingerichtetes Konto aktiviert,
gilt eine Einrichtungsfrist von 14 Tagen. Nach deren Ablauf erlaubt ein eingeschränktes
Login nur noch die Einrichtung des zweiten Faktors. Passwort-, persönliche QR- und
persönliche Dienstgeräteanmeldungen durchlaufen anschließend dieselbe kurzlebige,
einmal verwendbare 2-FA-Challenge. Eine gerätebezogene MFA bleibt davon unabhängig.

2-FA-Geheimnisse werden mit AES-256-GCM und einem eigenen, zufälligen
`MFA_ENCRYPTION_KEY` verschlüsselt. Aktivierung, Deaktivierung, Richtlinienänderungen,
neue Wiederherstellungscodes und administrative Resets werden protokolliert und per
Sicherheits-E-Mail angekündigt. Ein Reset macht bestehende Sitzungen ungültig.

Die normale Systemsuche blendet ausgegebene, archivierte und ausgesonderte
Artikel aus. Für eine Mängelmeldung kann ein ausgegebener Artikel ausschließlich
über seine exakte Inventarnummer beziehungsweise seinen Barcode gefunden werden;
Empfänger- und Ausgabedaten verlassen das Backend dabei nicht. Sichtbar und
temporär zu öffnen sind nur Vorlagen und Gebrauchsanweisungen.

Jede Meldung aus einem Dienstgerät erhält eine Mängelnummer und einen zufälligen
Code im Format `ABCD-EFGH-JKLM`. Damit kann genau diese Meldung auf einem
aktivierten Dienstgerät geöffnet und bis zum Beginn der regulären Bearbeitung
geändert werden. Danach bleibt sie bis zum Ende der Mängelaufbewahrung
schreibgeschützt erreichbar. Systemzugänge laufen nach fünf Minuten ab; der
Client warnt 30 Sekunden vorher und entfernt anschließend Kontakte, Bilder,
Suchergebnisse und temporär geöffnete Dokumente.

## Offlinebetrieb

Die installierten Android-, iOS-, Windows-, Linux- und macOS-Clients halten nach
einer erfolgreichen Online-Anmeldung einen verschlüsselten, berechtigungs- und
standortgefilterten Snapshot vor. Material, Kleidung und offene Mängel können
damit ohne Verbindung gesucht und gescannt werden. Ausgabe, Rücknahme,
Umbuchung und neue textbasierte Mängelmeldungen werden lokal vorgemerkt und bei
der nächsten erreichbaren API-Verbindung automatisch übertragen. Bilder und
sonstige Anhänge werden nicht offline vorgemerkt. Die leere
Mängelbericht-Vorlage wird für die Offlinenutzung zwischengespeichert.

Jede vorgemerkte Änderung besitzt eine zufällige Befehls-ID. Das Backend merkt
sich erfolgreiche Ergebnisse pro Benutzer und Gerät, sodass ein Retry nach
Timeout oder Verbindungsabbruch keine zweite Buchung erzeugt. Fachlich nicht
mehr zulässige Änderungen bleiben als Konflikt sichtbar. Das Cloud-Symbol im
Dashboard zeigt ausstehende Änderungen und bietet eine manuelle
Synchronisation. Eine Abmeldung mit offenen Änderungen wird blockiert, sofern
der Benutzer deren Verwerfen nicht ausdrücklich bestätigt.

In den Offline-Einstellungen lassen sich die lokal benötigten Standorte, die
Nutzung von Mobilfunk und die Grenze für große Übertragungen festlegen
(Standard: 10 MB, darüber nur WLAN/LAN). Im Vordergrund wird regelmäßig sowie
beim Fortsetzen der App synchronisiert. Nicht erneuerte Snapshots und
abgelaufene Offline-Anmeldungen werden lokal nach spätestens 30 Tagen bereinigt;
ausstehende Fachbuchungen bleiben bis zur Synchronisation oder einem
ausdrücklich bestätigten Verwerfen erhalten.

Admins aktivieren den Offlinebetrieb und die erlaubten Benutzer je Dienstgerät
unter **Nutzerverwaltung → Dienstgeräte**. Persönliche Offline-QR-Codes werden
dort einzeln ausgestellt und widerrufen. Eine Offlinefreigabe gilt höchstens
sieben Tage. Der Client speichert niemals das QR-Geheimnis, sondern nur dessen
Prüfwert im durch das Betriebssystem geschützten Schlüsselspeicher. Ein
Gerätewiderruf wird beim nächsten Serverkontakt wirksam. Für normale native
Installationen wird zusätzlich eine widerrufbare Clientregistrierung angelegt;
Admins können diese unter **Offline-Installationen** einsehen und sperren.
Webbrowser erhalten keinen Offline-Schreibbetrieb.

Ein persönliches Konto ist nur offlineberechtigt, wenn es 2-FA eingerichtet und sich
innerhalb der letzten 365 Tage vollständig mit dem zweiten Faktor angemeldet hat. Die
weiterhin höchstens sieben Tage gültige gerätegebundene Offlinefreigabe wird bei
Serverkontakt automatisch verlängert. Nach Ablauf der Jahresfrist ist vor einer
weiteren Verlängerung wieder eine interaktive 2-FA-Anmeldung erforderlich.

## Inventuren

Der eigene Bereich „Inventuren“ bildet Bestandsaufnahmen für das Materialinventar
und die Kleiderkammer ab:

- Statusfolge `Angelegt → In Arbeit → Auswertung → Abgeschlossen`
- Einschränkung auf mehrere Standorte, Lagerplätze und Fachbereiche; kombinierte
  Inventuren von Material und Kleidung sind möglich
- Blindzählung oder sichtbarer Sollbestand, Ist-Mengen für Mengenartikel sowie
  `vorhanden`, `beschädigt` und `nicht vorhanden` für Einzelartikel
- Kamera-/QR-Scan auf Mobilgeräten, USB-Handscanner und filterbare Positionsliste
- Beliebige Nachzählungen mit unveränderlichem Verlauf aus Bearbeiter und Zeitpunkt
- Unbekannte Inventarnummern werden als Fundstücke für die spätere Zuordnung vorgemerkt
- Abweichungen erzeugen beim Wechsel in die Auswertung nachvollziehbare Fehlbestands-
  beziehungsweise Mangelvorgänge; technische Mängel sperren den betroffenen Artikel
- Bestands- und Standortkorrekturen werden nur beim ausdrücklich bestätigten Abschluss
  übernommen; abgeschlossene Inventuren bleiben revisionssicher unveränderlich
- Zähl- und Ergebnislisten als XLSX, ODS und PDF sowie Tabellenimport für Papierlisten

Für eine Papierinventur trägt die erzeugte Liste ihre Inventur-ID. Ausgefüllte PDF-,
JPG-, PNG-, XLSX- oder ODS-Dateien können an `inventur@materialkompass.org` gesendet
werden, wenn Betreff oder Dateiname diese ID enthält. Der IMAP-Eingang ordnet die Mail
der Inventur zu und stellt den Originalanhang zur kontrollierten Übertragung bereit;
nicht eindeutig erkannte E-Mails landen beim Jugendvorsitz zur manuellen Zuordnung.
Dies vermeidet unkontrollierte Bestandsänderungen durch unsichere Handschrift-OCR.

Materialwarte dürfen Materialinventuren, Kleiderwarte Kleiderkammerinventuren anlegen
und zählen. Der Jugendvorsitz darf beide Bereiche bearbeiten, auswerten und abschließen.
Die Einzelrechte heißen `stocktakes.read`, `stocktakes.create`, `stocktakes.count`,
`stocktakes.evaluate`, `stocktakes.export` und `stocktakes.email.import`.

## Mängelmanagement

Inventar und Kleidung besitzen einen gemeinsamen, rollenbasierten Mängelworkflow:

- Statusfolge `Neu → In Prüfung → Zugewiesen → In Bearbeitung → Behoben → Geprüft/Geschlossen`
- Automatische Mangelnummern im Format `M-JJJJ-NNNN`, Prioritäten, Teilmengen,
  Schadensart, Ursache, Gefährdung, Einsatzsicherheit, Verantwortliche, Fristen und Kosten
- Zuweisung an aktive, für den jeweiligen Bereich berechtigte Nutzerkonten oder
  wahlweise an externe Personen; Konto-Zuweisungen erzeugen eine In-App-Benachrichtigung
  und können über „Mir zugewiesen“ gefiltert werden
- Kommentare, Checklisten, Folgeaufgaben, JPEG-/PNG-Nachweise und ein vollständiger Änderungsverlauf
- Bilder können bereits beim Erfassen ausgewählt werden; Gefährdungsstufe,
  Einsatzbereitschaft, bereits getroffene Maßnahmen sowie Kontaktname, E-Mail und
  Telefon sind direkt hinterlegbar
- Mängel können zusätzlich an `maengel@materialkompass.org` gemeldet werden. Ein
  PDF-, PNG- oder JPEG-Bericht wird lokal ausgewertet, Schadensbilder werden
  automatisch getrennt und der E-Mail-Text wird als Kommentar übernommen
- Die Anwendung stellt eine leere sowie eine mit Inventarnummer und Kontaktdaten
  vorbefüllte PDF-Vorlage bereit. Unvollständige oder unsichere Scans landen in
  einer Prüfwarteschlange für berechtigte Nutzer
- Verknüpfungen zu Prüfungen, Reparaturen, Beschaffungen und Aussonderungen sowie
  Kennzeichnung von Wiederholungen und Duplikaten
- Betroffene Artikel können direkt in der Mängelbearbeitung mit oder ohne
  Ersatzbeschaffung ausgesondert werden. Bei vollständiger Aussonderung wird die
  Inventarnummer revisionssicher freigegeben und bei der nächsten automatischen
  Nummernvergabe bevorzugt wiederverwendet; bei einer Teilmenge bleibt sie belegt.
  Die Variante mit Ersatz legt zusätzlich einen vorbefüllten Beschaffungsentwurf an
- Fehlgeschlagene Inventar- und Kleidungsprüfungen erzeugen automatisch einen Mangel
- Betroffene Artikel werden auf `Defekt` gesetzt; Rücknahmen bleiben möglich, neue
  Ausgaben werden bis zum geprüften Abschluss gesperrt
- In-App-Benachrichtigungen für neue und zugewiesene Mängel sowie Eskalationen an den Vorsitz
- Listenansicht mit Suche und Filtern sowie XLSX-, ODS-, CSV-, PDF- und Druckausgabe
- Geschlossene Mängel werden archiviert und zwei Kalenderjahre nach der Archivierung
  automatisch gelöscht

Materialwarte verwalten Inventarmängel, Kleiderwarte Kleidungsmängel. Die einzelnen
Aktionen werden zusätzlich über die Berechtigungen `defects.report`, `defects.edit`,
`defects.assign`, `defects.close`, `defects.archive`, `defects.delete` und
`defects.export` gesteuert. „Löschen“ verschiebt einen geschlossenen Eintrag dabei
zunächst revisionssicher ins Archiv; die endgültige Löschung erfolgt automatisch.

Der E-Mail-Eingang verwendet ein eigenes IMAP-Postfach. Erfolgreich eingelesene
Nachrichten werden in den konfigurierten Ordner `Verarbeitet` verschoben und beim
Archivieren des zugehörigen Mangels gelöscht. Die gesamte Mail darf höchstens
25 MB, die Anhänge zusammen 20 MB, der Bericht 10 MB und jedes der höchstens zehn
Schadensbilder 8 MB groß sein. HEIC und WebP werden lokal nach JPEG konvertiert;
OCR und Dateiklassifizierung verlassen das Backend nicht.

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
curl --fail -H "X-Forwarded-Proto: https" http://127.0.0.1:3001/ready
```

MariaDB-Daten liegen im benannten Docker-Volume `materialkompass_db` und bleiben beim
Neuaufbau des Backend-Containers erhalten. Das Schema wird bei einer leeren Datenbank
automatisch angelegt; Migrationen für bestehende Datenbanken werden weiterhin gezielt
aus `backend/src/db/migrations` ausgeführt.

### Automatische Datenbanksicherungen

Der Compose-Dienst `backup` erstellt einmal täglich ab der in `BACKUP_HOUR_UTC`
festgelegten UTC-Stunde einen transaktionskonsistenten, komprimierten MariaDB-Dump.
Ein erfolgreicher Lauf wird für den jeweiligen UTC-Tag markiert, sodass Container-
Neustarts keine unnötigen Mehrfachsicherungen erzeugen. Fehlgeschlagene Läufe werden
alle 15 Minuten wiederholt. Standardmäßig liegen die Sicherungen im Serververzeichnis
`/opt/materialkompass/backups`, wenn Compose aus `/opt/materialkompass` gestartet wird,
und werden nach 30 Tagen entfernt. Ablage, Startstunde und Aufbewahrung werden in `.env`
konfiguriert:

```dotenv
BACKUP_DIR=./backups
BACKUP_HOUR_UTC=2
BACKUP_RETENTION_DAYS=30
```

Jeder Dump erhält eine SHA-256-Prüfsumme. Status und Dateien lassen sich auf dem Server
prüfen:

```bash
docker compose logs --tail=100 backup
ls -la backups
cd backups && sha256sum -c materialkompass-*.sql.gz.sha256
```

Vor dem ersten Produktiveinsatz und danach regelmäßig muss eine Wiederherstellung in
eine separate Testdatenbank geprüft werden. Beispiel (Dateiname und Testdatenbank
anpassen):

```bash
docker compose exec db sh -c \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -u root -e "CREATE DATABASE materialkompass_restore_test"'
gunzip -c backups/materialkompass-20260701T020000Z.sql.gz \
  | docker compose exec -T db sh -c \
      'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -u root materialkompass_restore_test'
```

Die Sicherungen liegen auf demselben Server und schützen damit vor Datenbankfehlern,
nicht vor dem Ausfall oder Verlust des gesamten Servers. Für vollständige
Ausfallsicherheit muss `BACKUP_DIR` zusätzlich verschlüsselt auf ein getrenntes System
repliziert werden.

Für den Produktivbetrieb wird `backend/.env.example` als Vorlage verwendet. Besonders
`JWT_SECRET`, `MFA_ENCRYPTION_KEY`, `INITIAL_ADMIN_PASSWORD`, `APP_BASE_URL`, `CORS_ORIGIN`, die MariaDB-,
IONOS-SMTP- und `DEFECT_IMAP_*`-Werte müssen als Server-Umgebungsvariablen gesetzt werden. Der
erste Administrator lautet `admin@materialkompass.org`; das einmalige Startpasswort
muss direkt nach der ersten Anmeldung geändert werden.

Physische Adressmasken verwenden eine gemeinsame EU-Adresssuche. Nach mindestens drei
Zeichen fragt das Backend Geoapify mit 450 ms Verzögerung ab und liefert strukturierte
Vorschläge für Straße, Postleitzahl, Ort und Land. Eine Auswahl befüllt diese Felder;
die Hausnummer bleibt bewusst manuell und alle Werte bleiben editierbar. Übertragen
werden nur die bereits eingegebenen Adressbestandteile, niemals Lieferanten- oder
Kontaktdaten. `GEOAPIFY_API_KEY` wird ausschließlich im Backend hinterlegt und nicht an
Clients ausgeliefert. Ohne Schlüssel oder bei einem Ausfall bleiben alle Felder manuell
ausfüllbar. `GEOAPIFY_BASE_URL` muss normalerweise nicht verändert werden.

In Produktion muss `JWT_SECRET` mindestens 32 zufällige Zeichen enthalten und
`APP_BASE_URL` HTTPS verwenden. Das Backend akzeptiert außerhalb von `/health` keine
Klartextanfragen. TLS muss daher an einem lokalen Reverse Proxy terminieren;
`TRUST_PROXY` wird eng auf diesen Proxy begrenzt (bei Compose üblicherweise `loopback`).
Der Postfach-Provisioner erhält keine allgemeine `.env`-Datei und keinen Netzwerkzugriff;
Backend und Hilfsdienst tauschen Zugangsdaten ausschließlich über das private
`materialkompass_mailbox_socket`-Volume aus.

`MFA_ENCRYPTION_KEY` muss unabhängig vom JWT- und Postfachschlüssel als 64-stelliger
zufälliger Hex-Wert erzeugt und gesichert werden. Ein Verlust macht bestehende
TOTP-Einrichtungen unlesbar; ein unkoordiniertes Austauschen des Schlüssels ist daher
nicht zulässig.

Das MariaDB-Volume enthält fachliche Daten im Datenbankformat. Der Serverdatenträger
einschließlich Backups muss deshalb betriebssystemseitig verschlüsselt und nur für die
zuständigen Administratoren zugänglich sein. Datenbank- und Root-Kennwörter müssen
getrennt sein; das Root-Kennwort wird nicht in den Backend-Container durchgereicht.

Ein vorhandenes MariaDB-System wird mit den SQL-Dateien in
`backend/src/db/migrations` erweitert. Die Tabelle für die fachlichen Snapshots wird
beim Backend-Start zusätzlich mit `CREATE TABLE IF NOT EXISTS` abgesichert. Bei einer
Neuinstallation enthält `backend/src/db/schema.sql` bereits das vollständige Schema.
Solange die Fachsammlungen noch als transaktionale Snapshots gespeichert werden,
erzwingt das Backend über eine MariaDB-Sperre genau eine aktive Backend-Instanz. Eine
zweite Instanz beendet sich beim Start, statt konkurrierende Snapshots zu überschreiben.
Für die Konto-2-FA muss bei Bestandsinstallationen vor dem neuen Backendstart
`backend/src/db/migrations/20260821_user_mfa.sql` ausgeführt werden.
`DB_CONNECTION_LIMIT` muss deshalb mindestens 2 sein. `/health` ist der reine
Prozess-Livenesscheck; `/ready` prüft zusätzlich die Datenbankverbindung.

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

Der Web-Build teilt die Fachbereiche in bedarfsgeladene Module. Der eigene, bei jedem
Build versionierte Service Worker hält die App-Oberfläche und bereits besuchte Bereiche
bei kurzen Verbindungsabbrüchen verfügbar; API-Antworten werden aus Datenschutzgründen
nicht darin gespeichert. Sichere Lesezugriffe werden bei vorübergehenden Netzfehlern
einmal wiederholt, Schreibzugriffe dagegen nie automatisch.

Android-Builds benötigen Java 17 oder neuer. Produktive APKs werden nur erstellt, wenn
`flutter/android/key.properties` auf einen dauerhaften, nicht versionierten
Release-Schlüssel verweist. Das Buildskript fällt absichtlich nicht auf einen
Debug-Schlüssel zurück.

Messwerte, Architekturentscheidungen, Plattformprüfungen und bekannte Grenzen stehen
im [Performance- und Kompatibilitätsbericht](PERFORMANCE.md).

Die Webanwendung muss auf `materialkompass.org` so ausgeliefert werden, dass Hash-Routen
für `/#/verify-email` und `/#/password-reset` an Flutter gehen. Das Backend braucht für
den IONOS-Versand typischerweise `SMTP_HOST=smtp.ionos.de`, Port 587 und TLS über
STARTTLS (`SMTP_SECURE=false`).

### Fest installierbare Apps und automatische Updates

Der Flutter-Client ist nativ für Windows, macOS, Linux, Android und iOS eingerichtet.
Alle Apps laden ihre Anwendungsdaten über dieselbe REST-API. Die Download-Auswahl wird
nur in der Webanwendung angezeigt und ist in installierten Apps ausgeblendet. Windows,
macOS, Linux und Android fragen beim Start und danach alle sechs Stunden automatisch
`GET /api/client-updates/<plattform>` ab. Bei einem neuen Release lädt MaterialKompass
den Installer in ein temporäres Verzeichnis, prüft Größe und SHA-256 und startet den
System-Installer. iOS-Updates werden wegen der Apple-Signatur- und Store-Vorgaben über
den gewählten Apple-Verteilungskanal ausgeliefert.

### Scanner-E-Mail-Adressen

Administratoren können in der Nutzerverwaltung unter „Scanner-E-Mails“ echte
docker-mailserver-Postfächer wie `scanner-geraetehaus@materialkompass.org` anlegen und
einem Zielbereich zuordnen. MaterialKompass erzeugt ein zufälliges Initialpasswort,
übergibt es an docker-mailserver und speichert es ausschließlich AES-256-GCM-
verschlüsselt. Ein Admin kann die SMTP-/IMAP-Zugangsdaten nach erneuter Bestätigung mit
dem eigenen MaterialKompass-Passwort anzeigen. Jeder Abruf wird protokolliert. Das
Entfernen eines Eintrags in MaterialKompass löscht das Postfach und vorhandene E-Mails
bewusst nicht automatisch.

Die Domain wird mit `SCANNER_EMAIL_DOMAIN`, der angezeigte Mailhostname mit
`MAILBOX_SERVER_HOST` festgelegt. Der interne Dienst `mailbox-provisioner` besitzt als
einziger MaterialKompass-Container Zugriff auf den Docker-Socket und akzeptiert nur
validierte Postfachanlagen für diese Domain. Backend und Provisionierungsdienst
authentifizieren sich mit einem mindestens 32 Zeichen langen, zufälligen
`MAILBOX_PROVISIONER_TOKEN`:

```bash
openssl rand -hex 32
```

Der erzeugte Wert wird ausschließlich in der nicht versionierten Serverdatei `.env`
gespeichert. Zusätzlich ist ein eigener `MAILBOX_PASSWORD_ENCRYPTION_KEY` mit demselben
Befehl zu erzeugen. Dieser Schlüssel muss dauerhaft gesichert werden und darf nach der
ersten Postfachanlage nicht geändert werden, da vorhandene Passwörter sonst nicht mehr
entschlüsselt werden können. docker-mailserver wird standardmäßig im Container
`mailserver` erwartet; bei einem anderen Namen muss `MAILSERVER_CONTAINER` angepasst
werden.

### Angebots-Postbox

Die Beschaffung besitzt den Reiter „Postbox“. Eingehende Angebote werden aus einem
eigenen IMAP-Postfach gelesen und nach dem Import serverseitig in den Ordner
`Verarbeitet` verschoben. Die sichtbare Adresse ist standardmäßig
`angebote@materialkompass.org`; sie kann mit `PROCUREMENT_EMAIL_ADDRESS` geändert
werden. Enthält Betreff, Nachricht oder Dateiname eine Beschaffungsnummer wie
`BA-2026-0001`, ordnet MaterialKompass die E-Mail automatisch zu. Auch der Lieferant
wird anhand seiner hinterlegten Absenderadresse vorgeschlagen.

Für den produktiven Betrieb werden `PROCUREMENT_IMAP_HOST`,
`PROCUREMENT_IMAP_USER` (üblicherweise `angebote@materialkompass.org`) und
`PROCUREMENT_IMAP_PASSWORD` benötigt. Port, TLS, Postfach, Zielordner und Prüfintervall
lassen sich mit `PROCUREMENT_IMAP_PORT`, `PROCUREMENT_IMAP_SECURE`,
`PROCUREMENT_IMAP_MAILBOX`, `PROCUREMENT_IMAP_PROCESSED_MAILBOX` und
`PROCUREMENT_IMAP_POLL_INTERVAL_MS` anpassen. Unterstützte Angebotsanhänge sind PDF,
PNG, JPG, DOCX, XLSX und ODS bis jeweils 5 MB; die gesamte Nachricht darf höchstens
25 MB groß sein.

Die abschließende Sicherheitsfreigabe bleibt beim Betriebssystem: Windows verlangt je
nach Signatur/SmartScreen eine Bestätigung, macOS Gatekeeper, Linux die
Administratorfreigabe und Android den Paket-Installer. Diese Dialoge dürfen normale
Apps nicht umgehen.

Bei der Docker-Bereitstellung erwartet `compose.yaml` diese Release-Dateien:

```text
releases/MaterialKompass-Windows.exe
releases/MaterialKompass-macOS.dmg
releases/MaterialKompass-Linux.deb
releases/MaterialKompass-Android.apk
releases/MaterialKompass-iOS.ipa
```

Das Verzeichnis wird schreibgeschützt nach `/app/downloads` in den Backend-Container
eingebunden. Abweichende Pfade können mit `DOWNLOAD_WINDOWS_PATH`,
`DOWNLOAD_MACOS_PATH`, `DOWNLOAD_LINUX_PATH`, `DOWNLOAD_ANDROID_PATH` und
`DOWNLOAD_IOS_PATH` konfiguriert werden.
`CLIENT_<PLATTFORM>_VERSION` bezeichnet die aktuelle, `CLIENT_<PLATTFORM>_MIN_VERSION`
die kleinste noch zulässige Version. `CLIENT_UPDATE_NOTES` enthält optionale Hinweise.
Release-Binärdateien und Signaturschlüssel werden nicht in Git eingecheckt.

Die Installer werden auf dem jeweiligen Zielsystem mit der produktiven API-Adresse
gebaut. Windows benötigt Flutter, Visual Studio mit C++-Desktop-Tools und Inno Setup 6:

```powershell
$env:WINDOWS_CERT_THUMBPRINT = "40-STELLIGER-ZERTIFIKAT-FINGERABDRUCK"
.\packaging\windows\build_installer.ps1 -ApiBaseUrl https://materialkompass.org -Version 1.4.1
```

Das Windows-Skript signiert und prüft Anwendung und Installer mit Authenticode.
Nur ausdrücklich mit `-AllowUnsigned` erzeugte lokale Prüf-Builds dürfen unsigniert
sein.

```bash
bash packaging/linux/build_deb.sh https://materialkompass.org 1.4.1
```

macOS wird auf einem Mac als DMG gebaut:

```bash
export MACOS_SIGNING_IDENTITY="Developer ID Application: Organisation (TEAMID)"
export APPLE_ID="apple-id@example.org"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="app-spezifisches-passwort"
bash packaging/macos/build_dmg.sh https://materialkompass.org
```

Das Skript signiert die App und das DMG, reicht das DMG zur Apple-Notarisierung ein
und prüft anschließend das Stapling-Ticket.

Android wird als signiertes APK gebaut. `flutter/android/key.properties` muss auf den
dauerhaften Release-Key verweisen; Updates lassen sich nur installieren, wenn sie mit
demselben Schlüssel wie die bereits installierte App signiert sind. Anschließend:

```bash
.\packaging\android\build_installer.ps1 -ApiBaseUrl https://materialkompass.org
```

Nach dem Kopieren werden die passenden `CLIENT_*_VERSION`-Werte in `.env` erhöht und
der Backend-Container neu gestartet. Release-Builds akzeptieren ausschließlich eine
HTTPS-API-Adresse. Die erste Installation erfolgt durch Öffnen des jeweiligen EXE-,
DMG-, DEB- oder APK-Installers. Danach übernimmt die App die Update-Downloads selbst.

Der GitHub-Workflow `.github/workflows/client-installers.yml` erzeugt Windows-, macOS-,
Linux- und Android-Installer sowie einen nicht signierten iOS-Prüf-Build. Für Android
müssen zuvor die Repository-Secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` und
`ANDROID_KEY_PASSWORD` gesetzt werden. Für Windows sind
`WINDOWS_SIGNING_PFX_BASE64` und `WINDOWS_SIGNING_PFX_PASSWORD` erforderlich. macOS
benötigt `MACOS_SIGNING_CERTIFICATE_BASE64`,
`MACOS_SIGNING_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`,
`MACOS_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID` und `APPLE_APP_PASSWORD`.
Eine auf Geräten installierbare iOS-IPA muss auf macOS mit Apple-Developer-Zertifikat
und Provisioning Profile signiert und als `releases/MaterialKompass-iOS.ipa`
veröffentlicht werden; der CI-Prüf-Build ist nicht installierbar.

Der Workflow `.github/workflows/quality.yml` führt bei Pull Requests und Änderungen
am Hauptbranch Backend- und Flutter-Tests, Flutter-Analyse, Formatprüfung,
Provisioner-Tests und den npm-Sicherheitsaudit aus.

### Etikettendruck

Windows und Android können Etiketten im Format 50,8 × 25,4 mm mit 203 dpi direkt
per ZPL über eine LAN-Verbindung drucken. In Inventar, Kleiderkammer und
Beschaffungsübernahme stehen Vorschau, Mehrfachdruck und lokal gespeicherte
Druckereinstellungen zur Verfügung. Unterstützt werden mehrere Drucker mit getrennten
Standardeinstellungen für Inventar und Kleidung, Port 9100, Geschwindigkeit,
Schwärzungsgrad und Testdruck.

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
