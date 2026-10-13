# Fahrzeugverwaltung

## Fachlicher Umfang

Die Fahrzeugverwaltung unterscheidet die feste Fahrzeugart (`Kraftfahrzeug`, `Boot`, `Anhänger` oder `Sonstige Fahrzeugart`), die Verwendung und den davon abhängigen Fahrzeugtyp. Als Verwendungen stehen zunächst `Einsatzfahrt` und `sonstige Verwendung` bereit. Organisationsverwalter können weitere Verwendungen ergänzen; Fahrzeugwarte pflegen für jede Verwendung die auswählbaren Fahrzeugtypen.

Kennzeichen und Fahrgestellnummer sind nur bei Kraftfahrzeugen und Anhängern Pflichtfelder. Bei Booten und sonstigen Fahrzeugarten können beide Angaben leer bleiben. Funkrufname, Stellplatz, Baujahr, Status und weitere beschreibende Angaben bleiben optional.

Die besitzende Gliederung verwaltet das Fahrzeug und legt getrennt fest, welche Gliederungen es sehen beziehungsweise reservieren dürfen. Die Freigaben ersetzen keine Rollenrechte: Ein Benutzer benötigt zusätzlich immer die passende Berechtigung.

Eine ausdrücklich verknüpfte Jugendorganisation und ihre Stammgliederung dürfen ihre Fahrzeuge automatisch gegenseitig sehen und reservieren. Diese Sonderfreigabe erlaubt weder Stammdatenänderungen noch Wartung, Beladung, Ausgabe, Rücknahme oder Freigabeverwaltung. Die besitzende Gliederung entscheidet weiterhin über die Reservierung; Sicherheits- und gegebenenfalls TLE-Freigaben bleiben unverändert.

## Rollen und Berechtigungen

Die Rolle `Fahrzeugwart` ist für Stammdaten, Freigaben, Wartungen, Beladung und Beladungslisten vorgesehen. Reservierungsentscheidungen werden durch die organisatorisch zuständigen Rollen getroffen. Für primär ausrückende Fahrzeuge kann organisationsweit eine zweite Freigabe durch den Technischen Leiter Einsatz verlangt werden.

Die Fahrzeugrechte sind nach dem Prinzip der geringsten Rechte getrennt:

- Lesen und Bearbeiten der Fahrzeugstammdaten
- Verwalten der Sicht- und Reservierungsfreigaben
- Lesen und Ändern der tatsächlichen Beladung
- Erstellen und Drucken versionierter Beladungslisten
- Anfragen, Entscheiden und betrieblich Freigeben von Reservierungen
- Planen und Abschließen von Wartungen

## Reservierungen

Eine Reservierung enthält Zeitraum, Titel, Zweck, Ziel, anfragende Person, Kontakt und eine optionale Notiz. Überschneidungen werden serverseitig verhindert. Der normale Ablauf ist:

1. Eine berechtigte Person stellt eine Anfrage.
2. Die besitzende Gliederung genehmigt oder lehnt sie ab.
3. Falls für ein primär ausrückendes Fahrzeug konfiguriert, erteilt der Technische Leiter Einsatz die zweite Freigabe.
4. Bei der Ausgabe können Kilometerstand und Tankstand erfasst werden.
5. Bei der Rückgabe können Kilometerstand, Tankstand, Schäden und Notizen dokumentiert werden.

Ein Fahrzeug mit sicherheitsrelevantem Status, einer blockierenden Wartung oder einem offenen Fahrzeugmangel kann nicht ohne ausdrücklich protokollierte Übersteuerung ausgegeben werden. Reservierungen und offene Wartungen erscheinen schreibgeschützt im gemeinsamen Kalender. Andere sichtberechtigte Gliederungen sehen dort nur die für die Planung erforderlichen Fahrzeugdaten; persönliche Reservierungsdetails werden nicht offengelegt.

## Beladung und Inventar

Für jedes Fahrzeug wird automatisch ein geschützter Lagerort angelegt. Individuell geführtes Inventar wechselt beim Beladen physisch an diesen Lagerort. Bei Mengenartikeln wird die Fahrzeugmenge getrennt gebucht und von der frei verfügbaren Menge abgezogen.

Beladungen können eine Positions- oder Fachangabe enthalten. Eine Soll-Beladung wird als versionierte Beladungsliste gespeichert; eine neue Version ersetzt die vorherige aktive Version, ohne die Historie zu verlieren. Die druckbare A4-Fassung enthält Fahrzeugidentifikation, Versionsstand, Soll-/Ist-Mengen, Abweichungen sowie Unterschriftsfelder.

## Wartung und Mängel

Wartungen enthalten Typ, Termin, Status, Werkstatt, Kosten, Kilometerstand, Beschreibung und eine optionale Sicherheitsblockade. Offene Fahrzeugmängel sind in die vorhandene Mängelverwaltung integriert und können den Fahrzeugstatus automatisch auf `Defekt` setzen. Das bloße Außerdienststellen eines Fahrzeugs erzeugt keinen Mangel.

## Lebenszyklus und Aufbewahrung

Außerdienstgestellte Fahrzeuge sind standardmäßig archiviert und bleiben nachvollziehbar. Frühestens zehn Jahre nach der Außerdienststellung werden sie automatisch entfernt. Eine Löschung unterbleibt, solange offene Mängel oder eine noch vorhandene Beladung bestehen. Reservierungs-, Wartungs- und Beladungsdaten werden beim endgültigen Entfernen bereinigt; Audit-Einträge bleiben als organisatorischer Nachweis bestehen.

## Schnittstellenübersicht

- `/api/vehicles`: Fahrzeugliste und Stammdaten
- `/api/vehicles/options`: Auswahldaten für Formulare
- `/api/vehicles/sharing-candidates`: freigabefähige Gliederungen
- `/api/vehicle-settings`: organisationsweite Verwendungen und verwendungsabhängige Fahrzeugtypen
- `/api/vehicles/:id/sharing`: Sicht- und Reservierungsfreigaben
- `/api/vehicles/:id/reservations`: Reservierungen und Entscheidungen
- `/api/vehicles/:id/maintenance`: Wartungsplanung und Abschluss
- `/api/vehicles/:id/load`: tatsächliche Beladung
- `/api/vehicles/:id/load-lists`: versionierte Soll-Beladungslisten
- `/api/vehicles/:id/load-lists/:listId/print`: druckbare PDF-Fassung

Alle schreibenden Operationen werden serverseitig validiert, rollen- und mandantenbezogen autorisiert und über die vorhandene atomare Persistenz gespeichert.
