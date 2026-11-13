# Kistenverwaltung

## Fachlicher Umfang

Eine Kiste ist ein eigenständiger Lagerort, zum Beispiel eine Sanitätskiste, eine
Wurfsackkiste oder ein Verbandmodul. Jede Kiste ist genau einem Lagerplatz
(Gebäude → Regal → Ebene → Lagerplatz) zugewiesen und hat eine eindeutige
Kistennummer innerhalb der Gliederung. Ohne Angabe wird sie fortlaufend vergeben
(`K-001`, `K-002`, …). Kisten werden unter **Kisten → Kiste anlegen** erstellt.

Eine Kiste enthält zwei Arten von Artikeln:

| | Artikel mit Inventarnummer | Inhalt ohne Inventarnummer |
| --- | --- | --- |
| Beispiele | Pulsoximeter, Funkgerät, Wetterjacke, Kabelbinder (Mengenartikel mit Inventarnummer) | Pflasterstrips, Kompressen, Rettungsdecken |
| Datenhaltung | Inventar- oder Kleidungsdatensatz mit der Kiste als Lagerort (`containerId`) | Position der Kiste (`containerContents`) mit Bezeichnung, Menge, Einheit, Fach, Ablaufdatum, Charge und Notiz |
| In die Kiste | **Einlagern** in der Kiste oder Sammelumbuchung mit Ziel-Kiste | **Inhalt erfassen** in der Kiste |
| Aus der Kiste | **Umbuchen** auf einen Lagerplatz, ein Gebäude oder eine andere Kiste, ebenso über die normale Sammelumbuchung | nicht möglich, nur **Bearbeiten** oder **Ausbuchen** (verbraucht, entsorgt, verloren) |

Inhalt ohne Inventarnummer ist fester Bestandteil der Kiste. Versuche, ihn auf
einen anderen Lagerort umzubuchen, werden mit `409` abgewiesen.

Mengenartikel mit Inventarnummer wechseln immer vollständig in die Kiste; eine
Teilmenge wird stattdessen als Inhalt ohne Inventarnummer erfasst.

## Lagerort, Mitwandern und Ausgabe

- Wird ein Artikel mit Inventarnummer in eine Kiste gebucht, übernimmt er Gebäude
  und Lagerplatz der Kiste. Die Bewegung wird als `container-pack` bzw.
  `container-unpack` mit Quell- und Ziel-Kiste protokolliert.
- Wird die Kiste einem anderen Lagerplatz zugewiesen, folgen alle darin gelagerten
  Artikel mit Inventarnummer (Bewegung `container-follow`). Inhalt ohne
  Inventarnummer gehört ohnehin zur Kiste.
- Artikel in einer Kiste verhalten sich wie an jedem anderen Lagerort: Sie können
  ausgegeben, zurückgegeben und auf Fahrzeuge geladen werden. Beim Laden auf ein
  Fahrzeug verlassen sie die Kiste; beim Entladen ohne abweichendes Ziel kehren sie
  in die Kiste zurück. Ausgegebene oder geladene Artikel können nicht umgebucht
  werden.
- Wird ein Artikel an anderer Stelle (Inventarformular, Inventurkorrektur,
  Archivierung) an einen anderen Platz gebucht, endet die Zuordnung zur Kiste.
- Belegte Lagerplätze, Ebenen, Regale und Gebäude können nicht gelöscht werden.
  Kisten erscheinen unter **Zugeordnete Artikel** des Lagerplatzes.
- Nur leere Kisten (ohne Artikel und ohne Inhalt) können aufgelöst werden.
  Prüfprotokolle bleiben erhalten.

## Packlisten und Vollständigkeitsprüfung

Die Soll-Packliste wird wie die Fahrzeug-Beladungsliste versioniert. Eine neue aktive
Version ersetzt die vorherige, die als `Ersetzt` erhalten bleibt. Entwürfe können
später aktiviert werden. Positionen sind entweder Artikel mit Inventarnummer
(`MaterialItem`/`ClothingItem`) oder Inhalt ohne Inventarnummer (`Content`, über die
Bezeichnung zugeordnet). Die Kistenansicht zeigt laufend den Soll/Ist-Vergleich.

Eine Vollständigkeitsprüfung erfasst für jede Position der aktiven Packliste
(ohne Packliste: für jeden aktuellen Inhalt) das Ergebnis `vorhanden`, `fehlt`,
`beschädigt` oder `abgelaufen` sowie die Ist-Menge. Danach erhält die Kiste den
Status `Vollständig` oder `Unvollständig`. Bei Abweichungen kann für jeden
betroffenen Artikel mit Inventarnummer direkt ein Mangel angelegt werden; nur die
Priorität `Kritisch` setzt den Artikel auf `Defekt`. Fehlender Inhalt ohne
Inventarnummer wird über den Kistenstatus und das Prüfprotokoll nachverfolgt. Pro
Kiste werden die letzten 500 Prüfprotokolle aufbewahrt.

Die Packliste lässt sich als A4-PDF mit Soll-, Ist- und Ablaufangaben, einer
Prüfspalte und einem Unterschriftsfeld drucken.

## Ablaufdaten

Jede Kiste hat eine Vorwarnzeit von 0 bis 365 Tagen, standardmäßig 30. Inhalte ohne
Inventarnummer mit Ablaufdatum erscheinen als `läuft bald ab` oder `abgelaufen` in
der Kistenübersicht, in der Kistenansicht und unter **Kisten → Ablaufende Inhalte**.

## Scan, Inventur und Offlinebetrieb

- Ein Scan in der Kistenübersicht öffnet die Kiste über ihre Kistennummer oder die
  Kiste, in der der gescannte Artikel liegt.
- Inventurpositionen zeigen, in welcher Kiste ein Artikel liegt. Eine verschlossen
  vorgefundene Kiste kann als Einheit bestätigt werden: Alle noch nicht gezählten
  Einzelstücke mit Inventarnummer darin gelten dann als `vorhanden`. Mengenartikel
  werden weiterhin separat gezählt.
- Native Clients speichern Kistenübersicht und -ansichten im verschlüsselten
  Offline-Cache. Vollständigkeitsprüfungen werden offline vorgemerkt und mit
  eindeutiger Befehls-ID genau einmal übertragen. Einlagern, Umbuchen und das
  Erfassen von Inhalt erfordern eine Verbindung.

## Berechtigungen

| Recht | Zweck | Standardrollen |
| --- | --- | --- |
| `containers.read` | Kisten, Inhalt und Ablaufdaten sehen | Admin, Materialwart, Fahrzeugwart, Kleiderwart, Fachbereichsleiter, Vorsitz |
| `containers.manage` | Kisten anlegen, bearbeiten, einem Lagerplatz zuweisen und auflösen | Admin, Materialwart |
| `containers.pack` | Artikel ein- und umbuchen, Inhalt erfassen, bearbeiten und ausbuchen | Admin, Materialwart, Fahrzeugwart, Kleiderwart |
| `containers.packlists` | Packlisten-Versionen pflegen | Admin, Materialwart |
| `containers.check` | Vollständigkeitsprüfungen erfassen | Admin, Materialwart, Fahrzeugwart, Kleiderwart, Fachbereichsleiter |
| `containers.print` | Packliste als PDF ausgeben | Admin, Materialwart, Fahrzeugwart, Fachbereichsleiter, Vorsitz |

Die Sammelumbuchung im Inventar mit einer Kiste als Ziel erfordert
`inventory.relocate`. Kisten sind strikt der besitzenden Gliederung zugeordnet;
Artikel können nur aus derselben Gliederung eingelagert werden.

## Datenhaltung und Übernahme bestehender Kisten

Kisten liegen in der Sammlung `containers`, Inhalt ohne Inventarnummer in
`containerContents`, Packlisten und Prüfungen in `containerPackLists` und
`containerChecks`. Artikel mit Inventarnummer verweisen über `containerId` auf ihre
Kiste. Alle Sammlungen sind organisations- und gliederungsbezogen, Teil der
regulären Persistenz und der gliederungsbezogenen Datensicherung. Eine
Datenbankmigration ist nicht erforderlich.

Kisten aus dem früheren Modell (inventarisiertes Einzelstück mit `isContainer`)
werden beim Start automatisch übernommen (`migrateLegacyContainers`):

- Die Kiste wird zu einem Kisten-Lagerort mit der bisherigen Inventarnummer als
  Kistennummer und dem bisherigen Lagerplatz. Fehlt ein Lagerplatz, zeigt die Kiste
  „Kein Lagerplatz“ und muss zugewiesen werden.
- Der bisherige Inventardatensatz der Kiste bleibt als normaler Artikel erhalten
  (`convertedToContainerId`).
- Gepackte Einzelstücke und Kleidung erhalten die Kiste als Lagerort.
- Gepackte Teilmengen von Mengenartikeln werden zu Inhalt ohne Inventarnummer; die
  Menge des Mengenartikels wird entsprechend reduziert (Bewegung `container-convert`).
- Unterkisten werden zu eigenen Kisten auf demselben Lagerplatz.
- Packlisten und Prüfprotokolle werden der neuen Kiste zugeordnet.

## Schnittstellenübersicht

- `GET /api/containers[?stockStructureId=…]`: Kistenübersicht
- `GET /api/containers/expiring?days=30`: ablaufende Inhalte
- `GET /api/containers/lookup?code=…`: Scan-Auflösung (Kisten- oder Inventarnummer)
- `GET /api/containers/storage-targets`: Lagerplätze, Gebäude und Kisten als Auswahl
- `POST /api/containers`, `PUT|DELETE /api/containers/:id`: Kisten verwalten; `PUT` mit
  neuem `stockStructureId` setzt die Kiste samt Inhalt um
- `GET /api/containers/:id`: Detail mit Artikeln, Inhalt, Soll/Ist, Packlisten und Prüfungen
- `GET /api/containers/:id/candidates`: einlagerbare Artikel mit Inventarnummer
- `POST /api/containers/:id/items`: Artikel mit Inventarnummer einlagern
- `POST /api/containers/:id/items/:entityType/:entityId/relocate`: Artikel mit
  Inventarnummer umbuchen (`locationId`/`stockStructureId` oder `containerId`)
- `POST /api/containers/:id/contents`, `PUT|DELETE …/contents/:contentId`: Inhalt ohne
  Inventarnummer erfassen, ändern, ausbuchen
- `POST /api/material/relocate/bulk` mit `containerId`: Sammelumbuchung in eine Kiste
- `POST /api/containers/:id/pack-lists`, `POST …/pack-lists/:listId/activate`: Packlisten
- `GET /api/containers/:id/pack-list/print`: PDF
- `POST /api/containers/:id/checks`: Vollständigkeitsprüfung
- `POST /api/stocktakes/:id/containers/:containerId/confirm`: Kiste in einer Inventur bestätigen
