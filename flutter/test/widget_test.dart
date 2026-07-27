import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/main.dart';
import 'package:materialkompass/pages/dashboard_page.dart';
import 'package:materialkompass/pages/users_page.dart';
import 'package:materialkompass/widgets/stat_card.dart';

void main() {
  test('default API base URL points to the backend port', () {
    expect(apiBaseUrl, 'http://localhost:3001');
  });

  testWidgets('Login page renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialKompassApp());

    expect(find.text('MaterialKompass Login'), findsOneWidget);
    expect(find.text('Interne Materialverwaltung'), findsOneWidget);
    expect(find.text('App herunterladen'), findsOneWidget);
    expect(find.text('Windows nicht verfügbar'), findsOneWidget);
    expect(find.text('Linux nicht verfügbar'), findsOneWidget);
    expect(find.text('Android nicht verfügbar'), findsOneWidget);
  });

  testWidgets('Dashboard is usable on a narrow phone screen',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var loadCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: DashboardPage(
        token: 'demo',
        dashboardLoader: () async {
          loadCount += 1;
          return {
            'summary': {
              'materialCount': 42,
              'issuedMaterialCount': 7,
              'defectiveMaterialCount': 2,
              'dueInspectionCount': 3,
              'clothingCount': 18,
              'defectCount': 1,
              'openDefectCount': 1,
              'defectsInProgressCount': 1,
              'pendingDefectEmailCount': 2,
              'procurementCount': 5,
              'pendingProcurementApprovals': 2,
              'overdueProcurementOrders': 1,
              'openProcurementReceipts': 4,
            },
            'currentUser': {
              'name': 'Admin User',
              'roles': ['Admin'],
              'permissions': [
                'users.read',
                'roles.read',
                'locations.read',
                'categories.read',
                'inventory.read',
                'clothing.read',
                'defects.read',
                'procurement.read',
                'procurement.approve',
                'procurement.order',
                'procurement.receive',
              ],
            },
            'recentActivity': [
              {
                'entityLabel': 'Material',
                'itemName': 'Rettungsweste',
                'actionLabel': 'aktualisiert',
                'actor': 'Testnutzer',
                'timestamp': '2026-07-23T10:00:00Z',
                'area': 'Inventar',
              },
            ],
          };
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(loadCount, 1);
    expect(find.text('Material'), findsWidgets);
    expect(find.text('Material ausgegeben'), findsOneWidget);
    expect(find.text('E-Mail-Prüfungen'), findsOneWidget);

    final firstCard = tester.getTopLeft(find.byWidgetPredicate(
      (widget) => widget is StatCard && widget.title == 'Material',
    ));
    final secondCard = tester.getTopLeft(find.byWidgetPredicate(
      (widget) => widget is StatCard && widget.title == 'Material ausgegeben',
    ));
    expect((firstCard.dy - secondCard.dy).abs(), lessThan(5));
    expect(secondCard.dx, greaterThan(firstCard.dx));

    await tester.scrollUntilVisible(
      find.text('Schnellzugriff'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Schnellzugriff'), findsOneWidget);
    expect(find.text('Nutzerverwaltung'), findsOneWidget);
    expect(find.text('Mängel'), findsOneWidget);
    expect(find.byIcon(Icons.checkroom), findsWidgets);

    final wardrobeIcon = tester.getTopLeft(find.byIcon(Icons.checkroom).first);
    final wardrobeLabel = tester.getTopLeft(find.text('Kleiderkammer').first);
    expect((wardrobeIcon.dy - wardrobeLabel.dy).abs(), lessThan(3));

    await tester.scrollUntilVisible(
      find.textContaining('Rettungsweste'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Rettungsweste'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dashboard hides areas and metrics without permission',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: DashboardPage(
        token: 'restricted',
        dashboardLoader: () async => {
          'summary': {
            'materialCount': 12,
            'issuedMaterialCount': 2,
            'defectiveMaterialCount': 1,
            'dueInspectionCount': 0,
            // Even accidentally supplied values must stay hidden in the UI.
            'clothingCount': 99,
            'pendingProcurementApprovals': 8,
          },
          'currentUser': {
            'name': 'Lesender Nutzer',
            'roles': ['Nutzer'],
            'permissions': [
              'dashboard.read',
              'inventory.read',
              'locations.read',
            ],
          },
          'recentActivity': const [],
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Inventar'), findsOneWidget);
    expect(find.text('Lagerorte'), findsOneWidget);
    expect(find.text('Kleiderkammer'), findsNothing);
    expect(find.text('Beschaffung'), findsNothing);
    expect(find.text('Nutzerverwaltung'), findsNothing);
    expect(find.text('Kleidung'), findsNothing);
    expect(find.text('Freigaben offen'), findsNothing);
    expect(find.text('Material defekt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Admin user dialog covers accounts and roles',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: UserDialog(user: null, roles: ['Admin', 'Nutzer']),
      ),
    ));

    expect(find.text('Nutzer anlegen'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Nutzername *'), findsOneWidget);
    expect(find.text('E-Mail *'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Account aktiv'), findsOneWidget);
  });

  testWidgets('Role dialog can edit name and permissions',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: RoleDialog(
          permissions: ['dashboard.read', 'users.read'],
          role: {
            'id': 'role-reader',
            'name': 'Leser',
            'permissions': ['dashboard.read'],
          },
        ),
      ),
    ));

    expect(find.text('Rolle bearbeiten'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Leser'), findsOneWidget);
    expect(find.text('dashboard.read'), findsOneWidget);
    expect(find.text('users.read'), findsOneWidget);
    expect(find.text('Speichern'), findsOneWidget);
  });

  testWidgets('Department dialog centrally edits name, code and status',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DepartmentDialog(
          department: {
            'id': 'department-technik',
            'name': 'Technik',
            'code': 'TECH',
            'active': true,
          },
        ),
      ),
    ));

    expect(find.text('Fachbereich bearbeiten'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Technik'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'TECH'), findsOneWidget);
    expect(find.text('Fachbereich aktiv'), findsOneWidget);
  });

  testWidgets('Scanner email dialog creates an admin-managed address',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ScannerEmailDialog(
          address: null,
          domain: 'materialkompass.org',
          destinations: ['Mängel', 'Dokumente'],
        ),
      ),
    ));

    expect(find.text('Scanner-E-Mail-Adresse anlegen'), findsOneWidget);
    expect(find.text('@materialkompass.org'), findsOneWidget);
    expect(find.text('Zielbereich *'), findsOneWidget);
    expect(find.text('Adresse aktiv'), findsOneWidget);
  });

  testWidgets('Wardrobe page renders its main actions',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: WardrobePage(token: 'demo-token')));

    expect(find.text('Kleiderkammer'), findsOneWidget);
    expect(find.text('Neue Kleidung anlegen'), findsOneWidget);
    expect(find.text('Ausgabe-/Rückgabe-Log'), findsOneWidget);
    expect(find.text('Ausgeben/Zurücknehmen'), findsOneWidget);
    expect(find.text('Kategorie ändern'), findsOneWidget);
    expect(find.text('Scannen'), findsOneWidget);
    expect(find.text('Tabelle importieren'), findsOneWidget);
    expect(find.text('Tabelle exportieren'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Excel (.xlsx)'), findsOneWidget);
    expect(find.text('OpenDocument (.ods)'), findsOneWidget);

    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ausgeben/Zurücknehmen'));
    await tester.pumpAndSettle();

    expect(find.text('Ausgeben / Zurücknehmen'), findsOneWidget);
    expect(find.text('Kleidung suchen'), findsOneWidget);
    expect(
      find.text('Name, Inventarnummer, Größe, Kategorie oder Person'),
      findsOneWidget,
    );
    expect(find.text('Kleidungsstück'), findsNothing);
  });

  testWidgets('Category management has its own page',
      (WidgetTester tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: CategoriesPage(token: 'demo')));
    await tester.pumpAndSettle();

    expect(find.text('Kategorieverwaltung'), findsOneWidget);
    expect(find.text('Globale Kategorien'), findsOneWidget);
    expect(find.text('Kategorie-ID'), findsOneWidget);
    expect(find.text('Übergeordnete Hauptkategorie'), findsOneWidget);
    expect(find.text('In Kleiderkammer nutzen'), findsOneWidget);
    expect(find.text('Kategorie hinzufügen'), findsOneWidget);

    await tester.tap(find.text('In Kleiderkammer nutzen'));
    await tester.pump();

    expect(find.text('Vordefinierte Größen'), findsOneWidget);
    expect(find.text('Prüfintervall (Monate)'), findsOneWidget);
  });

  testWidgets('Inventory form covers individual and quantity items',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InventoryFormDialog(
          categories: const [
            {'id': '02', 'name': 'Werkzeug', 'parentId': null},
            {'id': '02-02', 'name': 'Handwerk', 'parentId': '02'},
          ],
          locations: const [
            {'id': 'loc-1', 'name': 'Hauptlager'},
          ],
          stocks: const [
            {
              'id': 'stock-1',
              'name': 'Regal A',
              'section': 'A1',
              'locationId': 'loc-1',
            },
          ],
        ),
      ),
    ));

    expect(find.text('Material anlegen'), findsOneWidget);
    expect(find.text('Bezeichnung *'), findsOneWidget);
    expect(find.text('Inventarnummer (optional)'), findsOneWidget);
    expect(find.text('Einzelartikel'), findsOneWidget);
    expect(find.text('Prüfintervall (Monate)'), findsOneWidget);
    expect(find.text('Nächster Prüftermin (TT.MM.JJJJ)'), findsOneWidget);
  });

  testWidgets('Procurement page exposes its three work areas',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProcurementPage(token: 'demo-token')),
    );

    expect(find.text('Beschaffung'), findsOneWidget);
    expect(find.text('Vorgänge'), findsOneWidget);
    expect(find.text('Freigaben'), findsOneWidget);
    expect(find.text('Lieferanten'), findsOneWidget);
  });

  testWidgets('Procurement request dialog can create line items',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProcurementRequestDialog(
          categories: const [
            {'id': '02', 'name': 'Werkzeug', 'parentId': null},
            {'id': '02-02', 'name': 'Handwerk', 'parentId': '02'},
          ],
          suppliers: const [
            {'id': 'supplier-1', 'name': 'Testlieferant', 'active': true},
          ],
        ),
      ),
    ));

    expect(find.text('Beschaffungsantrag anlegen'), findsOneWidget);
    expect(find.text('Titel *'), findsOneWidget);
    expect(find.text('Beantragtes Budget *'), findsOneWidget);
    expect(find.text('Positionen'), findsOneWidget);
    expect(find.text('Bezeichnung *'), findsOneWidget);
    expect(find.text('Einzelpreis brutto *'), findsNothing);
    expect(find.text('Entwurf speichern'), findsOneWidget);
  });

  testWidgets('Procurement request dialog restores the requested budget',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProcurementRequestDialog(
          categories: const [
            {'id': '02', 'name': 'Werkzeug', 'parentId': null},
          ],
          suppliers: const [],
          request: const {
            'title': 'Testvorgang',
            'reason': 'Test',
            'requestedBudgetGross': 125.50,
            'priority': 'Normal',
            'items': [
              {
                'id': 'item-1',
                'name': 'Testmaterial',
                'categoryId': '02',
                'quantity': 1,
                'unit': 'Stück',
                'taxRate': 19,
              }
            ],
          },
        ),
      ),
    ));

    final budgetField = tester.widget<TextField>(find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Beantragtes Budget *'));
    expect(budgetField.controller?.text, '125.5');
    expect(find.text('Beschaffungsentwurf bearbeiten'), findsOneWidget);
  });

  testWidgets('Order dialog treats offer price as gross line total',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OrderDialog(
          request: const {
            'approvedBudgetGross': 450,
            'preferredSupplierId': 'supplier-1',
            'selectedOfferId': 'offer-1',
            'items': [
              {
                'id': 'item-1',
                'name': 'Feststoffweste',
                'quantity': 20,
              }
            ],
            'offers': [
              {
                'id': 'offer-1',
                'supplierId': 'supplier-1',
                'grossTotal': 432.50,
              }
            ],
          },
          suppliers: const [
            {'id': 'supplier-1', 'name': 'DLRG Fachhandel'},
          ],
        ),
      ),
    ));

    final totalField = tester.widget<TextField>(find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Positionssumme brutto'));
    expect(totalField.controller?.text, '432.5');
    expect(find.text('Freigegebenes Budget'), findsOneWidget);
  });
}
