import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/vehicles_page.dart';

void main() {
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    if (path == '/api/auth/me') {
      return {
        'user': {
          'permissions': [
            'vehicles.read',
            'vehicles.write',
            'vehicles.share',
            'vehicles.load.read',
            'vehicles.load.manage',
            'vehicles.print',
            'organizations.write',
            'vehicle_reservations.create',
            'vehicle_reservations.manage',
            'vehicle_reservations.operational_approve',
            'vehicle_maintenance.manage',
            'defects.report',
          ],
        },
        'context': {
          'unit': {'id': 'unit-default-root'},
        },
      };
    }
    if (path.startsWith('/api/vehicles?')) {
      return [
        {
          'id': 'vehicle-1',
          'unitId': 'unit-default-root',
          'registrationNumber': 'DLRG 1',
          'vin': 'WVWZZZ1JZXW000001',
          'radioCallName': 'Pelikan 1/11-1',
          'vehicleKind': 'Kraftfahrzeug',
          'usage': 'Einsatzfahrt',
          'type': 'Einsatzfahrzeug',
          'manufacturer': 'Volkswagen',
          'model': 'Transporter',
          'parkingDetails': 'Halle 1',
          'parkingLocationName': 'Fahrzeughalle',
          'ownerUnitName': 'Musterstadt',
          'status': 'Verfügbar',
          'safetyStatus': {'blocked': false, 'reasons': <String>[]},
        },
      ];
    }
    if (path == '/api/vehicles/options') {
      return {
        'types': ['Kraftfahrzeug', 'Einsatzfahrzeug'],
        'vehicleKinds': [
          'Kraftfahrzeug',
          'Boot',
          'Anhänger',
          'Sonstige Fahrzeugart',
        ],
        'usages': ['Einsatzfahrt', 'sonstige Verwendung'],
        'vehicleTypesByUsage': {
          'Einsatzfahrt': ['Einsatzfahrzeug', 'Kommandowagen'],
          'sonstige Verwendung': ['Vereinsfahrzeug'],
        },
        'statuses': ['Verfügbar', 'In Wartung', 'Defekt', 'Außer Dienst'],
        'parkingLocations': [
          {'id': 'loc-1', 'name': 'Fahrzeughalle', 'path': 'Fahrzeughalle'},
        ],
        'organizationSettings': {
          'primaryVehicleApprovalRequired': true,
          'usages': ['Einsatzfahrt', 'sonstige Verwendung'],
          'vehicleTypesByUsage': {
            'Einsatzfahrt': ['Einsatzfahrzeug', 'Kommandowagen'],
            'sonstige Verwendung': ['Vereinsfahrzeug'],
          },
        },
      };
    }
    if (path == '/api/vehicles/vehicle-1') {
      return {
        'id': 'vehicle-1',
        'unitId': 'unit-default-root',
        'registrationNumber': 'DLRG 1',
        'vin': 'WVWZZZ1JZXW000001',
        'radioCallName': 'Pelikan 1/11-1',
        'vehicleKind': 'Kraftfahrzeug',
        'usage': 'Einsatzfahrt',
        'type': 'Einsatzfahrzeug',
        'manufacturer': 'Volkswagen',
        'model': 'Transporter',
        'year': 2024,
        'mileage': 12500,
        'operatingHours': 420,
        'parkingDetails': 'Halle 1',
        'ownerUnitName': 'Musterstadt',
        'status': 'Verfügbar',
        'safetyStatus': {
          'blocked': true,
          'reasons': ['Sicherheitskritische Wartung offen'],
        },
        'viewAllowedUnitIds': ['unit-neighbor'],
        'reservationAllowedUnitIds': <String>[],
        'reservations': [
          {
            'id': 'reservation-1',
            'title': 'Sanitätsdienst',
            'purpose': 'Absicherung',
            'destination': 'Musterstadt',
            'requesterName': 'Nora Beispiel',
            'startAt': '2026-10-10T08:00:00.000Z',
            'endAt': '2026-10-10T12:00:00.000Z',
            'status': 'Ausstehend',
          },
          {
            'id': 'reservation-2',
            'title': 'Übung',
            'purpose': 'Ausbildung',
            'destination': 'Rhein',
            'requesterName': 'Max Beispiel',
            'startAt': '2026-10-11T08:00:00.000Z',
            'endAt': '2026-10-11T12:00:00.000Z',
            'status': 'TLE-Freigabe ausstehend',
          },
        ],
        'maintenance': [
          {
            'id': 'maintenance-1',
            'type': 'Inspektion',
            'status': 'Geplant',
            'dueDate': '2026-11-01',
            'provider': 'Werkstatt Muster',
            'nextDueDate': '2027-11-01',
            'safetyCritical': true,
          },
        ],
        'loadAssignments': [
          {
            'id': 'load-1',
            'materialId': 'material-1',
            'inventoryNumber': '10050035-01-01-0001',
            'materialName': 'Notfallrucksack',
            'quantity': 1,
            'unit': 'Stück',
            'position': 'Fach links',
            'notes': 'Verplombt',
          },
        ],
        'loadLists': [
          {'version': 2, 'status': 'Aktiv'},
        ],
        'defects': [
          {
            'defectNumber': 'M-2026-0012',
            'title': 'Blaulicht prüfen',
            'priority': 'Hoch',
            'status': 'Neu',
          },
        ],
      };
    }
    if (path == '/api/vehicles/vehicle-1/load-materials') {
      return [
        {
          'id': 'material-1',
          'inventoryNumber': '10050035-01-01-0001',
          'name': 'Notfallrucksack',
          'availableQuantity': 2,
        },
      ];
    }
    if (path == '/api/vehicles/sharing-candidates') {
      return [
        {
          'id': 'unit-neighbor',
          'name': 'Nachbargliederung',
          'type': 'Ortsgruppe',
        },
      ];
    }
    return <String, dynamic>{};
  }

  testWidgets('vehicle page lists vehicles and opens the complete workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: VehiclesPage(token: 'test', request: request),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fahrzeugverwaltung'), findsOneWidget);
    expect(find.text('DLRG 1'), findsOneWidget);
    expect(find.textContaining('Pelikan 1/11-1'), findsOneWidget);
    expect(find.text('Fahrzeug'), findsOneWidget);

    await tester.tap(find.text('DLRG 1'));
    await tester.pumpAndSettle();

    expect(find.text('Stammdaten'), findsOneWidget);
    expect(find.text('Reservierungen'), findsOneWidget);
    expect(find.text('Wartung'), findsOneWidget);
    expect(find.text('Beladung'), findsOneWidget);
    expect(find.text('Mängel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vehicle overview meets automated accessibility guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: VehiclesPage(token: 'test', request: request),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('creates a vehicle and saves organization settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <Map<String, dynamic>>[];

    Future<dynamic> recordingRequest(
      String path, {
      String method = 'GET',
      Object? body,
    }) async {
      calls.add({'path': path, 'method': method, 'body': body});
      return request(path, method: method, body: body);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: VehiclesPage(token: 'test', request: recordingRequest),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Fahrzeug'));
    await tester.pumpAndSettle();
    expect(find.text('Fahrzeug anlegen'), findsOneWidget);

    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.text('Pflichtfeld'), findsNWidgets(2));

    await tester.enterText(find.byType(TextFormField).at(0), 'DLRG 2');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'WVWZZZ1JZXW000002',
    );
    await tester.tap(find.text('Primär ausrückendes Fahrzeug'));
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final create = calls.lastWhere(
      (call) => call['path'] == '/api/vehicles' && call['method'] == 'POST',
    );
    expect((create['body'] as Map)['registrationNumber'], 'DLRG 2');
    expect((create['body'] as Map)['vehicleKind'], 'Kraftfahrzeug');
    expect((create['body'] as Map)['usage'], 'Einsatzfahrt');
    expect((create['body'] as Map)['type'], 'Einsatzfahrzeug');
    expect((create['body'] as Map)['primaryResponseVehicle'], isTrue);

    await tester.tap(find.byTooltip('Fahrzeug-Einstellungen'));
    await tester.pumpAndSettle();
    expect(find.text('TLE-Zweitfreigabe'), findsOneWidget);
    await tester.tap(find.text('TLE-Zweitfreigabe'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Verwendung ergänzen'),
      'Ausbildung',
    );
    await tester.tap(find.byTooltip('Verwendung hinzufügen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Fahrzeugtyp ergänzen'),
      'Schulungsboot',
    );
    await tester.tap(find.byTooltip('Fahrzeugtyp hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final settings = calls.lastWhere(
      (call) =>
          call['path'] == '/api/vehicle-settings' && call['method'] == 'PUT',
    );
    expect(
      (settings['body'] as Map)['primaryVehicleApprovalRequired'],
      isFalse,
    );
    expect((settings['body'] as Map)['usages'], contains('Ausbildung'));
    expect(
      ((settings['body'] as Map)['vehicleTypesByUsage'] as Map)['Ausbildung'],
      containsAll(['Sonstiger Fahrzeugtyp', 'Schulungsboot']),
    );
  });

  testWidgets(
    'vehicle kind controls identifier requirements and usage controls type',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <Map<String, dynamic>>[];

      Future<dynamic> recordingRequest(
        String path, {
        String method = 'GET',
        Object? body,
      }) async {
        calls.add({'path': path, 'method': method, 'body': body});
        return request(path, method: method, body: body);
      }

      await tester.pumpWidget(
        MaterialApp(
          home: VehiclesPage(token: 'test', request: recordingRequest),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fahrzeug'));
      await tester.pumpAndSettle();

      expect(find.text('Fahrzeugart'), findsOneWidget);
      expect(find.text('Verwendung'), findsOneWidget);
      expect(find.text('Fahrzeugtyp'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vehicle-kind')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Boot').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('vehicle-usage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sonstige Verwendung').last);
      await tester.pumpAndSettle();
      expect(find.text('Vereinsfahrzeug'), findsOneWidget);

      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(find.text('Pflichtfeld'), findsNothing);

      final create = calls.lastWhere(
        (call) => call['path'] == '/api/vehicles' && call['method'] == 'POST',
      );
      expect((create['body'] as Map)['vehicleKind'], 'Boot');
      expect((create['body'] as Map)['usage'], 'sonstige Verwendung');
      expect((create['body'] as Map)['type'], 'Vereinsfahrzeug');
      expect((create['body'] as Map)['registrationNumber'], '');
      expect((create['body'] as Map)['vin'], '');
    },
  );

  testWidgets('opens every vehicle workflow dialog', (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: VehiclesPage(token: 'test', request: request),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DLRG 1'));
    await tester.pumpAndSettle();

    expect(find.text('Fahrzeug ist gesperrt'), findsOneWidget);
    expect(find.textContaining('Sanitätsdienst'), findsOneWidget);
    expect(find.textContaining('Inspektion'), findsOneWidget);
    expect(find.textContaining('Notfallrucksack'), findsOneWidget);
    expect(find.textContaining('M-2026-0012'), findsOneWidget);

    Future<void> openAndCancel(Finder trigger, String title) async {
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text(title), findsWidgets);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
    }

    await openAndCancel(find.text('Reservieren'), 'Fahrzeug reservieren');
    await openAndCancel(find.text('Wartung planen'), 'Wartung planen');
    await openAndCancel(
      find.text('Inventar buchen'),
      'Inventar auf Fahrzeug buchen',
    );
    await openAndCancel(
      find.text('Soll-Liste erstellen'),
      'Soll-Beladungsliste erstellen',
    );
    await openAndCancel(find.text('Mangel melden'), 'Fahrzeugmangel melden');
    await openAndCancel(
      find.byTooltip('Für Gliederungen freigeben'),
      'Gliederungsfreigaben',
    );
    await openAndCancel(
      find.byTooltip('Fahrzeug bearbeiten'),
      'Fahrzeug bearbeiten',
    );
    expect(tester.takeException(), isNull);
  });
}
