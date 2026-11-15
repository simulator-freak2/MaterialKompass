# Aenderungsprotokoll

## [1.7.8] - 2026-11-13

-Update

## Unveroeffentlicht

- Web-Loginseite als reines HTML: in rund 0,1–0,2 s bedienbar, unabhängig vom Laden
  der App. Passwort- und Zwei-Faktor-Anmeldung (Code, Push) laufen direkt; Passkey,
  QR-Code, Pflicht-Einrichtung, Passwort vergessen und rechtliche Hinweise werden an
  die App übergeben. Die App lädt unsichtbar im Hintergrund und zeigt nach der
  Anmeldung den Arbeitsbereich.
- Abmeldung nach 60 Minuten Inaktivität: Server verwirft Zugriffs- und Refresh-Token
  einer Sitzung ohne Nutzeraktivität; automatische Abfragen und Token-Refresh zählen
  nicht als Aktivität. Die App meldet sich nach 60 Minuten ohne Eingabe lokal ab.
- Web-Start: Die Loginseite erscheint sofort als statischer Platzhalter und ist
  bei wiederholtem Aufruf in rund 0,7 s, beim allerersten Aufruf (50 Mbit/s) in
  rund 1,0 s bedienbar (vorher 1,3 beziehungsweise 2,3 s). CanvasKit und Schriften
  kommen vom eigenen Server, der Flutter-Loader wartet nicht mehr auf den Service
  Worker, dieser liefert Build-Dateien versionsgebunden aus dem Cache, und nginx
  validiert Startdateien per ETag und liefert vorkomprimierte Dateien aus.
- Kistenverwaltung: Einzelstücke als Kisten führen und mit Einzelstücken,
  Teilmengen, Kleidung und Unterkisten packen. Der Inhalt wird gesperrt und wandert
  bei Umbuchung, Ausgabe und Fahrzeugbeladung mit. Dazu kommen versionierte
  Packlisten mit PDF, Vollständigkeitsprüfung mit optionalem Mangel, Ablaufdaten,
  Scan-Suche, Inventurbestätigung als Einheit und offline erfassbare Prüfungen.
- Reservierungsänderungen werden wie Neuanlagen gegen Wartungen, Sperren und
  vergangene Zeiträume geprüft; Übersteuerungen nur durch die besitzende Gliederung.
- Ausgabe mit protokollierter Übersteuerung bei nicht kritischen Sperren, Schutz vor
  Doppelausgabe und Plausibilitätsprüfung des Kilometerstands.
- TLE-Entscheidungen können abgeschlossene Reservierungen nicht mehr überschreiben.
- Außerdienststellung storniert offene Reservierungen und ist bei ausgegebenem
  Fahrzeug gesperrt.
- Wartungsänderungen werden vor dem Speichern vollständig validiert; Abschluss mit
  Ergebnis legt den Folgetermin automatisch an; Planung ohne Werkstattzeitraum möglich.
- Beladungslisten: Entwürfe aktivierbar, Druck je Version, zusammengeführte
  Doppelpositionen, robuste PDF-Ausgabe bei Sonderzeichen.
- Inventar des Fahrzeugbesitzers ist für freigegebene Gliederungen nicht mehr über die
  Beladungsauswahl einsehbar; Kalender folgt der ausdrücklichen Fahrzeugfreigabe.
- Oberfläche: keine "null"-Anzeigen mehr, Stornieren nur wenn erlaubt, TLE-Ablehnung,
  Rückgabe mit Schaden führt direkt zur Mängelmeldung.

## [1.7.7] - 2026-11-12

-Update

## [1.7.6] - 2026-11-12

-Update

## [1.7.5] - 2026-11-12

-Update

## [1.7.4] - 2026-11-12

-Überarbeitung der Nutzerverwaltung## [1.6.3] - 2026-11-06

- Überarbeitung 2 FA
- Updater in die Installierten Apps eingebaut
- performance verbessert

## Unveroeffentlicht

- PSAgE-Prüfdokumentation für Westen in der Kleiderkammer: fest hinterlegte
  Checklisten nach der Westenkunde des DLRG LV Hessen (Stand 2023-1) für
  Schwimm-/Auftriebshilfen bzw. Prallschutzwesten und Rettungswesten mit
  N/A-, OK- und KO-Bewertung, Patronen-Soll/Ist-Abgleich, Prüfplakette und
  Altersgrenzen; automatische Ausgabesperre und Mängelanlage; je Organisation
  einstellbare Sichtprüfung durch Nutzer sowie PDF-Prüfnachweis mit optionaler
  Ablagepflicht.
- Native Apps koennen vollstaendig authentifizierte Sitzungen mit Geraete-PIN,
  Biometrie oder Windows Hello entsperren; Web-Sitzungen ueberstehen Reloads und
  bleiben bis zum Schliessen des letzten Tabs aktiv.
- Rotierende Refresh-Sitzungen, Mehrtab-Synchronisierung und kontoweiter Widerruf
  bei Logout sowie sicherheitsrelevanten Kontoaenderungen ergaenzt.
- Push-Abfragen von Vorder- und Hintergrunddienst loesen keine gegenseitigen
  Neustarts oder irrtuemlichen Meldungen ueber zu viele Versuche mehr aus.## [1.6.2] - 2026-10-27

- Überarbeitung 2 FA## [1.6.0] - 2026-10-23

- Überarbeitung 2 FA## [1.5.10] - 2026-10-23

- Einschränkung der Anmeldemöglichkeiten## [1.5.7] - 2026-10-20

-Überarbeitung Loginseite
-Überabeitung der 2FA
-Gedächtnis der Letzten Einheit Eingeführt## [1.5.6] - 2026-10-18

-2FA## [1.5.5] - 2026-10-18

-2FA## [1.5.4] - 2026-10-17

-Datenschutzupdate## [1.5.3] - 2026-10-17

-Sicherheitsupdate

## [1.7.3] - 2026-11-11

-Überarbeitung der Nutzerverwaltung## [1.6.3] - 2026-11-06

- Überarbeitung 2 FA
- Updater in die Installierten Apps eingebaut
- performance verbessert

## Unveroeffentlicht

- Native Apps koennen vollstaendig authentifizierte Sitzungen mit Geraete-PIN,
  Biometrie oder Windows Hello entsperren; Web-Sitzungen ueberstehen Reloads und
  bleiben bis zum Schliessen des letzten Tabs aktiv.
- Rotierende Refresh-Sitzungen, Mehrtab-Synchronisierung und kontoweiter Widerruf
  bei Logout sowie sicherheitsrelevanten Kontoaenderungen ergaenzt.
- Push-Abfragen von Vorder- und Hintergrunddienst loesen keine gegenseitigen
  Neustarts oder irrtuemlichen Meldungen ueber zu viele Versuche mehr aus.## [1.6.2] - 2026-10-27

- Überarbeitung 2 FA## [1.6.0] - 2026-10-23

- Überarbeitung 2 FA## [1.5.10] - 2026-10-23

- Einschränkung der Anmeldemöglichkeiten## [1.5.7] - 2026-10-20

-Überarbeitung Loginseite
-Überabeitung der 2FA
-Gedächtnis der Letzten Einheit Eingeführt## [1.5.6] - 2026-10-18

-2FA## [1.5.5] - 2026-10-18

-2FA## [1.5.4] - 2026-10-17

-Datenschutzupdate## [1.5.3] - 2026-10-17

-Sicherheitsupdate

## [1.7.1] - 2026-11-11

-Überarbeitung der Nutzerverwaltung## [1.6.3] - 2026-11-06

- Überarbeitung 2 FA
- Updater in die Installierten Apps eingebaut
- performance verbessert

## Unveroeffentlicht

- Push-Anmeldeanfragen oeffnen in der aktiven Authenticator-App automatisch einen verbindlichen Freigabedialog. Android-Benachrichtigungen fuehren beim Antippen direkt zu dieser Anfrage und verbergen Kontodetails auf dem Sperrbildschirm.

- Native Apps koennen vollstaendig authentifizierte Sitzungen mit Geraete-PIN,
  Biometrie oder Windows Hello entsperren; Web-Sitzungen ueberstehen Reloads und
  bleiben bis zum Schliessen des letzten Tabs aktiv.
- Rotierende Refresh-Sitzungen, Mehrtab-Synchronisierung und kontoweiter Widerruf
  bei Logout sowie sicherheitsrelevanten Kontoaenderungen ergaenzt.
- Push-Abfragen von Vorder- und Hintergrunddienst loesen keine gegenseitigen
  Neustarts oder irrtuemlichen Meldungen ueber zu viele Versuche mehr aus.## [1.6.2] - 2026-10-27

- Überarbeitung 2 FA## [1.6.0] - 2026-10-23

- Überarbeitung 2 FA## [1.5.10] - 2026-10-23

- Einschränkung der Anmeldemöglichkeiten## [1.5.7] - 2026-10-20

-Überarbeitung Loginseite
-Überabeitung der 2FA
-Gedächtnis der Letzten Einheit Eingeführt## [1.5.6] - 2026-10-18

-2FA## [1.5.5] - 2026-10-18

-2FA## [1.5.4] - 2026-10-17

-Datenschutzupdate## [1.5.3] - 2026-10-17

-Sicherheitsupdate

## [1.5.9] - 2026-10-23

- Einschränkung der Anmeldemöglichkeiten## [1.5.7] - 2026-10-20

-Überarbeitung Loginseite
-Überabeitung der 2FA
-Gedächtnis der Letzten Einheit Eingeführt## [1.5.6] - 2026-10-18

-2FA## [1.5.5] - 2026-10-18

-2FA## [1.5.4] - 2026-10-17

-Datenschutzupdate## [1.5.3] - 2026-10-17

-Sicherheitsupdate

## [1.5.2] - 2026-10-17

- Sicheres Updatewerkzeug hinzugefügt
- Versionsverwaltung für Backend, Web und Apps vereinheitlicht
- Changelog-Anzeige einmal pro Nutzer ergänzt
- Wartungshinweise vor der Anmeldung hinzugefügt
- Server-Deployment mit Backup und Rollback abgesichert
- SSH-Hostschlüsselprüfung verbessert
- Changelog-Anzeige im Web nach der Anmeldung stabilisiert
- Aktualisierte Web-App wird nach einem Service-Worker-Wechsel zuverlässig geladen
- Allgemeine Sicherheits- und Stabilitätsverbesserungen
