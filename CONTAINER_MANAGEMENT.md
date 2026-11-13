# Kistenverwaltung

## Fachlicher Umfang

Eine Kiste ist ein individuell inventarisiertes Einzelstück mit dem Kennzeichen
`isContainer`, zum Beispiel eine Sanitätskiste, eine Wurfsackkiste oder ein
Verbandmodul. Sie behält Inventarnummer, QR-Etikett, Prüfungen, Mängel und
Bewegungsverlauf wie jeder andere Artikel. Eine Kiste wird unter **Kisten → Kiste
anlegen** aus einem bestehenden Einzelstück erzeugt oder im Inventarformular über
**Als Kiste verwenden** gekennzeichnet.

In eine Kiste können gepackt werden:

- individuell geführte Einzelstücke,
- Teilmengen von Mengenartikeln (die Menge wird vom frei verfügbaren Bestand abgezogen),
- Kleiderkammer-Artikel (erfordert zusätzlich `clothing.read`),
- weitere Kisten, höchstens fünf Ebenen tief und ohne Zyklen.

Jede Inhaltsposition kann ein Fach, ein Ablaufdatum, eine Charge und eine Notiz
enthalten. Sind an der Kiste Fächer definiert, muss eines davon gewählt werden.
Belegte Fächer lassen sich nicht entfernen.

## Mitwandern und Sperren

Einzelstücke, Kleidung und Unterkisten wechseln beim Packen physisch an den
Lagerort der Kiste. Solange sie gepackt sind, können sie nicht einzeln umgebucht,
ausgegeben, auf ein Fahrzeug geladen, archiviert oder gelöscht werden. Wird die
Kiste umgebucht, wiederhergestellt, auf ein Fahrzeug geladen oder von dort entladen,
folgt der gesamte Inhalt rekursiv. Für Inventarartikel entsteht dabei jeweils eine
Bewegung `container-follow`.

Eine ausgegebene Kiste nimmt ihren Inhalt mit. Bis zur Rückgabe kann der Inhalt
nicht verändert werden. Enthält eine Kiste sicherheitsbedingt gesperrtes Material,
sind Ausgabe und Fahrzeugbeladung der Kiste gesperrt. Abgelaufene Inhalte werden
dagegen nur gemeldet, damit eine Einsatzkiste nicht wegen eines einzelnen
Verbrauchsartikels ausfällt.

Beim Entnehmen geht ein Einzelstück an seinen vorherigen Lagerort zurück. Existiert
dieser nicht mehr, geht es an den Lagerort der Kiste, sofern dieser kein Fahrzeug
ist. Ein ausdrücklich gewähltes Ziel hat Vorrang.

## Packlisten und Vollständigkeitsprüfung

Die Soll-Packliste wird wie die Fahrzeug-Beladungsliste versioniert. Eine neue aktive
Version ersetzt die vorherige, die als `Ersetzt` erhalten bleibt. Entwürfe können
später aktiviert werden. Die Kistenansicht zeigt laufend den Soll/Ist-Vergleich.

Eine Vollständigkeitsprüfung erfasst für jede Position der aktiven Packliste
(ohne Packliste: für jeden aktuellen Inhalt) das Ergebnis `vorhanden`, `fehlt`,
`beschädigt` oder `abgelaufen` sowie die Ist-Menge. Danach erhält die Kiste den
Status `Vollständig` oder `Unvollständig`. Bei Abweichungen kann direkt ein Mangel
in der bestehenden Mängelverwaltung angelegt werden. Nur die Priorität `Kritisch`
setzt die Kiste auf `Defekt`. Pro Kiste werden die letzten 500 Prüfprotokolle
aufbewahrt.

Die Packliste lässt sich als A4-PDF mit Soll-, Ist- und Ablaufangaben, einer
Prüfspalte und einem Unterschriftsfeld drucken.

## Ablaufdaten

Jede Kiste hat eine Vorwarnzeit von 0 bis 365 Tagen, standardmäßig 30. Inhalte
erscheinen als `läuft bald ab` oder `abgelaufen` in der Kistenübersicht, in der
Kistenansicht und unter **Kisten → Ablaufende Inhalte**.

## Scan, Inventur und Offlinebetrieb

- Ein Scan in der Kistenübersicht öffnet die Kiste selbst oder die Kiste, in der der
  gescannte Artikel liegt. Kisten verwenden die normalen Inventaretiketten.
- Inventurpositionen zeigen, in welcher Kiste ein Artikel liegt. Eine verschlossen
  vorgefundene Kiste kann als Einheit bestätigt werden: Kiste und alle noch nicht
  gezählten Einzelstücke darin gelten dann als `vorhanden`. Mengenartikel werden
  weiterhin separat gezählt.
- Native Clients speichern Kistenübersicht und -ansichten im verschlüsselten
  Offline-Cache. Vollständigkeitsprüfungen werden offline vorgemerkt und mit
  eindeutiger Befehls-ID genau einmal übertragen. Packen und Entnehmen erfordern
  eine Verbindung, weil Verfügbarkeiten serverseitig geprüft werden.

## Berechtigungen

| Recht | Zweck | Standardrollen |
| --- | --- | --- |
| `containers.read` | Kisten, Inhalt und Ablaufdaten sehen | Admin, Materialwart, Fahrzeugwart, Kleiderwart, Fachbereichsleiter, Vorsitz |
| `containers.manage` | Kisten anlegen, bearbeiten und auflösen | Admin, Materialwart |
| `containers.pack` | Inhalt packen, bearbeiten und entnehmen | Admin, Materialwart, Fahrzeugwart, Kleiderwart |
| `containers.packlists` | Packlisten-Versionen pflegen | Admin, Materialwart |
| `containers.check` | Vollständigkeitsprüfungen erfassen | Admin, Materialwart, Fahrzeugwart, Kleiderwart, Fachbereichsleiter |
| `containers.print` | Packliste als PDF ausgeben | Admin, Materialwart, Fahrzeugwart, Fachbereichsleiter, Vorsitz |

Kisten sind strikt der besitzenden Gliederung zugeordnet. Inhalt kann nur aus
derselben Gliederung gepackt werden.

## Datenhaltung

Der Inhalt liegt in den organisations- und gliederungsbezogenen Sammlungen
`containerContents`, `containerPackLists` und `containerChecks`. Sie sind Teil der
regulären Persistenz und der gliederungsbezogenen Datensicherung. Eine
Datenbankmigration ist nicht erforderlich.

## Schnittstellenübersicht

- `GET /api/containers`: Kistenübersicht
- `GET /api/containers/expiring?days=30`: ablaufende Inhalte
- `GET /api/containers/lookup?code=…`: Scan-Auflösung
- `POST /api/containers`, `PUT|DELETE /api/containers/:id`: Kisten verwalten
- `GET /api/containers/:id`: Detail mit Inhalt, Soll/Ist, Packlisten und Prüfungen
- `GET /api/containers/:id/candidates`: packbare Artikel
- `POST /api/containers/:id/contents`, `PUT …/contents/:contentId`,
  `POST …/contents/:contentId/unpack`: Inhalt
- `POST /api/containers/:id/pack-lists`, `POST …/pack-lists/:listId/activate`: Packlisten
- `GET /api/containers/:id/pack-list/print`: PDF
- `POST /api/containers/:id/checks`: Vollständigkeitsprüfung
- `POST /api/stocktakes/:id/containers/:containerId/confirm`: Kiste in einer Inventur bestätigen
