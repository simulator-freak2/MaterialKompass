import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';

import '../services/label_print_service.dart';

bool userMayPrintLabels(Iterable<String> roles) {
  const allowed = {'Materialwart', 'Kleiderwart', 'Vorsitz'};
  return roles.any(allowed.contains);
}

Future<void> showPrinterSettingsDialog(BuildContext context) async {
  final service = LabelPrintService.instance;
  await service.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _PrinterSettingsDialog(),
  );
}

Future<void> showPrintQueueDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _PrintQueueDialog(),
  );
}

Future<bool> showLabelPrintDialog(
  BuildContext context, {
  required List<LabelData> labels,
  required LabelType type,
}) async {
  if (labels.isEmpty) return false;
  final service = LabelPrintService.instance;
  await service.load();
  if (!context.mounted) return false;
  if (!service.supported) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
          'Direkter Etikettendruck ist nur in der Windows- und Android-App verfügbar.'),
    ));
    return false;
  }
  if (service.printers.isEmpty) {
    await showPrinterSettingsDialog(context);
    if (!context.mounted || service.printers.isEmpty) return false;
  }
  final lines = await showDialog<List<LabelPrintLine>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LabelPreviewDialog(labels: labels, type: type),
  );
  if (lines == null || !context.mounted) return false;
  final printer = service.defaultPrinter(type);
  if (printer == null) return false;
  try {
    await service.print(printer, lines);
    if (!context.mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Druckauftrag wurde an „${printer.name}“ gesendet.'),
    ));
    return true;
  } catch (error) {
    if (!context.mounted) return false;
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Drucken fehlgeschlagen'),
        content: Text(
            'Der Auftrag konnte nicht über „${printer.name}“ gedruckt werden.\n\n$error\n\nAuftrag für einen manuellen neuen Versuch zwischenspeichern?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Verwerfen')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Zwischenspeichern')),
        ],
      ),
    );
    if (save == true) service.enqueue(printer, lines, error);
    return false;
  }
}

class LabelPreview extends StatelessWidget {
  final LabelData label;

  const LabelPreview({required this.label, super.key});

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 2,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
        child: LayoutBuilder(builder: (context, constraints) {
          final scale = constraints.maxWidth / 406;
          TextStyle style(double size, {FontWeight? weight}) => TextStyle(
                color: Colors.black,
                fontSize: size * scale,
                height: 1,
                fontWeight: weight ?? FontWeight.w700,
              );
          return Column(
            children: [
              Text(LabelPrintService.owner,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(19)),
              SizedBox(height: 8 * scale),
              Expanded(
                child: bw.BarcodeWidget(
                  barcode: bw.Barcode.code128(),
                  data: label.inventoryNumber,
                  drawText: false,
                  padding: EdgeInsets.zero,
                ),
              ),
              SizedBox(height: 3 * scale),
              Text(label.inventoryNumber, style: style(18)),
              SizedBox(height: 4 * scale),
              Text(label.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(24)),
              SizedBox(height: 3 * scale),
              Text(label.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(22)),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('BJ:${label.year}', style: style(25)),
                  if (label.type == LabelType.clothing && label.size.isNotEmpty)
                    Text('GR:${label.size}', style: style(25)),
                ],
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _LabelPreviewDialog extends StatefulWidget {
  final List<LabelData> labels;
  final LabelType type;

  const _LabelPreviewDialog({required this.labels, required this.type});

  @override
  State<_LabelPreviewDialog> createState() => _LabelPreviewDialogState();
}

class _LabelPreviewDialogState extends State<_LabelPreviewDialog> {
  late final List<TextEditingController> copies;
  int previewIndex = 0;

  @override
  void initState() {
    super.initState();
    copies = widget.labels
        .map((label) =>
            TextEditingController(text: label.suggestedCopies.toString()))
        .toList();
  }

  @override
  void dispose() {
    for (final controller in copies) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final printer = LabelPrintService.instance.defaultPrinter(widget.type);
    return AlertDialog(
      title: const Text('Etikettenvorschau'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LabelPreview(label: widget.labels[previewIndex]),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Drucker: ${printer?.name ?? 'nicht eingerichtet'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              ...List.generate(widget.labels.length, (index) {
                final label = widget.labels[index];
                return ListTile(
                  selected: previewIndex == index,
                  onTap: () => setState(() => previewIndex = index),
                  title: Text('${label.inventoryNumber} · ${label.name}'),
                  trailing: SizedBox(
                    width: 90,
                    child: TextField(
                      controller: copies[index],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Anzahl'),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => showPrinterSettingsDialog(context)
              .then((_) => mounted ? setState(() {}) : null),
          child: const Text('Drucker einrichten'),
        ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton.icon(
          onPressed: printer == null
              ? null
              : () {
                  final lines = <LabelPrintLine>[];
                  for (var index = 0; index < widget.labels.length; index++) {
                    final count = int.tryParse(copies[index].text);
                    if (count == null || count < 1 || count > 9999) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Anzahl muss zwischen 1 und 9999 liegen.')),
                      );
                      return;
                    }
                    lines.add(LabelPrintLine(widget.labels[index], count));
                  }
                  Navigator.pop(context, lines);
                },
          icon: const Icon(Icons.print),
          label: const Text('Drucken'),
        ),
      ],
    );
  }
}

class _PrinterSettingsDialog extends StatefulWidget {
  const _PrinterSettingsDialog();

  @override
  State<_PrinterSettingsDialog> createState() => _PrinterSettingsDialogState();
}

class _PrinterSettingsDialogState extends State<_PrinterSettingsDialog> {
  final service = LabelPrintService.instance;
  bool busy = false;

  Future<void> edit([LabelPrinter? printer]) async {
    final saved = await showDialog<LabelPrinter>(
      context: context,
      builder: (_) => _PrinterEditor(printer: printer),
    );
    if (saved == null) return;
    await service.savePrinter(saved);
    if (mounted) setState(() {});
  }

  Future<void> test(LabelPrinter printer) async {
    setState(() => busy = true);
    try {
      await service.test(printer);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Testetikett wurde gesendet.')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Testdruck fehlgeschlagen: $error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Etikettendrucker einrichten'),
      content: SizedBox(
        width: 650,
        child: service.printers.isEmpty
            ? const Text('Noch kein Drucker eingerichtet.')
            : ListView(
                shrinkWrap: true,
                children: service.printers
                    .map((printer) => Card(
                          child: ListTile(
                            title: Text(printer.name),
                            subtitle: Text(
                              '${switch (printer.connection) {
                                LabelPrinterConnection.network =>
                                  'LAN ${printer.host}:${printer.port}',
                                LabelPrinterConnection.windowsDriver =>
                                  'Windows-Treiber · ${printer.systemPrinterName}',
                                LabelPrinterConnection.zebraPrintConnect =>
                                  'Zebra PrintConnect · Android',
                              }} · Geschwindigkeit ${printer.speed} · Schwärzung ${printer.darkness}'
                              '${printer.defaultInventory ? '\nStandard Inventar' : ''}'
                              '${printer.defaultClothing ? '\nStandard Kleidung' : ''}',
                            ),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  onPressed: busy ? null : () => test(printer),
                                  tooltip: 'Testdruck',
                                  icon: const Icon(Icons.print_outlined),
                                ),
                                IconButton(
                                  onPressed: busy ? null : () => edit(printer),
                                  tooltip: 'Bearbeiten',
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          await service
                                              .deletePrinter(printer.id);
                                          if (mounted) setState(() {});
                                        },
                                  tooltip: 'Löschen',
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        ))
                    .toList(),
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: busy ? null : () => edit(),
          icon: const Icon(Icons.add),
          label: const Text('Drucker hinzufügen'),
        ),
        FilledButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Fertig'),
        ),
      ],
    );
  }
}

class _PrinterEditor extends StatefulWidget {
  final LabelPrinter? printer;
  const _PrinterEditor({this.printer});

  @override
  State<_PrinterEditor> createState() => _PrinterEditorState();
}

class _PrinterEditorState extends State<_PrinterEditor> {
  late final TextEditingController name;
  late final TextEditingController host;
  late final TextEditingController port;
  late LabelPrinterConnection connection;
  String? systemPrinterName;
  List<String> systemPrinters = const [];
  bool loadingConnections = true;
  bool printConnectInstalled = false;
  late double speed;
  late double darkness;
  late bool defaultInventory;
  late bool defaultClothing;

  @override
  void initState() {
    super.initState();
    final printer = widget.printer;
    name = TextEditingController(text: printer?.name ?? 'Zebra ZD621');
    host = TextEditingController(text: printer?.host ?? '');
    port = TextEditingController(text: '${printer?.port ?? 9100}');
    connection = printer?.connection ?? LabelPrinterConnection.network;
    systemPrinterName = printer?.systemPrinterName.isNotEmpty == true
        ? printer!.systemPrinterName
        : null;
    speed = (printer?.speed ?? 4).toDouble();
    darkness = (printer?.darkness ?? 15).toDouble();
    defaultInventory = printer?.defaultInventory ?? true;
    defaultClothing = printer?.defaultClothing ?? true;
    _loadConnections();
  }

  Future<void> _loadConnections() async {
    final service = LabelPrintService.instance;
    final printers = service.supportsWindowsDriver
        ? await service.installedSystemPrinters()
        : const <String>[];
    final printConnect = service.supportsZebraPrintConnect
        ? await service.printConnectInstalled()
        : false;
    if (!mounted) return;
    setState(() {
      systemPrinters = printers;
      if (systemPrinterName != null &&
          !systemPrinters.contains(systemPrinterName)) {
        systemPrinters = [...systemPrinters, systemPrinterName!];
      }
      systemPrinterName ??= systemPrinters.firstOrNull;
      printConnectInstalled = printConnect;
      loadingConnections = false;
    });
  }

  String _connectionLabel(LabelPrinterConnection value) => switch (value) {
        LabelPrinterConnection.network => 'Direkt über LAN (ZPL)',
        LabelPrinterConnection.windowsDriver =>
          'Installierter Windows-Druckertreiber',
        LabelPrinterConnection.zebraPrintConnect =>
          'Zebra PrintConnect (Android)',
      };

  @override
  void dispose() {
    name.dispose();
    host.dispose();
    port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
          widget.printer == null ? 'Drucker hinzufügen' : 'Drucker bearbeiten'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<LabelPrinterConnection>(
              initialValue: connection,
              decoration: const InputDecoration(labelText: 'Anschlussart'),
              items: [
                LabelPrinterConnection.network,
                if (LabelPrintService.instance.supportsWindowsDriver)
                  LabelPrinterConnection.windowsDriver,
                if (LabelPrintService.instance.supportsZebraPrintConnect)
                  LabelPrinterConnection.zebraPrintConnect,
              ]
                  .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text(_connectionLabel(value)),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => connection = value);
              },
            ),
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Anzeigename')),
            if (connection == LabelPrinterConnection.network) ...[
              TextField(
                  controller: host,
                  decoration: const InputDecoration(labelText: 'IP-Adresse')),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Port', hintText: '9100'),
              ),
            ],
            if (connection == LabelPrinterConnection.windowsDriver) ...[
              const SizedBox(height: 12),
              if (loadingConnections)
                const LinearProgressIndicator()
              else if (systemPrinters.isEmpty)
                const Text(
                    'Windows meldet keine installierte Druckerwarteschlange.')
              else
                DropdownButtonFormField<String>(
                  initialValue: systemPrinterName,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Installierter Drucker'),
                  items: systemPrinters
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => systemPrinterName = value),
                ),
            ],
            if (connection == LabelPrinterConnection.zebraPrintConnect) ...[
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  printConnectInstalled ? Icons.check_circle : Icons.error,
                  color: printConnectInstalled ? Colors.green : Colors.red,
                ),
                title: Text(printConnectInstalled
                    ? 'Zebra PrintConnect ist installiert'
                    : 'Zebra PrintConnect ist nicht installiert'),
                subtitle: const Text(
                    'Der Drucker wird in der Zebra-PrintConnect-App gekoppelt.'),
              ),
            ],
            const SizedBox(height: 12),
            Text('Druckgeschwindigkeit: ${speed.round()}'),
            Slider(
              value: speed,
              min: 2,
              max: 6,
              divisions: 4,
              onChanged: (value) => setState(() => speed = value),
            ),
            Text('Schwärzungsgrad: ${darkness.round()}'),
            Slider(
              value: darkness,
              min: 0,
              max: 30,
              divisions: 30,
              onChanged: (value) => setState(() => darkness = value),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: defaultInventory,
              onChanged: (value) =>
                  setState(() => defaultInventory = value ?? false),
              title: const Text('Standarddrucker für Inventar'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: defaultClothing,
              onChanged: (value) =>
                  setState(() => defaultClothing = value ?? false),
              title: const Text('Standarddrucker für Kleidung'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () {
            final parsedPort = int.tryParse(port.text);
            if (name.text.trim().isEmpty ||
                (connection == LabelPrinterConnection.network &&
                    (host.text.trim().isEmpty ||
                        parsedPort == null ||
                        parsedPort < 1 ||
                        parsedPort > 65535)) ||
                (connection == LabelPrinterConnection.windowsDriver &&
                    (systemPrinterName == null ||
                        systemPrinterName!.isEmpty))) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text(
                      'Name und eine gültige Druckerverbindung sind erforderlich.')));
              return;
            }
            Navigator.pop(
              context,
              LabelPrinter(
                id: widget.printer?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: name.text.trim(),
                host: host.text.trim(),
                connection: connection,
                systemPrinterName: systemPrinterName ?? '',
                port: parsedPort ?? 9100,
                speed: speed.round(),
                darkness: darkness.round(),
                defaultInventory: defaultInventory,
                defaultClothing: defaultClothing,
              ),
            );
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class _PrintQueueDialog extends StatefulWidget {
  const _PrintQueueDialog();

  @override
  State<_PrintQueueDialog> createState() => _PrintQueueDialogState();
}

class _PrintQueueDialogState extends State<_PrintQueueDialog> {
  final service = LabelPrintService.instance;
  String? busyId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Zwischengespeicherte Druckaufträge'),
      content: SizedBox(
        width: 620,
        child: service.queue.isEmpty
            ? const Text('Keine Druckaufträge zwischengespeichert.')
            : ListView(
                shrinkWrap: true,
                children: service.queue.map((job) {
                  final count =
                      job.lines.fold<int>(0, (sum, line) => sum + line.copies);
                  return ListTile(
                    title: Text('$count Etikett(en) · ${job.printer.name}'),
                    subtitle: Text(job.error, maxLines: 2),
                    trailing: Wrap(children: [
                      IconButton(
                        tooltip: 'Erneut drucken',
                        onPressed: busyId == null
                            ? () async {
                                setState(() => busyId = job.id);
                                try {
                                  await service.retry(job.id);
                                  if (mounted) setState(() {});
                                } catch (error) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Drucken fehlgeschlagen: $error')));
                                  }
                                } finally {
                                  if (mounted) setState(() => busyId = null);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.refresh),
                      ),
                      IconButton(
                        tooltip: 'Verwerfen',
                        onPressed: busyId == null
                            ? () {
                                service.removeJob(job.id);
                                setState(() {});
                              }
                            : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ]),
                  );
                }).toList(),
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Schließen'),
        ),
      ],
    );
  }
}
