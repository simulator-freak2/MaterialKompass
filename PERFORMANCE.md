# Performance- und Kompatibilitätsbericht

Stand: 6. September 2026. Die Größen- und Startzeitmessungen vom 16. August 2026 wurden
als Release-Build beziehungsweise frischer Node-Prozess auf der lokalen
Windows-Entwicklungsumgebung durchgeführt.
Sie dienen als reproduzierbare Vergleichswerte, nicht als Garantie für jede
Produktionshardware.

## Ergebnis

| Messgröße | Vorher | Nachher | Änderung |
| --- | ---: | ---: | ---: |
| Backend: RSS direkt nach Laden der App | 125,2 MB | 42–46 MB | etwa −65 % |
| Backend: beobachtete Ladezeit | 1.672 ms | 386–482 ms | etwa −71 bis −77 % |
| Web: initiales `main.dart.js` | 4.206.258 B | 3.657.990 B | −13,0 % |
| Login-Logo | 241.589 B | 73.445 B | −69,6 % |
| Initiales JavaScript plus Login-Logo | 4.447.847 B | 3.731.435 B | −16,1 % |

Der vollständige Web-Ausgabeordner ist 44.618.052 Bytes groß. Darin liegen mehrere
alternative Flutter-Renderer; ein Browser lädt nicht alle Varianten. 876.887 Bytes
Fachcode sind in verzögerte Chunks aufgeteilt und werden erst beim Öffnen des jeweiligen
Bereichs benötigt.

Nach Ergänzung des plattformübergreifenden Systemdrucks wurde der Web-Release-Build am
6. September erneut gemessen: `main.dart.js` umfasst 3.701.872 Bytes und der vollständige
Ausgabeordner 46.160.409 Bytes. Die rund 1,2 % größere Hauptdatei ist der Preis für die
Web-Druckbrücke; PDF- und Fachoberflächen bleiben weiterhin verzögert geladen.

## Umgesetzte Maßnahmen

- OCR, PDF-Rendering, Bildverarbeitung, Mailparser und XLSX werden serverseitig erst
  beim Aufruf der jeweiligen Funktion geladen.
- Synchrones BCrypt-Hashing wurde aus dem normalen Startpfad entfernt. Ein individuell
  konfiguriertes Erstadmin-Passwort wird weiterhin erst bei einer leeren Datenbank mit
  BCrypt gehasht.
- MariaDB-Snapshots vergleichen serialisierte Sammlungen und schreiben nur tatsächlich
  geänderte Werte. Ein identischer Snapshot verursacht keine Datenbankabfrage mehr;
  eine normale Mutation schreibt typischerweise nur Fachdaten und Audit-Log statt aller
  28 Sammlungen.
- Die Persistenzkoordination liegt in einem eigenen Modul und vereinigt gleichzeitige
  Speicheranforderungen weiterhin in höchstens einem vollständigen Snapshot.
- Dashboard-Fachmodule werden im Web verzögert geladen. Ein Ladeindikator und eine
  verständliche Fehlermeldung decken langsame oder unterbrochene Downloads ab.
- Der gemeinsame HTTP-Client verwendet Verbindungen wieder, begrenzt hängende Aufrufe
  auf 30 Sekunden und wiederholt ausschließlich sichere GET-Anfragen einmal bei
  Netzwerkfehlern oder HTTP 502/503/504. Nur ausdrücklich freigegebene Mutationen
  gelangen mit einer idempotenten Befehls-ID in die Offline-Warteschlange.
- Wiederholte Offline-Aktualisierungen verwenden einen Revisionszeiger. Ein vollständiger
  Snapshot wird nur bei der ersten Anmeldung, geänderter Standortauswahl oder fachlichen
  Änderungen übertragen; parallele Aktualisierungen derselben Sitzung werden vereinigt.
- Dienstgeräte und Offline-Clients werden serverseitig indiziert. Die redigierte
  Gerätesuche beendet den Scan nach 100 Treffern und baut Dokument-/Standortzuordnungen
  nur einmal pro Anfrage auf.
- Suchen in Inventar, Beschaffung und Mängeln werden um 180 ms entprellt.
- Die Mängelliste erzeugt nur sichtbare Karten. Die Inventartabelle zeigt standardmäßig
  10 Zeilen pro Seite statt alle Zeilen samt Aktionsschaltflächen gleichzeitig.
- Der versionsgebundene Web-Service-Worker speichert App-Shell und bereits verwendete
  Module für Verbindungsabbrüche. `/api/` und damit vertrauliche Anwendungsdaten werden
  ausdrücklich nicht im Service-Worker-Cache gespeichert.
- Passkey-Credentials werden beim Backendstart einmal nach Credential-ID indiziert;
  eine Anmeldung benötigt dadurch keinen linearen Datenbank- oder Nutzerscan. Die
  normalisierte Tabelle besitzt eindeutige beziehungsweise gezielte Indizes. Kurzlebige
  WebAuthn-Challenges sind auf 5.000 Einträge begrenzt und werden bei jedem neuen
  Vorgang bereinigt.
- Die kleine WebAuthn-Browserbrücke wird selbst gehostet und gemeinsam mit der App-Shell
  versioniert. Damit entfallen ein zusätzlicher CDN-Verbindungsaufbau und eine externe
  Laufzeitabhängigkeit auf der Loginseite.
- Eine ungenutzte Flutter-Abhängigkeit und ein ungenutztes Laufzeit-Asset wurden entfernt;
  das sichtbare Login-Logo wird in einer zur Anzeige passenden Auflösung erzeugt.
- Eine gemeinsame Ausgabeschicht ersetzt 14 voneinander getrennte Speichervorgänge.
  PDF-Daten werden nur einmal dekodiert und direkt an Download oder Systemdruck
  weitergereicht. Dateigröße, Base64, MIME-Typ, PDF-Signatur und Dateiname werden vor
  der Ausgabe begrenzt beziehungsweise geprüft.
- Konfigurierte native Download-Ziele werden mit temporärer Datei und abschließendem
  Umbenennen beschrieben. Namenskonflikte überschreiben keine bestehenden Daten.
  Programmupdates verbleiben im separaten, prüfsummenkontrollierten Updatepfad.

## Prüfstatus

- `flutter analyze`: keine Fehler oder Warnungen
- Flutter-Tests: 55 von 55 bestanden, einschließlich Vorlagenauswahl sowie Dateinamen-,
  Base64- und MIME-Prüfungen
- Windows-Release-Build: bestanden; native Passkey-, Datei- und Druckintegration
  kompiliert
- Web-Release-Build: bestanden; Web-Druckbrücke und getrennte Browserdownloads
  kompiliert
- Android: Der Debug-Build konnte auf dieser Maschine nicht starten, weil die benötigte
  Gradle-8.14-Distribution trotz Netzwerkfreigabe bei 0 Byte stehen blieb. Der temporäre
  alternative Gradle-Cache wurde danach entfernt. Ein Release-Build benötigt zusätzlich
  den absichtlich nicht versionierten Betreiber-Signierschlüssel.
- macOS, Linux und iOS: Plattformcode und Pluginregistrierung sind erzeugt; native Builds
  benötigen weiterhin den jeweiligen Betriebssystem-Runner beziehungsweise die Apple-
  Signierumgebung. macOS besitzt die erforderliche Druckberechtigung in Debug und Release.
- Backend-Tests: 135 von 135 bestanden

## Betriebsgrenzen

Flutter Web verwendet weiterhin nur den Service-Worker für die Programmoberfläche und
erhält keinen schreibfähigen Offlinebetrieb. Verschlüsselte Snapshots und vorgemerkte
Fachaktionen stehen ausschließlich in installierten nativen Apps zur Verfügung. Bilder
und sonstige Anhänge werden nicht offline vorgemerkt. Für reproduzierbare
Android-Release-Builds sind Java 17 oder neuer sowie
`flutter/android/key.properties` mit dem dauerhaften Release-Schlüssel erforderlich.
Passkeys werden vom aktuellen Client auf Web, Android, iOS, macOS und Windows
unterstützt. Linux bleibt beim Passwort-/TOTP-Fallback. Die native Freigabe setzt die
korrekte Domainzuordnung zum produktiven Apple-Team beziehungsweise Android-
Signierzertifikat voraus.
