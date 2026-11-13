# Zentrale Konten und Bereichsrechte

Jede Person erhält ein zentrales MaterialKompass-Konto mit einem systemweit eindeutigen Nutzernamen und einer eindeutigen E-Mail-Adresse. Beide Angaben werden für die Anmeldung verwendet und teilen deshalb einen Namensraum. Die Prüfung ignoriert Groß-/Kleinschreibung und äußere Leerzeichen. Gleiche Anzeigenamen sind zulässig und beweisen keine Personenidentität. Unterschiedliche tatsächliche E-Mail-Adressen lassen sich ohne zusätzlichen Identitätsnachweis nicht automatisch derselben Person zuordnen.

## Zuständigkeiten

Neue Konten werden ausschließlich durch Plattformadministratoren in „MaterialKompass – Zentrale Verwaltung“ angelegt. Organisationsadmins bzw. berechtigte Nutzerverwalter nehmen vorhandene Konten auf und verwalten nur die Freigaben der aktuell ausgewählten Ebene. Kontoinhaber verwalten ihren persönlichen Zugang weiter unter „Mein Account“. Ein Organisationsaustritt löscht kein Konto.

## Geschützte oberste Verwaltungsebene

„MaterialKompass – Zentrale Verwaltung“ wird beim Start idempotent ergänzt. Die technische Kennung ist org-materialkompass-administration, die einzige geschützte Wurzeleinheit unit-materialkompass-administration. Ihre Mitgliedschaft wird ausschließlich aus platformAdmin=true abgeleitet. Die normale Organisationsrolle „Admin“ genügt ausdrücklich nicht. Einladungen, manuelle Mitgliedschaftsaufnahme, neue Untereinheiten, Dienstgerätesitzungen und normale Fachmodule sind dort gesperrt. Deaktivierte Konten bleiben durch die globale Anmeldungskontrolle gesperrt. Normale Organisationen und deren Datenbereiche werden nicht unter diese Organisation verschoben oder mit ihr zusammengeführt.

Plattformadministratoren wählen im Dashboard über „Organisation oder Einheit wechseln“ die zentrale Verwaltung und öffnen „Zentrale Kontenverwaltung“. Dort stehen das globale Kontenverzeichnis, Kontoanlage, globale Profil- und Sicherheitsverwaltung, Duplikatsprüfung und Gesamtdatensicherung bereit. Das Kontenverzeichnis enthält alle verwalteten Konten; diese Auflistung ist keine Mitgliedschaft in der Verwaltungsorganisation. Neue normale Konten erhalten dort keine Freigabe und werden nicht zu Mitgliedern. Die zuständigen Organisationsadmins vergeben anschließend ihre lokalen Rechte direkt oder per Einladung.

Organisationen werden ausschließlich von Plattformadministratoren in der zentralen Verwaltung angelegt (`POST /api/organizations`), bearbeitet (`PUT /api/organizations/:id`) und gelöscht (`DELETE /api/organizations/:id`); die Übersicht aller Organisationen liefert `GET /api/platform/organizations`. Organisationsadmins – auch Plattformadministratoren, die in einer normalen Organisation arbeiten – erhalten dafür 403 und können auch die Wurzeleinheit (= Organisation) nicht mehr bearbeiten; Unterorganisationen verwalten sie weiterhin selbst. Das Löschen verlangt die Eingabe „ORGANISATION <EDV-Nummer> LÖSCHEN“ sowie Passwort und ggf. 2-FA-Code. Die Organisation und alle Einheiten werden sofort archiviert und gesperrt und nach Ablauf der Aufbewahrungsfrist (730 Tage) mit ihren Daten endgültig entfernt; zentrale Konten bleiben bestehen.

In normalen Organisationen heißt der Einstieg „Berechtigungen dieser Ebene“. Zum Verwalten einer anderen berechtigten Ebene muss der Kontext bewusst gewechselt werden. Auch ein Plattformadministrator erhält in dieser Ansicht nur die lokalen Nutzerfreigaben; globale Kontenaktionen und vollständige Sicherungen gehören in die Zentrale. Persönliche Gerätefreigaben werden dort über einen geschützten, nur für die Plattformadministration sichtbaren Gerätekatalog gewählt.

Die Systemorganisation und ihre Mitgliedschaften verwenden die vorhandenen JSON-Sammlungen; für diese Ergänzung ist keine neue SQL-Spalte erforderlich. Beim vollständigen Sicherungsimport wird die Administrator-Mitgliedschaft ebenfalls neu aus den Plattformflags abgeleitet. Bestehende gewöhnliche Organisationszuordnungen bleiben bestehen.

## Bestehende Konten aufnehmen

Im Dashboard „Berechtigungen dieser Ebene → Bestehendes Konto aufnehmen“ wählen. Die direkte Freigabe verlangt einen genauen Nutzernamen oder eine genaue E-Mail-Adresse und aktiviert die ausgewählten Bereichsrechte sofort. Es gibt keine organisationsübergreifende Nutzersuche. Bereits freigegebene Einheiten werden über „Bereichsrechte bearbeiten“ geändert; die Aufnahme überschreibt keine vorhandenen Rechte.

Die Einladung verlangt die genaue E-Mail-Adresse. Der Empfänger erhält einen sieben Tage gültigen, einmal verwendbaren Link und sieht vor seiner Entscheidung Organisation, Einheiten und Rollen. Nur ausdrückliche Zustimmung aktiviert die Freigabe. Ablehnung, Ablauf und Widerruf aktivieren keine Rechte. Vor der Annahme prüft der Server die aktuelle E-Mail-Bindung sowie die aktuellen Verwaltungsrechte des Einladenden erneut. Eine Änderung kann eine neue Einladung erforderlich machen. Offene Einladungen lassen sich über das Briefsymbol widerrufen.

## Rechte ändern oder entziehen

„Bereichsrechte bearbeiten“ verändert nur die aktive Ebene. Die Nutzerantwort enthält ausschließlich die dortigen Rollen, Berechtigungen und Fachbereiche; Freigaben anderer Ebenen oder Organisationen sowie globale Geräte- und Sicherheitsdetails werden nicht mitgeliefert. Rechte anderer Einheiten und Organisationen bleiben erhalten. „Bereichsrechte entziehen“ entfernt nur die Freigabe in der aktiven Ebene. Die letzte aktive Adminzuordnung jeder Einheit ist geschützt. Autorisierte Folgeanfragen berechnen die Rechte aus den aktuellen Mitgliedschaften neu.

Auch ohne Organisationsrechte bleibt das zentrale Konto bestehen. Ein neuer Aufnahmevorgang verwendet dieses Konto weiter. Globale Aufbewahrungs- und Löschregeln bleiben eigenständige Kontovorgänge.

## Dubletten und Bestandsdaten

In der zentralen Verwaltungsorganisation findet die Plattformadministration Konflikte unter dem Symbol „Identitätskonflikte“ bzw. über `GET /api/users/identity-conflicts`. Die Antwort enthält Konto-IDs, keine zusätzliche Klartextliste persönlicher Daten. Mehrdeutige Anmeldekennungen werden nicht automatisch einem der Konten zugeordnet. Es wird kein Konto automatisch zusammengeführt oder gelöscht.

Zur manuellen Klärung zuerst eine geschützte Sicherung erstellen und die Identität der betroffenen Personen prüfen. Anschließend die richtigen Kennungen mit der Plattformadministration festlegen und die jeweiligen Organisationsadmins die erforderlichen Bereichsrechte bestätigen lassen. Keine Passwörter, MFA-Schlüssel oder Wiederherstellungscodes zwischen Konten kopieren. Eine berechtigte globale Löschung erfolgt separat, nach Prüfung der Referenzen und Aufbewahrungspflichten; der letzte Admin eines Bereichs bleibt geschützt.

## Betrieb und Migration

Die globale Nutzertabelle und die Plattformsammlung `memberships` werden weiterverwendet. Die Migration `20261110_central_user_membership.sql` ergänzt `users.membership_managed`; die Speicherinitialisierung stellt die Spalte zusätzlich idempotent sicher. Neue zentrale Konten speichern die Kennzeichnung bereits beim ersten Identitätsschreibvorgang. Nach einem Absturz vor der ersten dauerhaften Mitgliedschaft erhalten sie deshalb keine Legacy-Standardrechte. Ältere Konten durchlaufen die vorhandene Legacy-Übernahme einmal; vorhandene explizite Mitgliedschaften werden nicht um eine zusätzliche Standardorganisation erweitert. Beim vollständigen Sicherungsimport werden Konten als zentral verwaltet gekennzeichnet, auch wenn sie absichtlich keine Mitgliedschaften besitzen.

Einladungen liegen als gehashte, befristete Nachweise in den Mitgliedschaften. Inaktive Mitgliedschaften bleiben als Entzugsnachweis erhalten. Zusammen mit der Kennzeichnung verhindert dies eine erneute automatische Rechtevergabe beim Neustart. Vor einem Rollback auf ältere Programmversionen beachten, dass deren Legacy-Normalisierung diese neue Kennzeichnung noch nicht auswertet.

`backend/server.js` muss weiter die exklusive Datenbanksperre halten. Der unterstützte Persistenzmodus ist eine einzelne Backendinstanz. Der Speicher baut nach dem Entschlüsseln einen nur im Arbeitsspeicher gehaltenen Kennungsindex auf und serialisiert Nutzer-Schreibvorgänge. Die bisherigen SQL-Spalten enthalten verschlüsselte Identitäten bzw. nutzerabhängige Platzhalter und sind allein kein Eindeutigkeitsnachweis echter E-Mail-Adressen. Es entstehen keine zusätzlichen dauerhaft gespeicherten Klartextkennungen.

Bei fehlgeschlagenem Speichern bleiben Kennungsreservierungen vorsichtshalber belegt, bis ein kontrollierter Neustart den Index aus der Datenbank neu aufbaut. Vor dem Neustart zuerst die Speicherstörung beheben. Direkte SQL-Schreibzugriffe und ein Betrieb unter Umgehung der Instanzsperre sind nicht unterstützt. Eine zukünftige horizontale Skalierung benötigt transaktionale, datenbankseitige Kennungsreservierungen und ein anderes Persistenzmodell.

Sicherungen mit doppelten Kennungen oder Kollisionen zwischen Anmeldename und E-Mail verschiedener Konten werden beim Import abgelehnt. Die produktiven Bestandsdaten wurden in dieser Umsetzung nicht gelesen oder verändert. Vor dem Rollout die Konfliktanzeige mit der Plattformadministration prüfen und Konflikte manuell klären.

## Globale Löschung

Organisationsadmins verwenden ausschließlich den Rechteentzug. Eine Plattformadministration kann ein Konto separat über `DELETE /api/platform/users/:id` löschen; erforderlich sind ihr `currentPassword` und bei aktiver MFA ihr `mfaCode`. Der Kontoinhaber verwendet die bestehende Selbstlöschung. Beide Wege schützen letzte Bereichsadmins und verwenden die vorhandene Anonymisierung und Schlüsselvernichtung.

Die letzte aktive Plattformadministration ist unabhängig von Bereichsrollen geschützt. Eine Löschung reserviert das Konto synchron als inaktiv, bevor die asynchrone Bereinigung beginnt. Der Verlust einer normalen Organisationszuordnung entzieht keine Plattformrechte: Für die globale Kontoverwaltung wird ausdrücklich in die automatisch zugeordnete zentrale Verwaltungsorganisation gewechselt. Daraus entstehen keine Rechte auf die Fachdaten anderer Organisationen.

Eine lokal geänderte Organisationsrolle darf keine andere Ebene mitverändern. Wird sie auch andernorts in Mitgliedschaften oder offenen Einladungen verwendet, ist sie in der aktuellen Ebene nicht frei änderbar. Persönliche NFC- und Offline-QR-Zugänge werden ausschließlich durch die Plattformadministration eingerichtet. Dienstgeräteverwaltung und -aktivierung berücksichtigen neben der Organisation auch die aktive berechtigte Einheit. Eine bestehende TOTP-Einrichtung muss vor einer Neueinrichtung mit Passwort und aktuellem Faktor deaktiviert werden.

## Prüfung und Freigabe

Die Regressionen in `backend/test/central-user-management.test.js` und `backend/test/user-identity.test.js` beschreiben parallele Neuanlage, Kennungskollisionen, Organisationsgrenzen, Rechteentzug und Einladungslebenszyklus. Vor einem produktiven Rollout in einer isolierten Testumgebung mit Dummy-Daten ausführen, außerdem die bestehenden Nutzer-, Mandanten-, Speicher-, Sicherungs-, MFA-, Passkey-, QR- und Dienstgerätetests sowie Flutter-Analyse und Widgettests prüfen. Der Security-Audit-Bericht unterscheidet Quellenprüfung und noch ausstehende dynamische Validierung ausdrücklich.

Zusätzlich beschreiben flutter/test/central_user_dialog_test.dart zwei Oberflächenregressionen für gemischte Bereichsfreigaben und globale Profiländerungen bei unveränderter Dienstgeräterichtlinie. Diese Fixtures wurden vorbereitet und statisch geparst, aber nicht ausgeführt.

Die gezielten Regressionen in backend/test/platform-administration.test.js beschreiben geschützte, idempotente Administrator-Mitgliedschaft, zentrale Kontoanlage und Duplikatsprüfung, Ausschluss normaler Organisationsadmins und ausschließlich sichtbare Freigaben der aktiven Ebene. Sie wurden vorbereitet; isolierte Laufzeittests bleiben ausstehend.
