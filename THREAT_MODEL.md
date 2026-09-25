# Bedrohungsmodell

Stand: 11. September 2026

## Schutzwerte und Vertrauensgrenzen

Zu schützen sind Konten, Rollen, MFA-Geheimnisse, Scanner-Zugangsdaten, Personenbezug,
Material- und Prüfhistorien, Beschaffungsdaten, Dokumente, Auditnachweise, Backups und
Signierschlüssel. Vertrauensgrenzen bestehen zwischen Client und TLS-Proxy, Proxy und
Backend, Backend und MariaDB/IMAP/SMTP/Adressdienst, Backend und Mailbox-Provisioner
sowie Host und Docker-Socket.

## Angreifer und Annahmen

- anonyme Internetangreifer und automatisierte Zugangstests;
- angemeldete Nutzer mit zu weit gehenden oder missbrauchten Rechten;
- kompromittierte Dienstgeräte, Clients oder E-Mail-Absender;
- manipulierte Anhänge, Archive, Tabellen und Updateartefakte;
- fehlerhafte Administration, verlorene Schlüssel und ausgefallene Infrastruktur.

TLS-Termination, Hostverschlüsselung, getrennte Backup-Replikation, Alarmierung und
Schutz der CI-Signierschlüssel liegen in der Verantwortung des Betreibers.

## Wesentliche Risiken und Kontrollen

| Risiko | Prävention/Erkennung | Restrisiko |
| --- | --- | --- |
| Kontoübernahme | bcrypt, Rate-Limits, Sperrlogik, MFA, Passkeys, kurze Challenges, Session-Versionen | Phishing und kompromittierte Endgeräte |
| Rechteausweitung/IDOR | Authentifizierung plus Routenberechtigung, Bereichsfilter, Negativtests | Fehler in neuen Fachrouten |
| Datenmanipulation/Doppelbuchung | serverseitige Validierung, Transaktionen, persist-before-response, idempotente Offline-ID | fachlich falsche, aber formal gültige Eingabe |
| Schadanhänge/ZIP-Bomben/Formeln | Größen-, Typ-, Magic-, Archiv- und Komplexitätsgrenzen; Formelneutralisierung | unbekannte Parserlücken |
| Secret-Abfluss | keine `.env`/Schlüssel in Git, lokaler Secret-Scan, GitHub-Secrets, getrennte Schlüssel | Host-/CI-Administratorzugriff |
| Token-/Datendiebstahl | HTTPS-Pflicht, HSTS, restriktives CORS, No-store, OS-Schlüsselspeicher | kompromittiertes Betriebssystem |
| Manipuliertes Update | HTTPS, Größenlimit, SHA-256, Plattformsignatur und OS-Bestätigung | kompromittierter Release-/Signierprozess |
| Docker-Socket-Missbrauch | Provisioner ohne Netzwerk, enges Protokoll, Token, allowlisted Befehle | Dienst besitzt weiterhin Host-nahe Rechte |
| Verlust/Korruption | Transaktionen, tägliche Dumps, Prüfsumme, Restore-Test, externe Replikation | RPO-Fenster und Betreiberfehler |
| Unsichere Materialausgabe | serverseitiges Safety-Gate, Prüf-/Wartungsnachweis, sichtbare Warnung, Audit | falsche Klassifizierung oder Prüfdaten |

## Sicherheitsprüfung

Vor jedem Release: Tests, `npm audit --omit=dev --audit-level=high`, CodeQL,
`node tool/secret_scan.js`, Komponenteninventar und Prüfung offener Warnungen. Mindestens
jährlich sowie nach wesentlichen Auth-/Uploadänderungen ist ein unabhängiger
Penetrationstest erforderlich. Findings erhalten Schweregrad, Eigentümer und Termin.

## Reaktion

Bei Verdacht: Zugriff begrenzen, betroffene Tokens/Schlüssel widerrufen, Beweise und
Request-IDs sichern, Datenschutz-/Betriebsverantwortliche informieren, Umfang bestimmen,
bereinigen und kontrolliert wiederherstellen. Personenbezogene Daten dürfen nicht in
Tickets oder allgemeine Logs kopiert werden.
