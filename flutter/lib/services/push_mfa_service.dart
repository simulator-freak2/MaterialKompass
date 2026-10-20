import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

typedef PushApprovalHandler =
    Future<void> Function(String approvalId, String deviceId);

class PushMfaService {
  PushMfaService._();

  static final PushMfaService instance = PushMfaService._();
  static const _credentialsKey = 'mfa_push_device_credentials';
  static const _storage = FlutterSecureStorage();

  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  final ApiClient _api = ApiClient();
  StreamSubscription<String>? _registrationSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  Completer<String>? _registrationCompleter;
  String? _registrationId;
  PushApprovalHandler? _approvalHandler;
  bool _initialized = false;

  static bool get platformSupported {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  static bool get configured =>
      platformSupported &&
      _apiKey.isNotEmpty &&
      _appId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _projectId.isNotEmpty;

  static String get platformName => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    _ => 'unsupported',
  };

  static String get defaultDeviceName => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android-Telefon',
    TargetPlatform.iOS => 'iPhone oder iPad',
    TargetPlatform.macOS => 'Mac',
    _ => 'MaterialKompass-App',
  };

  Future<void> initialize({required PushApprovalHandler onApproval}) async {
    _approvalHandler = onApproval;
    if (!configured || _initialized) return;
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: _apiKey,
        appId: _appId,
        messagingSenderId: _senderId,
        projectId: _projectId,
      ),
    );
    _initialized = true;
    _messageSubscription = FirebaseMessaging.onMessage.listen(_handleMessage);
    _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      _handleMessage,
    );
    final messaging = FirebaseMessaging.instance;
    _registrationCompleter = Completer<String>();
    _registrationSubscription = messaging.onRegistered.listen(
      _handleRegistration,
    );
    await messaging.register();
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) await _handleMessage(initial);
  }

  Future<void> _handleRegistration(String registrationId) async {
    if (registrationId.isEmpty) return;
    _registrationId = registrationId;
    final completer = _registrationCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(registrationId);
    }
    await _refreshToken(registrationId);
  }

  Future<String> _registeredPushTarget() async {
    final registrationId = _registrationId;
    if (registrationId != null && registrationId.isNotEmpty) {
      return registrationId;
    }
    final completer = _registrationCompleter;
    if (completer == null) {
      throw const ApiException(
        'Der Push-Dienst konnte nicht initialisiert werden. Bitte starte die App neu.',
      );
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const ApiException(
        'Die Push-Registrierung hat zu lange gedauert. Bitte versuche es erneut.',
      );
    }
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    if (message.data['type'] != 'mfa_approval') return;
    final approvalId = message.data['approvalId'];
    final deviceId = message.data['deviceId'];
    if (approvalId == null ||
        approvalId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty) {
      return;
    }
    await _approvalHandler?.call(approvalId, deviceId);
  }

  Future<Map<String, String>> _credentials() async {
    final encoded = await _storage.read(key: _credentialsKey);
    if (encoded == null || encoded.isEmpty) return {};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } on FormatException {
      return {};
    }
  }

  Future<void> _saveCredentials(Map<String, String> credentials) =>
      _storage.write(key: _credentialsKey, value: jsonEncode(credentials));

  Future<Map<String, dynamic>> enroll({
    required String token,
    required String name,
    required String currentPassword,
    String code = '',
  }) async {
    if (!configured) {
      throw const ApiException(
        'Push-2-FA ist für diesen App-Build noch nicht konfiguriert.',
      );
    }
    if (!_initialized) {
      throw const ApiException(
        'Der Push-Dienst konnte nicht initialisiert werden. Bitte prüfe die Firebase-Konfiguration und starte die App neu.',
      );
    }
    final permission = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (permission.authorizationStatus == AuthorizationStatus.denied) {
      throw const ApiException(
        'Benachrichtigungen wurden abgelehnt. Bitte erlaube sie in den Systemeinstellungen.',
      );
    }
    final pushToken = await _registeredPushTarget();
    final response = await _api.post(
      '/api/users/me/mfa/push-devices',
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: {
        'name': name,
        'platform': platformName,
        'pushToken': pushToken,
        'currentPassword': currentPassword,
        if (code.trim().isNotEmpty) 'code': code.trim(),
      },
    );
    if (response.statusCode != 201) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Das Push-Gerät konnte nicht registriert werden.',
        statusCode: response.statusCode,
      );
    }
    final device = Map<String, dynamic>.from(response.object['device'] as Map);
    final credentials = await _credentials();
    credentials[device['id'].toString()] = response.object['deviceSecret']
        .toString();
    await _saveCredentials(credentials);
    return response.object;
  }

  Future<List<Map<String, dynamic>>> list({required String token}) async {
    final response = await _api.get(
      '/api/users/me/mfa/push-devices',
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200 || response.data is! List) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Push-Geräte konnten nicht geladen werden.',
        statusCode: response.statusCode,
      );
    }
    return (response.data as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
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
            'Das Push-Gerät konnte nicht entfernt werden.',
        statusCode: response.statusCode,
      );
    }
    final credentials = await _credentials();
    if (credentials.remove(deviceId) != null) {
      await _saveCredentials(credentials);
    }
  }

  Future<void> respond(
    String approvalId, {
    required String deviceId,
    required bool approve,
  }) async {
    final credentials = await _credentials();
    final deviceSecret = credentials[deviceId];
    if (deviceSecret == null) {
      throw const ApiException(
        'Dieses Gerät ist nicht mehr für Push-2-FA registriert.',
      );
    }
    final response = await _api.post(
      '/api/auth/mfa/push/respond',
      body: {
        'approvalId': approvalId,
        'deviceId': deviceId,
        'deviceSecret': deviceSecret,
        'decision': approve ? 'approve' : 'deny',
      },
    );
    if (response.statusCode != 204) {
      throw ApiException(
        response.object['error']?.toString() ??
            'Die Push-Anfrage konnte nicht beantwortet werden.',
        statusCode: response.statusCode,
      );
    }
  }

  Future<void> _refreshToken(String pushToken) async {
    final credentials = await _credentials();
    var changed = false;
    for (final entry in credentials.entries.toList()) {
      try {
        final response = await _api.put(
          '/api/auth/mfa/push-device-token',
          body: {
            'deviceId': entry.key,
            'deviceSecret': entry.value,
            'pushToken': pushToken,
          },
        );
        if (response.statusCode == 401) {
          credentials.remove(entry.key);
          changed = true;
        }
      } catch (_) {
        // Beim nächsten App-Start oder Tokenwechsel wird erneut aktualisiert.
      }
    }
    if (changed) await _saveCredentials(credentials);
  }

  void dispose() {
    _registrationSubscription?.cancel();
    _messageSubscription?.cancel();
    _openedSubscription?.cancel();
    _api.close();
  }
}
