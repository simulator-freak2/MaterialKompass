import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:materialkompass/services/document_output_service.dart';
import 'package:materialkompass/services/download_service.dart';

void main() {
  group('sichere Dateinamen', () {
    test('entfernt Pfadbestandteile und Windows-reservierte Namen', () {
      expect(
        sanitizedFileBaseName(r'..\Mängel/bericht:*?'),
        '.._Mängel_bericht___',
      );
      expect(sanitizedFileBaseName('CON'), '_CON');
      expect(safeDownloadFileName('Bericht', '.PDF'), 'Bericht.pdf');
    });

    test('weist ungültige Dateiendungen zurück', () {
      expect(
        () => normalizedFileExtension('../exe'),
        throwsA(isA<DownloadException>()),
      );
    });
  });

  group('Dokumentdaten', () {
    test('dekodiert und normalisiert einen gültigen Payload', () {
      final payload = DocumentPayload.fromMap({
        'fileName': r'../Mängelbericht.PDF',
        'mimeType': 'application/pdf',
        'fileBase64': base64Encode(utf8.encode('%PDF-test')),
      });

      expect(payload.fileName, '.._Mängelbericht.pdf');
      expect(payload.mimeType, 'application/pdf');
      expect(utf8.decode(payload.bytes), '%PDF-test');
    });

    test('weist leere und beschädigte Base64-Daten zurück', () {
      expect(
        () =>
            DocumentPayload.fromMap({'fileName': 'leer.pdf', 'fileBase64': ''}),
        throwsA(isA<DownloadException>()),
      );
      expect(
        () => DocumentPayload.fromMap({
          'fileName': 'defekt.pdf',
          'fileBase64': '***',
        }),
        throwsA(isA<DownloadException>()),
      );
    });

    test('weist manipulierte MIME-Typen zurück', () {
      expect(
        () => DocumentPayload.fromMap({
          'fileName': 'bericht.pdf',
          'mimeType': 'application/pdf\r\nX-Test: unsicher',
          'fileBase64': base64Encode(utf8.encode('%PDF-test')),
        }),
        throwsA(isA<DownloadException>()),
      );
    });
  });
}
