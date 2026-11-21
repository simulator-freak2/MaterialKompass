# Betriebs- und Wiederherstellungshandbuch

Stand: 17. Oktober 2026

## Serviceziele und Überwachung

- Verfügbarkeit: 99,5 % pro Monat.
- RPO: 24 Stunden; RTO: 4 Stunden.
- `/health` prüft ausschließlich den Prozess, `/ready` zusätzlich MariaDB.
- Alarmieren bei drei fehlgeschlagenen Readiness-Prüfungen, wiederholten HTTP-5xx,
  ausbleibendem Tagesbackup, knappem Datenträger oder Container-Neustartschleifen.
- Strukturierte Backendlogs enthalten Request-ID, Methode, Pfad, Status und Dauer, aber
  keine Tokens, Passwörter, Mailinhalte oder vollständigen personenbezogenen Datensätze.

## Tägliche Kontrollen

1. Containerzustand und `/ready` prüfen.
2. Zeitstempel des letzten erfolgreichen Backups kontrollieren.
3. SHA-256 des neuesten Backups prüfen und externen Replikationsstatus kontrollieren.
4. Prüfen, dass der neueste Dateiname mit `materialkompass-v2-` beginnt und keine
   `materialkompass-<Zeitstempel>`-Legacy-Dumps mehr vorhanden sind.
5. 5xx-/Rate-Limit-/Anmeldeanomalien und freien Speicher sichten.

## Wöchentliche Backup-Prüfung

Das Backend prüft jeden Montag um 03:30 UTC automatisch alle Sicherungen und meldet
das Ergebnis im Dashboard von „MaterialKompass – Zentrale Verwaltung“. Eine verpasste
Prüfung wird nach dem nächsten Start nachgeholt; Plattformadministratoren können unter
**Plattformsicherungen → Jetzt prüfen** jederzeit (höchstens alle 5 Minuten) prüfen.

| Prüfpunkt | Erwartung | Bei Fehler |
| --- | --- | --- |
| Automatische Wochensicherung | wird vor der Prüfung erstellt | Speicherplatz, Volume `materialkompass_platform_backups`, Logs |
| Aktualität der Plattformsicherung | neueste höchstens 8 Tage alt (sonst Hinweis) | Sicherung manuell erstellen |
| Integrität aller Plattformsicherungen | SHA-256 und AES-GCM-Authentifizierung gültig | beschädigte Kennung notieren, Datenträger prüfen |
| Probewiederherstellung | neueste Sicherung vollständig validiert, ohne zu schreiben | Keyring und `IDENTITY_KEYRING_MASTER_KEY` prüfen |
| MariaDB-Tagessicherung | höchstens 26 Stunden alt | `docker compose logs backup` |
| Prüfsumme des Dumps | stimmt mit `.sha256` überein | Dump verwerfen, neuen Lauf erzwingen |
| Inhalt des Dumps | vollständig entpackbar, Kerntabellen und `-- Dump completed` | Dump verwerfen, neuen Lauf erzwingen |

Jede rote Meldung wird wie ein Incident behandelt: Ursache beheben, eine neue Sicherung
erstellen (`docker compose run --rm -e BACKUP_ONCE=true backup` bzw. **Neue Sicherung
erstellen**) und erneut prüfen. Die Probewiederherstellung ersetzt nicht den
vierteljährlichen vollständigen Wiederherstellungstest unten.

## Wiederherstellung aus einer Plattformsicherung

Für logische Fehler (versehentlich gelöschte oder verfälschte Daten) bei intaktem Server
spielen Plattformadministratoren unter **Plattformsicherungen → Zurückspielen** eine
serverseitige Sicherung zurück. Der gesamte Plattformbestand aller Organisationen wird
ersetzt; vorher entsteht automatisch eine Sicherung „Vor Wiederherstellung“, mit der sich
der Schritt rückgängig machen lässt. Alle Refresh-Sitzungen werden beendet;
bereits ausgegebene Zugriffstoken laufen spätestens nach einer Stunde ab. Push-2-FA-Geräte
sind nicht enthalten und müssen ggf. neu registriert werden. Bei Datenträger-, Server-
oder Datenbankverlust gilt weiterhin die dumpbasierte Wiederherstellung unten.

## Wiederherstellungstest

Der Test erfolgt nie über der Produktionsdatenbank.

1. Incident-/Test-ID, Startzeit und verantwortliche Person erfassen.
2. Gewünschten Dump und dessen `.sha256` in einem geschützten Arbeitsverzeichnis prüfen.
3. Eine neue, isolierte MariaDB-Testdatenbank mit derselben Hauptversion starten.
4. Dump importieren; alle Fehler und Dauer erfassen.
5. Tabellenanzahl und Stichproben für Nutzer, Materialien, Prüfungen und Auditlog prüfen.
6. Den aktuellen verschlüsselten Identity-Keyring und denselben
   `IDENTITY_KEYRING_MASTER_KEY` ausschließlich in die isolierte Testumgebung geben.
7. Ein Backend mit ansonsten separaten Test-Secrets gegen die Testdatenbank starten.
8. `/health`, `/ready`, Anmeldung, lesenden Materialabruf und eine rücknehmbare
   Testmutation prüfen.
9. Testdatenbank, Test-Keyring und Secrets sicher entfernen und Ergebnis, tatsächliches RPO/RTO sowie Abweichungen
   protokollieren.

Der Keyring darf extern nur als überschreibender aktueller Stand ohne Versionierung
repliziert werden. Ein fehlender gesamter Keyring ist ein Wiederherstellungsfehler;
ein absichtlich fehlender einzelner Kontoschlüssel muss dagegen einen deaktivierten
Tombstone ohne Passwort, MFA und Passkeys ergeben.

Ein fehlgeschlagener Restore ist ein betrieblicher Incident. Bis zur Behebung darf kein
Release als wiederherstellbar freigegeben werden.

## Störung und Wiederanlauf

1. Auswirkungen und Beginn festhalten; bei Safety-/Datenschutzbezug sofort zuständige
   Verantwortliche einbinden.
2. Weitere Schäden verhindern, ohne flüchtige Nachweise unnötig zu vernichten.
3. Request-IDs und redigierte Logs sichern; Geheimnisse nicht in Tickets übertragen.
4. Ursache beheben oder auf die letzte geprüfte Version zurückrollen.
5. Bei Datenkorruption nach obigem Verfahren auf eine neue Datenbank wiederherstellen.
6. Funktions-, Berechtigungs- und Safety-Stichproben ausführen, erst dann Traffic öffnen.
7. Nachbetrachtung mit Ursache, Zeitlinie, Maßnahmen und Verantwortlichen erstellen.

## Release-Checkliste

- Qualitätsworkflow und Securityworkflow grün; Restrisiken akzeptiert.
- Datenbankmigration in einer Kopie getestet; Rückfallplan dokumentiert.
- Aktueller Restore-Nachweis vorhanden.
- Plattformartefakte signiert und Update von N-1 getestet.
- WCAG-Stichprobe sowie Safety-Ausgabe-/Sperrfall geprüft.
- Versionswerte, Prüfsummen, Releasehinweise und Betreiberkommunikation konsistent.
