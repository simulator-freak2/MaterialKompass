# Zentrale Konten und Bereichsrechte

Jede Person erhält ein zentrales MaterialKompass-Konto mit einem systemweit eindeutigen Nutzernamen und einer eindeutigen E-Mail-Adresse. Beide Angaben werden für die Anmeldung verwendet und teilen deshalb einen Namensraum. Die Prüfung ignoriert Groß-/Kleinschreibung und äußere Leerzeichen. Gleiche Anzeigenamen sind zulässig und beweisen keine Personenidentität. Unterschiedliche tatsächliche E-Mail-Adressen lassen sich ohne zusätzlichen Identitätsnachweis nicht automatisch derselben Person zuordnen.

## Zuständigkeiten

Organisationsadmins bzw. berechtigte Nutzerverwalter legen neue Konten an und verwalten ausschließlich die Freigaben ihrer administrierbaren Einheiten. Bestehende Kontodaten sind für sie lesend. Kontoinhaber und Plattformadministration verwalten globale Kontodaten und persönliche Anmeldesicherheit. Ein Organisationsaustritt löscht kein Konto.

## Bestehende Konten aufnehmen

In der Nutzerverwaltung „Bestehendes Konto aufnehmen“ wählen. Die direkte Freigabe verlangt einen genauen Nutzernamen oder eine genaue E-Mail-Adresse und aktiviert die ausgewählten Bereichsrechte sofort. Es gibt keine organisationsübergreifende Nutzersuche. Bereits freigegebene Einheiten werden über „Bereichsrechte bearbeiten“ geändert; die Aufnahme überschreibt keine vorhandenen Rechte.

Die Einladung verlangt die genaue E-Mail-Adresse. Der Empfänger erhält einen sieben Tage gültigen, einmal verwendbaren Link und sieht vor seiner Entscheidung Organisation, Einheiten und Rollen. Nur ausdrückliche Zustimmung aktiviert die Freigabe. Ablehnung, Ablauf und Widerruf aktivieren keine Rechte. Vor der Annahme prüft der Server die aktuelle E-Mail-Bindung sowie die aktuellen Verwaltungsrechte des Einladenden erneut. Eine Änderung kann eine neue Einladung erforderlich machen. Offene Einladungen lassen sich über das Briefsymbol widerrufen.

## Rechte ändern oder entziehen

„Bereichsrechte bearbeiten“ verändert nur administrierbare Einheiten. Rechte anderer Einheiten und Organisationen bleiben erhalten. „Bereichsrechte entziehen“ entfernt sämtliche vom handelnden Admin administrierbaren Freigaben dieses Kontos. Die letzte aktive Adminzuordnung jeder Einheit ist geschützt. Autorisierte Folgeanfragen berechnen die Rechte aus den aktuellen Mitgliedschaften neu.

Auch ohne Organisationsrechte bleibt das zentrale Konto bestehen. Ein neuer Aufnahmevorgang verwendet dieses Konto weiter. Globale Aufbewahrungs- und Löschregeln bleiben eigenständige Kontovorgänge.

## Dubletten und Bestandsdaten

Die Plattformadministration findet Konflikte unter dem Symbol „Identitätskonflikte“ bzw. über `GET /api/users/identity-conflicts`. Die Antwort enthält Konto-IDs, keine zusätzliche Klartextliste persönlicher Daten. Mehrdeutige Anmeldekennungen werden nicht automatisch einem der Konten zugeordnet. Es wird kein Konto automatisch zusammengeführt oder gelöscht.

Zur manuellen Klärung zuerst eine geschützte Sicherung erstellen und die Identität der betroffenen Personen prüfen. Anschließend die richtigen Kennungen mit der Plattformadministration festlegen und die jeweiligen Organisationsadmins die erforderlichen Bereichsrechte bestätigen lassen. Keine Passwörter, MFA-Schlüssel oder Wiederherstellungscodes zwischen Konten kopieren. Eine berechtigte globale Löschung erfolgt separat, nach Prüfung der Referenzen und Aufbewahrungspflichten; der letzte Admin eines Bereichs bleibt geschützt.

## Betrieb und Migration

Die globale Nutzertabelle und die Plattformsammlung `memberships` werden weiterverwendet. Die Migration `20261110_central_user_membership.sql` ergänzt `users.membership_managed`; die Speicherinitialisierung stellt die Spalte zusätzlich idempotent sicher. Neue zentrale Konten speichern die Kennzeichnung bereits beim ersten Identitätsschreibvorgang. Nach einem Absturz vor der ersten dauerhaften Mitgliedschaft erhalten sie deshalb keine Legacy-Standardrechte. Ältere Konten durchlaufen die vorhandene Legacy-Übernahme einmal; vorhandene explizite Mitgliedschaften werden nicht um eine zusätzliche Standardorganisation erweitert. Beim vollständigen Sicherungsimport werden Konten als zentral verwaltet gekennzeichnet, auch wenn sie absichtlich keine Mitgliedschaften besitzen.

Einladungen liegen als gehashte, befristete Nachweise in den Mitgliedschaften. Inaktive Mitgliedschaften bleiben als Entzugsnachweis erhalten. Zusammen mit der Kennzeichnung verhindert dies eine erneute automatische Rechtevergabe beim Neustart. Vor einem Rollback auf ältere Programmversionen beachten, dass deren Legacy-Normalisierung diese neue Kennzeichnung noch nicht auswertet.

`backend/server.js` muss weiter die exklusive Datenbanksperre halten. Der unterstützte Persistenzmodus ist eine einzelne Backendinstanz. Der Speicher baut nach dem Entschlüsseln einen nur im Arbeitsspeicher gehaltenen Kennungsindex auf und serialisiert Nutzer-Schreibvorgänge. Die bisherigen SQL-Spalten enthalten verschlüsselte Identitäten bzw. nutzerabhängige Platzhalter und sind allein kein Eindeutigkeitsnachweis echter E-Mail-Adressen. Es entstehen keine zusätzlichen dauerhaft gespeicherten Klartextkennungen.

Bei fehlgeschlagenem Speichern bleiben Kennungsreservierungen vorsichtshalber belegt, bis ein kontrollierter Neustart den Index aus der Datenbank neu aufbaut. Vor dem Neustart zuerst die Speicherstörung beheben. Direkte SQL-Schreibzugriffe und ein Betrieb unter Umgehung der Instanzsperre sind nicht unterstützt. Eine zukünftige horizontale Skalierung benötigt transaktionale, datenbankseitige Kennungsreservierungen und ein anderes Persistenzmodell.

Sicherungen mit doppelten Kennungen oder Kollisionen zwischen Anmeldename und E-Mail verschiedener Konten werden beim Import abgelehnt. Die produktiven Bestandsdaten wurden in dieser Umsetzung nicht gelesen oder verändert. Vor dem Rollout die Konfliktanzeige mit der Plattformadministration prüfen und Konflikte manuell klären.

## Globale Löschung

Organisationsadmins verwenden ausschließlich den Rechteentzug. Eine Plattformadministration kann ein Konto separat über `DELETE /api/platform/users/:id` löschen; erforderlich sind ihr `currentPassword` und bei aktiver MFA ihr `mfaCode`. Der Kontoinhaber verwendet die bestehende Selbstlöschung. Beide Wege schützen letzte Bereichsadmins und verwenden die vorhandene Anonymisierung und Schlüsselvernichtung.

Die letzte aktive Plattformadministration ist unabhängig von Bereichsrollen geschützt. Eine Löschung reserviert das Konto synchron als inaktiv, bevor die asynchrone Bereinigung beginnt. Globale Kontoverwaltung bleibt für Plattformadministratoren auch ohne nutzbare Organisationszuordnung über ausdrücklich freigegebene Kontorouten verfügbar; daraus entstehen keine Rechte auf Organisationsdaten.

Eine Organisationsrolle kann nur geändert werden, wenn alle Bereiche, die sie in Mitgliedschaften oder offenen Einladungen verwenden, administrierbar sind; die Plattformadministration besitzt die globale Ausnahme. Persönliche NFC- und Offline-QR-Zugänge werden ausschließlich durch die Plattformadministration eingerichtet. Dienstgeräteverwaltung und -aktivierung berücksichtigen neben der Organisation auch die aktive berechtigte Einheit. Eine bestehende TOTP-Einrichtung muss vor einer Neueinrichtung mit Passwort und aktuellem Faktor deaktiviert werden.

## Prüfung und Freigabe

Die Regressionen in `backend/test/central-user-management.test.js` und `backend/test/user-identity.test.js` beschreiben parallele Neuanlage, Kennungskollisionen, Organisationsgrenzen, Rechteentzug und Einladungslebenszyklus. Vor einem produktiven Rollout in einer isolierten Testumgebung mit Dummy-Daten ausführen, außerdem die bestehenden Nutzer-, Mandanten-, Speicher-, Sicherungs-, MFA-, Passkey-, QR- und Dienstgerätetests sowie Flutter-Analyse und Widgettests prüfen. Der Security-Audit-Bericht unterscheidet Quellenprüfung und noch ausstehende dynamische Validierung ausdrücklich.

Zusätzlich beschreiben flutter/test/central_user_dialog_test.dart zwei Oberflächenregressionen für gemischte Bereichsfreigaben und globale Profiländerungen bei unveränderter Dienstgeräterichtlinie. Diese Fixtures wurden vorbereitet und statisch geparst, aber nicht ausgeführt.
