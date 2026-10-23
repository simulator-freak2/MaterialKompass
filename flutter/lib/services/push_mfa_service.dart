import 'dart:async';

import 'api_client.dart';

String materialKompassEnrollmentUri(String pairingUri, String provisioningUri) {
  final pairing = Uri.parse(pairingUri);
  if (pairing.scheme != 'materialkompass-auth' || pairing.host != 'pair') {
    throw const FormatException('Ungültiger MaterialKompass-Kopplungscode.');
  }
  return pairing
      .replace(
        queryParameters: {...pairing.queryParameters, 'totp': provisioningUri},
      )
      .toString();
}

class PushPairing {
  const PushPairing({
    required this.id,
    required this.statusToken,
    required this.qrValue,
    required this.expiresAt,
  });

  final String id;
  final String statusToken;
  final String qrValue;
  final DateTime expiresAt;
}

class PushMfaService {
  PushMfaService({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

  Future<List<Map<String, dynamic>>> list({required String token}) async {
    final response = await _api.get(
      '/api/users/me/mfa/push-devices',
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200 || response.data is! List) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Authenticator-Geräte konnten nicht geladen werden.',
        statusCode: response.statusCode,
      );
    }
    return (response.data as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
  }

  Future<PushPairing> createPairing({
    required String token,
    required String currentPassword,
    String code = '',
  }) async {
    final response = await _api.post(
      '/api/users/me/mfa/push-pairings',
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: {
        'currentPassword': currentPassword,
        if (code.trim().isNotEmpty) 'code': code.trim(),
      },
    );
    if (response.statusCode != 201) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Die Geräte-Kopplung konnte nicht vorbereitet werden.',
        statusCode: response.statusCode,
      );
    }
    final expiresAt = DateTime.tryParse(
      response.object['expiresAt']?.toString() ?? '',
    );
    if (expiresAt == null) {
      throw const ApiException(
        'Der Server hat eine ungültige Ablaufzeit geliefert.',
      );
    }
    return PushPairing(
      id: response.object['pairingId'].toString(),
      statusToken: response.object['statusToken'].toString(),
      qrValue: response.object['qrValue'].toString(),
      expiresAt: expiresAt,
    );
  }

  Future<Map<String, dynamic>> waitForPairing(PushPairing pairing) async {
    while (DateTime.now().isBefore(pairing.expiresAt)) {
      final response = await _api.post(
        '/api/auth/mfa/push/pairing-status',
        body: {'pairingId': pairing.id, 'statusToken': pairing.statusToken},
      );
      if (response.statusCode == 200) return response.object;
      if (response.statusCode != 202) {
        throw ApiException(
          response.object['error']?.toString() ??
              'Die Geräte-Kopplung konnte nicht abgeschlossen werden.',
          statusCode: response.statusCode,
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw const ApiException('Der Kopplungscode ist abgelaufen.');
  }

  Future<void> revoke({
    required String token,
    required String deviceId,
    required String currentPassword,
    String code = '',
  }) async {
    final response = await _api.delete(
      '/api/users/me/mfa/push-devices/$deviceId',
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: {
        'currentPassword': currentPassword,
        if (code.trim().isNotEmpty) 'code': code.trim(),
      },
    );
    if (response.statusCode != 204) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Das Authenticator-Gerät konnte nicht entfernt werden.',
        statusCode: response.statusCode,
      );
    }
  }

  void close() => _api.close();
}
