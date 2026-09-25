import 'dart:typed_data';

const int maxDownloadBytes = 128 * 1024 * 1024;

class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DownloadResult {
  const DownloadResult({required this.fileName, this.path});

  final String fileName;
  final String? path;
}

String normalizedFileExtension(String value) {
  final normalized = value.replaceFirst(RegExp(r'^\.+'), '').toLowerCase();
  if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(normalized)) {
    throw const DownloadException('Die Dateiendung ist ungültig.');
  }
  return normalized;
}

String sanitizedFileBaseName(String value) {
  var safe = value
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.length > 160) safe = safe.substring(0, 160).trimRight();
  if (safe.isEmpty) safe = 'download';
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(safe.toUpperCase())) safe = '_$safe';
  return safe;
}

String safeDownloadFileName(String baseName, String extension) =>
    '${sanitizedFileBaseName(baseName)}.${normalizedFileExtension(extension)}';

void validateDownloadBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const DownloadException('Die heruntergeladene Datei ist leer.');
  }
  if (bytes.length > maxDownloadBytes) {
    throw const DownloadException(
      'Die Datei überschreitet die zulässige Größe von 128 MB.',
    );
  }
}
