import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SessionValues {
  const SessionValues({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

class SessionValueStore {
  static final SessionValueStore instance = SessionValueStore();
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());
  static const _accessKey = 'materialkompass_access_token_v1';
  static const _refreshKey = 'materialkompass_refresh_token_v1';

  Future<SessionValues?> read() async {
    final values = await Future.wait([
      _storage.read(key: _accessKey),
      _storage.read(key: _refreshKey),
    ]);
    final accessToken = values[0] ?? '';
    final refreshToken = values[1] ?? '';
    if (accessToken.isEmpty && refreshToken.isEmpty) return null;
    return SessionValues(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<void> write(SessionValues values) async {
    await Future.wait([
      _storage.write(key: _accessKey, value: values.accessToken),
      _storage.write(key: _refreshKey, value: values.refreshToken),
    ]);
  }

  Future<T> withRefreshLock<T>(Future<T> Function() action) => action();

  Future<void> clear({bool notifyOtherTabs = true}) => Future.wait([
    _storage.delete(key: _accessKey),
    _storage.delete(key: _refreshKey),
  ]);
}
