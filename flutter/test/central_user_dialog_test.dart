import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:materialkompass/pages/users_page.dart';

void main() {
  const ownUnit = {
    'id': 'unit-own',
    'name': 'Eigener Bereich',
    'status': 'active',
    'edvNumber': 'TEST-OWN',
  };
  final user = <String, dynamic>{
    'id': 'dummy-person',
    'name': 'Dummy Person',
    'username': 'dummy.person',
    'email': 'dummy.person@example.org',
    'active': true,
    'organizationAccess': {
      'defaultUnitId': 'unit-other',
      'scopes': [
        {
          'unitId': 'unit-own',
          'roles': ['Nutzer'],
          'departmentIds': <String>[],
        },
        {
          'unitId': 'unit-other',
          'roles': ['Admin'],
          'departmentIds': <String>[],
        },
      ],
    },
  };

  Future<void> openDialog(
    WidgetTester tester, {
    required Map<String, dynamic> account,
    required ValueChanged<Map<String, dynamic>?> onResult,
    bool platform = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onResult(
                await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) => UserDialog(
                    user: account,
                    roles: const ['Admin', 'Nutzer'],
                    currentUnitId: 'unit-other',
                    organizationUnits: const [ownUnit],
                    canManageAccount: platform,
                  ),
                ),
              ),
              child: const Text('Öffnen'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'only manageable scopes are edited and global fields stay read-only',
    (tester) async {
      Map<String, dynamic>? result;
      await openDialog(
        tester,
        account: user,
        onResult: (value) => result = value,
      );
      final adminChip = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .firstWhere((chip) => (chip.label as Text).data == 'Admin');
      expect(adminChip.selected, isFalse);
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        if ([
          'Dummy Person',
          'dummy.person',
          'dummy.person@example.org',
        ].contains(field.controller?.text)) {
          expect(field.readOnly, isTrue);
        }
      }
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(result?['defaultUnitId'], 'unit-own');
      final scopes = (result?['scopes'] as List).cast<Map>();
      expect(scopes, hasLength(1));
      expect(scopes.single['unitId'], 'unit-own');
      expect(scopes.single['roles'], ['Nutzer']);
      expect(result?.containsKey('email'), isFalse);
      expect(result?.containsKey('active'), isFalse);
    },
  );

  testWidgets(
    'platform profile edit without a manageable membership creates no implicit grant',
    (tester) async {
      Map<String, dynamic>? result;
      final globalAccount = <String, dynamic>{
        ...user,
        'loginAccess': {
          'mode': 'selected_service_devices',
          'allowedServiceDeviceIds': ['other-organization-device'],
        },
        'organizationAccess': {
          'defaultUnitId': 'unit-other',
          'scopes': [
            {
              'unitId': 'unit-other',
              'roles': ['Admin'],
              'departmentIds': <String>[],
            },
          ],
        },
      };
      await openDialog(
        tester,
        account: globalAccount,
        platform: true,
        onResult: (value) => result = value,
      );
      await tester.tap(find.text('Speichern'));
      await tester.pumpAndSettle();
      expect(result?['email'], 'dummy.person@example.org');
      expect(result?.containsKey('scopes'), isFalse);
      expect(result?.containsKey('defaultUnitId'), isFalse);
      expect(result?.containsKey('loginAccess'), isFalse);
    },
  );
}
