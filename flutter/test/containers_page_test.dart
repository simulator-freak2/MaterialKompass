import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/containers_page.dart';

Map<String, dynamic> _container() => {
  'id': 'material-9',
  'inventoryNumber': '10050035-02-02-009',
  'name': 'Sanitätskiste 1',
  'containerType': 'Sanitätskiste',
  'compartments': ['Deckel', 'Boden'],
  'locationName': 'Hauptlager',
  'contentCount': 2,
  'completenessStatus': 'Unvollständig',
  'issued': false,
  'packListMissingCount': 1,
  'expiredCount': 1,
  'expiringSoonCount': 0,
  'activePackListVersion': 1,
  'safetyStatus': {
    'blocked': false,
    'reasons': <String>[],
    'warnings': ['Inhalt 10050035-02-02-010 ist seit 2020-01-31 abgelaufen.'],
  },
  'contents': [
    {
      'id': 'content-1',
      'entityType': 'MaterialItem',
      'entityId': 'material-10',
      'inventoryNumber': '10050035-02-02-010',
      'name': 'Rettungsdecke',
      'itemType': 'bulk',
      'quantity': 5,
      'unit': 'Stück',
      'position': 'Deckel',
      'expiresAt': '2020-01-31',
      'expiryState': 'abgelaufen',
    },
    {
      'id': 'content-2',
      'entityType': 'MaterialItem',
      'entityId': 'material-11',
      'inventoryNumber': '10050035-02-02-011',
      'name': 'Verbandmodul',
      'itemType': 'individual',
      'quantity': 1,
      'unit': 'Stück',
      'isContainer': true,
      'nestedContentCount': 3,
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
          'entityType': 'MaterialItem',
          'entityId': 'material-10',
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
        'inventoryNumber': '10050035-02-02-010',
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
        'key': 'MaterialItem:material-10',
        'inventoryNumber': '10050035-02-02-010',
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
    if (path.startsWith('/api/containers/expiring')) return [];
    if (path == '/api/containers/material-9' && method == 'GET') {
      return _container();
    }
    if (path == '/api/containers/material-9/checks') {
      return {
        'complete': false,
        'defectNumber': null,
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

    expect(find.text('10050035-02-02-009 · Sanitätskiste 1'), findsOneWidget);
    expect(find.text('Unvollständig'), findsOneWidget);
    expect(find.text('1 abgelaufen'), findsOneWidget);
    expect(find.text('Kiste anlegen'), findsOneWidget);

    await tester.tap(find.text('10050035-02-02-009 · Sanitätskiste 1'));
    await tester.pumpAndSettle();

    expect(find.text('Inhalt (2)'), findsOneWidget);
    expect(
      find.textContaining('Unterkiste mit 3 Position(en)'),
      findsOneWidget,
    );
    expect(find.textContaining('Soll 10 · Ist 5'), findsOneWidget);

    await tester.tap(find.text('Vollständigkeit prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Vollständigkeitsprüfung'), findsOneWidget);
    // Abgelaufene Inhalte werden als „abgelaufen“ vorbelegt.
    expect(find.text('abgelaufen'), findsWidgets);
    await tester.tap(find.text('Prüfung speichern'));
    await tester.pumpAndSettle();

    final check = calls.lastWhere(
      (entry) => entry['path'] == '/api/containers/material-9/checks',
    );
    final body = check['body'] as Map;
    final results = body['results'] as List;
    expect((results.single as Map)['result'], 'abgelaufen');
    expect((results.single as Map)['actualQuantity'], 5);
    expect(find.text('Kiste ist unvollständig.'), findsOneWidget);
  });
}
