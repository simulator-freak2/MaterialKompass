import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/defects_page.dart';

void main() {
  final defect = <String, dynamic>{
    'id': 'defect-1',
    'defectNumber': 'M-2026-0001',
    'title': 'Druckminderer undicht',
    'description': 'Am Anschluss tritt unter Druck Luft aus.',
    'entityType': 'MaterialItem',
    'entityId': 'material-1',
    'entityName': 'Pressluftatmer',
    'inventoryNumber': 'PA-001',
    'affectedQuantity': 1,
    'status': 'In Bearbeitung',
    'priority': 'Hoch',
    'riskLevel': 'Hoch',
    'operationalSafety': 'Nicht einsatzfähig',
    'assignee': 'Nils Wart',
    'assigneeUserId': 'user-1',
    'responsibleDepartment': 'Material',
    'dueDate': '2026-08-30',
    'checklist': [
      {'id': 'check-1', 'label': 'Dichtung prüfen', 'done': false},
    ],
    'followUpTasks': <dynamic>[],
    'relatedActions': <dynamic>[],
    'comments': <dynamic>[],
    'images': <dynamic>[],
    'documents': <dynamic>[],
    'history': <dynamic>[],
  };

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    if (path == '/api/auth/me') {
      return {
        'user': {
          'id': 'user-1',
          'roles': ['Admin'],
          'permissions': [
            'defects.read',
            'defects.report',
            'defects.edit',
            'defects.assign',
            'defects.close',
            'defects.archive',
            'defects.export',
            'inventory.write',
            'procurement.request',
          ],
        },
      };
    }
    if (path.startsWith('/api/defects?')) return [defect];
    if (path == '/api/defects/defect-1') return defect;
    if (path == '/api/notifications' || path == '/api/defect-email-imports') {
      return <dynamic>[];
    }
    if (path == '/api/defect-report-items') {
      return [
        {
          'id': 'material-1',
          'entityType': 'MaterialItem',
          'name': 'Pressluftatmer',
          'inventoryNumber': 'PA-001',
        },
      ];
    }
    return <String, dynamic>{};
  }

  void setViewport(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('uses a desktop master-detail workspace', (tester) async {
    setViewport(tester, const Size(1440, 960));
    await tester.pumpWidget(
      MaterialApp(
        home: DefectsPage(token: 'test', request: request),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mängelmanagement'), findsOneWidget);
    expect(find.text('1 Mängel'), findsOneWidget);
    expect(find.textContaining('M-2026-0001'), findsNWidgets(2));
    expect(find.text('Weiter: Behoben'), findsOneWidget);
    expect(find.text('Mir zuweisen'), findsOneWidget);
    expect(find.text('Zuweisung & Frist'), findsOneWidget);
    expect(find.text('Dichtung prüfen'), findsOneWidget);

    await tester.tap(find.text('Bearbeiten'));
    await tester.pumpAndSettle();

    expect(find.text('Mangel bearbeiten'), findsOneWidget);
    expect(find.text('Speichern  Strg+S'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Titel *'), findsOneWidget);
  });

  testWidgets('opens a screen-filling detail on a narrow viewport', (
    tester,
  ) async {
    setViewport(tester, const Size(650, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: DefectsPage(token: 'test', request: request),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('M-2026-0001'), findsOneWidget);
    await tester.tap(find.textContaining('M-2026-0001'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('M-2026-0001 · Druckminderer undicht'), findsNWidgets(2));
    expect(find.text('Weiter: Behoben'), findsOneWidget);
  });
}
