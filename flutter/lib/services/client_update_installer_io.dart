import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'client_update_service.dart';

const _extensions = {
  'windows': '.exe',
  'linux': '.deb',
  'android': '.apk',
};

Future<bool> downloadAndInstallClientUpdate(
  http.Client client,
  ClientUpdate update, {
  void Function(double progress)? onProgress,
}) async {
  final expectedExtension = _extensions[ClientUpdateService.platformName];
  if (expectedExtension == null ||
      !update.fileName.toLowerCase().endsWith(expectedExtension)) {
    throw StateError('Das Update hat kein gültiges Installationsformat.');
  }

  final safeFileName =
      update.fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final temporaryDirectory = await getTemporaryDirectory();
  final updateDirectory = Directory(
    '${temporaryDirectory.path}${Platform.pathSeparator}materialkompass-updates',
  );
  await updateDirectory.create(recursive: true);
  final installer = File(
    '${updateDirectory.path}${Platform.pathSeparator}$safeFileName',
  );
  if (await installer.exists()) await installer.delete();

  final request = http.Request('GET', update.downloadUri);
  final response =
      await client.send(request).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw StateError(
        'Update-Download fehlgeschlagen (${response.statusCode}).');
  }

  final sink = installer.openWrite();
  var received = 0;
  try {
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 30))) {
      received += chunk.length;
      if (received > update.sizeBytes) {
        throw StateError('Das Update ist größer als angekündigt.');
      }
      sink.add(chunk);
      onProgress?.call(received / update.sizeBytes);
    }
  } finally {
    await sink.close();
  }

  if (received != update.sizeBytes) {
    await installer.delete();
    throw StateError('Das Update wurde nicht vollständig übertragen.');
  }
  final digest = await sha256.bind(installer.openRead()).first;
  if (digest.toString().toLowerCase() != update.sha256.toLowerCase()) {
    await installer.delete();
    throw StateError('Die Prüfsumme des Updates ist ungültig.');
  }

  onProgress?.call(1);
  final result =
      await OpenFilex.open(installer.path, type: _mimeType(expectedExtension));
  return result.type == ResultType.done;
}

String _mimeType(String extension) => switch (extension) {
      '.exe' => 'application/vnd.microsoft.portable-executable',
      '.deb' => 'application/vnd.debian.binary-package',
      '.apk' => 'application/vnd.android.package-archive',
      _ => 'application/octet-stream',
    };
