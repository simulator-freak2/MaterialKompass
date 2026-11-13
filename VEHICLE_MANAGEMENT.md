# Fahrzeugverwaltung

## Fachlicher Umfang

Die Fahrzeugverwaltung unterscheidet die feste Fahrzeugart (`Kraftfahrzeug`, `Boot`, `Anhänger` oder `Sonstige Fahrzeugart`), die Verwendung und den davon abhängigen Fahrzeugtyp. Als Verwendungen stehen zunächst `Einsatzfahrt` und `sonstige Verwendung` bereit. Organisationsverwalter können weitere Verwendungen ergänzen; Fahrzeugwarte pflegen für jede Verwendung die auswählbaren Fahrzeugtypen.

Kennzeichen und Fahrgestellnummer sind nur bei Kraftfahrzeugen und Anhängern Pflichtfelder. Bei Booten und sonstigen Fahrzeugarten können beide Angaben leer bleiben. Funkrufname, Stellplatz, Baujahr, Status und weitere beschreibende Angaben bleiben optional.

Die besitzende Gliederung verwaltet das Fahrzeug und legt getrennt fest, welche Gliederungen es sehen beziehungsweise reservieren dürfen. Die Freigaben ersetzen keine Rollenrechte: Ein Benutzer benötigt zusätzlich immer die passende Berechtigung.

Auch zwischen einer Jugendorganisation und ihrer Stammgliederung werden Fahrzeuge nur über diese ausdrücklichen Freigaben sichtbar beziehungsweise reservierbar; die Jugendverknüpfung allein gibt keine Fahrzeuge frei. Das gilt einheitlich für Fahrzeugliste, Detailansicht, Dashboard und Kalender. Freigaben erlauben weder Stammdatenänderungen noch Wartung, Beladung, Ausgabe, Rücknahme oder Freigabeverwaltung.

Die tatsächliche Beladung und die Beladungslisten werden nur Personen mit dem Recht zum Lesen der Beladung angezeigt. Die Materialauswahl zum Beladen steht ausschließlich der besitzenden Gliederung zur Verfügung, damit freigegebene Gliederungen nicht den Inventarbestand des Besitzers einsehen können.

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

Eine Reservierung enthält Zeitraum, Titel, Zweck, Ziel, anfragende Person, Kontakt und eine optionale Notiz. Überschneidungen, vergangene Zeiträume sowie Konflikte mit Wartungen und Sperren werden beim Anlegen und beim Ändern gleichermaßen serverseitig geprüft. Eine Änderung setzt alle Freigaben zurück. Der normale Ablauf ist:

1. Eine berechtigte Person stellt eine Anfrage.
2. Die besitzende Gliederung genehmigt oder lehnt sie ab.
3. Falls für ein primär ausrückendes Fahrzeug konfiguriert, erteilt der Technische Leiter Einsatz die zweite Freigabe.
4. Bei der Ausgabe können Kilometerstand und Tankstand erfasst werden.
5. Bei der Rückgabe können Kilometerstand, Tankstand, Schäden und Notizen dokumentiert werden.

Ein Fahrzeug mit sicherheitsrelevantem Status, einer blockierenden Wartung oder einem offenen Fahrzeugmangel kann nicht ohne ausdrücklich protokollierte Übersteuerung reserviert oder ausgegeben werden. Übersteuern dürfen nur Personen der besitzenden Gliederung mit Wartungsrecht oder Admin-Rolle, und nur bei nicht sicherheitskritischen Sperren; die Begründung wird an der Reservierung und im Audit gespeichert. Kritische Mängel, ein Status `Defekt`/`Außer Dienst` und sicherheitskritische Wartungen sperren immer.

Weitere Regeln: Ein Fahrzeug kann nicht übergeben werden, solange es aus einer anderen Reservierung noch ausgegeben ist. Der Kilometerstand bei Ausgabe darf den zuletzt erfassten Stand nicht unterschreiten, bei Rückgabe nicht den Ausgabestand. Abgeschlossene, abgelehnte oder stornierte Reservierungen können weder durch die besitzende Gliederung noch durch den TLE erneut entschieden werden. Wird bei der Rückgabe ein Schaden angegeben, bietet die Oberfläche direkt die Mängelmeldung an. Wird ein Fahrzeug außer Dienst gestellt, werden offene Reservierungen mit Begründung storniert; ein ausgegebenes Fahrzeug muss vorher zurückgenommen werden. Reservierungen und offene Wartungen erscheinen schreibgeschützt im gemeinsamen Kalender. Andere sichtberechtigte Gliederungen sehen dort nur die für die Planung erforderlichen Fahrzeugdaten; persönliche Reservierungsdetails werden nicht offengelegt.

## Beladung und Inventar

Für jedes Fahrzeug wird automatisch ein geschützter Lagerort angelegt. Individuell geführtes Inventar wechselt beim Beladen physisch an diesen Lagerort. Bei Mengenartikeln wird die Fahrzeugmenge getrennt gebucht und von der frei verfügbaren Menge abgezogen.

Beladungen können eine Positions- oder Fachangabe enthalten. Beim Abladen an einen anderen als den ursprünglichen Lagerort wird kein alter Lagerplatz übernommen; ohne Zielangabe kehrt das Material an seinen Ursprungsort zurück.

Eine Soll-Beladung wird als versionierte Beladungsliste gespeichert. Sie kann sofort aktiviert oder als Entwurf gespeichert und später aktiviert werden; die Aktivierung ersetzt die vorherige aktive Version, ohne die Historie zu verlieren. Mehrfach aufgeführtes Material wird zu einer Position zusammengefasst. Jede Version ist einzeln druckbar. Die A4-Fassung enthält Fahrzeugidentifikation, Stellplatz, Versionsstand, Soll-/Ist-Mengen, Abweichungen, zusätzlich geladenes Material außerhalb der Soll-Liste sowie Unterschriftsfelder.

## Wartung und Mängel

Wartungen enthalten Typ, Status, Werkstatt, Kosten, Kilometerstand, Beschreibung, Intervall und eine optionale Sicherheitsblockade. Jede Wartung benötigt entweder einen Werkstattzeitraum (Beginn und Ende, blockiert Reservierungen) oder eine Fälligkeit. Änderungen werden vollständig validiert, bevor sie gespeichert werden. Beim Abschluss wird der Kilometerstand übernommen und – über den angegebenen Folgetermin oder das Intervall – genau einmal eine neue geplante Wartung angelegt. Abgeschlossene oder abgebrochene Wartungen können nicht wieder geöffnet werden. Offene Fahrzeugmängel sind in die vorhandene Mängelverwaltung integriert und können den Fahrzeugstatus automatisch auf `Defekt` setzen. Das bloße Außerdienststellen eines Fahrzeugs erzeugt keinen Mangel.

## Lebenszyklus und Aufbewahrung

Außerdienstgestellte Fahrzeuge sind standardmäßig archiviert und bleiben nachvollziehbar. Frühestens zehn Jahre nach der Außerdienststellung werden sie automatisch entfernt. Eine Löschung unterbleibt, solange offene Mängel oder eine noch vorhandene Beladung bestehen. Reservierungs-, Wartungs- und Beladungsdaten werden beim endgültigen Entfernen bereinigt; Audit-Einträge bleiben als organisatorischer Nachweis bestehen.

## Schnittstellenübersicht

- `/api/vehicles`: Fahrzeugliste und Stammdaten
- `/api/vehicles/options`: Auswahldaten für Formulare
- `/api/vehicles/sharing-candidates`: freigabefähige Gliederungen
- `/api/vehicle-settings`: organisationsweite Verwendungen und verwendungsabhängige Fahrzeugtypen
- `/api/vehicles/:id/sharing`: Sicht- und Reservierungsfreigaben
- `/api/vehicles/:id/maintenance`: Wartungsplanung und Abschluss
- `/api/vehicles/:id/load`: tatsächliche Beladung
- `/api/vehicles/:id/load-materials`: Materialauswahl zum Beladen (nur besitzende Gliederung)
- `/api/vehicles/:id/load-lists`: versionierte Soll-Beladungslisten
- `/api/vehicles/:id/load-lists/:listId/activate`: Entwurf oder ältere Version aktivieren
- `/api/vehicles/:id/load-lists/:listId/print`: druckbare PDF-Fassung einer Version
- `/api/vehicles/:id/load-list/print`: druckbare PDF-Fassung der aktiven Version
- `/api/vehicle-reservations`: Reservierungen anlegen, ändern, entscheiden, stornieren, ausgeben und zurücknehmen

Alle schreibenden Operationen werden serverseitig validiert, rollen- und mandantenbezogen autorisiert und über die vorhandene atomare Persistenz gespeichert.
