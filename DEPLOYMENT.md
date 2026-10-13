# Wiederholbarer Updateprozess

Der produktive Server ist standardmäßig `31.70.106.152`. Nach der einmaligen
Einrichtung wird jede Änderung aus einem sauberen, committed `main` mit einem Befehl
ausgerollt:

```powershell
.\ops\update-server.ps1
```

Der Ablauf prüft lokal Backend, Mailbox-Provisioner und Flutter, pusht den aktuellen
Commit zu GitHub und startet das Update per SSH. Auf dem Server wird exklusiv genau ein
Update ausgeführt. Es akzeptiert ausschließlich einen Fast-Forward von `main`, baut die
Container, erstellt vor jeder tatsächlichen Änderung einen MariaDB-Dump samt SHA-256,
führt neue SQL-Migrationen genau einmal aus, startet Compose und wartet auf `/ready`.
Schlägt Build, Start oder Readiness fehl, wird die Anwendung auf den vorherigen Commit
zurückgesetzt; das Datenbank-Backup bleibt erhalten.

## Einmalige Einrichtung

Voraussetzungen auf dem lokalen Windows-Rechner:

- Git, Node.js, Flutter sowie OpenSSH (`ssh` und `scp`)
- Schreibzugriff auf den GitHub-Branch `main`
- ein SSH-Schlüssel für den Server

Der öffentliche Schlüssel muss beim gewünschten Serverkonto hinterlegt sein. Das
Skript verwendet standardmäßig `root`; ein anderes Konto kann mit `-SshUser` angegeben
werden. Das Konto benötigt Zugriff auf Docker und Schreibrechte in
`/opt/materialkompass`.

Auf dem Server muss das Repository bereits wie im README beschrieben eingerichtet sein:

```bash
cd /opt
git clone https://github.com/simulator-freak2/MaterialKompass.git materialkompass
cd /opt/materialkompass
cp backend/.env.example .env
nano .env
docker compose up -d --build
```

Die produktive `.env`, `backups/`, `releases/` und `.deployments/` bleiben lokal auf dem
Server und werden nicht von Git überschrieben. Vor der ersten Aktualisierung sollten
`docker compose ps` und `curl -H 'X-Forwarded-Proto: https' http://127.0.0.1:3001/ready`
erfolgreich sein.

## Normales Update

1. Änderungen testen, committen und sicherstellen, dass `git status` sauber ist.
2. Im Repository ausführen:

   ```powershell
   .\ops\update-server.ps1
   ```

3. Das Skript endet erst erfolgreich, wenn der neue Backend-Container bereit ist.

Abweichende SSH-Einstellungen werden als Parameter übergeben:

```powershell
.\ops\update-server.ps1 -SshUser deploy -IdentityFile "$env:USERPROFILE\.ssh\materialkompass"
```

Lokale Prüfungen lassen sich für einen bereits vollständig geprüften Commit bewusst mit
`-SkipChecks` überspringen. `-SkipPush` ist nur sinnvoll, wenn exakt derselbe Commit
bereits auf `origin/main` liegt.

## Client-Installer mit aktualisieren

Installer sind absichtlich nicht in Git. Die Option `-UploadReleases` überträgt nach
einem erfolgreichen Serverupdate ausschließlich die freigegebenen Dateinamen für
Windows, Linux, Android, iOS und macOS aus `releases/`. Schlüsseldateien, Quellarchive
und beliebige weitere Dateien werden nie übertragen. Jede Datei wird vor der
Veröffentlichung per SHA-256 geprüft.

```powershell
.\ops\update-server.ps1 -UploadReleases
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

Beim allerersten Lauf werden alle Migrationsdateien des bisher auf dem Server
ausgecheckten Commits als vorhandener Ausgangsstand registriert. Dieser Commit muss
daher dem tatsächlich betriebenen Datenbankschema entsprechen. Bei einer historisch
nur teilweise migrierten Installation ist der Datenbankstand vor dem ersten Lauf
manuell mit den Dateien unter `backend/src/db/migrations` abzugleichen.
