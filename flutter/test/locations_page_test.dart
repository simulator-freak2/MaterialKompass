import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/pages/locations_page.dart';

void main() {
  final hierarchy = {
    'locations': [
      {
        'id': 'loc-1',
        'name': 'Hauptlager',
        'code': 'HL',
        'street': 'Hafenstraße',
        'houseNumber': '1',
        'postalCode': '20457',
        'city': 'Hamburg',
        'country': 'Deutschland',
      },
      {
        'id': 'loc-2',
        'name': 'Kleiderkammer',
        'code': 'KK',
        'street': 'Deichweg',
        'houseNumber': '2',
        'postalCode': '20457',
        'city': 'Hamburg',
        'country': 'Deutschland',
      },
    ],
    'shelves': [
      {
        'id': 'shelf-1',
        'name': 'Regal Atemschutz',
        'code': 'RA',
        'locationId': 'loc-1',
        'path': 'Hauptlager / Regal Atemschutz',
      },
      {
        'id': 'shelf-2',
        'name': 'Jackenregal',
        'code': 'JR',
        'locationId': 'loc-2',
        'path': 'Kleiderkammer / Jackenregal',
      },
    ],
    'storageLevels': [
      {
        'id': 'level-1',
        'name': 'Ebene 1',
        'code': 'E1',
        'shelfId': 'shelf-1',
        'locationId': 'loc-1',
        'path': 'Hauptlager / Regal Atemschutz / Ebene 1',
      },
      {
        'id': 'level-2',
        'name': 'Ebene 1',
        'code': 'E1',
        'shelfId': 'shelf-2',
        'locationId': 'loc-2',
        'path': 'Kleiderkammer / Jackenregal / Ebene 1',
      },
    ],
    'stockStructures': [
      {
        'id': 'stock-1',
        'name': 'Lagerplatz B-02',
        'code': 'B-02',
        'levelId': 'level-1',
        'shelfId': 'shelf-1',
        'locationId': 'loc-1',
        'path': 'Hauptlager / Regal Atemschutz / Ebene 1 / Lagerplatz B-02',
        'fullCode': 'HL-RA-E1-B-02',
      },
      {
        'id': 'stock-2',
        'name': 'Lagerplatz J-01',
        'code': 'J-01',
        'levelId': 'level-2',
        'shelfId': 'shelf-2',
        'locationId': 'loc-2',
        'path': 'Kleiderkammer / Jackenregal / Ebene 1 / Lagerplatz J-01',
        'fullCode': 'KK-JR-E1-J-01',
      },
    ],
  };

  MockClient client({
    bool canWrite = false,
    void Function(http.Request)? onPost,
  }) {
    return MockClient((request) async {
      if (request.method == 'POST') {
        onPost?.call(request);
        return http.Response(jsonEncode({'id': 'loc-3'}), 201);
      }
      if (request.url.path == '/api/storage-hierarchy') {
        return http.Response(jsonEncode(hierarchy), 200);
      }
      if (request.url.path == '/api/auth/me') {
        return http.Response(
          jsonEncode({
            'user': {
              'permissions': canWrite
                  ? ['locations.read', 'locations.write']
                  : ['locations.read'],
            },
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });
  }

  testWidgets('shows hierarchy and filters by a nested storage place', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsPage(token: 'test', client: client()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Gebäude und Lagerstruktur'), findsOneWidget);
    expect(find.text('Hauptlager'), findsOneWidget);
    expect(find.text('Kleiderkammer'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    await tester.enterText(find.byType(TextField), 'B-02');
    await tester.pumpAndSettle();

    expect(find.text('Hauptlager'), findsOneWidget);
    expect(find.text('Kleiderkammer'), findsNothing);
    expect(find.text('Regal Atemschutz'), findsOneWidget);
    expect(find.text('Lagerplatz B-02'), findsOneWidget);
  });

  testWidgets('validates and normalizes a new building', (tester) async {
    Map<String, dynamic>? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsPage(
          token: 'test',
          client: client(
            canWrite: true,
            onPost: (request) {
              submitted = jsonDecode(request.body) as Map<String, dynamic>;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Neues Gebäude'));
    await tester.pumpAndSettle();

    final formFields = find.byType(TextFormField);
    await tester.enterText(formFields.at(0), '  Außenlager  ');
    await tester.enterText(formFields.at(1), 'al-2');
    final addressFields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(addressFields.at(2), '  Hafenstraße  ');
    await tester.enterText(addressFields.at(3), '  7a  ');
    await tester.enterText(addressFields.at(4), '  20457  ');
    await tester.enterText(addressFields.at(5), '  Hamburg  ');
    expect(
      tester.widget<TextFormField>(formFields.at(0)).controller?.text,
      '  Außenlager  ',
    );
    expect(
      tester.widget<TextFormField>(formFields.at(1)).controller?.text,
      'AL-2',
    );
    expect(
      tester.widget<TextField>(addressFields.at(2)).controller?.text,
      '  Hafenstraße  ',
    );
    expect(
      tester.widget<TextField>(addressFields.at(5)).controller?.text,
      '  Hamburg  ',
    );
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    expect(submitted, {
      'name': 'Außenlager',
      'code': 'AL-2',
      'street': 'Hafenstraße',
      'houseNumber': '7a',
      'postalCode': '20457',
      'city': 'Hamburg',
      'country': 'Deutschland',
    });
    expect(find.text('Gebäude wurde angelegt.'), findsOneWidget);
  });

  testWidgets('shows a retry action when loading fails', (tester) async {
    final failingClient = MockClient((_) async => http.Response('{}', 500));
    await tester.pumpWidget(
      MaterialApp(
        home: LocationsPage(token: 'test', client: failingClient),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Die Lagerstruktur konnte nicht geladen werden.'),
      findsOneWidget,
    );
    expect(find.text('Erneut versuchen'), findsOneWidget);
  });
}
