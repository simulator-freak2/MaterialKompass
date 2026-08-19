# Performance- und Kompatibilitätsbericht

Stand: 16. August 2026. Die Messungen wurden als Release-Build beziehungsweise
frischer Node-Prozess auf der lokalen Windows-Entwicklungsumgebung durchgeführt.
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
- Eine ungenutzte Flutter-Abhängigkeit und ein ungenutztes Laufzeit-Asset wurden entfernt;
  das sichtbare Login-Logo wird in einer zur Anzeige passenden Auflösung erzeugt.

## Prüfstatus

- `flutter analyze`: ohne Befund
- Flutter-Tests: 34 von 34 bestanden
- Windows-Release-Build: bestanden, Ausgabeordner 34.338.252 Bytes
- Web-Release-Build: bestanden; eigener Service Worker syntaktisch und in der
  Bootstrap-Datei geprüft
- Android: Java-/Flutter-/Plugin-Kompilierung erreicht. Ein Release-Build benötigt den
  absichtlich nicht versionierten Betreiber-Signierschlüssel. Der Debug-Build wurde auf
  dieser Maschine beim nativen Merge durch nur 0,62 GB freien Platz auf Laufwerk C:
  verhindert; ein alternativer Gradle-Cache auf E: konnte seine Distribution wegen des
  lokalen Downloadstillstands nicht initialisieren.
- Backend-Tests: 112 von 112 bestanden

## Betriebsgrenzen

Flutter Web verwendet weiterhin nur den Service-Worker für die Programmoberfläche und
erhält keinen schreibfähigen Offlinebetrieb. Verschlüsselte Snapshots und vorgemerkte
Fachaktionen stehen ausschließlich in installierten nativen Apps zur Verfügung. Bilder
und sonstige Anhänge werden nicht offline vorgemerkt. Für reproduzierbare
Android-Release-Builds sind Java 17 oder neuer sowie
`flutter/android/key.properties` mit dem dauerhaften Release-Schlüssel erforderlich.
