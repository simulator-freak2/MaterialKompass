# Wiederholbarer Updateprozess

Der produktive Server ist standardmäßig `31.70.106.152`. Der Updater erstellt aus dem
lokalen Projekt ein geprüftes Serverpaket und überträgt es direkt per SSH. Ein Commit,
Push, GitHub-Abruf oder Git-Repository auf dem Server ist dafür nicht erforderlich:

```powershell
.\ops\deploy-package.ps1
```

Der Ablauf prüft lokal Backend, Mailbox-Provisioner und Flutter, packt nur freigegebene
Serverpfade und prüft jede Übertragung per SHA-256. Auf dem Server wird exklusiv genau
ein Update ausgeführt. Vor jeder Codeänderung entstehen ein MariaDB-Dump und ein
vollständiges Codearchiv. Danach werden Container gebaut, neue SQL-Migrationen genau
einmal ausgeführt und `/ready` geprüft. Schlägt Paketprüfung, Build, Start oder
Readiness fehl, wird der vorherige Code wiederhergestellt; das Datenbank-Backup bleibt
erhalten.

## Einmalige Einrichtung

Voraussetzungen auf dem lokalen Windows-Rechner:

- Node.js, Flutter, `tar` sowie OpenSSH (`ssh` und `scp`)
- ein SSH-Schlüssel für den Server

Der öffentliche Schlüssel muss beim gewünschten Serverkonto hinterlegt sein. Das
Skript verwendet standardmäßig `root`; ein anderes Konto kann mit `-SshUser` angegeben
werden. Das Konto benötigt Zugriff auf Docker und Schreibrechte in
`/opt/materialkompass`.

Auf dem Server muss eine bestehende MaterialKompass-Installation mit produktiver
`.env` vorhanden sein. Git wird nicht benötigt. Für eine neue Installation werden die
Startdateien einmalig nach `/opt/materialkompass` kopiert und Compose gestartet:

```bash
cd /opt/materialkompass
cp backend/.env.example .env
nano .env
docker compose up -d --build
```

Die produktive `.env`, `backups/`, `releases/`, `web-current/` und `.deployments/`
bleiben lokal auf dem Server und werden vom Paket nicht überschrieben. Vor der ersten Aktualisierung sollten
`docker compose ps` und `curl -H 'X-Forwarded-Proto: https' http://127.0.0.1:3001/ready`
erfolgreich sein.

Der Installer erzeugt bei der ersten Aktualisierung einen eigenen
`IDENTITY_KEYRING_MASTER_KEY`, falls die `.env` noch den Platzhalter enthält. Der
verschlüsselte Keyring liegt im separaten Docker-Volume
`materialkompass_identity_keyring`; er ist weder Teil des Serverpakets noch eines
MariaDB-Dumps.

## Normales Update

1. Änderungen lokal prüfen.
2. Im Projektordner ausführen:

   ```powershell
   .\ops\deploy-package.ps1
   ```

3. Das Skript endet erst erfolgreich, wenn der neue Backend-Container bereit ist.

Beim ersten Update mit `20261017_identity_crypto_erasure.sql` ist danach einmalig die
explizite Identitätsmigration auszuführen. Der genaue Stopp-, Migrations-, Neustart-
und v2-Backup-Ablauf steht im README. Reguläre Backups bleiben bis dahin gesperrt; der
vom Installer angelegte Legacy-Dump dient ausschließlich dem Rollback.

Abweichende SSH-Einstellungen werden als Parameter übergeben:

```powershell
.\ops\deploy-package.ps1 -SshUser deploy -IdentityFile "$env:USERPROFILE\.ssh\materialkompass"
```

Lokale Prüfungen lassen sich für ein bereits vollständig geprüftes Paket bewusst mit
`-SkipChecks` überspringen. Der Updater bietet diese Ausnahme in der normalen
Oberfläche nicht an.

## Client-Installer mit aktualisieren

Die Option `-UploadReleases` überträgt nach
einem erfolgreichen Serverupdate ausschließlich die freigegebenen Dateinamen für
Windows, Linux, Android, iOS und macOS aus `releases/`. Schlüsseldateien, Quellarchive
und beliebige weitere Dateien werden nie übertragen. Jede Datei wird vor der
Veröffentlichung per SHA-256 geprüft.

```powershell
.\ops\deploy-package.ps1 -Version 1.5.2 -UploadReleases
```

Die Versionswerte in `.env` müssen zu den hochgeladenen Installern passen. Flutter Web
ist derzeit kein Dienst in `compose.yaml`; dessen ZIP wird deshalb nicht automatisch in
einen unbekannten Reverse-Proxy-Webroot geschrieben.

## Kontrolle und Fehlerbehebung

```bash
cd /opt/materialkompass
docker compose ps
docker compose logs --tail=100 backend
cat .deployments/last-successful
tail -n 20 .deployments/history.log
ls -lt backups | head
```

Der automatische Rollback betrifft Anwendungscode und Container. SQL-Migrationen sind
grundsätzlich vorwärtsgerichtet und werden nicht automatisch rückgängig gemacht. Bei
einer nicht abwärtskompatiblen Migration muss der direkt davor erstellte Dump nach dem
Wiederherstellungsverfahren in `OPERATIONS.md` verwendet werden. Bereits angewendete
Migrationsdateien dürfen nicht nachträglich verändert werden; Korrekturen gehören in
eine neue, aufsteigend benannte `.sql`-Datei.

Beim allerersten Paketlauf werden alle Migrationsdateien des bisher auf dem Server
installierten Codearchivs als vorhandener Ausgangsstand registriert. Dieser Stand muss
dem tatsächlich betriebenen Datenbankschema entsprechen. Bei einer historisch
nur teilweise migrierten Installation ist der Datenbankstand vor dem ersten Lauf
manuell mit den Dateien unter `backend/src/db/migrations` abzugleichen.
