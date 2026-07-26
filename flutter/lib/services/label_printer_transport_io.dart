import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('materialkompass/label_printer');

Future<void> sendRawLabel(
  String host,
  int port,
  List<int> bytes,
) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 5),
  );
  try {
    socket.add(bytes);
    await socket.flush();
  } finally {
    await socket.close();
  }
}

bool get labelPrintingSupported => Platform.isWindows || Platform.isAndroid;

bool get windowsSystemPrinterSupported => Platform.isWindows;
bool get zebraPrintConnectSupported => Platform.isAndroid;

Future<List<String>> listSystemPrinters() async {
  if (!Platform.isWindows) return const [];
  final result = await _channel.invokeListMethod<String>('listSystemPrinters');
  return result ?? const [];
}

Future<bool> isZebraPrintConnectInstalled() async {
  if (!Platform.isAndroid) return false;
  return await _channel.invokeMethod<bool>('isPrintConnectInstalled') ?? false;
}

Future<void> sendRawToSystemPrinter(
  String printerName,
  List<int> bytes,
) async {
  if (!Platform.isWindows) {
    throw UnsupportedError(
        'Windows-Druckertreiber sind auf dieser Plattform nicht verfügbar.');
  }
  await _channel.invokeMethod<void>('sendSystemPrint', {
    'printerName': printerName,
    'bytes': Uint8List.fromList(bytes),
  });
}

Future<void> sendRawToZebraPrintConnect(List<int> bytes) async {
  if (!Platform.isAndroid) {
    throw UnsupportedError(
        'Zebra PrintConnect ist auf dieser Plattform nicht verfügbar.');
  }
  await _channel.invokeMethod<void>('sendPrintConnect', {
    'bytes': Uint8List.fromList(bytes),
  });
}
