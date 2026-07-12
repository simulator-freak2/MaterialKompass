import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/main.dart';

void main() {
  test('default API base URL points to the backend port', () {
    expect(apiBaseUrl, 'http://localhost:3001');
  });

  testWidgets('Login page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialKompassApp());

    expect(find.text('MaterialKompass Login'), findsOneWidget);
    expect(find.text('Interne Materialverwaltung'), findsOneWidget);
  });

  testWidgets('Wardrobe page renders its main actions',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: WardrobePage(token: 'demo-token')));

    expect(find.text('Kleiderkammer'), findsOneWidget);
    expect(find.text('Neue Kleidung anlegen'), findsOneWidget);
    expect(find.text('Ausgabe-/Rückgabe-Log'), findsOneWidget);
    expect(find.text('Neue Kleidung anlegen'), findsOneWidget);
  });
}
