# Organisationsbezogene Etikettenvorlagen

Die Flutter-Seite **Etikettenvorlagen** ist über das Dashboard erreichbar und
verwendet das zentrale MaterialKompass-Theme. Originaldateien werden im
Herstellerprogramm gestaltet. MaterialKompass speichert die Originaldatei,
Kategorien, Variablenzuordnung und Freigabe zentral in `labelTemplates`.
Die Sammlung ist Bestandteil der vorhandenen MariaDB-Persistenz und Backups;
eine zusätzliche Tabelle oder Migration ist nicht erforderlich.

## Verwaltung und Freigabe

- Organisationsadministratoren verwalten Material und Kleidung. Materialwarte
  verwalten Materialvorlagen, Kleiderwarte Kleidungsvorlagen.
- Änderungen erfolgen in der herausgebenden Einheit. In eine andere Einheit
  freigegebene Vorlagen sind dort ausschließlich lesbar.
- Freigaben: nicht freigegeben, gesamte Organisation, eigene und unterliegende
  Einheiten, ausgewählte zugeordnete Nutzer. Organisationweite Freigaben sind
  auf Organisationsebene oder für Organisationsadmins möglich.
- Eine Vorlage kann mehreren Kategorien ihres Bereichs zugeordnet werden.
  Einheitskategorien können nicht an andere Einheiten freigegeben werden.
- Variablen werden mit ihren exakten Namen aus dem Herstellerprogramm erfasst
  und Seriennummer, Inventarnummer, Bezeichnung, Baujahr oder Größe zugeordnet.
  Automatische Erkennung der Variablen und eine Layout-Vorschau beim Upload
  sind noch nicht implementiert.
- Maximal 5 MB je Datei, 32 MB Vorlagenspeicher und 100 Vorlagen je Organisation,
  50 Variablen je Vorlage.
  Updates prüfen den Zeitstempel, um parallele Änderungen nicht zu überschreiben.

## Dateiformate und tatsächlicher Stand

Die Dateiannahme unterstützt Zebra `.nlbl` und ältere `.lbl`, DYMO `.dymo` und
`.label`, Epson `.leb`, Brother `.lbx` und ältere `.lbl`. Bei `.lbl` muss der
Hersteller ausgewählt werden. Die Endung ist keine Inhalts- oder
Druckkompatibilitätsprüfung. Dateien werden unverändert gespeichert und können
über den autorisierten Originaldownload wieder heruntergeladen werden.

Die bereitgestellte `Kleideretikett.nlbl` von ZebraDesigner 3 for Developers
enthält verschlüsselte Einträge in einem ZIP-Container. Sie wird nicht als ZPL
interpretiert, nicht automatisch entpackt und nicht durch ein erfundenes Layout
ersetzt. Für die echte Verarbeitung proprietärer Vorlagen ist ein separater,
vertrauenswürdiger Herstellerdienst erforderlich. Dieser Dienst ist **nicht
Bestandteil dieser Implementierung**. Ohne ihn sind Originalvorschau und
Originaldruck nicht verfügbar; die App zeigt dies an.

Quellen:

- [ZebraDesigner](https://www.zebra.com/us/en/software/printer-software/zebradesigner.html)
- [DYMO Connect Framework](https://github.com/dymosoftware/dymo-connect-framework)
- [DYMO Beispieldatei](https://github.com/dymosoftware/DCD-SDK-Python-Sample/blob/main/Sample_Label.dymo)
- [Epson Label Editor: Speichern als .leb](https://download4.epson.biz/sec_pubs/bs/html/m001248/en/chapter2_7.html)
- [Brother b-PAC: .lbl/.lbx](https://support.brother.com/g/s/es/dev/en/bpac/faq/index.html?c=eu_ot&lang=en)

## Herstellerdienst anschließen

Das Backend liest `LABEL_RENDERER_URL` und optional `LABEL_RENDERER_TOKEN`.
Die URL ist ausschließlich Serverkonfiguration, kein vom Nutzer übergebener
Endpunkt. Sie sollte über HTTPS auf einen eigenen, abgesicherten Dienst zeigen.
Token werden nur im Authorization-Header übertragen, nicht im Client gespeichert.
Der Dienst muss passende Herstellerprogramme/SDKs, Lizenzen und unterstützte
Formate selbst bereitstellen. Ein Dienst unter einem solchen Namen existiert
nicht automatisch durch das Setzen der Umgebungsvariablen.

`POST <LABEL_RENDERER_URL>/render` erhält JSON:

```json
{
  "manufacturer": "Zebra",
  "fileName": "Kleideretikett.nlbl",
  "fileBase64": "<unveränderte Originaldatei>",
  "sha256": "<Dateiprüfsumme>",
  "records": [{ "copies": 1, "values": { "Inventarnummer": "MK-42" } }],
  "output": "pdf",
  "useTemplatePageSize": true
}
```

Die Antwort ist JSON `{ "fileBase64": "<PDF als Base64>" }`. Der Dienst muss
das Original-Layout und die Original-Etikettengröße erhalten, Variablenwerte als
Daten behandeln, die Stückzahlen umsetzen und nicht unterstützte Vorlagen
zurückweisen. Er darf keine Skripte/Makros, externen Dateiverweise oder
Netzwerkzugriffe aus hochgeladenen Dateien ungeprüft ausführen. Der Aufruf hat
45 Sekunden Zeitlimit, keine Weiterleitungen und eine begrenzte Antwortgröße.

## Drucken

Inventar, Kleiderkammer und Beschaffungsübernahme bieten passende freigegebene
Vorlagen im bestehenden Druckablauf an. Für einen Stapel muss die Vorlage auf
alle ausgewählten Kategorien passen; sonst muss die Auswahl getrennt werden.
Das Backend liest Originalwerte ausschließlich aus zugänglichen Datensätzen,
prüft Kategorien und begrenzt jeden Auftrag auf 100 Datensätze / 1000 Etiketten.
Fehlende Werte werden vor der Ausgabe aufgelistet. Erst nach ausdrücklicher
Bestätigung darf der Auftrag mit leeren Feldern weiterlaufen. Baujahr wird für
Herstellervorlagen nicht durch das Kaufjahr ersetzt.

Nach Verarbeitung durch den Herstellerdienst kann das PDF gespeichert oder mit
dem vorhandenen System-Druckdialog auf Web, Linux, Windows, macOS und den
unterstützten mobilen Plattformen ausgegeben werden. USB, Netzwerk/WLAN und
Bluetooth funktionieren nur, soweit Betriebssystem, Browser, Druckertreiber und
Gerät die jeweilige Verbindung über den Systemdruck unterstützen. Eine eigene
USB-/Bluetooth-Erkennung oder universelle Herstelleranbindung wurde nicht
implementiert. Der bisherige direkte Zebra-Standarddruck bleibt verfügbar und
wird auf nativen Plattformen über TCP angeboten; er verarbeitet keine
Herstellervorlagendateien.

## Überprüfung

`node --test test/label-templates.test.js test/label-templates-integration.test.js test/label-fields.test.js test/mariadb-persistence.test.js`
prüft Rechte, Organisations- und Einheitsgrenzen, Freigaben, Eingabeprüfung,
Originaldownload, Konflikte, Datenzuordnung und fehlende Herstellerdienste.
Ein echter Druck mit Herstellerprogrammen und Hardware bleibt eine separate
Integrationsprüfung, sobald der Herstellerdienst bereitgestellt ist.
