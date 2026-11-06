// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

class SessionValues {
  const SessionValues({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}

class SessionValueStore {
  SessionValueStore() {
    _channel.onMessage.listen(_onMessage);
  }

  static const _accessKey = 'materialkompass_access_token_v1';
  static const _refreshKey = 'materialkompass_refresh_token_v1';
  static const _refreshLockKey = 'materialkompass_refresh_lock_v1';
  static final SessionValueStore instance = SessionValueStore();
  final html.BroadcastChannel _channel = html.BroadcastChannel(
    'materialkompass_auth_v1',
  );
  final Map<String, Completer<SessionValues?>> _requests = {};

  SessionValues? _localValues() {
    final accessToken = html.window.sessionStorage[_accessKey] ?? '';
    final refreshToken = html.window.sessionStorage[_refreshKey] ?? '';
    if (accessToken.isEmpty && refreshToken.isEmpty) return null;
    return SessionValues(accessToken: accessToken, refreshToken: refreshToken);
  }

  Future<SessionValues?> read() async {
    final local = _localValues();
    if (local != null) return local;

    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${html.window.hashCode}';
    final completer = Completer<SessionValues?>();
    _requests[requestId] = completer;
    _channel.postMessage(jsonEncode({'type': 'request', 'id': requestId}));
    return completer.future.timeout(
      const Duration(milliseconds: 400),
      onTimeout: () {
        _requests.remove(requestId);
        return null;
      },
    );
  }

  Future<void> _writeLocal(SessionValues values) async {
    html.window.sessionStorage[_accessKey] = values.accessToken;
    html.window.sessionStorage[_refreshKey] = values.refreshToken;
  }

  Future<void> write(SessionValues values) async {
    await _writeLocal(values);
    _channel.postMessage(
      jsonEncode({
        'type': 'session-update',
        'accessToken': values.accessToken,
        'refreshToken': values.refreshToken,
      }),
    );
  }

  Future<T> withRefreshLock<T>(Future<T> Function() action) async {
    final owner =
        '${DateTime.now().microsecondsSinceEpoch}-${html.window.hashCode}';
    final deadline = DateTime.now().add(const Duration(seconds: 22));

    while (DateTime.now().isBefore(deadline)) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final current = _readRefreshLock();
      if (current == null || (current['expiresAt'] as int) <= now) {
        html.window.localStorage[_refreshLockKey] = jsonEncode({
          'owner': owner,
          'expiresAt': now + const Duration(seconds: 18).inMilliseconds,
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (_readRefreshLock()?['owner'] == owner) {
          try {
            return await action();
          } finally {
            if (_readRefreshLock()?['owner'] == owner) {
              html.window.localStorage.remove(_refreshLockKey);
            }
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('Web refresh lock could not be acquired');
  }

  Map<String, Object?>? _readRefreshLock() {
    final raw = html.window.localStorage[_refreshLockKey];
    if (raw == null) return null;
    try {
      final value = Map<String, Object?>.from(jsonDecode(raw) as Map);
      if (value['owner'] is! String || value['expiresAt'] is! int) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear({bool notifyOtherTabs = true}) async {
    html.window.sessionStorage.remove(_accessKey);
    html.window.sessionStorage.remove(_refreshKey);
    if (notifyOtherTabs) {
      _channel.postMessage(jsonEncode({'type': 'logout'}));
    }
  }

  void _onMessage(html.MessageEvent event) {
    try {
      final message = jsonDecode(event.data.toString()) as Map<String, dynamic>;
      if (message['type'] == 'logout') {
        unawaited(clear(notifyOtherTabs: false));
        return;
      }
      if (message['type'] == 'session-update') {
        unawaited(
          _writeLocal(
            SessionValues(
              accessToken: message['accessToken']?.toString() ?? '',
              refreshToken: message['refreshToken']?.toString() ?? '',
            ),
          ),
        );
        return;
      }
      if (message['type'] == 'request') {
        final values = _localValues();
        if (values == null) return;
        _channel.postMessage(
          jsonEncode({
            'type': 'response',
            'id': message['id'],
            'accessToken': values.accessToken,
            'refreshToken': values.refreshToken,
          }),
        );
        return;
      }
      if (message['type'] != 'response') return;
      final id = message['id']?.toString() ?? '';
      final completer = _requests.remove(id);
      if (completer == null || completer.isCompleted) return;
      final values = SessionValues(
        accessToken: message['accessToken']?.toString() ?? '',
        refreshToken: message['refreshToken']?.toString() ?? '',
      );
      unawaited(_writeLocal(values));
      completer.complete(values);
    } catch (_) {
      // Nachrichten aus anderen Origins erreichen den Channel nicht. Ungültige
      // gleichnamige Nachrichten innerhalb des Origins werden ignoriert.
    }
  }
}
