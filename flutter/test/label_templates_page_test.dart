import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/pages/label_templates_page.dart';
import 'package:materialkompass/services/authenticated_api_client.dart';

class _TemplateApi extends AuthenticatedApiClient {
  _TemplateApi({this.canManage = true}) : super('test');
  final bool canManage;
  Map? saved;

  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    if (method == 'PUT') {
      saved = body as Map;
      return {};
    }
    if (path.endsWith('/options')) {
      return {
        'manageableTypes': canManage ? ['inventory', 'clothing'] : [],
        'rendererAvailable': false,
        'organizationSharingAllowed': true,
        'categories': [
          {'id': 'mat', 'name': 'Technik', 'type': 'inventory'},
          {'id': 'wardrobe', 'name': 'Einsatzkleidung', 'type': 'clothing'},
        ],
        'users': [
          {'id': 'u1', 'name': 'Alex Beispiel'},
        ],
      };
    }
    return [
      {
        'id': 't1',
        'name': 'Geräteetikett',
        'fileName': 'Geraet.nlbl',
        'manufacturer': 'Zebra',
        'type': 'inventory',
        'scope': 'organization',
        'categoryIds': ['mat'],
        'userIds': [],
        'variables': [
          {'name': 'Inventory', 'field': 'inventoryNumber'},
        ],
        'fileBytes': 2048,
        'updatedAt': 'v1',
        'canManage': canManage,
      },
    ];
  }
}

void main() {
  testWidgets('shared templates are readable without management controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LabelTemplatesPage(
          token: 'test',
          apiClient: _TemplateApi(canManage: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Geräteetikett'), findsOneWidget);
    expect(find.text('Originaldatei'), findsOneWidget);
    expect(find.text('Vorlage hochladen'), findsNothing);
    expect(find.text('Bearbeiten'), findsNothing);
    expect(
      find.textContaining('Herstellerdienst eingerichtet'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing preserves file, categories, variable names and revision',
    (tester) async {
      final api = _TemplateApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LabelTemplatesPage(token: 'test', apiClient: api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Bearbeiten'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bearbeiten'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Vorlagenname'),
        'Neues Geräteetikett',
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(api.saved?['name'], 'Neues Geräteetikett');
      expect(api.saved?['fileName'], 'Geraet.nlbl');
      expect(api.saved?.containsKey('fileBase64'), false);
      expect(api.saved?['updatedAt'], 'v1');
      expect(api.saved?['categoryIds'], ['mat']);
      expect(api.saved?['variables'], [
        {'name': 'Inventory', 'field': 'inventoryNumber'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small screens keep list and upload dialog usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: LabelTemplatesPage(token: 'test', apiClient: _TemplateApi()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Vorlage hochladen'));
    await tester.pumpAndSettle();
    expect(find.text('Etikettenvorlage hochladen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(find.text('Etikettenvorlage hochladen'), findsNothing);
  });
}
