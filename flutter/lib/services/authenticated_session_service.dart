import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';

import '../constants.dart';
import 'session_value_store.dart';

class AuthenticatedSessionService {
  AuthenticatedSessionService._();

  static final _store = SessionValueStore.instance;
  static final _localAuthentication = LocalAuthentication();

  static Future<bool> get deviceUnlockAvailable async {
    if (kIsWeb) return false;
    try {
      return await _localAuthentication.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveLoginResponse(
    Map<String, dynamic> response, {
    bool allowNativeUnlock = true,
  }) async {
    final accessToken = response['token']?.toString() ?? '';
    if (accessToken.isEmpty) return;
    if (!kIsWeb && (!allowNativeUnlock || !await deviceUnlockAvailable)) {
      await _store.clear();
      return;
    }
    await _store.write(
      SessionValues(
        accessToken: accessToken,
        refreshToken: response['refreshToken']?.toString() ?? '',
      ),
    );
  }

  static Future<String?> restore({Duration? requestTimeout}) async {
    final stored = await _store.read();
    if (stored == null) return null;
    if (!kIsWeb && !await unlockDevice()) return null;
    final valid = await _accessTokenIsValid(
      stored.accessToken,
      requestTimeout: requestTimeout,
    );
    // Ein Verbindungsfehler ist kein abgelaufener Token. Kein zweiter
    // Netzwerkversuch und keine Rotation, deren Antwort verloren gehen kann.
    if (valid == null) return null;
    if (valid) {
      return stored.accessToken;
    }
    return refresh();
  }

  static Future<String?> refresh() async {
    try {
      return await _store.withRefreshLock(() async {
        // Nach Erwerb der Web-Sperre erneut lesen: Ein anderer Tab kann den
        // rotierenden Token unmittelbar vorher aktualisiert haben.
        final stored = await _store.read();
        if (stored == null || stored.refreshToken.isEmpty) return null;
        final response = await http
            .post(
              Uri.parse('$apiBaseUrl/api/auth/refresh'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'refreshToken': stored.refreshToken}),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200 || response.body.isEmpty) {
          await _store.clear();
          return null;
        }
        final data = Map<String, dynamic>.from(
          jsonDecode(response.body) as Map,
        );
        await saveLoginResponse(data);
        return data['token']?.toString();
      });
    } catch (_) {
      // Ohne Netz bleibt die verschlüsselt gespeicherte Sitzung erhalten. Sie
      // kann beim nächsten Start oder beim Wiederherstellen der Verbindung
      // erneut geprüft werden.
      return null;
    }
  }

  static Future<void> updateAccessToken(String accessToken) async {
    if (accessToken.isEmpty) return;
    final existing = await _store.read();
    if (existing == null) return;
    await _store.write(
      SessionValues(
        accessToken: accessToken,
        refreshToken: existing.refreshToken,
      ),
    );
  }

  static Future<void> logout(String accessToken) async {
    final stored = await _store.read();
    try {
      var response = await http
          .post(
            Uri.parse('$apiBaseUrl/api/auth/logout'),
            headers: {
              'Content-Type': 'application/json',
              if (accessToken.isNotEmpty)
                'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({'refreshToken': stored?.refreshToken ?? ''}),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 401 &&
          (stored?.refreshToken.isNotEmpty ?? false)) {
        final refreshed = await refresh();
        if (refreshed != null) {
          await http
              .post(
                Uri.parse('$apiBaseUrl/api/auth/logout'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $refreshed',
                },
                body: jsonEncode({'refreshToken': stored!.refreshToken}),
              )
              .timeout(const Duration(seconds: 10));
        }
      }
    } catch (_) {
      // Lokales Abmelden darf nicht durch einen Netzausfall verhindert werden.
    } finally {
      await _store.clear();
    }
  }

  static Future<bool> unlockDevice() async {
    try {
      if (!await _localAuthentication.isDeviceSupported()) return false;
      return await _localAuthentication.authenticate(
        localizedReason:
            'MaterialKompass mit der Geräte-PIN oder Biometrie entsperren',
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool?> _accessTokenIsValid(
    String token, {
    Duration? requestTimeout,
  }) async {
    if (token.isEmpty) return false;
    try {
      final response = await http
          .get(
            Uri.parse('$apiBaseUrl/api/auth/me'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(requestTimeout ?? const Duration(seconds: 10));
      if (response.statusCode == 200) return true;
      if (response.statusCode == 401) return false;
      return null;
    } catch (_) {
      return null;
    }
  }
}
