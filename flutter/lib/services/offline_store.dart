import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class OfflineStatus {
  const OfflineStatus({
    this.offline = false,
    this.syncing = false,
    this.pending = 0,
    this.conflicts = 0,
    this.lastSyncAt,
  });

  final bool offline;
  final bool syncing;
  final int pending;
  final int conflicts;
  final DateTime? lastSyncAt;

  OfflineStatus copyWith({
    bool? offline,
    bool? syncing,
    int? pending,
    int? conflicts,
    DateTime? lastSyncAt,
  }) =>
      OfflineStatus(
        offline: offline ?? this.offline,
        syncing: syncing ?? this.syncing,
        pending: pending ?? this.pending,
        conflicts: conflicts ?? this.conflicts,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );
}

class OfflineCommand {
  const OfflineCommand({
    required this.id,
    required this.subject,
    required this.method,
    required this.uri,
    required this.body,
    required this.createdAt,
    this.failure,
  });

  final String id;
  final String subject;
  final String method;
  final String uri;
  final String? body;
  final DateTime createdAt;
  final String? failure;

  Map<String, dynamic> toJson() => {
        'id': id,
        'subject': subject,
        'method': method,
        'uri': uri,
        'body': body,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'failure': failure,
      };

  factory OfflineCommand.fromJson(Map<String, dynamic> json) => OfflineCommand(
        id: json['id'].toString(),
        subject: json['subject'].toString(),
        method: json['method'].toString(),
        uri: json['uri'].toString(),
        body: json['body']?.toString(),
        createdAt: DateTime.parse(json['createdAt'].toString()),
        failure: json['failure']?.toString(),
      );

  OfflineCommand failed(String message) => OfflineCommand(
        id: id,
        subject: subject,
        method: method,
        uri: uri,
        body: body,
        createdAt: createdAt,
        failure: message,
      );
}

class OfflineStore {
  OfflineStore._();

  static final OfflineStore instance = OfflineStore._();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _queueKey = 'materialkompass_offline_queue_v1';
  static const _leaseKey = 'materialkompass_offline_qr_lease_v1';
  static const _settingsKey = 'materialkompass_offline_settings_v1';
  static const _lastSyncKey = 'materialkompass_offline_last_sync_v1';
  static const _clientIdKey = 'materialkompass_offline_client_id_v1';
  static const _cachePrefix = 'materialkompass_cache_';
  static const _checkpointPrefix = 'materialkompass_checkpoint_';
  static const _cacheManifestKey = 'materialkompass_cache_manifest_v1';

  final status = ValueNotifier<OfflineStatus>(const OfflineStatus());
  Future<void> _manifestUpdate = Future.value();

  Future<void> restoreStatus() async {
    await pruneExpiredData();
    final queued = await commands();
    final rawLastSync = await _storage.read(key: _lastSyncKey);
    status.value = status.value.copyWith(
      pending: queued.length,
      conflicts: queued.where((entry) => entry.failure != null).length,
      lastSyncAt: rawLastSync == null
          ? null
          : DateTime.tryParse(rawLastSync)?.toLocal(),
    );
  }

  String subjectFromHeaders(Map<String, String>? headers) {
    final authorization =
        headers?['Authorization'] ?? headers?['authorization'] ?? '';
    final token = authorization.startsWith('Bearer ')
        ? authorization.substring(7)
        : authorization;
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final payload = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
        if (payload is Map) {
          return '${payload['sub'] ?? 'unknown'}:${payload['did'] ?? 'personal'}';
        }
      }
    } catch (_) {
      // A cached/offline session can use an opaque local token.
    }
    return sha256.convert(utf8.encode(token)).toString().substring(0, 24);
  }

  String _cacheKey(String subject, Uri uri) =>
      '$_cachePrefix${sha256.convert(utf8.encode('$subject|$uri'))}';

  String _checkpointKey(String subject) =>
      '$_checkpointPrefix${sha256.convert(utf8.encode(subject))}';

  Future<Map<String, dynamic>?> syncCheckpoint(String subject) async {
    final raw = await _storage.read(key: _checkpointKey(subject));
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSyncCheckpoint(
    String subject, {
    required int revision,
    required List<String> locationIds,
  }) =>
      _storage.write(
        key: _checkpointKey(subject),
        value: jsonEncode({
          'revision': revision,
          'locationIds': locationIds,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );

  Future<void> pruneExpiredData(
      {Duration maximumAge = const Duration(days: 30)}) async {
    final cutoff = DateTime.now().toUtc().subtract(maximumAge);
    await _queueManifestUpdate(() async {
      final entries = await _cacheManifest();
      final retained = <Map<String, dynamic>>[];
      for (final entry in entries) {
        final key = entry['key']?.toString() ?? '';
        final storedAt =
            DateTime.tryParse(entry['storedAt']?.toString() ?? '')?.toUtc();
        if (key.isEmpty || storedAt == null || storedAt.isBefore(cutoff)) {
          if (key.isNotEmpty) await _storage.delete(key: key);
        } else {
          retained.add(entry);
        }
      }
      await _writeCacheManifest(retained);
    });
    final rawLeases = await _storage.read(key: _leaseKey);
    if (rawLeases == null) return;
    try {
      final decoded = jsonDecode(rawLeases);
      final leases = (decoded is List ? decoded : [decoded])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .where((entry) {
        final expiresAt =
            DateTime.tryParse(entry['expiresAt']?.toString() ?? '');
        return expiresAt != null &&
            expiresAt.toUtc().isAfter(DateTime.now().toUtc());
      }).toList();
      await _storage.write(key: _leaseKey, value: jsonEncode(leases));
    } catch (_) {
      await _storage.delete(key: _leaseKey);
    }
  }

  Future<void> cacheResponse(
      String subject, Uri uri, int statusCode, String body) async {
    final key = _cacheKey(subject, uri);
    final storedAt = DateTime.now().toUtc().toIso8601String();
    await _storage.write(
      key: key,
      value: jsonEncode({
        'statusCode': statusCode,
        'body': body,
        'storedAt': storedAt,
      }),
    );
    await _queueManifestUpdate(() async {
      final entries = await _cacheManifest();
      entries.removeWhere((entry) => entry['key'] == key);
      entries.add({'key': key, 'storedAt': storedAt});
      await _writeCacheManifest(entries);
    });
  }

  Future<void> _queueManifestUpdate(Future<void> Function() update) {
    final next = _manifestUpdate.catchError((_) {}).then((_) => update());
    _manifestUpdate = next;
    return next;
  }

  Future<List<Map<String, dynamic>>> _cacheManifest() async {
    final raw = await _storage.read(key: _cacheManifestKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeCacheManifest(List<Map<String, dynamic>> entries) =>
      _storage.write(key: _cacheManifestKey, value: jsonEncode(entries));

  Future<Map<String, dynamic>?> cachedResponse(String subject, Uri uri) async {
    final value = await _storage.read(key: _cacheKey(subject, uri));
    if (value == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } catch (_) {
      return null;
    }
  }

  String newCommandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return 'offline-${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Future<String> clientId() async {
    final stored = await _storage.read(key: _clientIdKey);
    if (stored != null && stored.isNotEmpty) return stored;
    final created = 'client-${newCommandId().substring('offline-'.length)}';
    await _storage.write(key: _clientIdKey, value: created);
    return created;
  }

  Future<List<OfflineCommand>> commands() async {
    final value = await _storage.read(key: _queueKey);
    if (value == null) return [];
    try {
      return (jsonDecode(value) as List)
          .map((entry) =>
              OfflineCommand.fromJson(Map<String, dynamic>.from(entry as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCommands(List<OfflineCommand> commands) async {
    await _storage.write(
      key: _queueKey,
      value: jsonEncode(commands.map((entry) => entry.toJson()).toList()),
    );
    status.value = status.value.copyWith(
      pending: commands.length,
      conflicts: commands.where((entry) => entry.failure != null).length,
    );
  }

  Future<void> discardCommands(String subject) async {
    final queued = await commands();
    await saveCommands(
        queued.where((entry) => entry.subject != subject).toList());
  }

  Future<void> discardCommand(String subject, String commandId) async {
    final queued = await commands();
    await saveCommands(queued
        .where((entry) => entry.subject != subject || entry.id != commandId)
        .toList());
  }

  Future<OfflineCommand> enqueue({
    required String subject,
    required String method,
    required Uri uri,
    required String? body,
  }) async {
    final queued = await commands();
    final command = OfflineCommand(
      id: newCommandId(),
      subject: subject,
      method: method,
      uri: uri.toString(),
      body: body,
      createdAt: DateTime.now().toUtc(),
    );
    queued.add(command);
    await saveCommands(queued);
    await _applyOptimistic(command);
    status.value = status.value.copyWith(offline: true);
    return command;
  }

  Future<List<dynamic>> _cachedList(
      String subject, Uri origin, String path) async {
    final cached = await cachedResponse(subject, origin.resolve(path));
    if (cached == null) return [];
    try {
      return List<dynamic>.from(jsonDecode(cached['body'].toString()) as List);
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveList(
          String subject, Uri origin, String path, List<dynamic> values) =>
      cacheResponse(subject, origin.resolve(path), 200, jsonEncode(values));

  Future<void> _applyOptimistic(OfflineCommand command) async {
    if (command.body == null) return;
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(command.body!) as Map);
    } catch (_) {
      return;
    }
    final uri = Uri.parse(command.uri);
    if (uri.path == '/api/material/transactions/bulk') {
      final materials = await _cachedList(
          command.subject, uri, '/api/material?archived=false');
      final action = body['action'];
      for (final requested in body['items'] as List? ?? const []) {
        final values = requested as Map;
        final item = materials
            .cast<Map>()
            .where((entry) => entry['id'] == values['materialId'])
            .firstOrNull;
        if (item == null) continue;
        final quantity = num.tryParse(values['quantity'].toString()) ?? 0;
        final issued =
            num.tryParse(item['issuedQuantity']?.toString() ?? '0') ?? 0;
        item['issuedQuantity'] =
            issued + (action == 'issue' ? quantity : -quantity);
        item['availableQuantity'] =
            (num.tryParse(item['quantity']?.toString() ?? '0') ?? 0) -
                item['issuedQuantity'];
        item['status'] = item['issuedQuantity'] > 0 ? 'Ausgegeben' : 'Lagernd';
        item['_offlinePending'] = true;
      }
      await _saveList(
          command.subject, uri, '/api/material?archived=false', materials);
    } else if (uri.path == '/api/material/relocate/bulk') {
      final materials = await _cachedList(
          command.subject, uri, '/api/material?archived=false');
      final ids = (body['materialIds'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toSet();
      for (final item in materials.cast<Map>()) {
        if (!ids.contains(item['id'].toString())) continue;
        item['locationId'] = body['locationId'];
        item['storagePositionId'] =
            body['storagePositionId'] ?? body['stockStructureId'];
        item['stockStructureId'] = item['storagePositionId'];
        item['_offlinePending'] = true;
      }
      await _saveList(
          command.subject, uri, '/api/material?archived=false', materials);
    } else if (uri.path == '/api/transactions') {
      final clothing = await _cachedList(command.subject, uri, '/api/clothing');
      final ids = (body['clothingIds'] as List? ?? [body['clothingId']])
          .where((entry) => entry != null)
          .map((entry) => entry.toString())
          .toSet();
      for (final item in clothing.cast<Map>()) {
        if (!ids.contains(item['id'].toString())) continue;
        final issued = body['action'] == 'ausgegeben';
        item['status'] = issued ? 'Ausgegeben' : 'Lagernd';
        item['assignedPerson'] = issued ? body['personName'] : null;
        item['_offlinePending'] = true;
      }
      await _saveList(command.subject, uri, '/api/clothing', clothing);
    } else if (command.method == 'PUT' &&
        RegExp(r'^/api/clothing/[^/]+$').hasMatch(uri.path)) {
      final clothing = await _cachedList(command.subject, uri, '/api/clothing');
      final id = uri.pathSegments.last;
      for (final item in clothing.cast<Map>()) {
        if (item['id'].toString() == id) {
          item.addAll({...body, '_offlinePending': true});
        }
      }
      await _saveList(command.subject, uri, '/api/clothing', clothing);
    } else if (uri.path == '/api/defects' ||
        uri.path == '/api/device/defects') {
      final defects = await _cachedList(
          command.subject, uri, '/api/defects?archived=false');
      defects.insert(0, {
        ...body,
        'id': 'local-${command.id}',
        'defectNumber': 'Ausstehend',
        'status': 'Neu',
        'priority': body['priority'] ?? 'Normal',
        'createdAt': command.createdAt.toIso8601String(),
        '_offlinePending': true,
      });
      await _saveList(
          command.subject, uri, '/api/defects?archived=false', defects);
      await _saveList(
          command.subject, uri, '/api/defects?archived=all', defects);
    }
  }

  Future<void> markOnline() async {
    final now = DateTime.now();
    await _storage.write(
        key: _lastSyncKey, value: now.toUtc().toIso8601String());
    status.value = status.value.copyWith(offline: false, lastSyncAt: now);
  }

  void markOffline() {
    status.value = status.value.copyWith(offline: true, syncing: false);
  }

  Future<void> setSyncing(bool value) async {
    status.value = status.value.copyWith(syncing: value);
  }

  Future<void> saveQrLease(Map<String, dynamic> lease,
      {required String sessionToken}) async {
    // FlutterSecureStorage encrypts this verifier with the platform keystore.
    // The QR credential itself is deliberately never persisted.
    final allowed = <String, dynamic>{
      'verifierHash': lease['verifierHash'],
      'expiresAt': lease['expiresAt'],
      'subjectId': lease['subjectId'],
      'sessionType': lease['sessionType'],
      'deviceId': lease['deviceId'],
      'deviceSecurityVersion': lease['deviceSecurityVersion'],
      'locationIds': lease['locationIds'] ?? const [],
      'user': lease['user'],
      'sessionToken': sessionToken,
    };
    final existingRaw = await _storage.read(key: _leaseKey);
    final leases = <Map<String, dynamic>>[];
    if (existingRaw != null) {
      try {
        final decoded = jsonDecode(existingRaw);
        if (decoded is List) {
          leases.addAll(
              decoded.map((entry) => Map<String, dynamic>.from(entry as Map)));
        } else if (decoded is Map) {
          leases.add(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }
    leases.removeWhere(
        (entry) => entry['verifierHash'] == allowed['verifierHash']);
    leases.add(allowed);
    if (leases.length > 50) leases.removeRange(0, leases.length - 50);
    await _storage.write(key: _leaseKey, value: jsonEncode(leases));
  }

  Future<Map<String, dynamic>?> authenticateQr(String qrCredential) async {
    final raw = await _storage.read(key: _leaseKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      final leases = decoded is List
          ? decoded
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : [Map<String, dynamic>.from(decoded as Map)];
      final supplied = sha256.convert(utf8.encode(qrCredential)).toString();
      for (final lease in leases) {
        final expiresAt = DateTime.parse(lease['expiresAt'].toString());
        if (!expiresAt.isAfter(DateTime.now().toUtc())) continue;
        final expected = lease['verifierHash']?.toString() ?? '';
        if (supplied.length != expected.length) continue;
        var difference = 0;
        for (var index = 0; index < supplied.length; index++) {
          difference |= supplied.codeUnitAt(index) ^ expected.codeUnitAt(index);
        }
        if (difference == 0) return lease;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> settings() async {
    final raw = await _storage.read(key: _settingsKey);
    if (raw == null) {
      return const {
        'mobileData': true,
        'largeFileBytes': 10 * 1024 * 1024,
        'locationIds': <String>[],
      };
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return const {
        'mobileData': true,
        'largeFileBytes': 10 * 1024 * 1024,
        'locationIds': <String>[],
      };
    }
  }

  Future<void> saveSettings(Map<String, dynamic> value) =>
      _storage.write(key: _settingsKey, value: jsonEncode(value));
}
