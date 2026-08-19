import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as base;

import 'offline_store.dart';
import 'network_probe.dart';

typedef Response = base.Response;

const _timeout = Duration(seconds: 12);
const _transientStatusCodes = {502, 503, 504};
final base.Client _client = base.Client();
bool _flushing = false;

bool _cacheableRead(Uri uri) {
  final path = uri.path;
  return path == '/api/dashboard' ||
      path == '/api/auth/me' ||
      path == '/api/material' ||
      path == '/api/categories' ||
      path == '/api/locations' ||
      path == '/api/stock-structures' ||
      path == '/api/clothing' ||
      path == '/api/clothing/history' ||
      path == '/api/transactions' ||
      path == '/api/material/history' ||
      path == '/api/defects' ||
      path == '/api/defect-report-items' ||
      path == '/api/defect-report-template' ||
      path == '/api/device/search' ||
      path == '/api/device/defect-target';
}

bool _queueable(String method, Uri uri, Object? body) {
  final path = uri.path;
  if (method == 'POST' && path == '/api/material/transactions/bulk') {
    return true;
  }
  if (method == 'POST' && path == '/api/material/relocate/bulk') return true;
  if (method == 'POST' && path == '/api/transactions') return true;
  if (method == 'POST' && path == '/api/defects') return true;
  if (method == 'POST' && path == '/api/device/defects') return true;
  if (method == 'PUT' && RegExp(r'^/api/clothing/[^/]+$').hasMatch(path)) {
    final value = body?.toString() ?? '';
    return value.contains('locationId') ||
        value.contains('storagePositionId') ||
        value.contains('stockStructureId');
  }
  return false;
}

String? _bodyString(Object? body, Encoding? encoding) {
  if (body == null) return null;
  if (body is String) return body;
  if (body is List<int>) return (encoding ?? utf8).decode(body);
  if (body is Map) return jsonEncode(body);
  return body.toString();
}

Future<Response> get(Uri url, {Map<String, String>? headers}) async {
  if (kIsWeb || !_cacheableRead(url)) {
    return _client.get(url, headers: headers).timeout(_timeout);
  }
  final store = OfflineStore.instance;
  final subject = store.subjectFromHeaders(headers);
  try {
    final response = await _client.get(url, headers: headers).timeout(_timeout);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      await store.cacheResponse(
          subject, url, response.statusCode, response.body);
      await store.markOnline();
      unawaited(flush(headers: headers));
    } else if (_transientStatusCodes.contains(response.statusCode)) {
      throw base.ClientException(
        'Temporärer Serverfehler (${response.statusCode})',
        url,
      );
    }
    return response;
  } catch (_) {
    store.markOffline();
    var cached = await store.cachedResponse(subject, url);
    if (cached == null && url.path == '/api/defect-report-template') {
      cached = await store.cachedResponse(subject, url.replace(query: null));
    }
    cached ??= await _syntheticDeviceResponse(store, subject, url);
    if (cached == null) rethrow;
    return base.Response(
      cached['body']?.toString() ?? '',
      cached['statusCode'] as int? ?? 200,
      headers: const {'x-materialkompass-offline': 'true'},
      request: base.Request('GET', url),
    );
  }
}

Future<Map<String, dynamic>?> _syntheticDeviceResponse(
    OfflineStore store, String subject, Uri url) async {
  if (url.path != '/api/device/search' &&
      url.path != '/api/device/defect-target') {
    return null;
  }
  Future<List<dynamic>> values(String path) async {
    final cached = await store.cachedResponse(subject, url.resolve(path));
    if (cached == null) return [];
    try {
      return List<dynamic>.from(jsonDecode(cached['body'].toString()) as List);
    } catch (_) {
      return [];
    }
  }

  final material = await values('/api/material?archived=false');
  final clothing = await values('/api/clothing');
  final combined = [
    ...material.map((entry) => {
          ...Map<String, dynamic>.from(entry as Map),
          'entityType': 'MaterialItem'
        }),
    ...clothing.map((entry) => {
          ...Map<String, dynamic>.from(entry as Map),
          'entityType': 'ClothingItem'
        }),
  ];
  if (url.path == '/api/device/defect-target') {
    final number = url.queryParameters['inventoryNumber']?.toLowerCase() ?? '';
    final match = combined
        .where((entry) =>
            entry['inventoryNumber']?.toString().toLowerCase() == number)
        .firstOrNull;
    if (match == null) return null;
    return {'statusCode': 200, 'body': jsonEncode(match)};
  }
  final query = url.queryParameters['q']?.trim().toLowerCase() ?? '';
  final matches = combined
      .where((entry) => [
            entry['inventoryNumber'],
            entry['name'],
            entry['serialNumber'],
            entry['manufacturer']
          ].any((value) =>
              value?.toString().toLowerCase().contains(query) == true))
      .take(100)
      .toList();
  return {'statusCode': 200, 'body': jsonEncode(matches)};
}

Future<Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _write('POST', url, headers: headers, body: body, encoding: encoding);

Future<Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _write('PUT', url, headers: headers, body: body, encoding: encoding);

Future<Response> patch(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _write('PATCH', url, headers: headers, body: body, encoding: encoding);

Future<Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) =>
    _write('DELETE', url, headers: headers, body: body, encoding: encoding);

Future<Response> _write(
  String method,
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
}) async {
  final encoded = _bodyString(body, encoding);
  if (kIsWeb) {
    final request = base.Request(method, url)
      ..headers.addAll(headers ?? const {});
    if (encoded != null) request.body = encoded;
    final streamed = await _client.send(request).timeout(_timeout);
    return base.Response.fromStream(streamed);
  }
  try {
    final request = base.Request(method, url)
      ..headers.addAll(headers ?? const {});
    if (encoded != null) request.body = encoded;
    final streamed = await _client.send(request).timeout(_timeout);
    final response = await base.Response.fromStream(streamed);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      await OfflineStore.instance.markOnline();
      unawaited(flush(headers: headers));
    }
    if (_transientStatusCodes.contains(response.statusCode) &&
        _queueable(method, url, body)) {
      OfflineStore.instance.markOffline();
      return await _enqueueWrite(method, url, headers, encoded);
    }
    return response;
  } catch (_) {
    OfflineStore.instance.markOffline();
    if (!_queueable(method, url, body)) rethrow;
    return _enqueueWrite(method, url, headers, encoded);
  }
}

Future<Response> _enqueueWrite(
  String method,
  Uri url,
  Map<String, String>? headers,
  String? body,
) async {
  final subject = OfflineStore.instance.subjectFromHeaders(headers);
  final command = await OfflineStore.instance.enqueue(
    subject: subject,
    method: method,
    uri: url,
    body: body,
  );
  return base.Response(
    jsonEncode({'offlineQueued': true, 'commandId': command.id}),
    method == 'POST' ? 201 : 200,
    headers: const {
      'content-type': 'application/json',
      'x-materialkompass-offline-queued': 'true'
    },
    request: base.Request(method, url),
  );
}

Future<void> flush({required Map<String, String>? headers}) async {
  if (kIsWeb || _flushing) return;
  _flushing = true;
  final store = OfflineStore.instance;
  await store.setSyncing(true);
  try {
    final settings = await store.settings();
    final network = await offlineNetworkKind();
    if (network == OfflineNetworkKind.mobile &&
        settings['mobileData'] == false) {
      return;
    }
    final largeFileBytes =
        (settings['largeFileBytes'] as num? ?? 10 * 1024 * 1024).toInt();
    final subject = store.subjectFromHeaders(headers);
    final queued = await store.commands();
    final remaining = <OfflineCommand>[];
    var connectionFailed = false;
    for (final command in queued) {
      if (command.subject != subject || connectionFailed) {
        remaining.add(command);
        continue;
      }
      if (network == OfflineNetworkKind.mobile &&
          utf8.encode(command.body ?? '').length > largeFileBytes) {
        remaining.add(command);
        continue;
      }
      try {
        final request = base.Request(command.method, Uri.parse(command.uri))
          ..headers.addAll(headers ?? const {})
          ..headers['X-Offline-Command-Id'] = command.id;
        if (command.body != null) request.body = command.body!;
        final streamed = await _client.send(request).timeout(_timeout);
        final response = await base.Response.fromStream(streamed);
        if (response.statusCode >= 200 && response.statusCode < 300) continue;
        if (response.statusCode == 409 || response.statusCode == 403) {
          String message = 'Der Server hat die Offline-Änderung abgelehnt.';
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded['error'] != null) {
              message = decoded['error'].toString();
            }
          } catch (_) {}
          remaining.add(command.failed(message));
          continue;
        }
        remaining.add(command.failed(
            'Synchronisation fehlgeschlagen (${response.statusCode}).'));
      } catch (_) {
        connectionFailed = true;
        remaining.add(command);
        store.markOffline();
      }
    }
    await store.saveCommands(remaining);
    if (!connectionFailed) await store.markOnline();
  } finally {
    await store.setSyncing(false);
    _flushing = false;
  }
}
