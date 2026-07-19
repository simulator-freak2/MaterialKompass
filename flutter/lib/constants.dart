import 'package:flutter/foundation.dart';

final String apiBaseUrl = _validatedApiBaseUrl();

String _validatedApiBaseUrl() {
  const configured = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:3001',
  );
  final uri = Uri.tryParse(configured);
  if (uri == null || !uri.hasAuthority ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery || uri.hasFragment ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw StateError('API_BASE_URL muss ein gültiger Origin ohne Pfad sein.');
  }
  if (kReleaseMode && uri.scheme != 'https') {
    throw StateError('API_BASE_URL muss in Release-Builds HTTPS verwenden.');
  }
  return configured.replaceFirst(RegExp(r'/$'), '');
}
