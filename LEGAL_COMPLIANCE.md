# Datenschutz- und Rechtsbetrieb

Stand: 28. Juli 2026

Dieses Dokument beschreibt den technisch vorbereiteten Rechtsbetrieb von
MaterialKompass. Es ist keine Rechtsberatung. Ob einzelne Vorschriften
anwendbar sind, hängt insbesondere von Betreiber, Rechtsform, Nutzerkreis,
Hosting, Beschäftigtenzahl und tatsächlichen Arbeitsabläufen ab.

## Vor dem Produktivbetrieb zwingend

1. Alle `LEGAL_*`-Werte aus `backend/.env.example` durch echte Angaben ersetzen.
   Der Produktionsstart wird bei fehlenden Kernangaben absichtlich abgebrochen.
2. Verantwortlichen, Rechtsgrundlagen und zuständige Datenschutzaufsicht prüfen.
   Nicht zutreffende Alternativen in `backend/src/legal-config.js` entfernen.
3. Für Hosting, E-Mail, Backups, Support und sonstige weisungsgebundene
   Dienstleister Auftragsverarbeitungsverträge nach Art. 28 DSGVO abschließen.
4. Verzeichnis der Verarbeitungstätigkeiten, Berechtigungskonzept,
   Löschkonzept, Datenschutzvorfall-Prozess und TOM-Nachweis freigeben.
5. Prüfen, ob ein Datenschutzbeauftragter zu benennen ist. Für
   nichtöffentliche Stellen gilt zusätzlich § 38 BDSG; öffentliche Stellen und
   besondere Verarbeitungssituationen haben abweichende Anforderungen.
6. Tatsächliche Aufbewahrungsfristen mit Steuer-, Handels-, Arbeits-, Vereins-,
   Vergabe- und Haftungsanforderungen abgleichen. Die technischen Standardwerte
   sind keine rechtliche Fristenentscheidung.
7. Falls Analyse, Marketing, externe Schriftarten, Videos oder andere
   nicht unbedingt erforderliche Zugriffe auf Endgeräte ergänzt werden, vor der
   Aktivierung eine wirksame Einwilligungsverwaltung nach § 25 TDDDG einbauen.

## Umgesetzte technische Maßnahmen

- Rollen- und Berechtigungsprüfung für geschützte API-Routen
- Passwörter mit bcrypt, kurzlebige signierte Anmeldetoken, Sperre nach
  Fehlversuchen und zeitlich begrenzte Einmal-Links
- HTTPS-Pflicht und explizite CORS-Ursprünge in Produktion
- Sicherheitsheader, keine API-Caches, Request-IDs und begrenzte Request-Größe
- Öffentliche, ständig erreichbare Anbieter- und Datenschutzinformationen
- Maschinenlesbare Datenkopie im Accountbereich
- Berichtigung von E-Mail und Passwort sowie Selbstlöschung des Accounts
- Pseudonymisierung direkter Kontoidentifikatoren in verbleibenden Fach- und
  Auditdaten bei Löschung; gesetzliche oder fachliche Aufbewahrung bleibt möglich
- Automatische Deaktivierung inaktiver Konten nach 24 Monaten und Löschung nach
  36 Monaten; technische Standardfristen für Audit-, Export-, Benachrichtigungs-
  und abgelaufene QR-Daten sind per `RETENTION_*` konfigurierbar
- Keine Analyse-, Werbe- oder Tracking-Komponenten; lokale Druckereinstellungen
  sind für die ausdrücklich gewünschte Funktion bestimmt
- Datenbank ist im Compose-Betrieb nur intern erreichbar; Backend-Port ist an
  Loopback gebunden und für TLS-Betrieb hinter einem Reverse Proxy vorgesehen
- Native Offline-Snapshots, Befehlswarteschlangen und QR-Prüfwerte werden im
  geschützten Schlüsselspeicher des Betriebssystems abgelegt; QR-Geheimnisse
  selbst werden nicht persistiert
- Offlinefreigaben laufen nach sieben Tagen ab, sind pro Benutzer und Gerät
  widerrufbar und werden beim nächsten Serverkontakt erneut geprüft; persönliche
  Offlinekonten benötigen zusätzlich mindestens jährlich eine vollständige 2-FA-Anmeldung

## Verarbeitungsübersicht

| Bereich | typische personenbezogene Daten | Zweck | Löschentscheidung |
|---|---|---|---|
| Konten | Name, Nutzername, E-Mail, Rollen, Anmeldezeiten, 2-FA-Status und verschlüsseltes TOTP-Geheimnis | Zugang und Berechtigungen | 24/36-Monats-Automatik oder berechtigtes Löschersuchen; Faktorwerte beim Reset sofort unbrauchbar machen |
| Inventar/Kleidung | Empfänger, zugewiesene Person, Prüfer | Ausgabe, Rückgabe, Prüfung | nach organisationsspezifischem Fach- und Haftungskonzept |
| Mängel | Meldende, Kontakte, Kommunikationsinhalte | Mangelbearbeitung und Nachweis | vorhandene Mängel-Aufbewahrungsregel, fachlich freizugeben |
| Beschaffung | Antragstellende, Genehmigende, Lieferkontakte | Beschaffungsprozess und Nachweis | Steuer-/Handels-/Vergabefristen prüfen |
| Audit/Export | pseudonymisierter Akteur, Aktion, Zeitpunkt | Sicherheit und Nachvollziehbarkeit | Standard 1095 bzw. 365 Tage, konfigurierbar |
| E-Mail/QR | Postfachdaten, Metadaten, Anmeldecode-Metadaten | Import und Anmeldung | Import-Policy bzw. 30 Tage nach QR-Ablauf |
| Dienstgeräte | Gerätekennung, Standort, verantwortliche Person, Login- und MFA-Metadaten, meldende Person und Kontakt | abgesicherter Hallenbetrieb, Mängelmeldung und Nachvollziehbarkeit | mit Geräte-, Audit- und Mängelaufbewahrung abstimmen; Geheimnisse bei Widerruf sofort unbrauchbar machen |
| Offlinebetrieb | lokaler fachlicher Snapshot, Benutzer-/Gerätekennung, ausstehende Buchungen, Konflikte und Synchronisationszeiten | Arbeiten bei fehlender Verbindung und spätere Synchronisation | standardmäßig nach 30 Tagen ohne erneute Anmeldung bereinigen; offene Buchungen nur nach ausdrücklicher Entscheidung verwerfen |

Dienstgeräte verarbeiten zusätzlich Anmelde- und Nutzungsereignisse gemeinsam
genutzter Terminals. Organisatorische Regeln müssen festlegen, wer NFC-Karten,
TOTP-Berechtigungen und System-QR-Codes erhalten darf. Vollständige Suchbegriffe
werden nicht protokolliert. Empfänger ausgegebener Artikel werden über die
Geräte-API nicht übermittelt. Temporär geöffnete Vorlagen und
Gebrauchsanweisungen werden bei Sitzungsende vom Client entfernt.

Für Geräteverlust muss der Betreiber den betroffenen Client und gegebenenfalls
den Benutzer unverzüglich sperren. Da ein vollständig getrenntes Gerät einen
Widerruf erst beim nächsten Kontakt empfangen kann, begrenzt die siebentägige
Offlinefreigabe das verbleibende Risiko. Organisatorisch ist zu dokumentieren,
wer persönliche Offline-QR-Codes erhält und wie Verlustmeldungen bearbeitet
werden. Lokale Vorschauen dürfen nicht als bereits serverseitig bestätigte
Buchungen behandelt werden.

Bei der optionalen EU-Adresssuche übermittelt ausschließlich das Backend die bereits
eingegebenen Adressbestandteile an Geoapify. Namen, Kontaktdaten und der serverseitige
API-Schlüssel werden nicht an Flutter-Clients beziehungsweise nicht zusammen mit der
Adressanfrage als Fachdaten übermittelt. Vollständige Suchanfragen werden nicht in den
Anwendungsprotokollen gespeichert; identische Anfragen werden kurzzeitig im Speicher
zwischengespeichert. Vor Produktivbetrieb sind Geoapify, dessen Datenschutzhinweise
und die erforderliche Auftragsverarbeitung in das Verzeichnis der
Verarbeitungstätigkeiten aufzunehmen.

## Betroffenenanfragen

Die Datenkopie unter **Mein Account → Meine Daten herunterladen** erfasst
Datensätze, die über Konto-ID, Name, Nutzername oder E-Mail unmittelbar
zugeordnet werden können. Vor einer manuellen Auskunft müssen zusätzlich
Freitext, Anhänge, E-Mail-Postfächer, Backups und Daten bei Dienstleistern
geprüft werden. Rechte Dritter sind vor Herausgabe zu schwärzen.

Löschersuchen sind nicht automatisch mit vollständiger Vernichtung aller
Vorgangsdaten gleichzusetzen. Bestehen Aufbewahrungspflichten oder überwiegende
berechtigte Gründe, sind Daten zu sperren bzw. zu pseudonymisieren und nach
Fristablauf zu löschen. Entscheidungen und Identitätsprüfung sind außerhalb der
Anwendung zu dokumentieren.

## Sicherheits- und Vorfallbetrieb

- TLS-Zertifikate, Betriebssystem, Container und Abhängigkeiten aktuell halten.
- Backups verschlüsseln, Wiederherstellung testen und dieselben Löschfristen
  anwenden; Zugriff auf Produktionsbackups protokollieren.
- Adminrechte regelmäßig rezertifizieren und ausgeschiedene Personen sofort
  deaktivieren.
- Datenschutzverletzungen intern unverzüglich eskalieren. Die 72-Stunden-
  Bewertung nach Art. 33 DSGVO beginnt mit Bekanntwerden; Melde- und
  Benachrichtigungspflichten sind durch den Verantwortlichen zu entscheiden.
- Keine Produktionsdaten in Entwicklung, Supporttickets oder ungeschützte
  Exporte übernehmen.

## Weitere Anwendbarkeitsprüfungen

- DDG-Anbieterangaben sind öffentlich erreichbar; Register-, Aufsichts-,
  Berufs- und Umsatzsteuerangaben müssen zur realen Organisation passen.
- Das BFSG betrifft bestimmte Produkte und Dienstleistungen für Verbraucher.
  Für eine rein interne Fachanwendung ist es regelmäßig nicht der zentrale
  Tatbestand; Barrierefreiheit sollte dennoch getestet und bei öffentlichem oder
  verbraucherbezogenem Einsatz gesondert rechtlich geprüft werden.
- DSA-/DDG-Pflichten für Vermittlungsdienste sind für die derzeitige interne
  Bestandsverwaltung nicht ersichtlich. Neue öffentliche Nutzerinhalte,
  Marktplatz- oder Hostingfunktionen erfordern eine neue Prüfung.
- Bei Beschäftigtendaten sind Mitbestimmung, § 26 BDSG und interne
  Dienst-/Betriebsvereinbarungen zu prüfen.
