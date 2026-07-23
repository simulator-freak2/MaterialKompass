import 'dart:io';

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
