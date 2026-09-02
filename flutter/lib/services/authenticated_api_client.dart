import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';
import 'app_http_client.dart';

/// Error returned by an authenticated backend request.
class AuthenticatedApiException implements Exception {
  const AuthenticatedApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Adds authentication, JSON conversion and uniform error handling to the
/// shared HTTP transport used by feature pages.
class AuthenticatedApiClient {
  const AuthenticatedApiClient(this.token);

  final String token;

  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    const supportedMethods = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'};
    if (!supportedMethods.contains(method)) {
      throw ArgumentError.value(method, 'method', 'Nicht unterstützte Methode');
    }

    final uri = Uri.parse('$apiBaseUrl$path');
    late final http.Response response;

    try {
      response = switch (method) {
        'GET' => await AppHttpClient.get(uri, headers: headers),
        'POST' => await AppHttpClient.post(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'PUT' => await AppHttpClient.put(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'PATCH' => await AppHttpClient.patch(
          uri,
          headers: headers,
          body: body == null ? null : jsonEncode(body),
        ),
        'DELETE' => await AppHttpClient.delete(uri, headers: headers),
        _ => throw StateError('Die HTTP-Methode wurde bereits geprüft.'),
      };
    } catch (_) {
      throw const AuthenticatedApiException(
        'Verbindung fehlgeschlagen. Bitte Netzwerk und Server prüfen.',
      );
    }

    final data = _decodeJson(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthenticatedApiException(
        data is Map
            ? data['error']?.toString() ?? 'Aktion fehlgeschlagen.'
            : 'Aktion fehlgeschlagen.',
        statusCode: response.statusCode,
      );
    }
    return data;
  }

  static dynamic _decodeJson(http.Response response) {
    if (response.body.isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw AuthenticatedApiException(
        'Der Server hat eine ungültige Antwort geliefert.',
        statusCode: response.statusCode,
      );
    }
  }
}
