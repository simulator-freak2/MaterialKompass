# MaterialKompass-Updater

Der Windows-Updater unter `tool/updater` verwaltet Releases für Produktion
(`31.70.106.152`) und das später vorgesehene Staging-System (`85.215.181.248`).
Er speichert keine Passwörter, privaten Schlüssel oder Anmeldetokens. Vor jeder
Verbindung wird der fest gespeicherte SSH-Hostschlüssel geprüft.

## Funktionsumfang

- Backend und vorwärtsgerichtete Datenbankmigrationen mit Backup, Readiness-Prüfung
  und Anwendungsrollback
- Web-App über einen ausschließlich lokal gebundenen Nginx-Container auf Port 8080
- geprüfte Clientdateien für Windows, Linux, Android, iOS und macOS
- synchronisierte Backend-, Flutter- und Clientversionen
- Changeloganzeige einmal je Nutzer
- öffentliche, zeitgesteuerte Wartungshinweise vor der Anmeldung
- optionaler vollständiger Datenimport mit frischem Serverbackup, Adminpasswort,
  2-FA und zusätzlichem Bestätigungssatz
- lokale Prüf-Builds oder Start des GitHub-Actions-Workflows
- optionales Committen und direktes Pushen lokaler Änderungen aus dem Updater
- direkter, SHA-256-geprüfter Serverupload ohne Git-Push oder Git-Abruf
- verpflichtende Anmeldung vor jedem echten Deployment; zugelassen sind ausschließlich
  Plattformadministratoren, die als Admin die Berechtigung `organizations.write`
  besitzen und damit auch neue Organisationen anlegen dürfen
- sichtbares Live-Protokoll mit Zeitstempeln, Prozessnamen und Exit-Codes sowie
  dauerhafte lokale Logdateien ohne Passwörter oder private Schlüssel

## EXE bauen und starten

Auf dem aktuellen Entwicklungsrechner ist die .NET-10-Desktoplaufzeit bereits
installiert. Der Updater wird so gebaut:

```powershell
.\tool\updater\build-updater.ps1
```

Danach wird diese Datei gestartet:

```text
releases\MaterialKompass-Updater\MaterialKompass-Updater.exe
```

Das fertig gepackte lokale Archiv liegt unter
`releases\MaterialKompass-Updater.zip`.

Die danebenliegenden `.dll`- und `.json`-Dateien gehören zur EXE und müssen gemeinsam
kopiert werden. Ein vollständig eigenständiger Single-File-Build kann später mit
ausreichend freiem Speicher als selbstenthaltendes .NET-Publish erzeugt werden.
Der Ordner muss innerhalb des MaterialKompass-Repositorys bleiben, weil die EXE die
geprüften Skripte aus `ops` und `packaging` verwendet. Das ZIP daher in
`releases\MaterialKompass-Updater` des Repositorys entpacken.

Das Protokoll wird im unteren Bereich des Fensters live angezeigt. Über
**Logdatei öffnen** gelangt man zur vollständigen Sitzungsdatei unter
`%LOCALAPPDATA%\MaterialKompass\Updater\logs`. Fehlermeldungen zeigen diesen Pfad
ebenfalls an, damit auch lange Ausgaben vollständig erhalten bleiben.

## SSH-Schlüssel erstmalig erstellen

In PowerShell einen eigenen Ed25519-Schlüssel ausschließlich für Deployments erzeugen:

```powershell
ssh-keygen -t ed25519 -a 100 `
  -f "$env:USERPROFILE\.ssh\materialkompass_deploy_ed25519" `
  -C "materialkompass-deploy"
```

Bei der Abfrage eine starke, nur lokal bekannte Passphrase setzen. Die Datei ohne
`.pub` ist privat und darf den Rechner niemals verlassen. Damit der Updater im
Batchmodus auf den verschlüsselten Schlüssel zugreifen kann, den Windows-SSH-Agent
einmal als Administrator aktivieren und den Schlüssel in einer normalen PowerShell
laden:

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add "$env:USERPROFILE\.ssh\materialkompass_deploy_ed25519"
Get-Content "$env:USERPROFILE\.ssh\materialkompass_deploy_ed25519.pub"
```

Nur die letzte Ausgabe – den öffentlichen Schlüssel – in `authorized_keys` auf dem
Server eintragen. Im Updater anschließend bei **SSH-Schlüssel** die private Datei ohne
`.pub` auswählen. Die Passphrase wird weder von MaterialKompass gespeichert noch an
den Server übertragen.

## Einmalige Servereinrichtung

Die folgenden Schritte werden über die Serverkonsole als `root` ausgeführt. Der
öffentliche Teil des soeben erzeugten Windows-SSH-Schlüssels wird wie oben beschrieben
angezeigt. Niemals den privaten Schlüssel übertragen.

```bash
apt-get update
apt-get install -y curl unzip docker-compose-plugin
adduser --disabled-password --gecos "" materialkompass-deploy
install -d -m 700 -o materialkompass-deploy -g materialkompass-deploy \
  /home/materialkompass-deploy/.ssh
editor /home/materialkompass-deploy/.ssh/authorized_keys
chown materialkompass-deploy:materialkompass-deploy \
  /home/materialkompass-deploy/.ssh/authorized_keys
chmod 600 /home/materialkompass-deploy/.ssh/authorized_keys
usermod -aG docker materialkompass-deploy
chown -R materialkompass-deploy:materialkompass-deploy /opt/materialkompass
```

Die Mitgliedschaft in der Dockergruppe ist technisch weitreichend und praktisch
root-gleich. Sie ersetzt jedoch die direkte SSH-Anmeldung als `root`, trennt das
Deploymentkonto von normalen Konten und kann später durch rootless Docker weiter
gehärtet werden. Nach `usermod` einmal neu anmelden.

Den echten Hostfingerprint ausschließlich in der Serverkonsole ablesen:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```

Anschließend im Updater **Hostschlüssel erfassen und prüfen** wählen, die angezeigten
SHA-256-Werte exakt mit der Serverkonsole vergleichen und erst dann bestätigen. Ein
geänderter Schlüssel wird später abgelehnt.

## Reverse Proxy

Der Compose-Webdienst lauscht nur auf `127.0.0.1:8080`, das Backend nur auf
`127.0.0.1:3001`. Der bestehende TLS-Reverse-Proxy für `materialkompass.org` muss
sinngemäß so weiterleiten:

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:3001;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
}
```

Die konkrete Konfiguration erst nach `nginx -t` neu laden. Bei Apache, Caddy oder
einem Provider-Proxy gelten dieselben beiden lokalen Ziele.

## Sicherer Releaseablauf

1. Im Updater Version, Buildnummer und Changelog eintragen.
2. **Release vorbereiten** ausführen.
3. Die Änderungen prüfen; das Tool führt Backend-, Mailbox- und Fluttertests aus.
4. Optional eine Commitnachricht eintragen und **Git committen & pushen** ausführen.
   Der Updater zeigt Zielbranch und Dateien vorab an, blockiert typische
   Geheimdateinamen und führt ausschließlich einen normalen Push ohne Force aus.
5. Plattformpakete lokal oder über GitHub Actions bauen. Der Android-Build erzeugt
   sowohl `MaterialKompass-Android.apk` als auch die separate
   `MaterialKompass-Authenticator-Android.apk`; beide gehören für die Veröffentlichung
   in den Ordner `releases`.
6. **Sicherheitsvorschau** kontrollieren.
7. Gewünschte Bereiche auswählen und das Deployment starten. Vor der ersten
   Serveränderung fordert der Updater eine frische Anmeldung einschließlich der
   vorhandenen 2-FA bzw. eines Recovery-Codes an und lässt die Berechtigung durch
   `POST /api/updater/authorization` serverseitig prüfen.
8. Status, Changeloganzeige, Web-App und Downloads kontrollieren.

Der Updater erstellt aus dem lokalen Projekt eine feste, allowlist-basierte
Serverdatei und überträgt sie direkt per SSH. Der optionale Git-Push ist vom Deployment
getrennt; Git bleibt auf dem Server unnötig. `.env`, Datenbankdateien, Backups,
Laufzeitmeldungen und Downloads werden nie in das Serverpaket aufgenommen. Native
Installer sind ohne Codesignatur standardmäßig gesperrt. Die Option für unsignierte
Dateien ist ausschließlich für interne Prüf-Builds vorgesehen.

Beim einmaligen Update eines älteren Servers kann die neue Autorisierungsroute noch
fehlen. Nur bei deren Antwort `404` prüft der Updater das angemeldete Konto zusätzlich
über `GET /api/auth/me`: Auf Legacy-Ständen muss es die Rolle `Admin` besitzen; kennt
der Server bereits Plattformadministratoren, werden außerdem `platformAdmin=true` und
`organizations.write` verlangt. Vor dem Fortsetzen ist eine weitere ausdrückliche
Bestätigung nötig. Andere Fehler – insbesondere `401` und `403` – brechen das
Deployment unverändert ab. Nach dem Backend-Update wird wieder die neue Route genutzt.

## Codesignaturen

Für öffentliche Direktdownloads werden mindestens benötigt:

- Windows: Authenticode-Zertifikat mit sicherem privaten Schlüssel und Zeitstempel
- Android: dauerhafter Release-Keystore; vorzugsweise gesichert in GitHub Secrets
- macOS: Developer-ID-Zertifikat plus Apple-Notarisierung
- iOS: Apple-Developer-Zertifikat und passendes Provisioning Profile
- Linux: Repository- oder Paket-Signatur, wenn die DEB öffentlich angeboten wird

Bis diese Schlüssel eingerichtet sind, sind macOS/iOS-Builds nicht für Endnutzer
vertrauenswürdig beziehungsweise auf normalen Geräten nicht installierbar.

## Backups und Rollback

Vor Codeänderungen und Datenimporten wird ein MariaDB-Dump mit SHA-256-Prüfsumme
erzeugt. Der bisherige Anwendungscode wird unter `.deployments/archive` gesichert;
Webdateien und Downloads besitzen eigene Rückfallpfade.
SQL-Migrationen werden absichtlich nicht automatisch rückwärts ausgeführt; bei einer
nicht kompatiblen Migration wird der vorherige Dump nach `OPERATIONS.md` in eine
kontrollierte Wiederherstellung einbezogen.
