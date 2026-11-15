# Performance- und Kompatibilitätsbericht

Stand: 18. Oktober 2026. Die Größen- und Startzeitmessungen vom 16. August 2026 wurden
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

Seit dem 18. Oktober werden die vom Dashboard erreichbaren Fachoberflächen bewusst im
Haupt-Bundle ausgeliefert. Damit sind Anwendungscode und Navigation bei einem Deployment
atomar und können nicht mehr durch alte, unter stabilen Dateinamen gecachte Dart-Chunks
auseinanderlaufen. Die historischen Größenwerte oben bilden diese Änderung noch nicht ab.

## Startzeit der Loginseite (Web)

Ziel: Die Loginseite ist innerhalb von 1 Sekunde bedienbar. Seit dem 15. November
2026 ist sie reines HTML in `flutter/web/index.html` und wartet nicht mehr auf
Flutter. Gemessen mit Flutter 3.47.9 (Release-Build), Chromium, HTTPS und der
produktiven `ops/nginx-web.conf` hinter einem drosselnden Proxy; je drei Läufe.
"Kalt" ist der allererste Aufruf mit leerem Browser-Cache, "warm" jeder weitere.

| Netz | Messgröße | Ursprünglich | HTML-Login |
| --- | --- | ---: | ---: |
| 50 Mbit/s, 20 ms RTT | Loginformular bedienbar, kalt | 2.250 ms | 160 ms |
| 50 Mbit/s, 20 ms RTT | Loginformular bedienbar, warm | 1.300 ms | 100 ms |
| 20 Mbit/s, 40 ms RTT | Loginformular bedienbar, kalt | 3.100 ms | 220 ms |
| 20 Mbit/s, 40 ms RTT | Loginformular bedienbar, warm | 1.750 ms | 115 ms |

Nach "Anmelden" (3 s Eingabezeit) bis zum sichtbaren Arbeitsbereich: 50 Mbit/s kalt
rund 1.050 ms, warm rund 880 ms; 20 Mbit/s kalt rund 1.500 ms, warm rund 900 ms.
Davon entfallen rund 450 ms auf die Passwortprüfung (bcrypt) des Servers. Wird
sofort nach dem Laden abgeschickt, wartet der allererste Aufruf zusätzlich auf den
Download der App (20 Mbit/s: rund 3 s).

Ablauf:

- Die HTML-Seite meldet Passwort sowie Zwei-Faktor per Code und Push selbst bei der
  API an und speichert die Tokens wie die App (`sessionStorage`, gleiche Schlüssel).
  Seltene Wege (Passkey, QR-Code, Pflicht-Einrichtung der starken Anmeldung, Passwort
  vergessen, Downloads, rechtliche Hinweise) übergibt sie über
  `lib/services/web_startup_bridge*.dart` an die Flutter-Loginseite; Eingaben werden
  übernommen, ein Passwort-Login wird dort automatisch fortgesetzt.
- Parallel lädt `flutter_bootstrap.js` Engine und App. Die App startet unsichtbar hinter
  der Loginseite, lädt den Arbeitsbereich (Dart-Teilpaket) vor und wartet auf das
  Signal der Loginseite. Nach einer frischen Anmeldung entfällt die erneute
  Tokenprüfung. Die Loginseite verschwindet, sobald die App die Zielseite gezeichnet
  hat (`materialKompassAppReady`).
- Eine vorhandene Sitzung oder ein Link (`#/verify-email`, `#/password-reset`,
  `#/membership-invitation`) startet die App sofort.
- Der API-Origin steht im Meta-Tag `materialkompass-api`; `ops/build-web.ps1` und der
  Release-Workflow setzen ihn auf den Wert von `API_BASE_URL`.
- Ein neuer Build lädt die Seite einmal neu, aber nie während einer Eingabe.

Bereits zuvor umgesetzt und weiterhin gültig:

- `main.dart.js` und das Login-Logo werden per `preload` sofort angefordert,
  `passkeys.js` blockiert den Start nicht (`defer`).
- Der Service Worker wird nicht an den Flutter-Loader übergeben, sondern nach dem
  Initialisieren der Engine registriert, und übernimmt dann die bereits geladenen
  Startdateien (CanvasKit, Schriften, Manifeste) in seinen Cache.
- Der Service Worker liefert innerhalb seiner Build-Version alle Dateien außer
  Navigation, `flutter_bootstrap.js` und `version.json` direkt aus dem Cache.
- Builds verwenden `--no-web-resources-cdn`: CanvasKit und die Roboto-Schrift kommen
  vom eigenen Server statt von `www.gstatic.com` und `fonts.gstatic.com`.
- nginx liefert `index.html`, `flutter_bootstrap.js`, `main.dart.js` und `canvaskit/`
  mit `no-cache` statt `no-store` aus (Revalidierung per ETag) und nutzt per
  `gzip_static` die beim Build erzeugten `.gz`-Dateien.

`tool/web_startup.test.js` sichert die Maßnahmen gegen Regressionen.

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
- Dashboard-Fachmodule werden im Web gemeinsam mit dem Haupt-Bundle ausgeliefert. Der
  Webserver markiert zusätzlich eventuell vorhandene Dart-Teilpakete als nicht cachebar,
  damit spätere Code-Splitting-Änderungen keine gemischten Buildstände erzeugen.
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
- Die Jugend-/Stammverknüpfung erweitert nicht den allgemeinen Mandantenkontext. Pro
  Anfrage wird höchstens eine direkt verknüpfte Gegeneinheit gezielt berücksichtigt;
  Listen bleiben organisationsgebunden und bestehende Ergebnisgrenzen gelten weiter.
- Die Auswahl meldbarer Inventar- und Fahrzeugobjekte prüft jeden Datensatz in einem
  linearen Durchlauf, ohne für jeden Treffer erneut die gesamte Sammlung zu durchsuchen.
  Reservierungs- und Mängelobergrenzen werden je Organisation statt systemweit gezählt,
  damit eine große Organisation andere Mandanten nicht ausbremst.

## Prüfstatus

- `flutter analyze`: keine Fehler oder Warnungen
- Flutter-Tests: 67 von 67 bestanden, einschließlich Vorlagenauswahl sowie Dateinamen-,
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
- Jugend-/Stamm-Fachtests: 3 von 3 bestanden; das serielle Backend-Performance-Budget
  wurde eingehalten. Im vollständigen Windows-Lauf bestanden alle fachlichen
  Assertions. Vier Test-Worker meldeten beim Beenden weiterhin einen libuv-Fehler
  (`UV_HANDLE_CLOSING`), der unabhängig von den Jugendfunktionen untersucht wird.

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
