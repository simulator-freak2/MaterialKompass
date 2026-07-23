Future<void> sendRawLabel(
  String host,
  int port,
  List<int> bytes,
) async {
  throw UnsupportedError(
      'Der direkte Etikettendruck wird nur unter Windows und Android unterstützt.');
}

bool get labelPrintingSupported => false;
