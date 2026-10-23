import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AuthenticatorApp());
}

class AuthenticatorApp extends StatelessWidget {
  const AuthenticatorApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MaterialKompass Authenticator',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('de')],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff075e54),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff4bd0bd),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const HomePage(),
      );
}

class TotpEntry {
  const TotpEntry({
    required this.id,
    required this.issuer,
    required this.account,
    required this.secret,
    this.algorithm = 'SHA1',
    this.digits = 6,
    this.period = 30,
  });

  final String id;
  final String issuer;
  final String account;
  final String secret;
  final String algorithm;
  final int digits;
  final int period;

  factory TotpEntry.fromUri(Uri uri) {
    if (uri.scheme != 'otpauth' || uri.host != 'totp') {
      throw const FormatException('Nur TOTP-QR-Codes werden unterstützt.');
    }
    final secret = (uri.queryParameters['secret'] ?? '')
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase();
    if (secret.length < 16 || !RegExp(r'^[A-Z2-7]+=*$').hasMatch(secret)) {
      throw const FormatException('Das TOTP-Geheimnis ist ungültig.');
    }
    final label = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
    final separator = label.indexOf(':');
    final labelIssuer = separator < 0 ? '' : label.substring(0, separator);
    final account = separator < 0 ? label : label.substring(separator + 1);
    final issuer = (uri.queryParameters['issuer'] ?? labelIssuer).trim();
    final algorithm =
        (uri.queryParameters['algorithm'] ?? 'SHA1').toUpperCase();
    final digits = int.tryParse(uri.queryParameters['digits'] ?? '') ?? 6;
    final period = int.tryParse(uri.queryParameters['period'] ?? '') ?? 30;
    if (!{'SHA1', 'SHA256', 'SHA512'}.contains(algorithm) ||
        !{6, 8}.contains(digits) ||
        period < 15 ||
        period > 120 ||
        account.trim().isEmpty) {
      throw const FormatException(
        'Die TOTP-Parameter werden nicht unterstützt.',
      );
    }
    return TotpEntry(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      issuer: issuer.isEmpty ? 'TOTP' : issuer,
      account: account.trim(),
      secret: secret,
      algorithm: algorithm,
      digits: digits,
      period: period,
    );
  }

  factory TotpEntry.fromJson(Map<String, dynamic> json) => TotpEntry(
        id: json['id'].toString(),
        issuer: json['issuer'].toString(),
        account: json['account'].toString(),
        secret: json['secret'].toString(),
        algorithm: json['algorithm']?.toString() ?? 'SHA1',
        digits: json['digits'] as int? ?? 6,
        period: json['period'] as int? ?? 30,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'issuer': issuer,
        'account': account,
        'secret': secret,
        'algorithm': algorithm,
        'digits': digits,
        'period': period,
      };
}

TotpEntry? embeddedTotpEntry(Uri pairingUri) {
  if (pairingUri.scheme != 'materialkompass-auth' ||
      pairingUri.host != 'pair') {
    return null;
  }
  final value = pairingUri.queryParameters['totp'];
  if (value == null || value.isEmpty) return null;
  return TotpEntry.fromUri(Uri.parse(value));
}

class PushAccount {
  const PushAccount({
    required this.id,
    required this.serverUrl,
    required this.account,
    required this.deviceId,
    required this.deviceSecret,
    required this.name,
  });

  final String id;
  final String serverUrl;
  final String account;
  final String deviceId;
  final String deviceSecret;
  final String name;

  factory PushAccount.fromJson(Map<String, dynamic> json) => PushAccount(
        id: json['id'].toString(),
        serverUrl: json['serverUrl'].toString(),
        account: json['account'].toString(),
        deviceId: json['deviceId'].toString(),
        deviceSecret: json['deviceSecret'].toString(),
        name: json['name']?.toString() ?? 'MaterialKompass',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'serverUrl': serverUrl,
        'account': account,
        'deviceId': deviceId,
        'deviceSecret': deviceSecret,
        'name': name,
      };
}

class PendingApproval {
  const PendingApproval({
    required this.id,
    required this.matchingCode,
    required this.client,
    required this.sourceIp,
    required this.expiresAt,
  });

  final String id;
  final String matchingCode;
  final String client;
  final String sourceIp;
  final DateTime expiresAt;

  factory PendingApproval.fromJson(Map<String, dynamic> json) =>
      PendingApproval(
        id: json['approvalId'].toString(),
        matchingCode: json['matchingCode'].toString(),
        client: json['client']?.toString() ?? 'Unbekannter Client',
        sourceIp: json['sourceIp']?.toString() ?? '',
        expiresAt: DateTime.parse(json['expiresAt'].toString()),
      );
}

class Vault {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _totpKey = 'totp_entries_v1';
  static const _pushKey = 'push_accounts_v1';
  static const _appLockKey = 'app_lock_enabled_v1';

  Future<List<TotpEntry>> loadTotp() async {
    final value = await _storage.read(key: _totpKey);
    if (value == null) return [];
    final decoded = jsonDecode(value) as List;
    return decoded
        .map(
          (item) => TotpEntry.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<List<PushAccount>> loadPush() async {
    final value = await _storage.read(key: _pushKey);
    if (value == null) return [];
    final decoded = jsonDecode(value) as List;
    return decoded
        .map(
          (item) =>
              PushAccount.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<void> saveTotp(List<TotpEntry> entries) => _storage.write(
        key: _totpKey,
        value: jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      );

  Future<void> savePush(List<PushAccount> accounts) => _storage.write(
        key: _pushKey,
        value: jsonEncode(accounts.map((entry) => entry.toJson()).toList()),
      );

  Future<bool> loadAppLock() async =>
      await _storage.read(key: _appLockKey) == 'true';

  Future<void> saveAppLock(bool enabled) =>
      _storage.write(key: _appLockKey, value: enabled.toString());
}

bool appLockSupportedPlatform(TargetPlatform platform, {required bool isWeb}) =>
    !isWeb &&
    {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }.contains(platform);

bool appLockTriggeredBy(AppLifecycleState state) =>
    state == AppLifecycleState.paused ||
    state == AppLifecycleState.hidden ||
    state == AppLifecycleState.detached;

Uint8List decodeBase32(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var buffer = 0;
  var bitsLeft = 0;
  final output = <int>[];
  for (final rune in input.replaceAll('=', '').toUpperCase().runes) {
    final value = alphabet.indexOf(String.fromCharCode(rune));
    if (value < 0) throw const FormatException('Ungültiges Base32-Geheimnis.');
    buffer = (buffer << 5) | value;
    bitsLeft += 5;
    if (bitsLeft >= 8) {
      bitsLeft -= 8;
      output.add((buffer >> bitsLeft) & 0xff);
      buffer &= (1 << bitsLeft) - 1;
    }
  }
  return Uint8List.fromList(output);
}

String generateTotp(TotpEntry entry, DateTime instant) {
  var counter = instant.millisecondsSinceEpoch ~/ 1000 ~/ entry.period;
  final message = Uint8List(8);
  for (var index = 7; index >= 0; index -= 1) {
    message[index] = counter & 0xff;
    counter >>= 8;
  }
  final algorithm = switch (entry.algorithm) {
    'SHA256' => sha256,
    'SHA512' => sha512,
    _ => sha1,
  };
  final digest = Hmac(
    algorithm,
    decodeBase32(entry.secret),
  ).convert(message).bytes;
  final offset = digest.last & 0x0f;
  final binary = ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
  var divisor = 1;
  for (var index = 0; index < entry.digits; index += 1) {
    divisor *= 10;
  }
  return (binary % divisor).toString().padLeft(entry.digits, '0');
}

class PushApi {
  PushApi(this.client);
  final http.Client client;

  Future<PushAccount> pair(Uri pairingUri, String name) async {
    if (pairingUri.scheme != 'materialkompass-auth' ||
        pairingUri.host != 'pair') {
      throw const FormatException(
        'Dies ist kein MaterialKompass-Kopplungscode.',
      );
    }
    final server = Uri.tryParse(pairingUri.queryParameters['server'] ?? '');
    final token = pairingUri.queryParameters['token'] ?? '';
    if (server == null ||
        !{'https', if (kDebugMode) 'http'}.contains(server.scheme) ||
        server.host.isEmpty ||
        token.length < 32) {
      throw const FormatException(
        'Der Kopplungscode ist unsicher oder unvollständig.',
      );
    }
    final response = await client
        .post(
          server.resolve('/api/auth/mfa/push/pair'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'pairToken': token,
            'name': name.trim().isEmpty ? 'Authenticator' : name.trim(),
            'platform': kIsWeb ? 'web' : 'android',
          }),
        )
        .timeout(const Duration(seconds: 15));
    final body = _decodeObject(response);
    if (response.statusCode != 201) {
      throw StateError(body['error']?.toString() ?? 'Kopplung fehlgeschlagen.');
    }
    final device = Map<String, dynamic>.from(body['device'] as Map);
    return PushAccount(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      serverUrl: body['serverUrl'].toString(),
      account: body['account'].toString(),
      deviceId: device['id'].toString(),
      deviceSecret: body['deviceSecret'].toString(),
      name: device['name'].toString(),
    );
  }

  Future<PendingApproval?> pending(PushAccount account) async {
    final response = await client
        .post(
          Uri.parse(account.serverUrl).resolve('/api/auth/mfa/push/pending'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'deviceId': account.deviceId,
            'deviceSecret': account.deviceSecret,
          }),
        )
        .timeout(const Duration(seconds: 35));
    if (response.statusCode == 204) return null;
    final body = _decodeObject(response);
    if (response.statusCode == 401) {
      throw StateError('Gerätekopplung widerrufen.');
    }
    if (response.statusCode != 200) {
      throw StateError(body['error']?.toString() ?? 'Server nicht erreichbar.');
    }
    return PendingApproval.fromJson(body);
  }

  Future<void> respond(
    PushAccount account,
    PendingApproval approval,
    String decision,
  ) async {
    final response = await client
        .post(
          Uri.parse(account.serverUrl).resolve('/api/auth/mfa/push/respond'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            'deviceId': account.deviceId,
            'deviceSecret': account.deviceSecret,
            'approvalId': approval.id,
            'matchingCode':
                decision == 'approve' ? approval.matchingCode : null,
            'decision': decision,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 204) {
      final body = _decodeObject(response);
      throw StateError(body['error']?.toString() ?? 'Antwort fehlgeschlagen.');
    }
  }

  static Map<String, dynamic> _decodeObject(http.Response response) {
    if (response.body.isEmpty) return {};
    final value = jsonDecode(response.body);
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const nativePush = MethodChannel(
    'org.materialkompass.authenticator/push',
  );
  final vault = Vault();
  final client = http.Client();
  final localAuth = LocalAuthentication();
  late final api = PushApi(client);
  List<TotpEntry> totp = [];
  List<PushAccount> pushAccounts = [];
  final pending = <String, PendingApproval>{};
  Timer? clock;
  bool loading = true;
  bool polling = false;
  bool appLockEnabled = false;
  bool appUnlocked = true;
  bool unlocking = false;
  String? unlockError;
  String? message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (appLockEnabled && appLockTriggeredBy(state)) {
      if (mounted) setState(() => appUnlocked = false);
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (appLockEnabled && !appUnlocked) {
        unawaited(_unlock());
      } else {
        _poll();
      }
    }
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait([
        vault.loadTotp(),
        vault.loadPush(),
        vault.loadAppLock(),
      ]);
      totp = values[0] as List<TotpEntry>;
      pushAccounts = values[1] as List<PushAccount>;
      appLockEnabled = values[2] as bool;
      appUnlocked = !appLockEnabled;
      await _syncNativeService();
    } catch (_) {
      message = 'Der verschlüsselte Speicher konnte nicht geöffnet werden.';
    }
    if (mounted) setState(() => loading = false);
    if (appLockEnabled) {
      unawaited(_unlock());
    } else {
      _poll();
    }
  }

  Future<bool> _authenticateDevice(String reason) async {
    if (!appLockSupportedPlatform(defaultTargetPlatform, isWeb: kIsWeb)) {
      if (mounted) {
        setState(
          () => unlockError =
              'Die App-Sperre ist auf dieser Plattform nicht verfügbar.',
        );
      }
      return false;
    }
    try {
      if (!await localAuth.isDeviceSupported()) {
        if (mounted) {
          setState(
            () => unlockError =
                'Richte zuerst eine Gerätesperre mit Biometrie, PIN oder Passcode ein.',
          );
        }
        return false;
      }
      return await localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException {
      if (mounted) {
        setState(
          () => unlockError =
              'Die Geräteauthentifizierung ist nicht verfügbar. Prüfe Biometrie und Gerätesperre.',
        );
      }
      return false;
    } on PlatformException {
      if (mounted) {
        setState(() => unlockError = 'Die App konnte nicht entsperrt werden.');
      }
      return false;
    }
  }

  Future<void> _unlock() async {
    if (unlocking || !appLockEnabled || appUnlocked || !mounted) return;
    setState(() {
      unlocking = true;
      unlockError = null;
    });
    final authenticated = await _authenticateDevice(
      'MaterialKompass Authenticator entsperren',
    );
    if (!mounted) return;
    setState(() {
      unlocking = false;
      appUnlocked = authenticated;
      if (!authenticated && unlockError == null) {
        unlockError = 'Die App bleibt gesperrt.';
      }
    });
    if (authenticated) _poll();
  }

  Future<void> _setAppLock(bool enabled) async {
    if (unlocking) return;
    setState(() {
      unlocking = true;
      unlockError = null;
    });
    final authenticated = await _authenticateDevice(
      enabled
          ? 'App-Sperre für MaterialKompass aktivieren'
          : 'App-Sperre für MaterialKompass deaktivieren',
    );
    if (!mounted) return;
    if (!authenticated) {
      setState(() {
        unlocking = false;
        if (unlockError == null) {
          message = 'Die Einstellung wurde nicht geändert.';
        }
      });
      return;
    }
    try {
      await vault.saveAppLock(enabled);
      if (!mounted) return;
      setState(() {
        appLockEnabled = enabled;
        appUnlocked = true;
        unlocking = false;
        message = enabled ? 'App-Sperre aktiviert.' : 'App-Sperre deaktiviert.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          unlocking = false;
          message = 'Die App-Sperre konnte nicht gespeichert werden.';
        });
      }
    }
  }

  void _lockNow() {
    if (!appLockEnabled) return;
    setState(() {
      appUnlocked = false;
      unlockError = null;
    });
  }

  Future<void> _syncNativeService() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await nativePush.invokeMethod<void>('configure', {
        'accounts': jsonEncode(
          pushAccounts.map((item) => item.toJson()).toList(),
        ),
      });
    } on PlatformException {
      if (mounted) {
        setState(
          () => message = 'Hintergrunddienst konnte nicht gestartet werden.',
        );
      }
    }
  }

  Future<void> _poll() async {
    if (polling ||
        pushAccounts.isEmpty ||
        !mounted ||
        (appLockEnabled && !appUnlocked)) {
      return;
    }
    polling = true;
    try {
      for (final account in List<PushAccount>.of(pushAccounts)) {
        try {
          final approval = await api.pending(account);
          if (approval != null && approval.expiresAt.isAfter(DateTime.now())) {
            pending[account.id] = approval;
          } else {
            pending.remove(account.id);
          }
        } catch (error) {
          message = error.toString().replaceFirst('Bad state: ', '');
        }
      }
    } finally {
      polling = false;
      if (mounted) setState(() {});
      if (mounted &&
          pushAccounts.isNotEmpty &&
          (!appLockEnabled || appUnlocked)) {
        unawaited(Future<void>.delayed(const Duration(seconds: 1), _poll));
      }
    }
  }

  Future<void> _scan() async {
    final value = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (value == null || !mounted) return;
    await _import(value);
  }

  Future<void> _manualImport() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Einrichtungsschlüssel einfügen'),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'otpauth://… oder materialkompass-auth://…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Importieren'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && mounted) await _import(value);
  }

  Future<void> _import(String raw) async {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme == 'otpauth') {
        final entry = TotpEntry.fromUri(uri);
        if (totp.any(
          (item) =>
              item.secret == entry.secret && item.account == entry.account,
        )) {
          throw StateError('Dieser TOTP-Eintrag ist bereits vorhanden.');
        }
        totp.add(entry);
        await vault.saveTotp(totp);
      } else if (uri.scheme == 'materialkompass-auth') {
        final embeddedTotp = embeddedTotpEntry(uri);
        final name = await _deviceName();
        if (name == null) return;
        final account = await api.pair(uri, name);
        pushAccounts.add(account);
        await vault.savePush(pushAccounts);
        if (embeddedTotp != null &&
            !totp.any(
              (item) =>
                  item.secret == embeddedTotp.secret &&
                  item.account == embeddedTotp.account,
            )) {
          totp.add(embeddedTotp);
          await vault.saveTotp(totp);
        }
        await _syncNativeService();
        _poll();
      } else {
        throw const FormatException('Unbekannter QR-Code.');
      }
      if (mounted) {
        setState(
          () => message = uri.scheme == 'materialkompass-auth' &&
                  uri.queryParameters.containsKey('totp')
              ? 'Codes und Push-Bestätigung wurden sicher eingerichtet.'
              : 'Sicher importiert.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<String?> _deviceName() async {
    final controller = TextEditingController(text: 'Mein Authenticator');
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Gerät benennen'),
        content: TextField(
          controller: controller,
          maxLength: 100,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Koppeln'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _respond(
    PushAccount account,
    PendingApproval approval,
    String decision,
  ) async {
    try {
      await api.respond(account, approval, decision);
      pending.remove(account.id);
      if (mounted) {
        setState(
          () => message = decision == 'approve'
              ? 'Anmeldung freigegeben.'
              : 'Anmeldung abgelehnt.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    }
  }

  Future<void> _removeTotp(TotpEntry entry) async {
    if (!await _confirm('„${entry.issuer} – ${entry.account}“ löschen?')) {
      return;
    }
    totp.removeWhere((item) => item.id == entry.id);
    await vault.saveTotp(totp);
    if (mounted) setState(() {});
  }

  Future<void> _removePush(PushAccount account) async {
    if (!await _confirm(
      'Lokale Kopplung für „${account.account}“ entfernen? Widerrufe das Gerät zusätzlich in MaterialKompass.',
    )) {
      return;
    }
    pushAccounts.removeWhere((item) => item.id == account.id);
    pending.remove(account.id);
    await vault.savePush(pushAccounts);
    await _syncNativeService();
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sicherheitsfaktor entfernen'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Entfernen'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('MaterialKompass Authenticator'),
        actions: [
          if (!appLockEnabled || appUnlocked) ...[
            if (appLockEnabled)
              IconButton(
                onPressed: _lockNow,
                tooltip: 'App jetzt sperren',
                icon: const Icon(Icons.lock_outline),
              ),
            IconButton(
              onPressed: _manualImport,
              tooltip: 'Schlüssel einfügen',
              icon: const Icon(Icons.content_paste_outlined),
            ),
            IconButton(
              onPressed: _scan,
              tooltip: 'QR-Code scannen',
              icon: const Icon(Icons.qr_code_scanner),
            ),
          ],
        ],
      ),
      floatingActionButton: appLockEnabled && !appUnlocked
          ? null
          : FloatingActionButton.extended(
              onPressed: _scan,
              icon: const Icon(Icons.add),
              label: const Text('Konto hinzufügen'),
            ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : appLockEnabled && !appUnlocked
              ? _lockedView()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  children: [
                    if (message != null)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: Text(message!),
                          trailing: IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => message = null),
                          ),
                        ),
                      ),
                    Card(
                      child: SwitchListTile(
                        secondary: const Icon(Icons.fingerprint),
                        title: const Text('App-Sperre'),
                        subtitle: Text(
                          appLockSupportedPlatform(
                            defaultTargetPlatform,
                            isWeb: kIsWeb,
                          )
                              ? 'Beim Öffnen mit Biometrie, Geräte-PIN oder Passcode entsperren.'
                              : 'Auf dieser Plattform nicht verfügbar.',
                        ),
                        value: appLockEnabled,
                        onChanged: unlocking ||
                                !appLockSupportedPlatform(
                                  defaultTargetPlatform,
                                  isWeb: kIsWeb,
                                )
                            ? null
                            : _setAppLock,
                      ),
                    ),
                    if (pending.isNotEmpty) ...[
                      Text(
                        'Anmeldeanfragen',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      for (final account in pushAccounts)
                        if (pending[account.id] case final approval?)
                          _approvalCard(account, approval),
                      const SizedBox(height: 20),
                    ],
                    Text(
                      'Einmalcodes',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    if (totp.isEmpty)
                      const Card(
                        child: ListTile(
                          leading: Icon(Icons.password),
                          title: Text('Noch keine TOTP-Konten'),
                          subtitle: Text(
                            'Scanne einen standardisierten otpauth://-QR-Code.',
                          ),
                        ),
                      ),
                    for (final entry in totp)
                      Card(
                        child: ListTile(
                          title: Text(entry.issuer),
                          subtitle: Text(
                            '${entry.account}\n${generateTotp(entry, now)} · ${entry.period - (now.millisecondsSinceEpoch ~/ 1000) % entry.period} s',
                          ),
                          isThreeLine: true,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removeTotp(entry),
                          ),
                          onTap: () => Clipboard.setData(
                            ClipboardData(text: generateTotp(entry, now)),
                          ).then((_) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Code kopiert.')),
                            );
                          }),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Text(
                      'Push-Kopplungen',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    if (pushAccounts.isEmpty)
                      const Card(
                        child: ListTile(
                          leading: Icon(Icons.notifications_none),
                          title: Text('Noch kein MaterialKompass-Konto'),
                          subtitle: Text(
                            'Erzeuge im Hauptsystem einen einmaligen Kopplungs-QR-Code.',
                          ),
                        ),
                      ),
                    for (final account in pushAccounts)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.verified_user_outlined),
                          title: Text(account.account),
                          subtitle: Text(account.serverUrl),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _removePush(account),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.shield_outlined),
                        title: Text('Keine US-Push-Dienste'),
                        subtitle: Text(
                          'Codes und Geräteschlüssel bleiben verschlüsselt auf diesem Gerät. Push-Anfragen laufen ausschließlich über den selbst gehosteten MaterialKompass-Server.',
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _lockedView() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  'Authenticator gesperrt',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Entsperre die App mit Fingerabdruck, Gesichtserkennung, '
                  'Geräte-PIN oder Passcode.',
                  textAlign: TextAlign.center,
                ),
                if (unlockError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    unlockError!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: unlocking ? null : _unlock,
                  icon: unlocking
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fingerprint),
                  label: Text(unlocking ? 'Prüfung läuft …' : 'Entsperren'),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _approvalCard(PushAccount account, PendingApproval approval) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Anmeldung für ${account.account}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(approval.client,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              if (approval.sourceIp.isNotEmpty)
                Text('Quelle: ${approval.sourceIp}'),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  approval.matchingCode,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 12,
                      ),
                ),
              ),
              const Center(
                child: Text(
                  'Nur freigeben, wenn dieser Code im Login angezeigt wird.',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _respond(account, approval, 'deny'),
                      icon: const Icon(Icons.close),
                      label: const Text('Ablehnen'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _respond(account, approval, 'approve'),
                      icon: const Icon(Icons.check),
                      label: const Text('Freigeben'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool handled = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('QR-Code scannen')),
        body: MobileScanner(
          onDetect: (capture) {
            if (handled) return;
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value == null) return;
            handled = true;
            Navigator.pop(context, value);
          },
        ),
      );
}
