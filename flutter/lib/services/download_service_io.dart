import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_service_types.dart';

export 'download_service_types.dart';

const _downloadDirectoryPreference = 'materialkompass.download_directory.v1';

class DownloadService {
  DownloadService._();

  static final instance = DownloadService._();
  final Random _random = Random.secure();

  bool get supportsCustomFolder => true;

  Future<String?> configuredDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_downloadDirectoryPreference)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<String?> chooseDirectory() async {
    final selected = await FilePicker.getDirectoryPath();
    if (selected == null) return null;
    final directory = Directory(selected);
    if (!Platform.isIOS) await _verifyWritable(directory);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_downloadDirectoryPreference, directory.path);
    return directory.path;
  }

  Future<void> resetDirectory() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_downloadDirectoryPreference);
  }

  Future<DownloadResult> save({
    required String name,
    required Uint8List bytes,
    required String fileExtension,
    required String mimeType,
  }) async {
    validateDownloadBytes(bytes);
    final safeName = sanitizedFileBaseName(name);
    final safeExtension = normalizedFileExtension(fileExtension);
    final fileName = safeDownloadFileName(safeName, safeExtension);
    var configured = await configuredDirectory();
    if (configured == null) {
      await FileSaver.instance.saveFile(
        name: safeName,
        bytes: bytes,
        fileExtension: safeExtension,
        mimeType: MimeType.custom,
        customMimeType: mimeType,
      );
      return DownloadResult(fileName: fileName);
    }

    if (Platform.isIOS) {
      final saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        initialDirectory: configured,
      );
      if (saved == null) {
        throw const DownloadException('Das Speichern wurde abgebrochen.');
      }
      return DownloadResult(fileName: fileName, path: saved.toString());
    }

    var directory = Directory(configured);
    try {
      await _verifyWritable(directory);
    } on DownloadException {
      configured = await chooseDirectory();
      if (configured == null) {
        throw const DownloadException(
          'Der konfigurierte Download-Ordner ist nicht mehr erreichbar. '
          'Bitte wähle einen neuen Ordner aus.',
        );
      }
      directory = Directory(configured);
    }

    final target = await _availableTarget(directory, safeName, safeExtension);
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}'
      '.materialkompass-${DateTime.now().microsecondsSinceEpoch}-'
      '${_random.nextInt(1 << 32)}.part',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        final replacement = await _availableTarget(
          directory,
          safeName,
          safeExtension,
        );
        await temporary.rename(replacement.path);
        return DownloadResult(
          fileName: replacement.uri.pathSegments.last,
          path: replacement.path,
        );
      }
      await temporary.rename(target.path);
      return DownloadResult(
        fileName: target.uri.pathSegments.last,
        path: target.path,
      );
    } on FileSystemException catch (error) {
      throw DownloadException(
        'Die Datei konnte nicht im Download-Ordner gespeichert werden: '
        '${error.osError?.message ?? error.message}',
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _verifyWritable(Directory directory) async {
    try {
      if (!directory.path.trim().isNotEmpty || !directory.isAbsolute) {
        throw const DownloadException('Der ausgewählte Ordner ist ungültig.');
      }
      if (!await directory.exists()) {
        throw const DownloadException(
          'Der ausgewählte Download-Ordner ist nicht erreichbar.',
        );
      }
      final probe = File(
        '${directory.path}${Platform.pathSeparator}'
        '.materialkompass-write-test-${_random.nextInt(1 << 32)}',
      );
      try {
        await probe.writeAsBytes(const [0], flush: true);
      } finally {
        if (await probe.exists()) await probe.delete();
      }
    } on DownloadException {
      rethrow;
    } on FileSystemException catch (error) {
      throw DownloadException(
        'Auf den ausgewählten Ordner kann nicht geschrieben werden: '
        '${error.osError?.message ?? error.message}',
      );
    }
  }

  Future<File> _availableTarget(
    Directory directory,
    String baseName,
    String extension,
  ) async {
    for (var suffix = 0; suffix < 10000; suffix += 1) {
      final candidateName = suffix == 0
          ? '$baseName.$extension'
          : '$baseName ($suffix).$extension';
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}$candidateName',
      );
      if (!await candidate.exists()) return candidate;
    }
    throw const DownloadException(
      'Für diese Datei konnte kein freier Dateiname gefunden werden.',
    );
  }
}
