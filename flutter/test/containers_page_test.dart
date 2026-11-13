import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/containers_page.dart';

Map<String, dynamic> _container() => {
  'id': 'container-9',
  'code': 'K-009',
  'name': 'Sanitätskiste 1',
  'containerType': 'Sanitätskiste',
  'compartments': ['Deckel', 'Boden'],
  'locationName': 'Hauptlager',
  'stockStructureId': 'stock-1',
  'stockStructureName': 'Hauptlager / Regal A / Ebene 1 / Lagerplatz P1',
  'itemCount': 1,
  'contentCount': 1,
  'completenessStatus': 'Unvollständig',
  'packListMissingCount': 1,
  'expiredCount': 1,
  'expiringSoonCount': 0,
  'activePackListVersion': 1,
  'safetyStatus': {
    'blocked': false,
    'reasons': <String>[],
    'warnings': ['Rettungsdecke ist seit 2020-01-31 abgelaufen.'],
  },
  'items': [
    {
      'entityType': 'MaterialItem',
      'entityId': 'material-11',
      'inventoryNumber': '10050035-02-02-011',
      'name': 'Pulsoximeter',
      'itemType': 'individual',
      'quantity': 1,
      'unit': 'Stück',
      'status': 'Lagernd',
      'issued': false,
      'relocatable': true,
    },
  ],
  'contents': [
    {
      'id': 'content-1',
      'entityType': 'Content',
      'inventoryNumber': null,
      'name': 'Rettungsdecke',
      'quantity': 5,
      'unit': 'Stück',
      'position': 'Deckel',
      'expiresAt': '2020-01-31',
      'expiryState': 'abgelaufen',
      'relocatable': false,
    },
  ],
  'packLists': [
    {
      'id': 'list-1',
      'version': 1,
      'name': 'Standard',
      'status': 'Aktiv',
      'createdAt': '2026-11-01T10:00:00.000Z',
      'createdBy': 'admin',
      'items': [
        {
          'entityType': 'Content',
          'name': 'Rettungsdecke',
          'unit': 'Stück',
          'targetQuantity': 10,
        },
      ],
    },
  ],
  'packListDeviation': {
    'name': 'Standard',
    'version': 1,
    'rows': [
      {
        'inventoryNumber': null,
        'name': 'Rettungsdecke',
        'targetQuantity': 10,
        'actualQuantity': 5,
        'deviation': -5,
        'unit': 'Stück',
      },
    ],
  },
  'checks': <Map<String, dynamic>>[],
  'checkTemplate': {
    'packListVersion': 1,
    'items': [
      {
        'key': 'Content:rettungsdecke',
        'entityType': 'Content',
        'inventoryNumber': null,
        'name': 'Rettungsdecke',
        'unit': 'Stück',
        'targetQuantity': 10,
        'expectedQuantity': 5,
        'earliestExpiry': '2020-01-31',
      },
    ],
  },
};

void main() {
  late List<Map<String, Object?>> calls;

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    calls.add({'path': path, 'method': method, 'body': body});
    if (path == '/api/auth/me') {
      return {
        'user': {
          'permissions': [
            'containers.read',
            'containers.manage',
            'containers.pack',
            'containers.packlists',
            'containers.check',
            'containers.print',
          ],
        },
      };
    }
    if (path == '/api/containers') return [_container()];
    if (path == '/api/containers/storage-targets') {
      return {
        'locations': [
          {'id': 'loc-3', 'path': 'Nebenlager'},
        ],
        'stockStructures': [
          {
            'id': 'stock-1',
            'locationId': 'loc-1',
            'path': 'Hauptlager / Regal A / Ebene 1 / Lagerplatz P1',
          },
        ],
        'containers': [
          {
            'id': 'container-9',
            'code': 'K-009',
            'name': 'Sanitätskiste 1',
            'path': 'Hauptlager',
          },
          {
            'id': 'container-10',
            'code': 'K-010',
            'name': 'Verbandmodul',
            'path': 'Hauptlager',
          },
        ],
      };
    }
    if (method != 'GET') return {'success': true};
    if (path.startsWith('/api/containers/expiring')) return [];
    if (path == '/api/containers/container-9' && method == 'GET') {
      return _container();
    }
    if (path == '/api/containers/container-9/checks') {
      return {
        'complete': false,
        'defectNumbers': <String>[],
        'container': _container(),
      };
    }
    return null;
  }

  setUp(() => calls = []);

  testWidgets('lists containers and records a completeness check', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ContainersPage(token: 'token', request: request),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('K-009 · Sanitätskiste 1'), findsOneWidget);
    expect(find.textContaining('Hauptlager / Regal A'), findsOneWidget);
    expect(find.text('Unvollständig'), findsOneWidget);
    expect(find.text('1 abgelaufen'), findsOneWidget);
    expect(find.text('Kiste anlegen'), findsOneWidget);

    await tester.tap(find.text('K-009 · Sanitätskiste 1'));
    await tester.pumpAndSettle();

    expect(find.text('Artikel mit Inventarnummer (1)'), findsOneWidget);
    expect(find.text('Inhalt ohne Inventarnummer (1)'), findsOneWidget);
    // Nur Artikel mit Inventarnummer können umgebucht werden.
    expect(find.byTooltip('Umbuchen'), findsOneWidget);
    await tester.tap(find.byTooltip('Aktionen'));
    await tester.pumpAndSettle();
    expect(find.text('Ausbuchen'), findsOneWidget);
    expect(find.text('Umbuchen'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Soll 10 · Ist 5'), findsOneWidget);

    await tester.tap(find.text('Vollständigkeit prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Vollständigkeitsprüfung'), findsOneWidget);
    // Abgelaufene Inhalte werden als „abgelaufen“ vorbelegt.
    expect(find.text('abgelaufen'), findsWidgets);
    await tester.tap(find.text('Prüfung speichern'));
    await tester.pumpAndSettle();

    final check = calls.lastWhere(
      (entry) => entry['path'] == '/api/containers/container-9/checks',
    );
    final body = check['body'] as Map;
    final results = body['results'] as List;
    expect((results.single as Map)['result'], 'abgelaufen');
    expect((results.single as Map)['actualQuantity'], 5);
    expect(find.text('Kiste ist unvollständig.'), findsOneWidget);
  });

  testWidgets('records contents and relocates only inventoried items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ContainersPage(token: 'token', request: request),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('K-009 · Sanitätskiste 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Inhalt erfassen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Bezeichnung *'),
      'Pflasterstrips',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Menge *'), '20');
    await tester.tap(find.text('Fach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Boden').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    final created = calls.lastWhere(
      (entry) => entry['path'] == '/api/containers/container-9/contents',
    );
    expect(created['method'], 'POST');
    expect((created['body'] as Map)['name'], 'Pflasterstrips');
    expect((created['body'] as Map)['quantity'], 20);
    expect((created['body'] as Map)['position'], 'Boden');

    await tester.tap(find.byTooltip('Umbuchen'));
    await tester.pumpAndSettle();
    expect(find.text('Artikel umbuchen'), findsOneWidget);
    await tester.tap(find.text('Ziel-Lagerort'));
    await tester.pumpAndSettle();
    // Die aktuelle Kiste wird nicht als Ziel angeboten.
    expect(find.textContaining('Kiste K-009 · '), findsNothing);
    expect(find.textContaining('Kiste K-010 · '), findsWidgets);
    await tester.tap(find.textContaining('Kiste K-010').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Umbuchen'));
    await tester.pumpAndSettle();
    final relocated = calls.lastWhere(
      (entry) => '${entry['path']}'.endsWith('/relocate'),
    );
    expect(
      relocated['path'],
      '/api/containers/container-9/items/MaterialItem/material-11/relocate',
    );
    expect((relocated['body'] as Map)['containerId'], 'container-10');
  });
}
