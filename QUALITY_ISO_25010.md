# Qualitätsanforderungen nach ISO/IEC 25010:2023

Stand: 20. Oktober 2026

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

## Kontobezogene Anmelderichtlinien

Die Auswahl zwischen allgemeiner Anmeldung, allen Dienstgeräten und ausgewählten
Dienstgeräten konkretisiert die Qualitätsmatrix wie folgt:

| Merkmal | Umsetzung und Nachweis |
| --- | --- |
| Funktionale Eignung | Die drei Richtlinien werden bei Passwort-, QR-, NFC-, Passkey- und MFA-Anmeldungen sowie bei laufenden Sitzungen einheitlich ausgewertet. Integrations- und Widgettests decken erlaubte und abgelehnte Fälle ab. |
| Leistungseffizienz | Die Entscheidung verwendet normalisierte Kontofelder und eine begrenzte Geräteliste; es entsteht keine zusätzliche Datenbankabfrage im Anfragepfad. |
| Kompatibilität | Bestehende Konten und ältere Sicherungen erhalten additiv die Voreinstellung `all_clients`; die Migration verändert vorhandene Anmeldemöglichkeiten nicht. |
| Interaktionsfähigkeit | Die Nutzerverwaltung benennt die drei Optionen verständlich, zeigt nur bei gezielter Auswahl die Geräte an und verhindert das Speichern einer leeren Auswahl. Fehler werden auf Deutsch und ohne unnötige Kontodetails ausgegeben. |
| Zuverlässigkeit | Die Richtlinie ist Teil der Sicherheitsversion eines Kontos. Änderungen entwerten bestehende Sitzungen und ausstehende MFA-Anfragen; Backups validieren Geräteverweise vor der Übernahme. |
| Sicherheit | Das Backend prüft die Richtlinie fail-closed am Anmelde- und am Sitzungs-Gate. Ausgewählte Geräte müssen zum administrierten Mandanten gehören. Änderungen werden auditiert und per Sicherheits-E-Mail angekündigt. |
| Wartbarkeit | Normalisierung, Validierung und Entscheidung liegen im Modul `login-access-policy.js`; Routen konsumieren dieselbe Funktion statt eigener Varianten. |
| Flexibilität | Eine additive MariaDB-Migration und stabile Moduswerte erlauben die schrittweise Einführung ohne Änderung bestehender Konten. |
| Safety | Keine unmittelbare fachliche Safety-Wirkung; die Beschränkung reduziert jedoch unkontrollierte Zugänge zu sicherheitsrelevanten Materialdaten. |

Vor einer produktiven Freigabe sind zusätzlich Tastatur- und Screenreader-Bedienung
des Auswahldialogs sowie ein Login-Smoke-Test auf Web und einem aktivierten nativen
Dienstgerät zu protokollieren.

## Datenreset und editierbare Sicherungen

Die administrativen Datenreset- und Wiederherstellungsfunktionen konkretisieren die
Qualitätsmatrix wie folgt:

| Merkmal | Umsetzung und Nachweis |
| --- | --- |
| Funktionale Eignung | Organisations- und Einheitenreset unterscheiden ihren Geltungsbereich; Struktur und Zugänge bleiben erhalten. Erfolgs-, Fehler-, Mandanten- und Berechtigungstests prüfen die fachliche Vollständigkeit. |
| Leistungseffizienz | Größen- und Datensatzlimits werden vor Entschlüsselung und Persistenz geprüft. Der Reset bearbeitet nur organisationsbezogene Sammlungen und persistiert sie gesammelt. |
| Kompatibilität | Exportformat 3 ist selbstbeschreibend und sektioniert; der Import bleibt zu Format 2 kompatibel. Unbekannte, doppelte oder deaktivierte Pflichtsektionen werden eindeutig abgelehnt. |
| Interaktionsfähigkeit | Destruktive Aktionen nennen Ziel und Umfang, verlangen Passwort/MFA und die EDV-gebundene Bestätigungsphrase. Deutsche Fehlertexte und das integrierte Handbuch beschreiben die Wiederherstellung. |
| Zuverlässigkeit | Der Datenbankaustausch erfolgt transaktional. Bei einem Persistenzfehler wird der In-Memory-Stand zurückgesetzt; ein Import validiert erst vollständig und ersetzt danach. |
| Sicherheit | Mandant und administrierbare Einheit werden serverseitig geprüft. Identitätsfelder bleiben im editierbaren Export authentifiziert verschlüsselt; Reset und Import werden auditiert. |
| Wartbarkeit | Formatkonvertierung, Validierung und Resetlogik sind in Backendmodulen gekapselt und durch fokussierte Regressionstests abgedeckt. |
| Flexibilität | Einzelne Datensätze können entfernt und optionale Sektionen deaktiviert werden, ohne das Format oder andere Sektionen neu erzeugen zu müssen. |

Vor der Freigabe ist zusätzlich ein manueller Restore einer bearbeiteten v3-Datei in
einer isolierten Testinstanz durchzuführen. Dabei werden mindestens Anmeldung,
Organisationswechsel, Datenumfang, Auditlog sowie das Verhalten einer deaktivierten
optionalen Sektion geprüft.

## Fahrzeugverwaltung

Die Fahrzeugverwaltung konkretisiert die Qualitätsmatrix wie folgt:

| Merkmal | Fahrzeugbezogene Umsetzung und Nachweis |
| --- | --- |
| Funktionale Eignung | Stammdaten, Freigaben, konfliktfreie Reservierung, optionale TLE-Zweitfreigabe, Ausgabe/Rückgabe, Wartung, Mängel, Ist-Beladung, versionierte Soll-Listen und PDF-Druck werden durch Integrationstests abgedeckt. |
| Leistungseffizienz | Listen sind serverseitig begrenzt und gefiltert; Zuordnungen nutzen Indizes im Arbeitsspeicher. Binäre PDF-Daten werden nur am Druckendpunkt erzeugt. |
| Kompatibilität | Fahrzeuge verwenden das bestehende Rollen-, Mandanten-, Inventar-, Mängel-, Aktivitäts-, Dashboard-, Lagerort- und Kalendersystem. |
| Interaktionsfähigkeit | Suche, Archivfilter, responsive Arbeitsbereiche, Status- und Sicherheitshinweise sowie Widget- und Accessibility-Tests decken Desktop und schmale Ansichten ab. |
| Zuverlässigkeit | Serverseitige Konfliktprüfungen verhindern Doppelreservierungen; schreibende Abläufe nutzen die atomare Persistenz und lehnen ungültige Zwischenzustände ab. |
| Sicherheit | Besitzgrenzen, explizite Sicht-/Reservierungsfreigaben und granulare Rollenrechte werden kombiniert. Persönliche Reservierungsdetails sind im gemeinsamen Kalender nur für Anfragende und zuständige Entscheider sichtbar. |
| Wartbarkeit | Fachlogik ist im Backendmodul `vehicles.js`, die Oberfläche in `vehicles_page.dart` und die Regressionstests in eigenen Testfällen gebündelt. |
| Flexibilität | Fahrzeugarten, optionale Stammdaten, Fachpositionen und die organisationsweite TLE-Option erlauben Anpassungen ohne Änderung des Grundablaufs. |
| Safety | Defekte, blockierende Wartungen und fehlende Freigaben verhindern die Ausgabe. Erlaubte Übersteuerungen benötigen eine dokumentierte Begründung. |

Zusätzliche Abnahmekriterien sind:

- Kennzeichen und Fahrgestellnummer sind Pflichtfelder und organisationsweit eindeutig.
- Sicht- und Reservierungsfreigabe werden getrennt geprüft; fremde Organisationen erhalten keine Daten.
- Beladene Mengen stehen nicht gleichzeitig als frei verfügbarer Bestand zur Verfügung.
- Fahrzeuglagerorte sind gegen allgemeines Löschen und Zweckentfremden geschützt.
- Drucklisten bilden Version, Soll, Ist und Abweichung reproduzierbar ab.
- Außerdienstgestellte Fahrzeuge werden frühestens nach zehn Jahren entfernt; offene
  Mängel oder Restbeladung verhindern die endgültige Löschung.

## Pflege

Die Matrix wird bei Architektur-, Rollen-, Plattform- oder Betriebsänderungen sowie
mindestens jährlich überprüft. Jede Abweichung benötigt Risiko, verantwortliche Person,
Kompensation und Termin. Nachweise verweisen auf unveränderliche CI-Läufe oder
signierte Betriebsprotokolle.
