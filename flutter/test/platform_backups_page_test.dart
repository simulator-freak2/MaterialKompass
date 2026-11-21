import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/pages/platform_backups_page.dart';
import 'package:materialkompass/widgets/backup_status_card.dart';

Map<String, dynamic> _status({String checkStatus = 'ok', bool weekly = true}) {
  final check = {
    'id': 'bc-20261123T033000Z-0123abcd',
    'kind': 'scheduled',
    'status': checkStatus,
    'completedAt': '2026-11-23T03:31:00Z',
    'summary': checkStatus == 'ok'
        ? 'Alle Sicherungen sind vorhanden, intakt und wiederherstellbar.'
        : 'Mindestens eine Sicherung ist fehlerhaft oder fehlt. Bitte sofort prüfen.',
    'items': [
      {
        'key': 'database-dump-age',
        'label': 'Aktualität der MariaDB-Tagessicherung',
        'status': checkStatus,
        'detail': 'Neueste Sicherung geprüft.',
      },
    ],
    'acknowledged': false,
  };
  return {
    'configured': true,
    'latestCheck': check,
    'weeklyMessage': weekly ? check : null,
    'nextScheduledCheckAt': '2026-11-30T03:30:00Z',
    'backupCount': 1,
    'newestBackup': {'createdAt': '2026-11-23T03:30:00Z'},
  };
}

void main() {
  testWidgets(
    'backup status card shows the weekly message and acknowledges it',
    (tester) async {
      String? acknowledged;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackupStatusCard(
                status: _status(checkStatus: 'error'),
                onAcknowledge: (id) async => acknowledged = id,
                onManage: () {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Backup-Status: Fehler'), findsOneWidget);
      expect(find.textContaining('Wöchentliche Statusmeldung'), findsOneWidget);
      expect(find.text('Sicherungen verwalten'), findsOneWidget);
      await tester.tap(find.text('Zur Kenntnis genommen'));
      expect(acknowledged, 'bc-20261123T033000Z-0123abcd');
    },
  );

  testWidgets('unconfigured backups are shown as an error', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BackupStatusCard(status: {'configured': false})),
      ),
    );
    expect(find.text('Backup-Status: Fehler'), findsOneWidget);
    expect(find.textContaining('nicht konfiguriert'), findsOneWidget);
  });

  testWidgets('restore requires the exact confirmation text', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'backups': [
              {
                'id': 'pb-20261123T033000Z-89abcdef',
                'createdAt': '2026-11-23T03:30:00Z',
                'reason': 'scheduled',
                'recordCount': 120,
                'sizeBytes': 20480,
                'applicationVersion': '1.7.9',
              },
            ],
            'status': _status(weekly: false),
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(jsonEncode({'error': 'abgelehnt'}), 403);
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: PlatformBackupsPage(token: 'demo', client: client),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Wochensicherung'), findsOneWidget);
    expect(find.text('Neue Sicherung erstellen'), findsOneWidget);

    await tester.tap(find.text('Zurückspielen'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Passwort');
    await tester.enterText(fields.at(2), 'ALLE DATEN ERSETZEN');
    await tester.pump();
    final submit = find.widgetWithText(FilledButton, 'Zurückspielen');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);

    await tester.enterText(
      fields.at(2),
      'SICHERUNG pb-20261123T033000Z-89abcdef ZURÜCKSPIELEN',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final restore = requests.last;
    expect(
      restore.url.path,
      '/api/platform/backups/pb-20261123T033000Z-89abcdef/restore',
    );
    final body = jsonDecode(restore.body) as Map<String, dynamic>;
    expect(body['currentPassword'], 'Passwort');
    expect(
      body['confirmation'],
      'SICHERUNG pb-20261123T033000Z-89abcdef ZURÜCKSPIELEN',
    );
    expect(find.text('abgelehnt'), findsOneWidget);
  });
}
