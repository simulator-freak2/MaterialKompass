# Zentrale Nutzerkonten und organisationsbezogene Berechtigungen

Stand: 11. November 2026. Status: Umsetzung und Handbuch aktualisiert, unabhängige Quellenprüfung abgeschlossen. Isolierte Laufzeittests und strenge Audit-Dateiprüfung bleiben umgebungsbedingt offen; keine produktive Sicherheitsfreigabe.

## Ziel

Jede Person verwendet ein zentrales Konto. Organisationen vergeben und entziehen ausschließlich die Rechte für ihre administrierbaren Bereiche. Weitere Organisationszugehörigkeiten erfordern kein weiteres Konto.

## Ausgangslage

- `backend/src/user-management.js` verwaltet bereits globale Nutzer und getrennte Mitgliedschaften mit Bereichsrollen.
- Neuanlage prüft E-Mail und Anmeldename bereits normalisiert, allerdings vor der asynchronen Passwortberechnung. Parallele Anfragen müssen abgesichert werden.
- Die vorhandene Aufnahme bestehender Konten erfolgt sofort über einen Identifikator.
- Organisationsverwaltung kann globale Identitätsdaten und Authentifizierungseinstellungen verändern. Das Entfernen der letzten Mitgliedschaft kann das globale Konto löschen.
- `backend/src/db/user-store.js` verschlüsselt Identitätsdaten und speichert nutzerabhängige Platzhalter in den bisherigen eindeutigen SQL-Spalten. Deren Eindeutigkeit sichert deshalb nicht die tatsächlichen E-Mail-Adressen ab.
- Der Persistenzmodus verwendet eine exklusive Instanzsperre. Diese Voraussetzung muss bei der Umsetzung berücksichtigt werden.
- Die Oberfläche befindet sich in `flutter/lib/pages/users_page.dart`, das integrierte Handbuch in `flutter/lib/pages/knowledge_base_page.dart`.

## Bestätigte Entscheidungen

1. E-Mail-Adresse und Nutzername sind systemweit eindeutig.
2. Sowohl direkte Aufnahme als auch Einladung mit Zustimmung werden angeboten.
3. Organisationsadmins verwalten ausschließlich Bereichsrechte; globale Kontoverwaltung bleibt beim Kontoinhaber und der Plattformadministration.
4. Bestandskonflikte werden manuell geklärt; keine automatische Zusammenführung.
5. Zusätzlich wird eine statische Clawdex-Vorschau erstellt.

## Umsetzung

1. Gemeinsame Normalisierung und Kollisionsregeln für Neuanlage, administrative Änderungen, Selbstverwaltung und Wiederherstellung definieren. Auch Kollisionen zwischen E-Mail und Anmeldename prüfen, da beide zur Anmeldung dienen.
2. Bestehende Konten auf Konflikte prüfen, ohne sensible Identitätsdaten in Protokolle zu schreiben. Keine automatische Rechtevereinigung oder Kontolöschung.
3. Eindeutigkeit am letzten vertrauenswürdigen Schreibpunkt sichern; parallele Anfragen und fehlgeschlagene Speicherung dürfen keine doppelten oder halbfertigen Konten hinterlassen. Verschlüsselung und Löschbarkeit persönlicher Daten erhalten.
4. Bereichsrechte ausschließlich innerhalb der schreibberechtigten Einheiten verändern. Andere Einheiten und Organisationen erhalten ihre bisherigen Rechte unverändert. Letzte zuständige Admins schützen.
5. Globale Kontoaktionen von Mitgliedschaftsaktionen trennen. Entzug eines Bereichsrechts darf das Konto und andere Mitgliedschaften nicht verändern.
6. Aufnahme bestehender Konten nach der bestätigten Fachentscheidung umsetzen. Bei Einladungen: befristete, einmalig verwendbare, gehashte Tokens; bestätigte Identität des Empfängers; Berechtigungen bei Annahme erneut prüfen; Widerruf und Wiederholung berücksichtigen.
7. Oberfläche auf Konto anlegen, bestehendes Konto aufnehmen und Bereichsrechte verwalten ausrichten. Fehlermeldungen für Dubletten verständlich gestalten; kein organisationsübergreifendes Nutzerverzeichnis offenlegen.
8. Regressionen für parallele Neuanlage, Identifikator-Kollisionen, Einheiten- und Organisationsgrenzen, Rechteentzug, letzten Admin und gegebenenfalls Einladungsablauf ergänzen.
9. Security-Audit des geänderten Identitäts- und Berechtigungsbereichs mit dokumentierter Abdeckung und unabhängiger Quellenprüfung durchführen. Keine produktiven Endpunkte oder echten Nutzer verwenden. Falls die vom Audit geforderte Betriebssystem-Isolation lokal fehlt, dynamische Prüfungen ausdrücklich als noch zu validieren ausweisen.
10. Handbuch und Betriebsdokumentation für zentrale Identität, Aufnahme vorhandener Konten, Zuständigkeiten, Rechteentzug und Bestandskonflikte aktualisieren.

## Ergänzungen aus der Quellenprüfung

- Dauerhafte Kennzeichnung zentraler Konten in `users.membership_managed`, damit ein Absturz während der Neuanlage keine Legacy-Standardrechte erzeugt.
- Änderungen gemeinsam genutzter Rollen auf alle betroffenen administrierbaren Bereiche begrenzen.
- Passwortreset-Tokens vor asynchroner Passwortberechnung verbrauchen.
- Bereits aktive TOTP-Einrichtungen vor versehentlicher oder unzureichend bestätigter Ersetzung schützen.
- Letzte Plattformadministration auch bei gleichzeitigen Löschanfragen erhalten.
- Alternative persönliche Anmeldeverfahren und Dienstgeräteverwaltung an dieselben Zuständigkeiten binden.
- Einladungsfehler in der Oberfläche anhand des HTTP-Status korrekt anzeigen.

## Abnahme

- Zwei gleichzeitige Anfragen mit derselben normalisierten Identität erzeugen höchstens ein Konto.
- Ein Konto kann mehrere Organisationsmitgliedschaften mit unabhängigen Bereichsrollen besitzen.
- Organisationsadmins können keine fremden Bereiche oder globalen Zugangsdaten verändern.
- Rechteentzug wirkt bei der nächsten geschützten Aktion und lässt andere Mitgliedschaften bestehen.
- Bestehende Konflikte werden nachvollziehbar gemeldet und nicht stillschweigend zusammengeführt.
- Handbuch und Oberfläche beschreiben dasselbe Verhalten.
- Prüfergebnisse benennen tatsächliche Ausführung, Quellenprüfung und offene Validierungen getrennt.

## Veröffentlichung

Eine statische Clawdex-Vorschau ersetzt keine Backendbereitstellung oder Datenmigration. Produktive Migration und Veröffentlichung sind separate Schritte nach Prüfung des konkreten Ergebnisses.

## Abschlussstand

Umsetzung, Datenbankmigration, integriertes Handbuch und ergänzende Betriebsdokumentation sind im Projekt vorhanden. Die unabhängige Quellenprüfung einschließlich Nachkorrekturen ist abgeschlossen. Syntax-, Format- und JSON-Strukturprüfungen waren erfolgreich. Isolierte Laufzeittests und die strengen Audit-CLI-Dateiprüfungen bleiben umgebungsbedingt offen; der Auditbericht kennzeichnet den Lauf als unvollständig. Die produktive Datenbank wurde nicht migriert.

Die gewünschte statische Vorschau mit Beispieldaten ist aktiv und unlisted veröffentlicht: https://clawdex.io/materialkompass-benutzerverwaltung-vorschau-fcbaa29472/

## Erweiterung vom 11. November 2026: geschützte Verwaltungsorganisation

Die oberste Verwaltungsebene „MaterialKompass – Zentrale Verwaltung“ wird beim Start und nach vollständiger Wiederherstellung idempotent angelegt. Nur Plattformadministratoren erhalten dort eine automatisch abgeleitete Mitgliedschaft. Globale Kontoanlage, Kontoverwaltung und Duplikatsprüfung erfolgen ausschließlich in diesem Kontext; das globale Kontenverzeichnis verleiht normalen Konten keine Mitgliedschaft. Lokale Antworten, Formulare und Änderungen berücksichtigen ausschließlich die aktive Ebene. Andere Organisationsrechte bleiben erhalten und werden nicht an die lokale Nutzeransicht geliefert. Handbuch und gezielte Regressionen wurden ergänzt. Syntax-/Formatprüfungen werden ausgeführt; Laufzeittests bleiben wegen der zuvor dokumentierten fehlenden Testisolation offen.
