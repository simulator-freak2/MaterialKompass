import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'api_client.dart';

class PasskeyService {
  PasskeyService({PasskeyAuthenticator? authenticator, ApiClient? api})
    : _authenticator = authenticator ?? PasskeyAuthenticator(),
      _api = api ?? ApiClient();

  final PasskeyAuthenticator _authenticator;
  final ApiClient _api;

  static bool get platformSupported {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };
  }

  Future<Map<String, dynamic>> login() async {
    if (!platformSupported) {
      throw const ApiException(
        'Passkeys werden auf dieser Plattform derzeit nicht unterstützt.',
      );
    }
    try {
      final started = await _api.post(
        '/api/auth/passkey/options',
        body: const {},
      );
      if (started.statusCode != 200) {
        throw ApiException(
          _error(started, 'Passkey-Anmeldung konnte nicht gestartet werden.'),
          statusCode: started.statusCode,
        );
      }
      final data = started.object;
      final options = Map<String, dynamic>.from(data['options'] as Map);
      final request = AuthenticateRequestType.fromJson(
        options,
        mediation: MediationType.Optional,
        preferImmediatelyAvailableCredentials: false,
      );
      final credential = await _authenticator.authenticate(request);
      final completed = await _api.post(
        '/api/auth/passkey/verify',
        body: {
          'challengeId': data['challengeId'],
          'credential': credential.toJson(),
        },
      );
      if (completed.statusCode != 200 || completed.object['token'] == null) {
        throw ApiException(
          _error(completed, 'Passkey-Anmeldung fehlgeschlagen.'),
          statusCode: completed.statusCode,
        );
      }
      return completed.object;
    } on ApiException {
      rethrow;
    } on PasskeyAuthCancelledException {
      throw const ApiException('Passkey-Anmeldung abgebrochen.');
    } on NoCredentialsAvailableException {
      throw const ApiException(
        'Für MaterialKompass ist auf diesem Gerät kein Passkey verfügbar.',
      );
    } on DomainNotAssociatedException {
      throw const ApiException(
        'Die App ist noch nicht sicher mit der MaterialKompass-Domain verknüpft.',
      );
    } on AuthenticatorException catch (error) {
      throw ApiException('Passkey konnte nicht verwendet werden: $error');
    } on FormatException {
      throw const ApiException(
        'Der Server hat ungültige Passkey-Optionen geliefert.',
      );
    } on TypeError {
      throw const ApiException(
        'Der Server hat ungültige Passkey-Optionen geliefert.',
      );
    }
  }

  Future<Map<String, dynamic>> register({
    required String token,
    required String name,
    required String currentPassword,
    String code = '',
  }) async {
    if (!platformSupported) {
      throw const ApiException(
        'Passkeys werden auf dieser Plattform derzeit nicht unterstützt.',
      );
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    try {
      final started = await _api.post(
        '/api/users/me/passkeys/options',
        headers: headers,
        body: {
          'name': name,
          'currentPassword': currentPassword,
          if (code.trim().isNotEmpty) 'code': code.trim(),
        },
      );
      if (started.statusCode != 200) {
        throw ApiException(
          _error(started, 'Passkey-Einrichtung konnte nicht gestartet werden.'),
          statusCode: started.statusCode,
        );
      }
      final data = started.object;
      final options = Map<String, dynamic>.from(data['options'] as Map);
      final credential = await _authenticator.register(
        RegisterRequestType.fromJson(options),
      );
      final completed = await _api.post(
        '/api/users/me/passkeys/verify',
        headers: headers,
        body: {
          'challengeId': data['challengeId'],
          'credential': credential.toJson(),
        },
      );
      if (completed.statusCode != 201) {
        throw ApiException(
          _error(completed, 'Passkey-Einrichtung fehlgeschlagen.'),
          statusCode: completed.statusCode,
        );
      }
      return completed.object;
    } on ApiException {
      rethrow;
    } on PasskeyAuthCancelledException {
      throw const ApiException('Passkey-Einrichtung abgebrochen.');
    } on ExcludeCredentialsCanNotBeRegisteredException {
      throw const ApiException(
        'Dieser Passkey ist bereits mit dem Konto verknüpft.',
      );
    } on DomainNotAssociatedException {
      throw const ApiException(
        'Die App ist noch nicht sicher mit der MaterialKompass-Domain verknüpft.',
      );
    } on AuthenticatorException catch (error) {
      throw ApiException('Passkey konnte nicht eingerichtet werden: $error');
    } on FormatException {
      throw const ApiException(
        'Der Server hat ungültige Passkey-Optionen geliefert.',
      );
    } on TypeError {
      throw const ApiException(
        'Der Server hat ungültige Passkey-Optionen geliefert.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> list({required String token}) async {
    final response = await _api.get(
      '/api/users/me/passkeys',
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200 || response.data is! List) {
      throw ApiException(
        _error(response, 'Passkeys konnten nicht geladen werden.'),
        statusCode: response.statusCode,
      );
    }
    return (response.data as List)
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  Future<void> rename({
    required String token,
    required String id,
    required String name,
  }) async {
    final response = await _api.patch(
      '/api/users/me/passkeys/$id',
      headers: {'Authorization': 'Bearer $token'},
      body: {'name': name},
    );
    if (response.statusCode != 200) {
      throw ApiException(
        _error(response, 'Passkey konnte nicht umbenannt werden.'),
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> revoke({
    required String token,
    required String id,
    required String currentPassword,
    String code = '',
  }) async {
    final response = await _api.delete(
      '/api/users/me/passkeys/$id',
      headers: {'Authorization': 'Bearer $token'},
      body: {
        'currentPassword': currentPassword,
        if (code.trim().isNotEmpty) 'code': code.trim(),
      },
    );
    if (response.statusCode != 204) {
      throw ApiException(
        _error(response, 'Passkey konnte nicht widerrufen werden.'),
        statusCode: response.statusCode,
      );
    }
  }

  static String _error(ApiResponse response, String fallback) =>
      response.object['error']?.toString() ?? fallback;

  void close() => _api.close();
}
