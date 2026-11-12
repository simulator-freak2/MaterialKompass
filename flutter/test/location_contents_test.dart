import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/pages/locations_page.dart';

void main() {
  testWidgets('location contents show current articles and optional history', (
    tester,
  ) async {
    final client = MockClient((request) async {
      Object body;
      if (request.url.path == '/api/auth/me') {
        body = {
          'user': {
            'permissions': [
              'locations.read',
              'inventory.read',
              'clothing.read',
            ],
          },
        };
      } else if (request.url.path == '/api/storage-hierarchy') {
        body = {
          'locations': [
            {'id': 'loc-test', 'name': 'Testlager', 'code': 'TL'},
          ],
          'shelves': [],
          'storageLevels': [],
          'stockStructures': [],
        };
      } else if (request.url.path ==
          '/api/storage-contents/locations/loc-test') {
        body = {
          'items': [
            {
              'id': 'one',
              'name': 'Aktuelle Jacke',
              'inventoryNumber': '001',
              'type': 'Kleidung',
              'quantity': 1,
              'status': 'Lagernd',
              'locationName': 'Testlager',
            },
            if (request.url.queryParameters['history'] == 'true')
              {
                'id': 'two',
                'name': 'Alte Jacke',
                'inventoryNumber': '002',
                'type': 'Kleidung',
                'quantity': 1,
                'status': 'Archiviert',
                'locationName': 'Testlager',
              },
          ],
          'hiddenTypes': [],
        };
      } else {
        return http.Response('{}', 404);
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsPage(token: 'test', client: client),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zugeordnete Artikel'));
    await tester.pumpAndSettle();
    expect(find.text('001 · Aktuelle Jacke'), findsOneWidget);
    expect(find.text('002 · Alte Jacke'), findsNothing);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('002 · Alte Jacke'), findsOneWidget);
    await tester.tap(find.text('Schließen'));
    await tester.pumpAndSettle();
    expect(find.text('Historie einblenden'), findsNothing);
  });
}
