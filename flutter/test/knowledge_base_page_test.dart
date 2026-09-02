import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/knowledge_base_page.dart';

void main() {
  testWidgets('knowledge base searches and opens an article', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: KnowledgeBasePage()));

    expect(find.text('Wie können wir dir helfen?'), findsOneWidget);
    expect(find.text('Seitenhierarchie'), findsOneWidget);
    expect(find.text('Alle Anleitungen'), findsWidgets);

    await tester.enterText(find.byType(SearchBar), 'Wareneingang');
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

  testWidgets('knowledge base contains 1.4 security and offline guides', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: KnowledgeBasePage()));

    await tester.enterText(find.byType(SearchBar), '2-FA');
    await tester.pump();

    expect(
      find.text('Zwei-Faktor-Authentifizierung einrichten'),
      findsOneWidget,
    );
    await tester.tap(find.text('Zwei-Faktor-Authentifizierung einrichten'));
    await tester.pumpAndSettle();

    expect(find.text('Stand 1.4.2'), findsOneWidget);
    expect(find.text('Für alle persönlichen Konten'), findsOneWidget);
    expect(find.text('Bevor du beginnst'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('knowledge base works on a narrow screen', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: KnowledgeBasePage()));

    expect(find.text('Themen'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsWidgets);
    expect(find.text('Seitenhierarchie'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('knowledge base explains keyboard dropdown selection', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: KnowledgeBasePage()));
    await tester.enterText(find.byType(SearchBar), 'Anfangsbuchstabe');
    await tester.pump();

    expect(
      find.text('Auswahlfelder mit der Tastatur bedienen'),
      findsOneWidget,
    );
    await tester.tap(find.text('Auswahlfelder mit der Tastatur bedienen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('mehrere Zeichen zügig'), findsOneWidget);
    expect(find.textContaining('nur hervorgehoben'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('knowledge base explains passkey setup and recovery', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: KnowledgeBasePage()));
    await tester.enterText(find.byType(SearchBar), 'Passkey');
    await tester.pump();

    expect(find.text('Passkey einrichten und verwenden'), findsOneWidget);
    await tester.tap(find.text('Passkey einrichten und verwenden'));
    await tester.pumpAndSettle();

    expect(find.textContaining('öffentlichen Schlüssel'), findsOneWidget);
    expect(find.textContaining('Linux'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
