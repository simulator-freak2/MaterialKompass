# Qualitätsanforderungen nach ISO/IEC 25010:2023

Stand: 11. September 2026

## Zweck und Geltungsbereich

Dieses Dokument übersetzt das Produktqualitätsmodell der ISO/IEC 25010:2023 in
prüfbare Anforderungen für MaterialKompass. Es gilt für Flutter-Clients, REST-API,
MariaDB-Persistenz, Mailbox-Provisioner, Containerbetrieb, Backups, CI und Installer.
Alte Release-Binärdateien sind keine Entwicklungsquelle und werden nicht bewertet.

ISO/IEC 25010 ist ein Referenzmodell und keine Zertifizierung mit universellen
Bestehensgrenzen. Die folgende Matrix ist deshalb die verbindliche, projektspezifische
Qualitätsdefinition. Eine externe Konformitätsbewertung bleibt Sache einer unabhängigen
Prüfstelle.

## Nutzungskontext und Messbasis

- Zielgruppen: Sachbearbeitung, Material- und Kleiderwarte, Fachbereichsleitungen,
  Vorsitz, Administration, Sachkundige und eingeschränkte Dienstgeräte.
- Umfang: 50 gleichzeitige Nutzer, 100.000 Materialdatensätze, 100 Standorte,
  maximal 10 MB je großer fachlicher Anfrage und zeitweise instabile Mobilnetze.
- Clients: Web sowie Windows, macOS, Linux, Android und iOS. Web unterstützt die
  aktuelle und vorherige Hauptversion der verbreiteten Browser.
- Barrierefreiheit: WCAG 2.2 AA, Tastaturbedienung, Screenreader, 200 % Textskalierung,
  ausreichende Kontraste und mindestens 48 logische Pixel große primäre Ziele.
- Sprache: Deutsch (de-DE). Technische Datumswerte und APIs bleiben locale-neutral.

## Qualitätsmatrix

| Merkmal | Verbindliche Anforderung | Automatischer oder dokumentierter Nachweis |
| --- | --- | --- |
| Funktionale Eignung | Kritische Fachabläufe besitzen Erfolgs-, Fehler- und Berechtigungstests; Buchungen sind atomar und Exporte vollständig. | Backend- und Flutter-Tests, Anforderungsfälle im README |
| Leistungseffizienz | API-Lesen p95 ≤ 500 ms, Schreiben p95 ≤ 1 s bei der Messlast; erste nutzbare Webansicht ≤ 3 s. Kapazitätsgrenzen werden vor speicherintensiver Verarbeitung geprüft. | `PERFORMANCE.md`, Größenlimits, Pagination, verzögertes Laden; produktiver Lasttest vor Freigabe |
| Kompatibilität | Versionierte API, CORS für Browser/native Clients, N-1-Abwärtskompatibilität und formatstabile Exporte. | Plattformtests, `/api/info`, Client-Update-Gate und Installer-CI |
| Interaktionsfähigkeit | WCAG 2.2 AA; verständliche deutsche Fehler, sichtbarer Fokus, Hilfetexte, Fehlerprävention und Bestätigungen für destruktive Aktionen. | Flutter-Accessibility-Tests, Widgettests und manuelle Screenreader-Prüfung |
| Zuverlässigkeit | 99,5 % Monatsverfügbarkeit; transaktionale Persistenz, idempotente Offline-Befehle, Liveness/Readiness, kontrolliertes Herunterfahren. | Backendtests, `/health`, `/ready`, Healthchecks und Betriebsprotokoll |
| Sicherheit | OWASP-ASVS-Level-2-Baseline; Vertraulichkeit, Integrität, Authentizität, Nachweisbarkeit und Widerstand gegen Missbrauch. | MFA/Passkeys/RBAC, Auditlog, Rate-Limits, CodeQL, Audit, Secret-Scan, Komponentenlisten |
| Wartbarkeit | Verantwortlichkeiten sind modular; Formatierung, Analyse und Tests blockieren fehlerhafte Änderungen. Ziel: Backend ≥ 80 %, Flutter ≥ 70 % relevante Zeilenabdeckung. | CI-Coverage-Berichte; Backend-Linienabdeckung wird bei mindestens 80 % erzwungen |
| Flexibilität | Konfiguration über validierte Umgebungswerte, additive Migrationen, sechs Clients und reproduzierbare Installer. | Konfigurationstests, Compose-Prüfung und Plattform-Builds |
| Safety | Sicherheitskritische Ausrüstung ist gekennzeichnet. Ausgabe und Reservierung versagen geschlossen, solange Prüfung, Wartung oder Status nicht sicher sind. | `material-safety`-Unit-/Integrationstests, serverseitiges Gate und sichtbare UI-Warnung |

## Freigabekriterien

Eine Änderung ist nur freigabefähig, wenn:

1. Formatierung, statische Analyse, Backend-, Provisioner- und Flutter-Tests bestehen.
2. der Web-Release-Build erfolgreich ist;
3. keine hoch eingestufte produktive npm-Schwachstelle oder erkannte Secret-Signatur
   vorhanden ist;
4. CodeQL keine neue hohe/kritische Feststellung meldet;
5. Coverage nicht unter den eingecheckten Ausgangswert fällt und neue kritische Logik
   Erfolgs- und Fail-closed-Tests besitzt;
6. Schemaänderungen additiv migrierbar und rückwärtskompatibel sind;
7. für ein Release Restore-Test, Accessibility-Stichprobe und Plattform-Smoke-Tests
   protokolliert wurden;
8. offene Restrisiken mit Eigentümer und Termin akzeptiert sind.

## Verfügbarkeit, Wiederherstellung und Aufbewahrung

- SLO: 99,5 % Verfügbarkeit pro Kalendermonat; geplante Wartung wird separat erfasst.
- RPO: höchstens 24 Stunden. Backups entstehen täglich und werden zusätzlich
  verschlüsselt auf ein getrenntes System repliziert.
- RTO: höchstens 4 Stunden. Ein Restore in eine isolierte Testdatenbank wird mindestens
  quartalsweise und vor wesentlichen Releases durchgeführt.
- Restore-Nachweise enthalten Zeitpunkt, Sicherungsdatei/Prüfsumme, Dauer, Ergebnis,
  Stichproben und verantwortliche Person; niemals Passwörter oder personenbezogene Dumps.

## Coverage-Strategie

Die Zielwerte 80 % Backend und 70 % Flutter sind Produktziele. Der gemessene
Backend-Ausgangswert beträgt 84,09 % Linienabdeckung und die CI erzwingt mindestens
80 %. Der Flutter-Ausgangswert beträgt 26,96 %; bis zum Erreichen des Zielwerts 70 %
verhindert die CI mit einer sofortigen 26,5-%-Schranke zunächst jede wesentliche
Regression. Die CI veröffentlicht
bei jedem Lauf maschinenlesbare Coverage. Solange der Gesamtbestand einen Zielwert noch
nicht erreicht, gilt zusätzlich: keine Absenkung des dokumentierten Ausgangswerts und
100 % Fallabdeckung der neu eingeführten Safety-, Authentifizierungs-, Autorisierungs-,
Persistenz- und Wiederherstellungslogik. Ungetestete reine Plattformbrücken werden über
native Smoke-Tests nachgewiesen.

## Manuelle Release-Nachweise

- Screenreader: NVDA/Windows, VoiceOver/Apple und TalkBack/Android für Login,
  Navigation, Materialsuche, Anlegen, Prüfung, Ausgabe und Fehlermeldungen.
- Tastatur: vollständiger Ablauf ohne Maus; sichtbarer Fokus; Escape schließt Dialoge
  ohne Speicherung; Enter löst nur die beschriftete Standardaktion aus.
- Skalierung: 200 % Text und schmale 390×844-Ansicht ohne Informationsverlust.
- Lasttest: repräsentative, anonymisierte Daten auf produktionsnaher Hardware.
- Restore: Verfahren aus `OPERATIONS.md`; danach Anmeldung, Materialabruf und Auditlog
  stichprobenartig prüfen.
- Installer: Signatur, Update von N-1, Neuinstallation und Deinstallation je Plattform.

## Restrisiken und Grenzen

- CI ersetzt keinen externen Penetrationstest und keine unabhängige WCAG-Prüfung.
- Native Builds für Apple/Linux benötigen die jeweiligen Zielsysteme und Signaturen.
- Ein Server mit nur einer Backendinstanz bleibt trotz Restart-Policy ein
  Verfügbarkeitsrisiko; horizontale Skalierung erfordert eine Abkehr vom globalen
  Snapshot-Lock.
- Backup-Replikation und produktive Alarmierung werden vom Betreiber bereitgestellt;
  Repository-Code kann deren tatsächliche Ausführung nur prüfbar vorbereiten.
- Fachverantwortliche müssen festlegen, welche realen Ausrüstungen als
  sicherheitskritisch gelten und welche Prüf-/Wartungsintervalle rechtlich einschlägig
  sind.

## Pflege

Die Matrix wird bei Architektur-, Rollen-, Plattform- oder Betriebsänderungen sowie
mindestens jährlich überprüft. Jede Abweichung benötigt Risiko, verantwortliche Person,
Kompensation und Termin. Nachweise verweisen auf unveränderliche CI-Läufe oder
signierte Betriebsprotokolle.
