import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/psage_inspection_dialog.dart';

Map<String, dynamic> _settings() => {
  'canInspect': true,
  'visualCheckEnabled': true,
  'pdfEnabled': true,
  'checklists': {
    'version': 'LV-Hessen-Westenkunde-2023-1',
    'expert': {
      'buoyancy-aid': {
        'title': 'Überprüfung einer Schwimmhilfe',
        'sections': [
          {
            'id': 'main',
            'title': 'Prüfung',
            'items': [
              {'id': 'ba-1.2', 'position': '1.2', 'label': 'Auftriebskörper'},
              {
                'id': 'ba-swiftwater',
                'position': 'NEU',
                'label': 'Strömungsretterweste: Notauslösemechanismus',
                'requires': 'swiftwater',
              },
              {'id': 'ba-3.5', 'position': '3.5', 'label': 'Zustand der Nähte'},
            ],
          },
        ],
      },
    },
    'visual': <String, dynamic>{},
  },
};

void main() {
  testWidgets('renders applicable positions and tracks open ratings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PsageChecklistDialog(
            token: 'token',
            item: const {
              'id': 'clothing-1',
              'name': 'Feststoffweste',
              'inventoryNumber': '10050035-04-04-0001',
              'psageSwiftwaterRescue': false,
            },
            vestType: 'buoyancy-aid',
            kind: 'expert',
            settings: _settings(),
          ),
        ),
      ),
    );

    expect(find.text('Prüfung durch einen Sachkundigen'), findsOneWidget);
    expect(find.text('Auftriebskörper'), findsOneWidget);
    expect(find.textContaining('Notauslösemechanismus'), findsNothing);
    expect(find.text('Offene Positionen auf OK (2)'), findsOneWidget);

    await tester.tap(find.text('KO').first);
    await tester.pump();
    expect(find.text('Offene Positionen auf OK (1)'), findsOneWidget);
    expect(
      find.text('Die vorliegende PSAgE ist nicht einsatzbereit.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Offene Positionen auf OK (1)'));
    await tester.pump();
    expect(find.text('Offene Positionen auf OK (0)'), findsOneWidget);
  });

  testWidgets('safety banner lists blocking reasons', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PsageSafetyBanner(
            safety: {
              'blocked': true,
              'reasons': ['Das Herstellungsdatum ist nicht hinterlegt.'],
              'warnings': [],
            },
          ),
        ),
      ),
    );
    expect(find.text('Nicht einsatzbereit – Ausgabe gesperrt'), findsOneWidget);
    expect(
      find.text('Das Herstellungsdatum ist nicht hinterlegt.'),
      findsOneWidget,
    );
  });
}
