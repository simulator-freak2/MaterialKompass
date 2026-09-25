import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';

import 'download_service_types.dart';

export 'download_service_types.dart';

class DownloadService {
  DownloadService._();

  static final instance = DownloadService._();

  bool get supportsCustomFolder => false;

  Future<String?> configuredDirectory() async => null;

  Future<String?> chooseDirectory() async => null;

  Future<void> resetDirectory() async {}

  Future<DownloadResult> save({
    required String name,
    required Uint8List bytes,
    required String fileExtension,
    required String mimeType,
  }) async {
    validateDownloadBytes(bytes);
    final safeName = sanitizedFileBaseName(name);
    final safeExtension = normalizedFileExtension(fileExtension);
    await FileSaver.instance.saveFile(
      name: safeName,
      bytes: bytes,
      fileExtension: safeExtension,
      mimeType: MimeType.custom,
      customMimeType: mimeType,
    );
    return DownloadResult(
      fileName: safeDownloadFileName(safeName, safeExtension),
    );
  }
}
