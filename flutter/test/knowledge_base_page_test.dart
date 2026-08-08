import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/knowledge_base_page.dart';

void main() {
  testWidgets('knowledge base searches and opens an article',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: KnowledgeBasePage()),
    );

    expect(find.text('Wie können wir helfen?'), findsOneWidget);
    expect(find.text('Seitenhierarchie'), findsOneWidget);
    expect(find.text('Alle Anleitungen'), findsWidgets);

    await tester.enterText(
      find.byType(SearchBar),
      'Wareneingang',
    );
    await tester.pump();

    expect(find.text('Wareneingang buchen'), findsOneWidget);
    expect(find.text('Material neu anlegen'), findsNothing);

    await tester.tap(find.text('Wareneingang buchen'));
    await tester.pumpAndSettle();

    expect(find.text('Schritt für Schritt'), findsOneWidget);
    expect(find.text('Zurück zur Übersicht'), findsOneWidget);
    expect(find.text('War diese Anleitung hilfreich?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('knowledge base works on a narrow screen',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: KnowledgeBasePage()),
    );

    expect(find.text('Themen'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(find.text('Seitenhierarchie'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('knowledge base contains the current operational workflows',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: KnowledgeBasePage()),
    );

    expect(find.text('Stand: August 2026'), findsOneWidget);
    expect(find.text('Inventuren'), findsWidgets);

    await tester.enterText(find.byType(SearchBar), 'Blindzählung');
    await tester.pump();
    expect(find.text('Inventur anlegen und vorbereiten'), findsOneWidget);

    await tester.enterText(
        find.byType(SearchBar), 'angebote@materialkompass.org');
    await tester.pump();
    expect(find.text('Angebote aus der Postbox übernehmen'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'HL-A-01-01');
    await tester.pump();
    expect(find.text('Lagerstruktur anlegen und pflegen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
