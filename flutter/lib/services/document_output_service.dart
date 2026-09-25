import 'dart:convert';
import 'dart:typed_data';

import 'package:printing/printing.dart';

import 'download_service.dart';

class DocumentPayload {
  const DocumentPayload({
    required this.fileName,
    required this.baseName,
    required this.extension,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String baseName;
  final String extension;
  final String mimeType;
  final Uint8List bytes;

  factory DocumentPayload.fromMap(
    Map<dynamic, dynamic> data, {
    String fallbackFileName = 'download.bin',
    String fallbackMimeType = 'application/octet-stream',
  }) {
    final rawFileName = data['fileName']?.toString().trim();
    final fileName = rawFileName == null || rawFileName.isEmpty
        ? fallbackFileName
        : rawFileName;
    final separator = fileName.lastIndexOf('.');
    final rawBaseName = separator > 0
        ? fileName.substring(0, separator)
        : fileName;
    final rawExtension = separator > 0
        ? fileName.substring(separator + 1)
        : fallbackFileName.split('.').last;
    final encoded = data['fileBase64']?.toString() ?? '';
    if (encoded.isEmpty || encoded.length > (maxDownloadBytes * 4 ~/ 3) + 8) {
      throw const DownloadException(
        'Die empfangenen Dateidaten sind ungültig.',
      );
    }
    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const DownloadException(
        'Die empfangenen Dateidaten sind ungültig.',
      );
    }
    validateDownloadBytes(bytes);
    final rawMimeType = data['mimeType']?.toString().trim();
    final mimeType = rawMimeType == null || rawMimeType.isEmpty
        ? fallbackMimeType
        : rawMimeType;
    if (!RegExp(
      r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+(?:\s*;\s*[a-z0-9!#$&^_.+-]+=[a-z0-9!#$&^_.+-]+)*$',
      caseSensitive: false,
    ).hasMatch(mimeType)) {
      throw const DownloadException('Der Dateityp ist ungültig.');
    }
    final baseName = sanitizedFileBaseName(rawBaseName);
    final extension = normalizedFileExtension(rawExtension);
    return DocumentPayload(
      fileName: safeDownloadFileName(baseName, extension),
      baseName: baseName,
      extension: extension,
      mimeType: mimeType,
      bytes: bytes,
    );
  }
}

class DocumentOutputService {
  DocumentOutputService._();

  static final instance = DocumentOutputService._();

  Future<DownloadResult> savePayload(
    Map<dynamic, dynamic> data, {
    String fallbackFileName = 'download.bin',
    String fallbackMimeType = 'application/octet-stream',
  }) {
    final payload = DocumentPayload.fromMap(
      data,
      fallbackFileName: fallbackFileName,
      fallbackMimeType: fallbackMimeType,
    );
    return DownloadService.instance.save(
      name: payload.baseName,
      bytes: payload.bytes,
      fileExtension: payload.extension,
      mimeType: payload.mimeType,
    );
  }

  Future<void> printPdfPayload(
    Map<dynamic, dynamic> data, {
    String fallbackFileName = 'maengelbericht.pdf',
  }) async {
    final payload = DocumentPayload.fromMap(
      data,
      fallbackFileName: fallbackFileName,
      fallbackMimeType: 'application/pdf',
    );
    if (payload.extension != 'pdf' ||
        payload.mimeType.toLowerCase() != 'application/pdf' ||
        payload.bytes.length < 5 ||
        String.fromCharCodes(payload.bytes.take(5)) != '%PDF-') {
      throw const DownloadException(
        'Das empfangene Dokument ist keine gültige PDF-Datei.',
      );
    }
    final opened = await Printing.layoutPdf(
      name: payload.fileName,
      onLayout: (_) async => payload.bytes,
      usePrinterSettings: true,
    );
    if (!opened) {
      throw const DownloadException(
        'Der System-Druckdialog konnte nicht geöffnet werden.',
      );
    }
  }
}
