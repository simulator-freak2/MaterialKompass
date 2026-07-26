import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'label_printer_transport.dart';

enum LabelType { inventory, clothing }

enum LabelPrinterConnection { network, windowsDriver, zebraPrintConnect }

class LabelPrinter {
  final String id;
  final String name;
  final String host;
  final LabelPrinterConnection connection;
  final String systemPrinterName;
  final int port;
  final int speed;
  final int darkness;
  final bool defaultInventory;
  final bool defaultClothing;

  const LabelPrinter({
    required this.id,
    required this.name,
    required this.host,
    this.connection = LabelPrinterConnection.network,
    this.systemPrinterName = '',
    this.port = 9100,
    this.speed = 4,
    this.darkness = 15,
    this.defaultInventory = false,
    this.defaultClothing = false,
  });

  LabelPrinter copyWith({
    String? id,
    String? name,
    String? host,
    LabelPrinterConnection? connection,
    String? systemPrinterName,
    int? port,
    int? speed,
    int? darkness,
    bool? defaultInventory,
    bool? defaultClothing,
  }) =>
      LabelPrinter(
        id: id ?? this.id,
        name: name ?? this.name,
        host: host ?? this.host,
        connection: connection ?? this.connection,
        systemPrinterName: systemPrinterName ?? this.systemPrinterName,
        port: port ?? this.port,
        speed: speed ?? this.speed,
        darkness: darkness ?? this.darkness,
        defaultInventory: defaultInventory ?? this.defaultInventory,
        defaultClothing: defaultClothing ?? this.defaultClothing,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'connection': connection.name,
        'systemPrinterName': systemPrinterName,
        'port': port,
        'speed': speed,
        'darkness': darkness,
        'defaultInventory': defaultInventory,
        'defaultClothing': defaultClothing,
      };

  factory LabelPrinter.fromJson(Map<String, dynamic> json) => LabelPrinter(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        host: json['host']?.toString() ?? '',
        connection: LabelPrinterConnection.values.firstWhere(
          (value) => value.name == json['connection']?.toString(),
          orElse: () => LabelPrinterConnection.network,
        ),
        systemPrinterName: json['systemPrinterName']?.toString() ?? '',
        port: int.tryParse(json['port']?.toString() ?? '') ?? 9100,
        speed: int.tryParse(json['speed']?.toString() ?? '') ?? 4,
        darkness: int.tryParse(json['darkness']?.toString() ?? '') ?? 15,
        defaultInventory: json['defaultInventory'] == true,
        defaultClothing: json['defaultClothing'] == true,
      );
}

class LabelData {
  final LabelType type;
  final String inventoryNumber;
  final String name;
  final String manufacturer;
  final String year;
  final String size;
  final int suggestedCopies;

  const LabelData({
    required this.type,
    required this.inventoryNumber,
    required this.name,
    this.manufacturer = '',
    this.year = '',
    this.size = '',
    this.suggestedCopies = 1,
  });

  factory LabelData.fromItem(
    Map<String, dynamic> item,
    LabelType type,
  ) {
    var year = item['manufacturingYear']?.toString().trim() ?? '';
    if (year.isEmpty) {
      year = DateTime.tryParse(item['purchaseDate']?.toString() ?? '')
              ?.year
              .toString() ??
          '';
    }
    final isBulk = type == LabelType.inventory && item['itemType'] == 'bulk';
    final quantity = num.tryParse(item['quantity']?.toString() ?? '') ?? 1;
    return LabelData(
      type: type,
      inventoryNumber: item['inventoryNumber']?.toString().trim() ?? '',
      name: item['name']?.toString().trim() ?? '',
      manufacturer: item['manufacturer']?.toString().trim() ?? '',
      year: year,
      size: item['size']?.toString().trim() ?? '',
      suggestedCopies: isBulk ? quantity.round().clamp(1, 9999) : 1,
    );
  }
}

class LabelPrintLine {
  final LabelData label;
  final int copies;

  const LabelPrintLine(this.label, this.copies);
}

class LabelPrintJob {
  final String id;
  final LabelPrinter printer;
  final List<LabelPrintLine> lines;
  final DateTime createdAt;
  final String error;

  const LabelPrintJob({
    required this.id,
    required this.printer,
    required this.lines,
    required this.createdAt,
    required this.error,
  });
}

class LabelPrintService extends ChangeNotifier {
  LabelPrintService._();

  static final instance = LabelPrintService._();
  static const _preferencesKey = 'label_printers_v1';
  static const owner = 'Jugend DLRG Ingelheim am Rhein';

  final List<LabelPrinter> _printers = [];
  final List<LabelPrintJob> _queue = [];
  bool _loaded = false;

  bool get supported => labelPrintingSupported;
  bool get supportsWindowsDriver => windowsSystemPrinterSupported;
  bool get supportsZebraPrintConnect => zebraPrintConnectSupported;
  List<LabelPrinter> get printers => List.unmodifiable(_printers);
  List<LabelPrintJob> get queue => List.unmodifiable(_queue);

  Future<List<String>> installedSystemPrinters() => listSystemPrinters();

  Future<bool> printConnectInstalled() => isZebraPrintConnectInstalled();

  Future<void> load() async {
    if (_loaded) return;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_preferencesKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw) as List;
        _printers
          ..clear()
          ..addAll(decoded.map((entry) =>
              LabelPrinter.fromJson(Map<String, dynamic>.from(entry as Map))));
      } catch (_) {
        _printers.clear();
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> savePrinter(LabelPrinter printer) async {
    await load();
    if (printer.defaultInventory) {
      for (var index = 0; index < _printers.length; index++) {
        _printers[index] = _printers[index].copyWith(defaultInventory: false);
      }
    }
    if (printer.defaultClothing) {
      for (var index = 0; index < _printers.length; index++) {
        _printers[index] = _printers[index].copyWith(defaultClothing: false);
      }
    }
    final index = _printers.indexWhere((entry) => entry.id == printer.id);
    if (index == -1) {
      _printers.add(printer);
    } else {
      _printers[index] = printer;
    }
    await _persistPrinters();
  }

  Future<void> deletePrinter(String id) async {
    _printers.removeWhere((entry) => entry.id == id);
    await _persistPrinters();
  }

  LabelPrinter? defaultPrinter(LabelType type) {
    final matching = _printers.where((printer) => type == LabelType.inventory
        ? printer.defaultInventory
        : printer.defaultClothing);
    return matching.firstOrNull ?? _printers.firstOrNull;
  }

  Future<void> _persistPrinters() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _preferencesKey,
      jsonEncode(_printers.map((printer) => printer.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> test(LabelPrinter printer) async {
    final testLabel = LabelData(
      type: LabelType.inventory,
      inventoryNumber: '10050035-00-00-0001',
      name: 'Testdruck',
      manufacturer: 'Zebra ZD621',
      year: DateTime.now().year.toString(),
    );
    await _send(printer, [LabelPrintLine(testLabel, 1)]);
  }

  Future<void> print(
    LabelPrinter printer,
    List<LabelPrintLine> lines,
  ) =>
      _send(printer, lines);

  Future<void> _send(
    LabelPrinter printer,
    List<LabelPrintLine> lines,
  ) async {
    if (!supported) {
      throw UnsupportedError(
          'Etikettendruck ist auf dieser Plattform nicht verfügbar.');
    }
    final zpl = lines
        .where((line) => line.copies > 0)
        .map((line) => buildZpl(line.label, printer, line.copies))
        .join();
    if (zpl.isEmpty) throw StateError('Der Druckauftrag ist leer.');
    final bytes = utf8.encode(zpl);
    switch (printer.connection) {
      case LabelPrinterConnection.network:
        await sendRawLabel(printer.host, printer.port, bytes);
      case LabelPrinterConnection.windowsDriver:
        await sendRawToSystemPrinter(printer.systemPrinterName, bytes);
      case LabelPrinterConnection.zebraPrintConnect:
        await sendRawToZebraPrintConnect(bytes);
    }
  }

  void enqueue(
    LabelPrinter printer,
    List<LabelPrintLine> lines,
    Object error,
  ) {
    _queue.add(LabelPrintJob(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      printer: printer,
      lines: List.unmodifiable(lines),
      createdAt: DateTime.now(),
      error: error.toString(),
    ));
    notifyListeners();
  }

  Future<void> retry(String id) async {
    final job = _queue.firstWhere((entry) => entry.id == id);
    await _send(job.printer, job.lines);
    _queue.removeWhere((entry) => entry.id == id);
    notifyListeners();
  }

  void removeJob(String id) {
    _queue.removeWhere((entry) => entry.id == id);
    notifyListeners();
  }

  String buildZpl(LabelData label, LabelPrinter printer, int copies) {
    String field(String value) => value
        .replaceAll('^', ' ')
        .replaceAll('~', ' ')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .trim();

    final inventoryNumber = field(label.inventoryNumber);
    final name = field(label.name);
    final manufacturer = field(label.manufacturer);
    final year = field(label.year);
    final size = field(label.size);
    final bottomSize = label.type == LabelType.clothing && size.isNotEmpty
        ? '^FO280,174^A0N,25,25^FB116,1,0,R,0^FDGR:$size^FS'
        : '';

    return '''
^XA
^CI28
^PW406
^LL203
^MNY
^MTT
^PR${printer.speed}
~SD${printer.darkness}
^LH0,0
^FO18,12^A0N,19,19^FB370,1,0,C,0^FD$owner^FS
^BY1,2,43
^FO14,42^BCN,43,N,N,N^FD$inventoryNumber^FS
^FO18,88^A0N,18,18^FB370,1,0,C,0^FD$inventoryNumber^FS
^FO18,110^A0N,24,22^FB370,1,0,C,0^FD$name^FS
^FO18,137^A0N,22,20^FB370,1,0,C,0^FD$manufacturer^FS
^FO10,174^A0N,25,25^FDBJ:$year^FS
$bottomSize
^PQ${copies.clamp(1, 9999)}
^XZ
''';
  }
}
