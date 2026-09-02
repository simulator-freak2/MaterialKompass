import 'dart:async';

import 'package:http/http.dart' as base;

import 'offline_http.dart' as offline;

/// Shared transport for authenticated application pages.
///
/// Reusing one client preserves native keep-alive connections. Safe reads get
/// one short retry for transient failures; mutations only receive a timeout so
/// an uncertain write can never be submitted twice automatically.
class AppHttpClient {
  AppHttpClient._();

  static const requestTimeout = Duration(seconds: 30);
  static const retryDelay = Duration(milliseconds: 300);
  static const transientStatusCodes = {502, 503, 504};

  static Future<base.Response> get(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final response = await offline
            .get(uri, headers: headers)
            .timeout(requestTimeout);
        if (attempt == 0 &&
            transientStatusCodes.contains(response.statusCode)) {
          await Future<void>.delayed(retryDelay);
          continue;
        }
        return response;
      } on TimeoutException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(retryDelay);
      } on base.ClientException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(retryDelay);
      }
    }
    throw StateError('HTTP retry loop ended unexpectedly.');
  }

  static Future<base.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) => offline.post(uri, headers: headers, body: body).timeout(requestTimeout);

  static Future<base.Response> put(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) => offline.put(uri, headers: headers, body: body).timeout(requestTimeout);

  static Future<base.Response> patch(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) =>
      offline.patch(uri, headers: headers, body: body).timeout(requestTimeout);

  static Future<base.Response> delete(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) =>
      offline.delete(uri, headers: headers, body: body).timeout(requestTimeout);
}
