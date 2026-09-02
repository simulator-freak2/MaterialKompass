import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'offline_store.dart';

class OfflineSessionService {
  const OfflineSessionService._();

  static final Map<String, Future<void>> _inFlight = {};

  static Future<void> prepare(String token, {List<String>? locationIds}) {
    if (kIsWeb || token.isEmpty) return Future.value();
    final subject = OfflineStore.instance.subjectFromHeaders({
      'Authorization': 'Bearer $token',
    });
    final running = _inFlight[subject];
    if (running != null) return running;
    final operation = _prepare(token, subject, locationIds: locationIds);
    _inFlight[subject] = operation;
    return operation.whenComplete(() {
      if (identical(_inFlight[subject], operation)) _inFlight.remove(subject);
    });
  }

  static Future<void> _prepare(
    String token,
    String subject, {
    List<String>? locationIds,
  }) async {
    final store = OfflineStore.instance;
    await store.pruneExpiredData();
    final configuredLocations =
        locationIds ??
        ((await store.settings())['locationIds'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toList();
    final clientId = await store.clientId();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    try {
      final enrollment = await http
          .post(
            Uri.parse('$apiBaseUrl/api/offline/enroll'),
            headers: headers,
            body: jsonEncode({
              'clientId': clientId,
              'name': 'MaterialKompass ${defaultTargetPlatform.name}',
              'platform': defaultTargetPlatform.name,
              'locationIds': configuredLocations,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (enrollment.statusCode != 200) return;
      final enrollmentData = Map<String, dynamic>.from(
        jsonDecode(enrollment.body) as Map,
      );
      final checkpoint = await store.syncCheckpoint(subject);
      final checkpointLocations =
          (checkpoint?['locationIds'] as List? ?? const [])
              .map((entry) => entry.toString())
              .toSet();
      final requestedLocations = configuredLocations.toSet();
      final sameLocations =
          checkpointLocations.length == requestedLocations.length &&
          checkpointLocations.containsAll(requestedLocations);
      final cursor = checkpoint?['revision'] as num?;
      final useChanges = cursor != null && sameLocations;
      final syncUri = useChanges
          ? Uri.parse(
              '$apiBaseUrl/api/offline/changes',
            ).replace(queryParameters: {'cursor': cursor.toInt().toString()})
          : Uri.parse('$apiBaseUrl/api/offline/bootstrap');
      final snapshot = await http
          .get(syncUri, headers: {...headers, 'X-Offline-Client-Id': clientId})
          .timeout(const Duration(seconds: 30));
      if (snapshot.statusCode != 200) return;
      final decoded = jsonDecode(snapshot.body);
      if (decoded is! Map) return;
      final revision =
          (decoded['revision'] as num?)?.toInt() ??
          (enrollmentData['revision'] as num?)?.toInt() ??
          0;
      if (decoded['changed'] == false) {
        await store.saveSyncCheckpoint(
          subject,
          revision: revision,
          locationIds: configuredLocations,
        );
        await store.markOnline();
        return;
      }
      if (decoded['data'] is! Map) return;
      final data = Map<String, dynamic>.from(decoded['data'] as Map);
      Future<void> cache(String path, Object? value) => store.cacheResponse(
        subject,
        Uri.parse('$apiBaseUrl$path'),
        200,
        jsonEncode(value ?? const []),
      );
      await Future.wait([
        cache('/api/material?archived=false', data['materials']),
        cache('/api/categories', data['categories']),
        cache('/api/locations', data['locations']),
        cache('/api/stock-structures', data['stockStructures']),
        cache('/api/storage-hierarchy', {
          'locations': data['locations'] ?? const [],
          'shelves': data['shelves'] ?? const [],
          'storageLevels': data['storageLevels'] ?? const [],
          'stockStructures': data['stockStructures'] ?? const [],
        }),
        cache('/api/clothing', data['clothingItems']),
        cache('/api/clothing/history', const []),
        cache('/api/transactions', data['issueTransactions']),
        cache('/api/material/history', data['materialMovements']),
        cache('/api/defects?archived=false', data['defectReports']),
        cache('/api/defects?archived=all', data['defectReports']),
        cache('/api/notifications', const []),
        cache('/api/defect-email-imports', const []),
        cache('/api/auth/me', {'user': enrollmentData['user']}),
        cache('/api/defect-report-items', [
          ...(data['materials'] as List? ?? const []).map(
            (item) => {
              'id': (item as Map)['id'],
              'entityType': 'MaterialItem',
              'inventoryNumber': item['inventoryNumber'],
              'name': item['name'],
              'quantity': item['quantity'] ?? 1,
              'status': item['status'],
            },
          ),
          ...(data['clothingItems'] as List? ?? const []).map(
            (item) => {
              'id': (item as Map)['id'],
              'entityType': 'ClothingItem',
              'inventoryNumber': item['inventoryNumber'],
              'name': item['name'],
              'quantity': 1,
              'status': item['status'],
            },
          ),
        ]),
      ]);
      final dashboardUri = Uri.parse('$apiBaseUrl/api/dashboard');
      final dashboard = await http
          .get(dashboardUri, headers: headers)
          .timeout(const Duration(seconds: 15));
      if (dashboard.statusCode == 200) {
        await store.cacheResponse(subject, dashboardUri, 200, dashboard.body);
      }
      final templateUri = Uri.parse('$apiBaseUrl/api/defect-report-template');
      final template = await http
          .get(templateUri, headers: headers)
          .timeout(const Duration(seconds: 30));
      if (template.statusCode == 200) {
        await store.cacheResponse(subject, templateUri, 200, template.body);
      }
      await store.saveSyncCheckpoint(
        subject,
        revision: revision,
        locationIds: configuredLocations,
      );
      await store.markOnline();
    } catch (_) {
      // Existing encrypted data remains usable; enrollment is retried later.
    }
  }
}
