# MaterialKompass

MaterialKompass ist eine interne Materialverwaltungssoftware für eine DLRG-Ortsgruppe.

## Aktueller Stand

- Backend-API mit Express und JWT-Login
- Datenbankschema für die Kernentitäten
- Flutter-Web-Startseite mit Login und Dashboard
- Seed-Daten für Rollen, Benutzer, Standorte, Kategorien und Material

## Verzeichnisstruktur

- backend/ – REST-Backend
- backend/src/db/schema.sql – MariaDB-/MySQL-Schema
- flutter/ – Flutter-Web-/Desktop-Frontend

## Lokale Ausführung

### Backend

```bash
cd backend
npm install
node server.js
```

### Flutter

```bash
cd flutter
flutter pub get
flutter run -d chrome
```

## Geplante Erweiterungen

Die Basis deckt bereits die Kernarchitektur und erste API-Endpunkte für Auth, Rollen, Standorte, Kategorien, Material, Kleidung, Mängel, Beschaffung, Dokumente, Berichte und Dashboard ab.
