import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';
import '../constants.dart';
import '../services/label_print_service.dart';
import '../widgets/date_input_field.dart';
import '../widgets/label_print_dialogs.dart';
import 'defects_page.dart';

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _formatDate(dynamic value, {bool includeTime = false}) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return '-';
  final date = DateTime.tryParse(raw);
  if (date == null) return raw;
  final formatted =
      '${_twoDigits(date.day)}.${_twoDigits(date.month)}.${date.year}';
  return includeTime
      ? '$formatted ${_twoDigits(date.hour)}:${_twoDigits(date.minute)}'
      : formatted;
}

class InventoryPage extends StatefulWidget {
  final String token;
  final VoidCallback? onLogout;

  const InventoryPage({required this.token, this.onLogout, super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class InventoryFormDialog extends StatefulWidget {
  final Map<String, dynamic>? item;
  final List<Map<String, dynamic>> categories, locations, stocks;

  const InventoryFormDialog({
    this.item,
    required this.categories,
    required this.locations,
    required this.stocks,
    super.key,
  });

  @override
  State<InventoryFormDialog> createState() => _InventoryFormDialogState();
}

class _InventoryFormDialogState extends State<InventoryFormDialog> {
  static const units = [
    'Stück',
    'Set',
    'Paar',
    'Kiste',
    'Packung',
    'Meter',
    'Liter',
    'Kilogramm',
  ];
  final formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  String itemType = 'individual', status = 'Lagernd', unit = 'Stück';
  String? categoryCode, subcategoryCode, locationId, stockId;

  @override
  void initState() {
    super.initState();
    final item = widget.item ?? {};
    String value(String key) => item[key]?.toString() ?? '';
    fields = {
      for (final name in [
        'name',
        'inventoryNumber',
        'quantity',
        'manufacturer',
        'model',
        'serialNumber',
        'manufacturingYear',
        'purchaseDate',
        'purchasePrice',
        'description',
        'notes',
        'department',
        'inspectionIntervalMonths',
        'nextInspectionDate',
      ])
        name: TextEditingController(
          text: name == 'quantity' && value(name).isEmpty
              ? '1'
              : (name == 'purchaseDate' || name == 'nextInspectionDate') &&
                      value(name).isNotEmpty
                  ? _formatDate(value(name))
                  : value(name),
        ),
    };
    itemType = value('itemType').isEmpty ? 'individual' : value('itemType');
    status = value('status').isEmpty ? 'Lagernd' : value('status');
    unit = value('unit').isEmpty ? 'Stück' : value('unit');
    categoryCode = value('categoryCode').isEmpty ? null : value('categoryCode');
    subcategoryCode =
        value('subcategoryCode').isEmpty ? null : value('subcategoryCode');
    locationId = value('locationId').isEmpty ? null : value('locationId');
    stockId =
        value('stockStructureId').isEmpty ? null : value('stockStructureId');
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _text(
    String name,
    String label, {
    bool required = false,
    bool enabled = true,
    bool numeric = false,
    bool wide = false,
    bool date = false,
    int lines = 1,
  }) {
    if (date) {
      return DateInputField(
        controller: fields[name]!,
        label: label,
        width: wide ? 704 : 230,
        required: required,
      );
    }
    return SizedBox(
      width: wide ? 704 : 230,
      child: TextFormField(
        controller: fields[name],
        enabled: enabled,
        maxLines: lines,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          if (required && (value == null || value.trim().isEmpty)) {
            return 'Pflichtfeld';
          }
          return null;
        },
      ),
    );
  }

  Widget _entityDropdown(
    String label,
    String? value,
    List<Map<String, dynamic>> entries,
    ValueChanged<String?> changed, {
    bool stock = false,
  }) {
    return SizedBox(
      width: 230,
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: entries
            .map((entry) => DropdownMenuItem(
                  value: entry['id'].toString(),
                  child: Text(
                    stock
                        ? '${entry['name']} · ${entry['section']}'
                        : entry['name'].toString(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
            .toList(),
        onChanged: changed,
        validator: label.endsWith('*')
            ? (value) => value == null ? 'Pflichtfeld' : null
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mains =
        widget.categories.where((entry) => entry['parentId'] == null).toList();
    final subs = widget.categories
        .where((entry) => entry['parentId'] == categoryCode)
        .toList();
    final availableStocks = widget.stocks
        .where((entry) => entry['locationId'] == locationId)
        .toList();
    return AlertDialog(
      title: Text(
          widget.item == null ? 'Material anlegen' : 'Material bearbeiten'),
      content: SizedBox(
        width: 760,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              _text('name', 'Bezeichnung *', required: true),
              _text(
                'inventoryNumber',
                widget.item == null
                    ? 'Inventarnummer (optional)'
                    : 'Inventarnummer',
                enabled: widget.item == null,
              ),
              _entityDropdown('Hauptkategorie *', categoryCode, mains, (value) {
                setState(() {
                  categoryCode = value;
                  subcategoryCode = null;
                });
              }),
              _entityDropdown('Unterkategorie', subcategoryCode, subs,
                  (value) => setState(() => subcategoryCode = value)),
              _entityDropdown('Standort *', locationId, widget.locations,
                  (value) {
                setState(() {
                  locationId = value;
                  stockId = null;
                });
              }),
              _entityDropdown('Regal/Fach', stockId, availableStocks,
                  (value) => setState(() => stockId = value),
                  stock: true),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: itemType,
                  decoration: const InputDecoration(labelText: 'Artikelart'),
                  items: const [
                    DropdownMenuItem(
                        value: 'individual', child: Text('Einzelartikel')),
                    DropdownMenuItem(
                        value: 'bulk', child: Text('Mengenartikel')),
                  ],
                  onChanged: (value) => setState(() {
                    itemType = value!;
                    if (itemType == 'individual')
                      fields['quantity']!.text = '1';
                  }),
                ),
              ),
              _text('quantity', 'Anzahl *',
                  enabled: itemType == 'bulk', numeric: true),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: units.contains(unit) ? unit : 'Stück',
                  decoration: const InputDecoration(labelText: 'Einheit'),
                  items: units
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => unit = value!,
                ),
              ),
              SizedBox(
                width: 230,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status *'),
                  items: _InventoryPageState.statuses
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => status = value!,
                ),
              ),
              _text('manufacturer', 'Hersteller'),
              _text('model', 'Modell'),
              _text('serialNumber', 'Seriennummer'),
              _text('manufacturingYear', 'Baujahr', numeric: true),
              _text('purchaseDate', 'Anschaffungsdatum', date: true),
              _text('purchasePrice', 'Kaufpreis', numeric: true),
              _text('department', 'Verantwortlicher Fachbereich'),
              _text('inspectionIntervalMonths', 'Prüfintervall (Monate)',
                  numeric: true),
              _text('nextInspectionDate', 'Nächster Prüftermin', date: true),
              _text('description', 'Beschreibung', wide: true, lines: 3),
              _text('notes', 'Notizen', wide: true, lines: 3),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(onPressed: _save, child: const Text('Speichern')),
      ],
    );
  }

  void _save() {
    if (formKey.currentState?.validate() != true) return;
    double? decimal(String name) {
      final value = fields[name]!.text.trim();
      return value.isEmpty ? null : double.tryParse(value.replaceAll(',', '.'));
    }

    Navigator.pop(context, {
      'name': fields['name']!.text.trim(),
      'inventoryNumber': fields['inventoryNumber']!.text.trim(),
      'categoryCode': categoryCode,
      'subcategoryCode': subcategoryCode ?? '',
      'locationId': locationId,
      'stockStructureId': stockId,
      'status': status,
      'itemType': itemType,
      'quantity': itemType == 'individual' ? 1 : decimal('quantity'),
      'unit': unit,
      'manufacturer': fields['manufacturer']!.text.trim(),
      'model': fields['model']!.text.trim(),
      'serialNumber': fields['serialNumber']!.text.trim(),
      'manufacturingYear': fields['manufacturingYear']!.text.trim(),
      'purchaseDate': dateInputToIso(fields['purchaseDate']!.text),
      'purchasePrice': decimal('purchasePrice'),
      'description': fields['description']!.text.trim(),
      'notes': fields['notes']!.text.trim(),
      'department': fields['department']!.text.trim(),
      'inspectionIntervalMonths': decimal('inspectionIntervalMonths'),
      'nextInspectionDate': dateInputToIso(fields['nextInspectionDate']!.text),
    });
  }
}

class _InventoryPageState extends State<InventoryPage> {
  static const statuses = [
    'Lagernd',
    'Ausgegeben',
    'Reserviert',
    'In Prüfung',
    'Defekt',
    'In Reparatur',
    'Ausgesondert',
    'Verloren',
  ];
  final search = TextEditingController();
  List<Map<String, dynamic>> items = [];
  List<Map<String, dynamic>> categories = [];
  List<Map<String, dynamic>> locations = [];
  List<Map<String, dynamic>> stocks = [];
  Set<String> permissions = {};
  Set<String> roles = {};
  final selected = <String>{};
  bool loading = true;
  bool archived = false;
  bool cards = true;
  String? categoryFilter, locationFilter, statusFilter, departmentFilter;
  String dueFilter = 'Alle';

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };
  bool can(String value) => permissions.contains(value);
  bool get canPrintLabels =>
      LabelPrintService.instance.supported && userMayPrintLabels(roles);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _list(http.Response response) =>
      (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final responses = await Future.wait([
        http.get(Uri.parse('$apiBaseUrl/api/material?archived=$archived'),
            headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/categories'), headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/locations'), headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/stock-structures'),
            headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: headers),
      ]);
      if (responses.any((response) => response.statusCode == 401)) {
        widget.onLogout?.call();
        return;
      }
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Inventardaten konnten nicht geladen werden.');
      }
      final user = jsonDecode(responses[4].body)['user'];
      if (!mounted) return;
      setState(() {
        items = _list(responses[0]);
        categories = _list(responses[1]);
        locations = _list(responses[2]);
        stocks = _list(responses[3]);
        permissions = ((user['permissions'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        roles = ((user['roles'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        selected.clear();
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      _message(error.toString(), error: true);
    }
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  Future<dynamic> _request(String path,
      {String method = 'GET', Object? body}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final response = method == 'POST'
        ? await http.post(uri,
            headers: headers, body: body == null ? null : jsonEncode(body))
        : method == 'PUT'
            ? await http.put(uri, headers: headers, body: jsonEncode(body))
            : method == 'DELETE'
                ? await http.delete(uri, headers: headers)
                : await http.get(uri, headers: headers);
    final data =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _message(
          data is Map
              ? data['error']?.toString() ?? 'Aktion fehlgeschlagen.'
              : 'Aktion fehlgeschlagen.',
          error: true);
      return null;
    }
    return data;
  }

  String _name(List<Map<String, dynamic>> source, dynamic id) {
    for (final entry in source) {
      if (entry['id'] == id) return entry['name'].toString();
    }
    return '-';
  }

  List<Map<String, dynamic>> get filtered {
    final query = search.text.trim().toLowerCase();
    final now = DateTime.now();
    final warning = now.add(const Duration(days: 30));
    return items.where((item) {
      final text = [
        item['inventoryNumber'],
        item['name'],
        item['manufacturer'],
        item['model'],
        item['serialNumber'],
        item['description'],
        item['notes'],
        item['department'],
      ].join(' ').toLowerCase();
      final due =
          DateTime.tryParse(item['nextInspectionDate']?.toString() ?? '');
      final dueMatches = dueFilter == 'Alle' ||
          (dueFilter == 'Überfällig' && due != null && due.isBefore(now)) ||
          (dueFilter == 'Bald fällig' &&
              due != null &&
              !due.isBefore(now) &&
              due.isBefore(warning)) ||
          (dueFilter == 'Ohne Termin' && due == null);
      return (query.isEmpty || text.contains(query)) &&
          (categoryFilter == null ||
              item['categoryCode'] == categoryFilter ||
              item['subcategoryCode'] == categoryFilter) &&
          (locationFilter == null || item['locationId'] == locationFilter) &&
          (statusFilter == null || item['status'] == statusFilter) &&
          (departmentFilter == null ||
              item['department'] == departmentFilter) &&
          dueMatches;
    }).toList();
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InventoryFormDialog(
        item: item,
        categories: categories,
        locations: locations,
        stocks: stocks,
      ),
    );
    if (result == null) return;
    final saved = await _request(
      item == null ? '/api/material' : '/api/material/${item['id']}',
      method: item == null ? 'POST' : 'PUT',
      body: result,
    );
    if (saved != null) {
      _message(item == null
          ? 'Material wurde angelegt.'
          : 'Material wurde gespeichert.');
      await _load();
      if (item == null && canPrintLabels && mounted) {
        await _printItems([Map<String, dynamic>.from(saved as Map)]);
      }
    }
  }

  Future<void> _printItems(List<Map<String, dynamic>> source) async {
    await showLabelPrintDialog(
      context,
      labels: source
          .map((item) => LabelData.fromItem(item, LabelType.inventory))
          .where((label) => label.inventoryNumber.isNotEmpty)
          .toList(),
      type: LabelType.inventory,
    );
  }

  Future<void> _printSelected() async {
    final chosen = items
        .where((item) => selected.contains(item['id']?.toString()))
        .toList();
    await _printItems(chosen);
  }

  Future<void> _detail(Map<String, dynamic> item) async {
    while (mounted) {
      final fresh = await _request('/api/material/${item['id']}');
      if (fresh == null || !mounted) return;
      final action = await showDialog<String>(
        context: context,
        builder: (_) => InventoryDetailDialog(
          item: fresh,
          categories: categories,
          locations: locations,
          stocks: stocks,
          canWrite: can('inventory.write'),
          canReportDefect: can('defects.write'),
          canPrint: canPrintLabels,
        ),
      );
      if (action == 'inspection') {
        await _addInspection(fresh);
      } else if (action == 'document') {
        await _addDocument(fresh);
      } else if (action == 'defect') {
        await _addDefect(fresh);
      } else if (action == 'print') {
        await _printItems([Map<String, dynamic>.from(fresh as Map)]);
      } else {
        return;
      }
    }
  }

  Future<void> _addInspection(Map<String, dynamic> item) async {
    final inspector = TextEditingController();
    final date = TextEditingController(
        text: _formatDate(DateTime.now().toIso8601String()));
    final next = TextEditingController(
        text: item['nextInspectionDate'] == null
            ? ''
            : _formatDate(item['nextInspectionDate']));
    final notes = TextEditingController();
    var result = 'Bestanden';
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                title: const Text('Prüfung erfassen'),
                content: SizedBox(
                    width: 440,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      DateInputField(
                          controller: date, label: 'Prüfdatum', required: true),
                      TextField(
                          controller: inspector,
                          decoration:
                              const InputDecoration(labelText: 'Prüfer *')),
                      DropdownButtonFormField<String>(
                          initialValue: result,
                          decoration:
                              const InputDecoration(labelText: 'Ergebnis'),
                          items: ['Bestanden', 'Mangel', 'Nicht bestanden']
                              .map((value) => DropdownMenuItem(
                                  value: value, child: Text(value)))
                              .toList(),
                          onChanged: (value) => update(() => result = value!)),
                      DateInputField(
                          controller: next, label: 'Nächster Prüftermin'),
                      TextField(
                          controller: notes,
                          decoration:
                              const InputDecoration(labelText: 'Notizen'),
                          maxLines: 3),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Speichern'))
                ],
              ),
            ));
    if (confirmed != true) return;
    final inspectionDate = dateInputToIso(date.text);
    final nextInspectionDate = dateInputToIso(next.text);
    if (inspectionDate == null ||
        (next.text.trim().isNotEmpty && nextInspectionDate == null)) {
      _message('Bitte ein gültiges Datum im Format TT.MM.JJJJ eingeben.',
          error: true);
      return;
    }
    final saved = await _request('/api/material/${item['id']}/inspections',
        method: 'POST',
        body: {
          'inspectionDate': inspectionDate,
          'inspector': inspector.text.trim(),
          'result': result,
          'nextInspectionDate': nextInspectionDate,
          'notes': notes.text.trim()
        });
    if (saved != null) _message('Prüfung wurde gespeichert.');
  }

  Future<void> _addDocument(Map<String, dynamic> item) async {
    final picked = await FilePicker.pickFiles(withData: true);
    final file = picked?.files.single;
    if (file?.bytes == null) return;
    final saved = await _request('/api/material/${item['id']}/documents',
        method: 'POST',
        body: {
          'title': file!.name,
          'documentType': 'Anleitung',
          'fileName': file.name,
          'fileBase64': base64Encode(file.bytes!),
        });
    if (saved != null) _message('Dokument wurde hochgeladen.');
  }

  Future<void> _addDefect(Map<String, dynamic> item) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DefectsPage(
        token: widget.token,
        initialEntityType: 'MaterialItem',
        initialEntityId: item['id']?.toString(),
      ),
    ));
    await _load();
  }

  Future<void> _archive(Map<String, dynamic> item) async {
    final action = archived ? 'restore' : 'archive';
    if (await _request('/api/material/${item['id']}/$action', method: 'POST') !=
        null) {
      _message(archived ? 'Eintrag wiederhergestellt.' : 'Eintrag archiviert.');
      await _load();
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Inventareintrag endgültig löschen?'),
        content: Text(
          '${item['inventoryNumber']} · ${item['name']} wird endgültig aus dem Inventar gelöscht. Diese Aktion kann nicht rückgängig gemacht werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Endgültig löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (await _request('/api/material/${item['id']}', method: 'DELETE') !=
        null) {
      _message('Inventareintrag wurde gelöscht.');
      await _load();
    }
  }

  Future<void> _transaction(String action) async {
    final recipient = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final materialSearch = TextEditingController();
    final dialogSelection = Set<String>.from(selected);
    String recipientType = 'person';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final query = materialSearch.text.trim().toLowerCase();
          final availableItems = items.where((item) {
            final eligible = action == 'issue'
                ? (num.tryParse(item['availableQuantity'].toString()) ?? 0) >
                        0 &&
                    !['Defekt', 'In Reparatur', 'Ausgesondert', 'Verloren']
                        .contains(item['status'])
                : (num.tryParse(item['issuedQuantity'].toString()) ?? 0) > 0;
            if (!eligible) return false;
            if (query.isEmpty) return true;
            return [
              item['inventoryNumber'],
              item['name'],
              item['department'],
              _name(categories, item['categoryCode']),
            ].any((value) => value.toString().toLowerCase().contains(query));
          }).toList();
          final eligibleIds =
              availableItems.map((item) => item['id'].toString()).toSet();
          dialogSelection.removeWhere((id) => !eligibleIds.contains(id));
          void selectUniqueMaterial(String value) {
            final normalized = value.trim().toLowerCase();
            if (normalized.isEmpty) return;
            final exactMatches = availableItems
                .where((item) =>
                    item['inventoryNumber'].toString().trim().toLowerCase() ==
                    normalized)
                .toList();
            final match = exactMatches.length == 1
                ? exactMatches.single
                : availableItems.length == 1
                    ? availableItems.single
                    : null;
            if (match == null) return;
            update(() {
              dialogSelection.add(match['id'].toString());
              materialSearch.clear();
            });
          }

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(action == 'issue'
                ? 'Material ausgeben'
                : 'Material zurücknehmen'),
            content: SizedBox(
              width: 680,
              height: 560,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (action == 'issue') ...[
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: recipientType,
                          decoration:
                              const InputDecoration(labelText: 'Empfängertyp'),
                          items: const [
                            DropdownMenuItem(
                                value: 'person', child: Text('Person')),
                            DropdownMenuItem(
                                value: 'purpose',
                                child: Text('Verwendungsziel')),
                          ],
                          onChanged: (value) =>
                              update(() => recipientType = value!),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: recipient,
                          onChanged: (_) => update(() {}),
                          decoration: const InputDecoration(
                              labelText: 'Empfänger/Verwendungsziel *'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: materialSearch,
                    autofocus: true,
                    onChanged: (_) => update(() {}),
                    onSubmitted: selectUniqueMaterial,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Material suchen oder scannen',
                      hintText: 'Name oder Inventarnummer',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: materialSearch.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                materialSearch.clear();
                                update(() {});
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                      '${dialogSelection.length} Materialpositionen ausgewählt'),
                  const SizedBox(height: 4),
                  Expanded(
                    child: availableItems.isEmpty
                        ? const Center(
                            child: Text('Kein passendes Material gefunden.'))
                        : ListView.separated(
                            itemCount: availableItems.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, index) {
                              final item = availableItems[index];
                              final id = item['id'].toString();
                              final amount = action == 'issue'
                                  ? item['availableQuantity']
                                  : item['issuedQuantity'];
                              return CheckboxListTile(
                                value: dialogSelection.contains(id),
                                onChanged: (checked) => update(() =>
                                    checked == true
                                        ? dialogSelection.add(id)
                                        : dialogSelection.remove(id)),
                                title: Text(
                                    '${item['inventoryNumber']} • ${item['name']}'),
                                subtitle: Text(
                                    '${action == 'issue' ? 'Verfügbar' : 'Ausgegeben'}: $amount ${item['unit']} • ${_name(locations, item['locationId'])}'),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: quantity,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Menge je ausgewähltem Eintrag'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Abbrechen')),
              FilledButton(
                  onPressed: dialogSelection.isEmpty ||
                          (action == 'issue' && recipient.text.trim().isEmpty)
                      ? null
                      : () => Navigator.pop(context, true),
                  child: Text(action == 'issue' ? 'Ausgeben' : 'Zurücknehmen')),
            ],
          );
        },
      ),
    );
    if (confirmed != true) return;
    final amount = double.tryParse(quantity.text.replaceAll(',', '.')) ?? 0;
    final result = await _request('/api/material/transactions/bulk',
        method: 'POST',
        body: {
          'action': action,
          'recipientType': recipientType,
          'recipient': recipient.text.trim(),
          'items': dialogSelection
              .map((id) => {'materialId': id, 'quantity': amount})
              .toList(),
        });
    if (result != null) {
      _message('Sammelbuchung wurde durchgeführt.');
      await _load();
    }
  }

  Future<void> _relocate() async {
    final materialSearch = TextEditingController();
    final dialogSelection = Set<String>.from(selected);
    String? locationId;
    String? stockId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        final availableStocks =
            stocks.where((entry) => entry['locationId'] == locationId).toList();
        final query = materialSearch.text.trim().toLowerCase();
        final movableItems = items.where((item) {
          if ((num.tryParse(item['issuedQuantity'].toString()) ?? 0) > 0) {
            return false;
          }
          if (query.isEmpty) return true;
          return [item['inventoryNumber'], item['name'], item['department']]
              .any((value) => value.toString().toLowerCase().contains(query));
        }).toList();
        final movableIds =
            movableItems.map((item) => item['id'].toString()).toSet();
        dialogSelection.removeWhere((id) => !movableIds.contains(id));
        void selectUniqueMaterial(String value) {
          final normalized = value.trim().toLowerCase();
          if (normalized.isEmpty) return;
          final exactMatches = movableItems
              .where((item) =>
                  item['inventoryNumber'].toString().trim().toLowerCase() ==
                  normalized)
              .toList();
          final match = exactMatches.length == 1
              ? exactMatches.single
              : movableItems.length == 1
                  ? movableItems.single
                  : null;
          if (match == null) return;
          update(() {
            dialogSelection.add(match['id'].toString());
            materialSearch.clear();
          });
        }

        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Material umbuchen'),
          content: SizedBox(
              width: 680,
              height: 540,
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      decoration:
                          const InputDecoration(labelText: 'Neuer Standort'),
                      items: locations
                          .map((entry) => DropdownMenuItem(
                              value: entry['id'].toString(),
                              child: Text(entry['name'].toString())))
                          .toList(),
                      onChanged: (value) => update(() {
                        locationId = value;
                        stockId = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: stockId,
                      decoration:
                          const InputDecoration(labelText: 'Regal/Fach'),
                      items: availableStocks
                          .map((entry) => DropdownMenuItem(
                              value: entry['id'].toString(),
                              child: Text(
                                  '${entry['name']} · ${entry['section']}')))
                          .toList(),
                      onChanged: (value) => update(() => stockId = value),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  controller: materialSearch,
                  autofocus: true,
                  onChanged: (_) => update(() {}),
                  onSubmitted: selectUniqueMaterial,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Material suchen oder scannen',
                    hintText: 'Name oder Inventarnummer',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                      '${dialogSelection.length} Materialpositionen ausgewählt'),
                ),
                Expanded(
                  child: movableItems.isEmpty
                      ? const Center(
                          child: Text('Kein passendes Material gefunden.'))
                      : ListView.separated(
                          itemCount: movableItems.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, index) {
                            final item = movableItems[index];
                            final id = item['id'].toString();
                            return CheckboxListTile(
                              value: dialogSelection.contains(id),
                              onChanged: (checked) => update(() =>
                                  checked == true
                                      ? dialogSelection.add(id)
                                      : dialogSelection.remove(id)),
                              title: Text(
                                  '${item['inventoryNumber']} • ${item['name']}'),
                              subtitle: Text(
                                  '${_name(locations, item['locationId'])} · ${_name(stocks, item['stockStructureId'])}'),
                              controlAffinity: ListTileControlAffinity.leading,
                            );
                          },
                        ),
                ),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: locationId == null || dialogSelection.isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Umbuchen')),
          ],
        );
      }),
    );
    if (confirmed != true) return;
    final result =
        await _request('/api/material/relocate/bulk', method: 'POST', body: {
      'materialIds': dialogSelection.toList(),
      'locationId': locationId,
      'stockStructureId': stockId,
    });
    if (result != null) {
      _message('Material wurde umgebucht.');
      await _load();
    }
  }

  Future<void> _scan() async {
    final manual = TextEditingController();
    final cameraSupported = isCameraScanningSupported;
    var completed = false;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Barcode oder QR-Code scannen'),
        content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: manual,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Handscanner / Inventarnummer'),
                onSubmitted: (value) => Navigator.pop(context, value.trim()),
              ),
              if (cameraSupported) ...[
                const SizedBox(height: 16),
                SizedBox(
                    height: 260,
                    child: MobileScanner(onDetect: (capture) {
                      final code = capture.barcodes.isEmpty
                          ? null
                          : capture.barcodes.first.rawValue;
                      if (code != null && !completed) {
                        completed = true;
                        Navigator.pop(context, code);
                      }
                    })),
              ] else
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                      'Der Kamera-Scan ist nur auf Smartphones und Tablets verfügbar. Am PC kann ein USB-Handscanner verwendet werden.'),
                ),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, manual.text.trim()),
              child: const Text('Suchen')),
        ],
      ),
    );
    if (value != null && value.isNotEmpty) setState(() => search.text = value);
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'ods'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file?.bytes == null) return;
    final result =
        await _request('/api/material/import', method: 'POST', body: {
      'fileName': file!.name,
      'fileBase64': base64Encode(file.bytes!),
    });
    if (result != null) {
      _message(
          '${result['imported']} importiert, ${result['skipped']} übersprungen.');
      await _load();
    }
  }

  Future<void> _export(String format) async {
    final data = await _request(
        '/api/material/export/table?format=$format&archived=$archived');
    if (data == null) return;
    final fileName = data['fileName'].toString();
    await FileSaver.instance.saveFile(
      name: fileName.substring(0, fileName.length - format.length - 1),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: format,
      mimeType: MimeType.custom,
    );
    _message('Export wurde erstellt.');
  }

  Widget _filter(
    String label,
    String? value,
    List<MapEntry<String, String>> values,
    ValueChanged<String?> changed,
  ) {
    return SizedBox(
      width: 175,
      child: DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem(value: null, child: Text('Alle')),
          ...values.map((entry) => DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              )),
        ],
        onChanged: changed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final departments = items
        .map((entry) => entry['department']?.toString() ?? '')
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return DefaultTabController(
      length: 2,
      initialIndex: archived ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Inventarverwaltung'),
          actions: [
            IconButton(
                onPressed: _load,
                tooltip: 'Aktualisieren',
                icon: const Icon(Icons.refresh)),
            if (widget.onLogout != null)
              IconButton(
                  onPressed: widget.onLogout,
                  tooltip: 'Abmelden',
                  icon: const Icon(Icons.logout)),
          ],
          bottom: TabBar(
            onTap: (index) {
              final showArchive = index == 1;
              if (showArchive == archived) return;
              archived = showArchive;
              _load();
            },
            tabs: const [
              Tab(text: 'Bestand'),
              Tab(text: 'Historie'),
            ],
          ),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      archived
                          ? 'Archiviertes Material'
                          : 'Material im Bestand',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          SizedBox(
                            width: 340,
                            child: TextField(
                              controller: search,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.search),
                                labelText: 'Inventarnummer oder Volltextsuche',
                                suffixIcon: IconButton(
                                  onPressed: _scan,
                                  tooltip: 'Scannen',
                                  icon: const Icon(Icons.qr_code_scanner),
                                ),
                              ),
                            ),
                          ),
                          _filter(
                            'Kategorie',
                            categoryFilter,
                            categories
                                .map((entry) => MapEntry(entry['id'].toString(),
                                    entry['name'].toString()))
                                .toList(),
                            (value) => setState(() => categoryFilter = value),
                          ),
                          _filter(
                            'Standort',
                            locationFilter,
                            locations
                                .map((entry) => MapEntry(entry['id'].toString(),
                                    entry['name'].toString()))
                                .toList(),
                            (value) => setState(() => locationFilter = value),
                          ),
                          _filter(
                              'Status',
                              statusFilter,
                              statuses
                                  .map((value) => MapEntry(value, value))
                                  .toList(),
                              (value) => setState(() => statusFilter = value)),
                          _filter(
                              'Fachbereich',
                              departmentFilter,
                              departments
                                  .map((value) => MapEntry(value, value))
                                  .toList(),
                              (value) =>
                                  setState(() => departmentFilter = value)),
                          _filter(
                            'Prüfung',
                            dueFilter == 'Alle' ? null : dueFilter,
                            ['Überfällig', 'Bald fällig', 'Ohne Termin']
                                .map((value) => MapEntry(value, value))
                                .toList(),
                            (value) =>
                                setState(() => dueFilter = value ?? 'Alle'),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      if (can('inventory.write') && !archived)
                        _actionButton(
                          label: 'Neues Material anlegen',
                          icon: Icons.add_circle_outline,
                          color: Colors.green.shade700,
                          onPressed: () => _edit(),
                        ),
                      _actionButton(
                        label: 'Scannen',
                        icon: Icons.qr_code_scanner,
                        color: Colors.blue.shade700,
                        onPressed: _scan,
                      ),
                      if (can('inventory.transactions') && !archived)
                        _actionButton(
                          label: 'Ausgeben',
                          icon: Icons.logout,
                          color: Colors.orange.shade700,
                          onPressed: () => _transaction('issue'),
                        ),
                      if (can('inventory.transactions') && !archived)
                        _actionButton(
                          label: 'Zurücknehmen',
                          icon: Icons.login,
                          color: Colors.orange.shade700,
                          onPressed: () => _transaction('return'),
                        ),
                      if (can('inventory.relocate') && !archived)
                        _actionButton(
                          label: 'Umbuchen',
                          icon: Icons.move_down,
                          color: Colors.deepOrange.shade700,
                          onPressed: _relocate,
                        ),
                      if (can('inventory.import') && !archived)
                        _actionButton(
                          label: 'Tabelle importieren',
                          icon: Icons.upload_file,
                          color: Colors.teal.shade700,
                          onPressed: _import,
                        ),
                      if (can('inventory.export'))
                        PopupMenuButton<String>(
                          onSelected: _export,
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                                value: 'xlsx', child: Text('Excel (.xlsx)')),
                            PopupMenuItem(
                                value: 'ods',
                                child: Text('OpenDocument (.ods)')),
                          ],
                          child: IgnorePointer(
                            child: _actionButton(
                              label: 'Tabelle exportieren',
                              icon: Icons.download,
                              color: Colors.indigo.shade700,
                              onPressed: () {},
                            ),
                          ),
                        ),
                      if (canPrintLabels && selected.isNotEmpty)
                        _actionButton(
                          label: 'Etiketten drucken',
                          icon: Icons.print,
                          color: Colors.blueGrey.shade700,
                          onPressed: _printSelected,
                        ),
                      if (canPrintLabels)
                        IconButton(
                          onPressed: () => showPrinterSettingsDialog(context),
                          tooltip: 'Etikettendrucker einrichten',
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      if (canPrintLabels)
                        IconButton(
                          onPressed: () => showPrintQueueDialog(context),
                          tooltip: 'Zwischengespeicherte Druckaufträge',
                          icon: const Icon(Icons.queue),
                        ),
                      if (selected.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 10),
                          child: Text('${selected.length} ausgewählt'),
                        ),
                      IconButton(
                        onPressed: () => setState(() => cards = !cards),
                        tooltip: cards ? 'Tabellenansicht' : 'Kartenansicht',
                        icon: Icon(cards ? Icons.table_rows : Icons.view_list),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(archived
                                  ? 'Noch kein Material im Archiv.'
                                  : 'Keine Inventareinträge gefunden.'),
                            )
                          : cards
                              ? _cardView()
                              : _tableView(),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        backgroundColor: color,
        foregroundColor: Colors.white,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }

  Widget _tableView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('')),
          DataColumn(label: Text('Inventarnummer')),
          DataColumn(label: Text('Bezeichnung')),
          DataColumn(label: Text('Kategorie')),
          DataColumn(label: Text('Standort · Fach')),
          DataColumn(label: Text('Bestand')),
          DataColumn(label: Text('Status')),
          DataColumn(label: Text('Fachbereich')),
          DataColumn(label: Text('Prüftermin')),
          DataColumn(label: Text('Aktionen')),
        ],
        rows: filtered
            .map((item) => DataRow(
                  selected: selected.contains(item['id']),
                  cells: [
                    DataCell(Checkbox(
                      value: selected.contains(item['id']),
                      onChanged: (value) => setState(() => value == true
                          ? selected.add(item['id'].toString())
                          : selected.remove(item['id'])),
                    )),
                    DataCell(Text(item['inventoryNumber']?.toString() ?? '-'),
                        onTap: () => _detail(item)),
                    DataCell(Text(item['name']?.toString() ?? '-'),
                        onTap: () => _detail(item)),
                    DataCell(Text(
                        '${_name(categories, item['categoryCode'])} / ${_name(categories, item['subcategoryCode'])}')),
                    DataCell(Text(
                        '${_name(locations, item['locationId'])} · ${_name(stocks, item['stockStructureId'])}')),
                    DataCell(Text(
                        '${item['availableQuantity']}/${item['quantity']} ${item['unit']}')),
                    DataCell(
                        Chip(label: Text(item['status']?.toString() ?? '-'))),
                    DataCell(Text(item['department']?.toString() ?? '-')),
                    DataCell(Text(_formatDate(item['nextInspectionDate']))),
                    DataCell(Row(children: [
                      IconButton(
                          onPressed: () => _detail(item),
                          tooltip: 'Details',
                          icon: const Icon(Icons.visibility_outlined)),
                      if (canPrintLabels)
                        IconButton(
                            onPressed: () => _printItems([item]),
                            tooltip: 'Etikett drucken',
                            icon: const Icon(Icons.print_outlined)),
                      if (can('inventory.write') && !archived)
                        IconButton(
                            onPressed: () => _edit(item),
                            tooltip: 'Bearbeiten',
                            icon: const Icon(Icons.edit_outlined)),
                      if (can('inventory.archive'))
                        IconButton(
                            onPressed: () => _archive(item),
                            tooltip:
                                archived ? 'Wiederherstellen' : 'Archivieren',
                            icon: Icon(archived
                                ? Icons.unarchive
                                : Icons.archive_outlined)),
                      if (can('inventory.archive') && archived)
                        IconButton(
                            onPressed: () => _delete(item),
                            tooltip: 'Endgültig löschen',
                            color: Colors.red.shade700,
                            icon: const Icon(Icons.delete_outline)),
                    ])),
                  ],
                ))
            .toList(),
      ),
    );
  }

  Widget _cardView() {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, index) {
        final item = filtered[index];
        return Card(
          child: ListTile(
            onTap: () => _detail(item),
            leading: Checkbox(
              value: selected.contains(item['id']),
              onChanged: (value) => setState(() => value == true
                  ? selected.add(item['id'].toString())
                  : selected.remove(item['id'])),
            ),
            title: Text(item['name']?.toString() ?? 'Unbenannt'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    'Inventarnummer: ${item['inventoryNumber']?.toString() ?? '-'}'),
                Text(
                    'Kategorie: ${_name(categories, item['categoryCode'])} / ${_name(categories, item['subcategoryCode'])}'),
                Text(
                    'Standort: ${_name(locations, item['locationId'])} · ${_name(stocks, item['stockStructureId'])}'),
                Text(
                    'Verfügbar: ${item['availableQuantity']} von ${item['quantity']} ${item['unit']}'),
                Text(
                    'Fachbereich: ${item['department']?.toString().isNotEmpty == true ? item['department'] : '-'}'),
                Text(
                    'Nächste Prüfung: ${_formatDate(item['nextInspectionDate'])}'),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Chip(label: Text(item['status']?.toString() ?? '-')),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'details') _detail(item);
                    if (action == 'print') _printItems([item]);
                    if (action == 'edit') _edit(item);
                    if (action == 'archive') _archive(item);
                    if (action == 'delete') _delete(item);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'details',
                      child: ListTile(
                        leading: Icon(Icons.visibility_outlined),
                        title: Text('Details'),
                      ),
                    ),
                    if (canPrintLabels)
                      const PopupMenuItem(
                        value: 'print',
                        child: ListTile(
                          leading: Icon(Icons.print_outlined),
                          title: Text('Etikett drucken'),
                        ),
                      ),
                    if (can('inventory.write') && !archived)
                      const PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Bearbeiten'),
                        ),
                      ),
                    if (can('inventory.archive'))
                      PopupMenuItem(
                        value: 'archive',
                        child: ListTile(
                          leading:
                              Icon(archived ? Icons.unarchive : Icons.archive),
                          title: Text(
                              archived ? 'Wiederherstellen' : 'Archivieren'),
                        ),
                      ),
                    if (can('inventory.archive') && archived)
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline,
                              color: Colors.red.shade700),
                          title: Text('Endgültig löschen',
                              style: TextStyle(color: Colors.red.shade700)),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class InventoryDetailDialog extends StatelessWidget {
  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> categories, locations, stocks;
  final bool canWrite;
  final bool canReportDefect;
  final bool canPrint;

  const InventoryDetailDialog({
    required this.item,
    required this.categories,
    required this.locations,
    required this.stocks,
    required this.canWrite,
    required this.canReportDefect,
    required this.canPrint,
    super.key,
  });

  String _name(List<Map<String, dynamic>> source, dynamic id) {
    for (final entry in source) {
      if (entry['id'] == id) return entry['name'].toString();
    }
    return '-';
  }

  Widget _line(String label, dynamic value) {
    final text = value?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 145,
          child:
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(child: Text(text.isEmpty ? '-' : text)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final movements = (item['movements'] as List?) ?? const [];
    final inspections = (item['inspections'] as List?) ?? const [];
    final documents = (item['documents'] as List?) ?? const [];
    final defects = (item['defects'] as List?) ?? const [];
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(item['name']),
          leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close)),
          actions: [
            if (canPrint)
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'print'),
                icon: const Icon(Icons.print_outlined),
                label: const Text('Etikett'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            if (canReportDefect)
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'defect'),
                icon: const Icon(Icons.report_problem_outlined),
                label: const Text('Mangel'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            if (canWrite)
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'inspection'),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Prüfung'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            if (canWrite)
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'document'),
                icon: const Icon(Icons.upload_file),
                label: const Text('Dokument'),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Wrap(spacing: 24, runSpacing: 24, children: [
            SizedBox(
              width: 430,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Stammdaten',
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 12),
                        _line('Inventarnummer', item['inventoryNumber']),
                        _line('Kategorie',
                            '${_name(categories, item['categoryCode'])} / ${_name(categories, item['subcategoryCode'])}'),
                        _line('Standort',
                            '${_name(locations, item['locationId'])} · ${_name(stocks, item['stockStructureId'])}'),
                        _line('Status', item['status']),
                        _line('Bestand',
                            '${item['availableQuantity']} verfügbar / ${item['quantity']} ${item['unit']}'),
                        _line('Hersteller / Modell',
                            '${item['manufacturer'] ?? ''} ${item['model'] ?? ''}'),
                        _line('Baujahr', item['manufacturingYear']),
                        _line('Seriennummer', item['serialNumber']),
                        _line('Fachbereich', item['department']),
                        _line('Anschaffung',
                            '${_formatDate(item['purchaseDate'])} · ${item['purchasePrice'] ?? '-'} €'),
                        _line('Nächste Prüfung',
                            _formatDate(item['nextInspectionDate'])),
                        _line('Beschreibung', item['description']),
                        _line('Notizen', item['notes']),
                      ]),
                ),
              ),
            ),
            SizedBox(
              width: 430,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(children: [
                    Text('Barcode & QR-Code',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 20),
                    bw.BarcodeWidget(
                      barcode: bw.Barcode.code128(),
                      data: item['inventoryNumber'],
                      height: 90,
                    ),
                    const SizedBox(height: 24),
                    bw.BarcodeWidget(
                      barcode: bw.Barcode.qrCode(),
                      data: item['inventoryNumber'],
                      width: 180,
                      height: 180,
                      drawText: false,
                    ),
                  ]),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 24),
          Text('Bewegungsverlauf',
              style: Theme.of(context).textTheme.titleLarge),
          if (movements.isEmpty)
            const ListTile(title: Text('Noch keine Bewegungen vorhanden.')),
          ...movements.map((entry) => ListTile(
                leading: Icon(entry['action'] == 'issue'
                    ? Icons.logout
                    : entry['action'] == 'return'
                        ? Icons.login
                        : Icons.move_down),
                title: Text(
                    '${entry['action']} · ${entry['quantity']} ${item['unit']}'),
                subtitle: Text(
                    '${entry['recipient'] ?? ''} ${_formatDate(entry['createdAt'], includeTime: true)}'),
              )),
          const SizedBox(height: 16),
          Text('Prüfungen', style: Theme.of(context).textTheme.titleLarge),
          if (inspections.isEmpty)
            const ListTile(title: Text('Noch keine Prüfungen vorhanden.')),
          ...inspections.map((entry) => ListTile(
                leading: const Icon(Icons.fact_check_outlined),
                title: Text(
                    '${entry['result']} · ${_formatDate(entry['inspectionDate'])}'),
                subtitle: Text('${entry['inspector']} ${entry['notes'] ?? ''}'),
              )),
          const SizedBox(height: 16),
          Text('Mängel', style: Theme.of(context).textTheme.titleLarge),
          if (defects.isEmpty)
            const ListTile(title: Text('Keine Mängel erfasst.')),
          ...defects.map((entry) => ListTile(
                leading: const Icon(Icons.report_problem_outlined),
                title: Text(entry['description']),
                subtitle: Text(
                    '${entry['status']} · ${_formatDate(entry['createdAt'], includeTime: true)}'),
              )),
          const SizedBox(height: 16),
          Text('Dokumente', style: Theme.of(context).textTheme.titleLarge),
          if (documents.isEmpty)
            const ListTile(
                title: Text(
                    'Noch keine Anleitungen oder Prüfberichte vorhanden.')),
          ...documents.map((entry) => ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(entry['title']),
                subtitle:
                    Text('${entry['documentType']} · ${entry['fileName']}'),
              )),
        ]),
      ),
    );
  }
}
