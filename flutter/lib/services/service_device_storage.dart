import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ServiceDeviceStorage {
  ServiceDeviceStorage._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  static const _credentialKey = 'materialkompass_service_device_credential';

  static Future<String?> readCredential() => _storage.read(key: _credentialKey);

  static Future<void> saveCredential(String value) =>
      _storage.write(key: _credentialKey, value: value);

  static Future<void> clear() => _storage.delete(key: _credentialKey);
}
