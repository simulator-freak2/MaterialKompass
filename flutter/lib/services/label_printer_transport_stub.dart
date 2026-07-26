Future<void> sendRawLabel(
  String host,
  int port,
  List<int> bytes,
) async {
  throw UnsupportedError(
      'Der direkte Etikettendruck wird nur unter Windows und Android unterstützt.');
}

bool get labelPrintingSupported => false;
bool get windowsSystemPrinterSupported => false;
bool get zebraPrintConnectSupported => false;

Future<List<String>> listSystemPrinters() async => const [];
Future<bool> isZebraPrintConnectInstalled() async => false;

Future<void> sendRawToSystemPrinter(
  String printerName,
  List<int> bytes,
) async {
  throw UnsupportedError(
      'Windows-Druckertreiber sind auf dieser Plattform nicht verfügbar.');
}

Future<void> sendRawToZebraPrintConnect(List<int> bytes) async {
  throw UnsupportedError(
      'Zebra PrintConnect ist auf dieser Plattform nicht verfügbar.');
}
