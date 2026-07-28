import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ApiResponse {
  const ApiResponse({required this.statusCode, required this.data});

  final int statusCode;
  final dynamic data;

  Map<String, dynamic> get object =>
      data is Map ? Map<String, dynamic>.from(data as Map) : const {};
}

class ApiClient {
  ApiClient({http.Client? client, this.timeout = const Duration(seconds: 15)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  Future<ApiResponse> get(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) =>
      _request(
        'GET',
        path,
        queryParameters: queryParameters,
        headers: headers,
      );

  Future<ApiResponse> post(
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      _request('POST', path, body: body, headers: headers);

  Future<ApiResponse> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) async {
    final baseUri = Uri.parse(apiBaseUrl);
    final uri = baseUri.resolve(path).replace(queryParameters: queryParameters);
    final requestHeaders = <String, String>{
      if (body != null) 'Content-Type': 'application/json',
      ...?headers,
    };

    try {
      final response = switch (method) {
        'GET' =>
          await _client.get(uri, headers: requestHeaders).timeout(timeout),
        'POST' => await _client
            .post(
              uri,
              headers: requestHeaders,
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(timeout),
        _ => throw ArgumentError.value(method, 'method'),
      };
      dynamic data;
      if (response.body.isNotEmpty) {
        try {
          data = jsonDecode(response.body);
        } on FormatException {
          throw ApiException(
            'Der Server hat eine ungültige Antwort geliefert.',
            statusCode: response.statusCode,
          );
        }
      }
      return ApiResponse(statusCode: response.statusCode, data: data);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException(
        'Der Server antwortet nicht. Bitte später erneut versuchen.',
      );
    } catch (_) {
      throw const ApiException(
        'MaterialKompass ist derzeit nicht erreichbar. Bitte die Verbindung prüfen.',
      );
    }
  }

  void close() => _client.close();
}
