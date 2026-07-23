import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../constants.dart';
import 'client_update_installer.dart';

class ClientUpdate {
  const ClientUpdate({
    required this.version,
    required this.minimumVersion,
    required this.downloadUri,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.required,
    this.notes,
  });

  final String version;
  final String minimumVersion;
  final Uri downloadUri;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final bool required;
  final String? notes;
}

/// Checks the MaterialKompass backend for a newer native client.
///
/// Installation remains with the operating system. This is intentional:
/// Android and managed desktops must verify and authorize app installers.
class ClientUpdateService {
  ClientUpdateService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static String? get platformName {
    if (kIsWeb) return null;
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.android => 'android',
      _ => null,
    };
  }

  Future<ClientUpdate?> check() async {
    final platform = platformName;
    if (platform == null) return null;

    final package = await PackageInfo.fromPlatform();
    final endpoint = Uri.parse('$apiBaseUrl/api/client-updates/$platform')
        .replace(queryParameters: {'currentVersion': package.version});
    final response =
        await _client.get(endpoint).timeout(const Duration(seconds: 10));
    if (response.statusCode == 204 || response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError(
          'Update-Prüfung fehlgeschlagen (${response.statusCode}).');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['updateAvailable'] != true ||
        data['downloadUrl'] is! String ||
        data['fileName'] is! String ||
        data['sizeBytes'] is! int ||
        (data['sizeBytes'] as int) <= 0 ||
        data['sha256'] is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(data['sha256'] as String)) {
      return null;
    }
    final downloadUri =
        Uri.parse(apiBaseUrl).resolve(data['downloadUrl'] as String);
    return ClientUpdate(
      version: data['version'] as String,
      minimumVersion: data['minimumVersion'] as String? ?? '0.0.0',
      downloadUri: downloadUri,
      fileName: data['fileName'] as String,
      sizeBytes: data['sizeBytes'] as int,
      sha256: data['sha256'] as String,
      required: data['required'] == true,
      notes: data['notes'] as String?,
    );
  }

  Future<bool> install(
    ClientUpdate update, {
    void Function(double progress)? onProgress,
  }) =>
      downloadAndInstallClientUpdate(
        _client,
        update,
        onProgress: onProgress,
      );

  void dispose() => _client.close();
}

int compareVersions(String left, String right) {
  List<int> parts(String value) => value
      .split(RegExp(r'[+-]'))
      .first
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final a = parts(left);
  final b = parts(right);
  for (var i = 0; i < 3; i++) {
    final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (difference != 0) return difference.sign;
  }
  return 0;
}
