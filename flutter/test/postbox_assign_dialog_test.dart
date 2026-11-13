import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/procurement_page.dart';

void main() {
  final email = <String, dynamic>{
    'id': 'procurement-email-1',
    'subject': 'Lieferschein und Rechnung',
    'requestId': 'request-1',
    'attachments': [
      {'id': 'attachment-1', 'fileName': 'Lieferschein.pdf'},
      {'id': 'attachment-2', 'fileName': 'Rechnung.pdf'},
    ],
  };
  final requests = <Map<String, dynamic>>[
    {
      'id': 'request-1',
      'number': 'BA-2026-0001',
      'title': 'Leinen',
      'status': 'Bestellt',
    },
    {
      'id': 'request-2',
      'number': 'BA-2026-0002',
      'title': 'Westen',
      'status': 'Abgeschlossen',
    },
  ];

  Future<void> openDialog(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  PostboxAssignDialog(email: email, requests: requests),
            ),
            child: const Text('öffnen'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();
  }

  testWidgets('preselects the detected request with all attachments', (
    tester,
  ) async {
    await openDialog(tester);
    expect(find.text('BA-2026-0001 · Leinen (Bestellt)'), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(2));
    expect(find.textContaining('endgültig gelöscht'), findsOneWidget);
  });

  testWidgets('second assignment receives the unassigned attachment', (
    tester,
  ) async {
    List<Map<String, dynamic>>? result;
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<List<Map<String, dynamic>>>(
                context: context,
                builder: (_) =>
                    PostboxAssignDialog(email: email, requests: requests),
              );
            },
            child: const Text('öffnen'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('öffnen'));
    await tester.pumpAndSettle();

    // Rechnung aus der ersten Zuweisung herausnehmen.
    await tester.tap(find.widgetWithText(FilterChip, 'Rechnung.pdf'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nicht zugewiesen'), findsOneWidget);

    await tester.tap(find.text('Weiteren Vorgang hinzufügen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nicht zugewiesen'), findsNothing);

    await tester.tap(find.byType(DropdownButtonFormField<String>).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BA-2026-0002 · Westen (Abgeschlossen)').last);
    await tester.pumpAndSettle();
    expect(
      find.text('Abgeschlossene Vorgänge nehmen nur Rechnungen an.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Zuweisen und löschen'));
    await tester.pumpAndSettle();
    expect(result, [
      {
        'requestId': 'request-1',
        'documentType': 'Angebot',
        'attachmentIds': ['attachment-1'],
      },
      {
        'requestId': 'request-2',
        'documentType': 'Rechnung',
        'attachmentIds': ['attachment-2'],
      },
    ]);
  });
}
