import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/widgets/integration_api_keys_panel.dart';

const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

void main() {
  testWidgets('admin creates an API key and sees it exactly once', (
    tester,
  ) async {
    final keys = <Map<String, dynamic>>[];
    Map<String, dynamic>? createdBody;
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer admin-token');
      if (request.method == 'GET' &&
          request.url.path == '/api/integration-keys') {
        return http.Response(
          jsonEncode({
            'scopes': [
              {'id': 'material:lesen', 'label': 'Material lesen'},
              {'id': 'fahrzeuge:lesen', 'label': 'Fahrzeuge lesen'},
            ],
            'keys': keys,
          }),
          200,
          headers: jsonHeaders,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == '/api/integration-keys') {
        createdBody = jsonDecode(request.body) as Map<String, dynamic>;
        final key = {
          'id': 'api-key-1',
          'name': createdBody!['name'],
          'scopes': createdBody!['scopes'],
          'keyHint': 'mkapi_abcd…wxyz',
          'active': true,
          'lastUsedAt': null,
        };
        keys.add(key);
        return http.Response(
          jsonEncode({...key, 'apiKey': 'mkapi_geheimer-schluessel'}),
          201,
          headers: jsonHeaders,
        );
      }
      return http.Response('{}', 404);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IntegrationApiKeysPanel(
            token: 'admin-token',
            baseUrl: 'https://materialkompass.example',
            client: client,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Noch keine API-Schlüssel angelegt.'), findsOneWidget);

    await tester.tap(find.text('API-Schlüssel erstellen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fahrzeuge lesen'));
    await tester.pump();
    await tester.tap(find.text('Erstellen'));
    await tester.pumpAndSettle();

    expect(createdBody, {
      'name': 'Übungsplaner',
      'scopes': ['material:lesen'],
    });
    expect(find.text('mkapi_geheimer-schluessel'), findsOneWidget);
    expect(find.text('https://materialkompass.example/api/v1'), findsWidgets);

    await tester.tap(find.text('Ich habe den Schlüssel gespeichert'));
    await tester.pumpAndSettle();

    expect(find.text('mkapi_geheimer-schluessel'), findsNothing);
    expect(find.text('Übungsplaner'), findsOneWidget);
    expect(find.textContaining('Material lesen'), findsOneWidget);
  });
}
