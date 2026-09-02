import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/offline_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'offline QR lease validates a QR without persisting its secret',
    () async {
      const qr = 'mkoffline:v1:very-secret-random-value';
      final verifier = sha256.convert(utf8.encode(qr)).toString();
      await OfflineStore.instance.saveQrLease({
        'verifierHash': verifier,
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(days: 7))
            .toIso8601String(),
        'subjectId': 'user-1',
        'sessionType': 'service_device_personal',
        'deviceId': 'device-1',
        'deviceSecurityVersion': 3,
        'locationIds': ['loc-1'],
      }, sessionToken: 'opaque-session-token');

      final accepted = await OfflineStore.instance.authenticateQr(qr);
      final rejected = await OfflineStore.instance.authenticateQr('$qr-wrong');

      expect(accepted?['subjectId'], 'user-1');
      expect(accepted?['sessionToken'], 'opaque-session-token');
      expect(rejected, isNull);
    },
  );

  test('queued commands remain separated by authenticated subject', () async {
    final first = await OfflineStore.instance.enqueue(
      subject: 'user-1:device-1',
      method: 'POST',
      uri: Uri.parse('https://example.invalid/api/transactions'),
      body: '{"action":"ausgegeben"}',
    );
    await OfflineStore.instance.enqueue(
      subject: 'user-2:device-1',
      method: 'POST',
      uri: Uri.parse('https://example.invalid/api/transactions'),
      body: '{"action":"zurückgegeben"}',
    );

    expect(first.id, startsWith('offline-'));
    expect((await OfflineStore.instance.commands()).length, 2);
    await OfflineStore.instance.discardCommand(
      'user-2:device-1',
      (await OfflineStore.instance.commands()).last.id,
    );
    expect(
      (await OfflineStore.instance.commands()).single.subject,
      'user-1:device-1',
    );
    await OfflineStore.instance.discardCommands('user-1:device-1');
    final remaining = await OfflineStore.instance.commands();
    expect(remaining, isEmpty);
  });

  test('sync checkpoints retain revision and selected locations', () async {
    await OfflineStore.instance.saveSyncCheckpoint(
      'user-1:device-1',
      revision: 42,
      locationIds: const ['loc-1', 'loc-2'],
    );

    final checkpoint = await OfflineStore.instance.syncCheckpoint(
      'user-1:device-1',
    );

    expect(checkpoint?['revision'], 42);
    expect(checkpoint?['locationIds'], ['loc-1', 'loc-2']);
  });

  test('cache manifest removes expired snapshots without readAll', () async {
    final uri = Uri.parse('https://example.invalid/api/material');
    await OfflineStore.instance.cacheResponse(
      'user-1:device-1',
      uri,
      200,
      '[]',
    );
    expect(
      await OfflineStore.instance.cachedResponse('user-1:device-1', uri),
      isNotNull,
    );

    await Future<void>.delayed(const Duration(milliseconds: 2));
    await OfflineStore.instance.pruneExpiredData(maximumAge: Duration.zero);

    expect(
      await OfflineStore.instance.cachedResponse('user-1:device-1', uri),
      isNull,
    );
  });
}
