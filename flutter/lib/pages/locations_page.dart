import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';
import '../constants.dart';
import '../services/file_save_mime_type.dart';
import '../services/label_print_service.dart';
import '../widgets/label_print_dialogs.dart';

class LocationsPage extends StatefulWidget {
  final String token;

  const LocationsPage({required this.token, super.key});

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  List<Map<String, dynamic>> hierarchy = [];
  List<Map<String, dynamic>> boxes = [];
  List<Map<String, dynamic>> assignments = [];
  List<Map<String, dynamic>> stocktakes = [];
  List<Map<String, dynamic>> materials = [];
  List<Map<String, dynamic>> clothing = [];
  List<Map<String, dynamic>> categories = [];
  Set<String> permissions = {};
  bool loading = true;
  final search = TextEditingController();

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  bool get canWrite => permissions.contains('locations.write');
  bool get canCount => permissions.contains('inventory.write');
  bool get canImport => permissions.contains('inventory.import');
  bool get canExport => permissions.contains('inventory.export');

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

  List<Map<String, dynamic>> _maps(dynamic value) =>
      (value as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();

  Future<dynamic> _request(String path,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final response = switch (method) {
      'GET' => await http.get(uri, headers: headers),
      'POST' =>
        await http.post(uri, headers: headers, body: jsonEncode(body ?? {})),
      'PUT' =>
        await http.put(uri, headers: headers, body: jsonEncode(body ?? {})),
      _ => throw ArgumentError('Nicht unterstützte Methode'),
    };
    dynamic decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {}
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return decoded;
    final message = decoded is Map
        ? decoded['error']?.toString() ?? 'Aktion fehlgeschlagen.'
        : 'Aktion fehlgeschlagen.';
    if (mounted) _message(message, error: true);
    return null;
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final responses = await Future.wait([
      _request('/api/storage/hierarchy'),
      _request('/api/storage/boxes'),
      _request('/api/storage/assignments'),
      _request('/api/stocktakes'),
      _request('/api/material'),
      _request('/api/clothing'),
      _request('/api/categories'),
      _request('/api/auth/me'),
    ]);
    if (!mounted) return;
    setState(() {
      hierarchy = _maps(responses[0]);
      boxes = _maps(responses[1]);
      assignments = _maps(responses[2]);
      stocktakes = _maps(responses[3]);
      materials = _maps(responses[4]);
      clothing = _maps(responses[5]);
      categories = _maps(responses[6]);
      final user = responses[7] is Map ? responses[7]['user'] as Map? : null;
      permissions = (user?['permissions'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toSet();
      loading = false;
    });
  }

  void _message(String value, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(value),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  Future<void> _editLocation([Map<String, dynamic>? location]) async {
    final keys = [
      'name',
      'code',
      'type',
      'street',
      'houseNumber',
      'postalCode',
      'city',
      'country',
      'building',
      'addressExtra',
      'contactName',
      'contactPhone',
      'notes'
    ];
    final fields = {
      for (final key in keys)
        key: TextEditingController(
            text: location?[key]?.toString() ??
                (key == 'country' ? 'Deutschland' : ''))
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title:
            Text(location == null ? 'Standort anlegen' : 'Standort bearbeiten'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final entry in [
                  ('name', 'Name *'),
                  ('code', 'Kürzel *'),
                  ('type', 'Typ *'),
                  ('street', 'Straße *'),
                  ('houseNumber', 'Hausnummer *'),
                  ('postalCode', 'PLZ *'),
                  ('city', 'Ort *'),
                  ('country', 'Land *'),
                  ('building', 'Gebäude'),
                  ('addressExtra', 'Adresszusatz'),
                  ('contactName', 'Ansprechpartner'),
                  ('contactPhone', 'Telefon'),
                ])
                  SizedBox(
                      width: 220,
                      child: TextField(
                        controller: fields[entry.$1],
                        decoration: InputDecoration(labelText: entry.$2),
                      )),
                SizedBox(
                    width: 684,
                    child: TextField(
                      controller: fields['notes'],
                      maxLines: 2,
                      decoration:
                          const InputDecoration(labelText: 'Bemerkungen'),
                    )),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              final result = await _request(
                location == null
                    ? '/api/storage/locations'
                    : '/api/storage/locations/${location['id']}',
                method: location == null ? 'POST' : 'PUT',
                body: {
                  for (final entry in fields.entries)
                    entry.key: entry.value.text.trim()
                },
              );
              if (result != null && dialogContext.mounted)
                Navigator.pop(dialogContext, true);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    for (final controller in fields.values) {
      controller.dispose();
    }
    if (saved == true) await _load();
  }

  Future<void> _editHierarchyEntity({
    required String type,
    required String parentField,
    required String parentId,
    Map<String, dynamic>? entity,
  }) async {
    final labels = {
      'racks': 'Regal',
      'levels': 'Ebene',
      'places': 'Lagerplatz'
    };
    final label = labels[type]!;
    final number =
        TextEditingController(text: entity?['number']?.toString() ?? '');
    final name = TextEditingController(text: entity?['name']?.toString() ?? '');
    final sortOrder =
        TextEditingController(text: entity?['sortOrder']?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(entity == null ? '$label anlegen' : '$label bearbeiten'),
        content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: number,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Nummer *')),
              TextField(
                  controller: name,
                  decoration:
                      const InputDecoration(labelText: 'Bezeichnung *')),
              TextField(
                  controller: sortOrder,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Sortierung')),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () async {
                final result = await _request(
                  entity == null
                      ? '/api/storage/$type'
                      : '/api/storage/$type/${entity['id']}',
                  method: entity == null ? 'POST' : 'PUT',
                  body: {
                    parentField: parentId,
                    'number': int.tryParse(number.text),
                    'name': name.text.trim(),
                    'sortOrder': int.tryParse(sortOrder.text),
                  },
                );
                if (result != null && dialogContext.mounted)
                  Navigator.pop(dialogContext, true);
              },
              child: const Text('Speichern')),
        ],
      ),
    );
    number.dispose();
    name.dispose();
    sortOrder.dispose();
    if (saved == true) await _load();
  }

  Future<void> _deactivate(String type, Map<String, dynamic> entity) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Element deaktivieren?'),
        content: const Text(
            'Das Element und seine Historie bleiben erhalten. Neue Zuordnungen sind danach nicht mehr möglich.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Deaktivieren')),
        ],
      ),
    );
    if (confirmed == true &&
        await _request('/api/storage/$type/${entity['id']}/deactivate',
                method: 'POST') !=
            null) {
      await _load();
    }
  }

  Future<void> _bulkCreate(Map<String, dynamic> location) async {
    final rackStart = TextEditingController(text: '1');
    final rackCount = TextEditingController(text: '1');
    final levelCount = TextEditingController(text: '5');
    final placeCount = TextEditingController(text: '4');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Lagerstruktur für ${location['name']} erzeugen'),
        content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: rackStart,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Erste Regalnummer')),
              TextField(
                  controller: rackCount,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Anzahl Regale')),
              TextField(
                  controller: levelCount,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Ebenen je Regal')),
              TextField(
                  controller: placeCount,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Plätze je Ebene')),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Erzeugen')),
        ],
      ),
    );
    if (confirmed == true) {
      final result =
          await _request('/api/storage/bulk-create', method: 'POST', body: {
        'locationId': location['id'],
        'rackStart': int.tryParse(rackStart.text),
        'rackCount': int.tryParse(rackCount.text),
        'levelsPerRack': int.tryParse(levelCount.text),
        'placesPerLevel': int.tryParse(placeCount.text),
      });
      if (result != null) {
        _message(
            '${result['racks']} Regale, ${result['levels']} Ebenen und ${result['places']} Plätze angelegt.');
        await _load();
      }
    }
    rackStart.dispose();
    rackCount.dispose();
    levelCount.dispose();
    placeCount.dispose();
  }

  List<Map<String, dynamic>> get allPlaces => [
        for (final location in hierarchy)
          for (final rack in _maps(location['racks']))
            for (final level in _maps(rack['levels']))
              for (final place in _maps(level['places']))
                {
                  ...place,
                  'locationId': location['id'],
                  'locationName': location['name'],
                  'rackId': rack['id'],
                  'rackName': rack['name'],
                  'levelId': level['id'],
                  'levelName': level['name'],
                }
      ];

  Future<void> _editBox([Map<String, dynamic>? box]) async {
    final fields = {
      for (final key in [
        'name',
        'type',
        'length',
        'width',
        'height',
        'maxLoadKg'
      ])
        key: TextEditingController(
            text: switch (key) {
          'length' => box?['dimensionsCm']?['length']?.toString() ?? '',
          'width' => box?['dimensionsCm']?['width']?.toString() ?? '',
          'height' => box?['dimensionsCm']?['height']?.toString() ?? '',
          _ => box?[key]?.toString() ?? '',
        })
    };
    String? placeId = box?['storagePlaceId']?.toString();
    var status = box?['status']?.toString() ?? 'aktiv';
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text(box == null
                    ? 'Kiste anlegen'
                    : 'Kiste bearbeiten / verschieben'),
                content: SizedBox(
                    width: 680,
                    child: SingleChildScrollView(
                        child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                            width: 320,
                            child: TextField(
                                controller: fields['name'],
                                decoration: const InputDecoration(
                                    labelText: 'Bezeichnung *'))),
                        SizedBox(
                            width: 320,
                            child: TextField(
                                controller: fields['type'],
                                decoration:
                                    const InputDecoration(labelText: 'Typ'))),
                        SizedBox(
                            width: 320,
                            child: DropdownButtonFormField<String>(
                              initialValue: placeId,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Lagerplatz *'),
                              items: allPlaces
                                  .where((entry) => entry['active'] != false)
                                  .map((place) => DropdownMenuItem(
                                        value: place['id'].toString(),
                                        child: Text(
                                            '${place['code']} · ${place['locationName']}'),
                                      ))
                                  .toList(),
                              onChanged: (value) =>
                                  update(() => placeId = value),
                            )),
                        SizedBox(
                            width: 320,
                            child: DropdownButtonFormField<String>(
                              initialValue: status,
                              decoration:
                                  const InputDecoration(labelText: 'Status'),
                              items: [
                                'aktiv',
                                'gesperrt',
                                'defekt',
                                'unterwegs',
                                'deaktiviert',
                                'archiviert'
                              ]
                                  .map((value) => DropdownMenuItem(
                                      value: value, child: Text(value)))
                                  .toList(),
                              onChanged: (value) =>
                                  update(() => status = value!),
                            )),
                        for (final entry in [
                          ('length', 'Länge (cm)'),
                          ('width', 'Breite (cm)'),
                          ('height', 'Höhe (cm)'),
                          ('maxLoadKg', 'Max. Last (kg)')
                        ])
                          SizedBox(
                              width: 155,
                              child: TextField(
                                  controller: fields[entry.$1],
                                  keyboardType: TextInputType.number,
                                  decoration:
                                      InputDecoration(labelText: entry.$2))),
                      ],
                    ))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () async {
                        final result = await _request(
                          box == null
                              ? '/api/storage/boxes'
                              : '/api/storage/boxes/${box['id']}',
                          method: box == null ? 'POST' : 'PUT',
                          body: {
                            'name': fields['name']!.text.trim(),
                            'type': fields['type']!.text.trim(),
                            'storagePlaceId': placeId,
                            'status': status,
                            'dimensions': {
                              'length': num.tryParse(fields['length']!.text),
                              'width': num.tryParse(fields['width']!.text),
                              'height': num.tryParse(fields['height']!.text),
                            },
                            'maxLoadKg':
                                num.tryParse(fields['maxLoadKg']!.text),
                          },
                        );
                        if (result != null && dialogContext.mounted)
                          Navigator.pop(dialogContext, true);
                      },
                      child: const Text('Speichern')),
                ],
              )),
    );
    for (final controller in fields.values) {
      controller.dispose();
    }
    if (saved == true) await _load();
  }

  Map<String, dynamic>? _item(String type, String id) {
    final source = type == 'material' ? materials : clothing;
    return source.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['id'] == id,
          orElse: () => null,
        );
  }

  Future<void> _assignItem({Map<String, dynamic>? initialBox}) async {
    var entityType = 'material';
    String? entityId;
    String? placeId = initialBox?['storagePlaceId']?.toString();
    String? boxId = initialBox?['id']?.toString();
    final quantity = TextEditingController(text: '1');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
        final items = entityType == 'material' ? materials : clothing;
        final availableBoxes = boxes
            .where((box) => box['storagePlaceId']?.toString() == placeId)
            .toList();
        return AlertDialog(
          title: const Text('Artikel zuordnen'),
          content: SizedBox(
              width: 620,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  initialValue: entityType,
                  decoration: const InputDecoration(labelText: 'Bereich'),
                  items: const [
                    DropdownMenuItem(
                        value: 'material', child: Text('Inventar')),
                    DropdownMenuItem(
                        value: 'clothing', child: Text('Kleiderkammer')),
                  ],
                  onChanged: (value) => update(() {
                    entityType = value!;
                    entityId = null;
                  }),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey(entityType),
                  initialValue: entityId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Artikel *'),
                  items: items
                      .map((item) => DropdownMenuItem(
                            value: item['id'].toString(),
                            child: Text(
                                '${item['inventoryNumber']} · ${item['name']}',
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (value) => update(() => entityId = value),
                ),
                DropdownButtonFormField<String>(
                  initialValue: placeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Lagerplatz *'),
                  items: allPlaces
                      .map((place) => DropdownMenuItem(
                            value: place['id'].toString(),
                            child: Text(
                                '${place['code']} · ${place['locationName']}'),
                          ))
                      .toList(),
                  onChanged: (value) => update(() {
                    placeId = value;
                    boxId = null;
                  }),
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('$placeId-${availableBoxes.length}'),
                  initialValue: boxId,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Kiste (optional)'),
                  items: [
                    const DropdownMenuItem(
                        value: null, child: Text('Lose auf dem Lagerplatz')),
                    ...availableBoxes.map((box) => DropdownMenuItem(
                          value: box['id'].toString(),
                          child: Text(
                              '${box['inventoryNumber']} · ${box['name']}'),
                        )),
                  ],
                  onChanged: (value) => update(() => boxId = value),
                ),
                if (entityType == 'material')
                  TextField(
                      controller: quantity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Menge (bei Mengenartikeln)')),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () async {
                  final result = await _request('/api/storage/assignments',
                      method: 'POST',
                      body: {
                        'entityType': entityType,
                        'entityId': entityId,
                        'storagePlaceId': placeId,
                        'boxId': boxId,
                        'quantity': num.tryParse(quantity.text),
                      });
                  if (result != null && dialogContext.mounted)
                    Navigator.pop(dialogContext, true);
                },
                child: const Text('Zuordnen')),
          ],
        );
      }),
    );
    quantity.dispose();
    if (saved == true) await _load();
  }

  Future<void> _showCodes(Map<String, dynamic> box) async {
    final number = box['inventoryNumber'].toString();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${box['name']} · $number'),
        content: SizedBox(
            width: 560,
            child: Row(children: [
              Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Barcode'),
                SizedBox(
                    height: 130,
                    child: bw.BarcodeWidget(
                        barcode: bw.Barcode.code128(), data: number)),
              ])),
              const SizedBox(width: 24),
              Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('QR-Code'),
                SizedBox(
                    height: 180,
                    child: bw.BarcodeWidget(
                        barcode: bw.Barcode.qrCode(), data: number)),
              ])),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Schließen')),
          FilledButton.icon(
            onPressed: () => showLabelPrintDialog(context,
                labels: [
                  LabelData(
                      type: LabelType.inventory,
                      inventoryNumber: number,
                      name: box['name'].toString())
                ],
                type: LabelType.inventory),
            icon: const Icon(Icons.print_outlined),
            label: const Text('Etikett drucken'),
          ),
        ],
      ),
    );
  }

  Future<String?> _scanCode() async {
    final manual = TextEditingController();
    var completed = false;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Barcode oder QR-Code scannen'),
        content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: manual,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Handscanner / Kennung'),
                onSubmitted: (value) =>
                    Navigator.pop(dialogContext, value.trim()),
              ),
              if (isCameraScanningSupported) ...[
                const SizedBox(height: 12),
                SizedBox(
                    height: 260,
                    child: MobileScanner(onDetect: (capture) {
                      final code = capture.barcodes.firstOrNull?.rawValue;
                      if (code != null && !completed) {
                        completed = true;
                        Navigator.pop(dialogContext, code);
                      }
                    })),
              ] else
                const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                        'Am PC kann ein USB-Handscanner verwendet werden.')),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, manual.text.trim()),
              child: const Text('Übernehmen')),
        ],
      ),
    );
    manual.dispose();
    return result;
  }

  Future<void> _createStocktake() async {
    final name = TextEditingController(
        text:
            'Inventur ${DateTime.now().day}.${DateTime.now().month}.${DateTime.now().year}');
    var scopeType = 'location';
    String? scopeId = hierarchy.firstOrNull?['id']?.toString();
    List<DropdownMenuItem<String>> choices(String type) {
      if (type == 'location')
        return hierarchy
            .map((item) => DropdownMenuItem(
                value: item['id'].toString(),
                child: Text(item['name'].toString())))
            .toList();
      if (type == 'rack')
        return [
          for (final location in hierarchy)
            for (final item in _maps(location['racks']))
              DropdownMenuItem(
                  value: item['id'].toString(),
                  child: Text('${location['name']} · ${item['name']}'))
        ];
      if (type == 'level')
        return [
          for (final location in hierarchy)
            for (final rack in _maps(location['racks']))
              for (final item in _maps(rack['levels']))
                DropdownMenuItem(
                    value: item['id'].toString(),
                    child: Text(
                        '${location['name']} · ${rack['name']} · ${item['name']}'))
        ];
      if (type == 'place')
        return allPlaces
            .map((item) => DropdownMenuItem(
                value: item['id'].toString(),
                child: Text(item['code'].toString())))
            .toList();
      if (type == 'box')
        return boxes
            .map((item) => DropdownMenuItem(
                value: item['id'].toString(),
                child: Text('${item['inventoryNumber']} · ${item['name']}')))
            .toList();
      if (type == 'category')
        return categories
            .map((item) => DropdownMenuItem(
                value: item['id'].toString(),
                child: Text(item['name'].toString())))
            .toList();
      return const [];
    }

    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: const Text('Inventur planen'),
                content: SizedBox(
                    width: 560,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          decoration: const InputDecoration(
                              labelText: 'Bezeichnung *')),
                      DropdownButtonFormField<String>(
                        initialValue: scopeType,
                        decoration: const InputDecoration(labelText: 'Bereich'),
                        items: const [
                          DropdownMenuItem(
                              value: 'location',
                              child: Text('Gesamter Standort')),
                          DropdownMenuItem(value: 'rack', child: Text('Regal')),
                          DropdownMenuItem(
                              value: 'level', child: Text('Ebene')),
                          DropdownMenuItem(
                              value: 'place', child: Text('Lagerplatz')),
                          DropdownMenuItem(value: 'box', child: Text('Kiste')),
                          DropdownMenuItem(
                              value: 'inventory',
                              child: Text('Gesamtes Inventar')),
                          DropdownMenuItem(
                              value: 'wardrobe',
                              child: Text('Gesamte Kleiderkammer')),
                          DropdownMenuItem(
                              value: 'category', child: Text('Kategorie')),
                        ],
                        onChanged: (value) => update(() {
                          scopeType = value!;
                          scopeId = choices(scopeType).firstOrNull?.value;
                        }),
                      ),
                      if (!['inventory', 'wardrobe'].contains(scopeType))
                        DropdownButtonFormField<String>(
                          key: ValueKey(scopeType),
                          initialValue: scopeId,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Auswahl *'),
                          items: choices(scopeType),
                          onChanged: (value) => update(() => scopeId = value),
                        ),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () async {
                        final result = await _request('/api/stocktakes',
                            method: 'POST',
                            body: {
                              'name': name.text.trim(),
                              'scopeType': scopeType,
                              'scopeId': scopeId,
                            });
                        if (result != null && dialogContext.mounted)
                          Navigator.pop(dialogContext, true);
                      },
                      child: const Text('Planen')),
                ],
              )),
    );
    name.dispose();
    if (created == true) await _load();
  }

  Future<void> _startStocktake(Map<String, dynamic> stocktake) async {
    if (await _request('/api/stocktakes/${stocktake['id']}/start',
            method: 'POST') !=
        null) {
      await _load();
    }
  }

  Future<void> _countEntry(
      Map<String, dynamic> stocktake, Map<String, dynamic> entry) async {
    final quantity = TextEditingController(
        text: entry['resolvedQuantity']?.toString() ?? '');
    final notes = TextEditingController(text: entry['notes']?.toString() ?? '');
    var present = entry['resolvedQuantity'] == null
        ? true
        : entry['resolvedQuantity'] == 1;
    var control = entry['needsRecount'] == true;
    String? foundPlaceId = entry['foundStoragePlaceId']?.toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: Text('${entry['inventoryNumber']} · ${entry['name']}'),
                content: SizedBox(
                    width: 580,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          'Soll: ${entry['expectedQuantity']} · ${entry['placeCode']}${entry['boxNumber'] == null ? '' : ' · ${entry['boxNumber']}'}'),
                      if (entry['itemType'] == 'individual')
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: present,
                          title: const Text('Vorhanden'),
                          onChanged: (value) => update(() => present = value),
                        )
                      else
                        TextField(
                            controller: quantity,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Gezählte Menge *')),
                      DropdownButtonFormField<String>(
                        initialValue: foundPlaceId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Gefundener Lagerplatz (optional)'),
                        items: allPlaces
                            .map((place) => DropdownMenuItem(
                                value: place['id'].toString(),
                                child: Text(place['code'].toString())))
                            .toList(),
                        onChanged: (value) =>
                            update(() => foundPlaceId = value),
                      ),
                      TextField(
                          controller: notes,
                          maxLines: 2,
                          decoration: const InputDecoration(
                              labelText: 'Zustand / Bemerkung')),
                      if (entry['needsRecount'] == true)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: control,
                          title: const Text('Kontrollzählung'),
                          subtitle: const Text(
                              'Die bisherigen Zählungen weichen voneinander ab.'),
                          onChanged: (value) =>
                              update(() => control = value ?? false),
                        ),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Zählung speichern')),
                ],
              )),
    );
    if (confirmed == true) {
      final result = await _request('/api/stocktakes/${stocktake['id']}/counts',
          method: 'POST',
          body: {
            'entryId': entry['id'],
            'present': present,
            'quantity': num.tryParse(quantity.text),
            'notes': notes.text.trim(),
            'condition': notes.text.trim(),
            'foundStoragePlaceId': foundPlaceId,
            'control': control,
          });
      if (result != null) await _load();
    }
    quantity.dispose();
    notes.dispose();
  }

  Future<void> _showStocktake(Map<String, dynamic> stocktake) async {
    while (mounted) {
      final fresh = stocktakes.cast<Map<String, dynamic>?>().firstWhere(
            (entry) => entry?['id'] == stocktake['id'],
            orElse: () => stocktake,
          )!;
      final action = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(fresh['name'].toString()),
          content: SizedBox(
            width: 850,
            height: 520,
            child: _maps(fresh['entries']).isEmpty
                ? const Center(
                    child:
                        Text('Die Sollbestände werden beim Start eingefroren.'))
                : ListView.separated(
                    itemCount: _maps(fresh['entries']).length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final entry = _maps(fresh['entries'])[index];
                      final resolved = entry['resolvedQuantity'];
                      return ListTile(
                        leading: Icon(entry['needsRecount'] == true
                            ? Icons.warning_amber
                            : resolved == null
                                ? Icons.radio_button_unchecked
                                : Icons.check_circle_outline),
                        title: Text(
                            '${entry['inventoryNumber']} ${entry['name']}'),
                        subtitle: Text(
                            '${entry['placeCode']} · Soll ${entry['expectedQuantity']} · Ist ${resolved ?? 'offen'}'),
                        onTap: fresh['status'] == 'Laufend' &&
                                !entry['entityType']
                                    .toString()
                                    .startsWith('empty-')
                            ? () => Navigator.pop(dialogContext, 'count:$index')
                            : null,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Schließen')),
            if (fresh['status'] == 'Laufend' && canImport)
              TextButton.icon(
                  onPressed: () => Navigator.pop(dialogContext, 'import'),
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Liste importieren')),
            if (canExport)
              PopupMenuButton<String>(
                tooltip: 'Liste exportieren',
                onSelected: (format) =>
                    Navigator.pop(dialogContext, 'export:$format'),
                itemBuilder: (_) => ['xlsx', 'ods', 'csv', 'pdf']
                    .map((format) => PopupMenuItem(
                        value: format, child: Text(format.toUpperCase())))
                    .toList(),
                child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.download),
                      SizedBox(width: 6),
                      Text('Liste')
                    ])),
              ),
            if (fresh['status'] == 'Laufend' && canCount)
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, 'complete'),
                  child: const Text('Abschließen')),
          ],
        ),
      );
      if (action == null) return;
      if (action.startsWith('count:')) {
        final index = int.parse(action.split(':').last);
        await _countEntry(fresh, _maps(fresh['entries'])[index]);
      } else if (action.startsWith('export:')) {
        await _exportStocktake(fresh, action.split(':').last);
      } else if (action == 'import') {
        await _importStocktake(fresh);
      } else if (action == 'complete') {
        final result = await _request('/api/stocktakes/${fresh['id']}/complete',
            method: 'POST');
        if (result != null) {
          _message('Inventur abgeschlossen und Bestände korrigiert.');
          await _load();
        }
      }
    }
  }

  Future<void> _exportStocktake(
      Map<String, dynamic> stocktake, String format) async {
    final data = await _request(
        '/api/stocktakes/${stocktake['id']}/export?format=$format');
    if (data == null) return;
    final fileName = data['fileName'].toString();
    await FileSaver.instance.saveFile(
      name: fileName.substring(0, fileName.length - format.length - 1),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: format,
      mimeType: MimeType.custom,
      customMimeType: fileMimeType(format),
    );
    _message('Inventurliste wurde erstellt.');
  }

  Future<void> _importStocktake(Map<String, dynamic> stocktake) async {
    final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'ods'],
        withData: true);
    final file = picked?.files.single;
    if (file?.bytes == null) return;
    final result = await _request('/api/stocktakes/${stocktake['id']}/import',
        method: 'POST',
        body: {
          'fileName': file!.name,
          'fileBase64': base64Encode(file.bytes!),
        });
    if (result != null) {
      _message('${result['imported']} Zählungen zur Prüfung übernommen.');
      await _load();
    }
  }

  Widget _structureTab() {
    final query = search.text.trim().toLowerCase();
    final filtered = hierarchy.where((location) {
      if (query.isEmpty) return true;
      final locationText = [
        location['name'],
        location['code'],
        location['street'],
        location['postalCode'],
        location['city']
      ].join(' ').toLowerCase();
      if (locationText.contains(query)) return true;
      return _maps(location['racks']).any((rack) =>
          rack.toString().toLowerCase().contains(query) ||
          _maps(rack['levels']).any((level) =>
              level.toString().toLowerCase().contains(query) ||
              _maps(level['places']).any(
                  (place) => place.toString().toLowerCase().contains(query))));
    }).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: 'Standort, Adresse oder Lagerplatz suchen',
            suffixIcon: IconButton(
                onPressed: () async {
                  final value = await _scanCode();
                  if (value != null) setState(() => search.text = value);
                },
                icon: const Icon(Icons.qr_code_scanner)),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      Expanded(
          child: filtered.isEmpty
              ? const Center(
                  child: Text('Noch keine passenden Standorte vorhanden.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                  children: [
                      for (final location in filtered)
                        Card(
                            child: ExpansionTile(
                          leading: Icon(location['active'] == false
                              ? Icons.warehouse_outlined
                              : Icons.warehouse),
                          title:
                              Text('${location['name']} (${location['code']})'),
                          subtitle: Text(
                              '${location['street']} ${location['houseNumber']}, ${location['postalCode']} ${location['city']} · ${location['type']}'),
                          trailing: canWrite
                              ? PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'rack')
                                      _editHierarchyEntity(
                                          type: 'racks',
                                          parentField: 'locationId',
                                          parentId: location['id'].toString());
                                    if (value == 'bulk') _bulkCreate(location);
                                    if (value == 'edit')
                                      _editLocation(location);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'rack',
                                        child: Text('Regal hinzufügen')),
                                    PopupMenuItem(
                                        value: 'bulk',
                                        child: Text(
                                            'Struktur gesammelt erzeugen')),
                                    PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Standort bearbeiten')),
                                  ],
                                )
                              : null,
                          children: [
                            for (final rack in _maps(location['racks']))
                              Padding(
                                padding: const EdgeInsets.only(left: 18),
                                child: ExpansionTile(
                                  leading: const Icon(Icons.shelves),
                                  title: Text(
                                      '${rack['name']} · R${rack['number'].toString().padLeft(3, '0')}'),
                                  trailing: canWrite
                                      ? PopupMenuButton<String>(
                                          onSelected: (value) {
                                            if (value == 'level')
                                              _editHierarchyEntity(
                                                  type: 'levels',
                                                  parentField: 'rackId',
                                                  parentId:
                                                      rack['id'].toString());
                                            if (value == 'edit')
                                              _editHierarchyEntity(
                                                  type: 'racks',
                                                  parentField: 'locationId',
                                                  parentId:
                                                      location['id'].toString(),
                                                  entity: rack);
                                            if (value == 'off')
                                              _deactivate('racks', rack);
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                                value: 'level',
                                                child:
                                                    Text('Ebene hinzufügen')),
                                            PopupMenuItem(
                                                value: 'edit',
                                                child: Text(
                                                    'Bearbeiten / verschieben')),
                                            PopupMenuItem(
                                                value: 'off',
                                                child: Text('Deaktivieren')),
                                          ],
                                        )
                                      : null,
                                  children: [
                                    for (final level in _maps(rack['levels']))
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(left: 18),
                                        child: ExpansionTile(
                                          leading:
                                              const Icon(Icons.layers_outlined),
                                          title: Text(
                                              '${level['name']} · E${level['number'].toString().padLeft(2, '0')}'),
                                          trailing: canWrite
                                              ? PopupMenuButton<String>(
                                                  onSelected: (value) {
                                                    if (value == 'place')
                                                      _editHierarchyEntity(
                                                          type: 'places',
                                                          parentField:
                                                              'levelId',
                                                          parentId: level['id']
                                                              .toString());
                                                    if (value == 'edit')
                                                      _editHierarchyEntity(
                                                          type: 'levels',
                                                          parentField: 'rackId',
                                                          parentId: rack['id']
                                                              .toString(),
                                                          entity: level);
                                                    if (value == 'off')
                                                      _deactivate(
                                                          'levels', level);
                                                  },
                                                  itemBuilder: (_) => const [
                                                    PopupMenuItem(
                                                        value: 'place',
                                                        child: Text(
                                                            'Lagerplatz hinzufügen')),
                                                    PopupMenuItem(
                                                        value: 'edit',
                                                        child: Text(
                                                            'Bearbeiten / verschieben')),
                                                    PopupMenuItem(
                                                        value: 'off',
                                                        child: Text(
                                                            'Deaktivieren')),
                                                  ],
                                                )
                                              : null,
                                          children: [
                                            for (final place
                                                in _maps(level['places']))
                                              ListTile(
                                                contentPadding:
                                                    const EdgeInsets.only(
                                                        left: 44, right: 12),
                                                leading: const Icon(
                                                    Icons.place_outlined),
                                                title: Text(
                                                    '${place['code']} · ${place['name']}'),
                                                subtitle: Text(
                                                    '${_maps(place['boxes']).length} Kisten · ${assignments.where((entry) => entry['storagePlaceId'] == place['id']).length} Zuordnungen'),
                                                trailing: canWrite
                                                    ? PopupMenuButton<String>(
                                                        onSelected: (value) {
                                                          if (value == 'assign')
                                                            _assignItem();
                                                          if (value == 'edit')
                                                            _editHierarchyEntity(
                                                                type: 'places',
                                                                parentField:
                                                                    'levelId',
                                                                parentId: level[
                                                                        'id']
                                                                    .toString(),
                                                                entity: place);
                                                          if (value == 'off')
                                                            _deactivate(
                                                                'places',
                                                                place);
                                                        },
                                                        itemBuilder: (_) =>
                                                            const [
                                                          PopupMenuItem(
                                                              value: 'assign',
                                                              child: Text(
                                                                  'Artikel zuordnen')),
                                                          PopupMenuItem(
                                                              value: 'edit',
                                                              child: Text(
                                                                  'Bearbeiten / verschieben')),
                                                          PopupMenuItem(
                                                              value: 'off',
                                                              child: Text(
                                                                  'Deaktivieren')),
                                                        ],
                                                      )
                                                    : null,
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        )),
                    ])),
    ]);
  }

  Widget _boxesTab() {
    final query = search.text.trim().toLowerCase();
    final visible = boxes
        .where((box) => [
              box['inventoryNumber'],
              box['name'],
              box['type'],
              box['placeCode'],
              box['status']
            ].join(' ').toLowerCase().contains(query))
        .toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: 'Kiste, Lagerplatz oder Inhalt suchen',
              suffixIcon: IconButton(
                  onPressed: () async {
                    final value = await _scanCode();
                    if (value != null) setState(() => search.text = value);
                  },
                  icon: const Icon(Icons.qr_code_scanner)),
            ),
          )),
      Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('Noch keine Kisten vorhanden.'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 90),
                  itemCount: visible.length,
                  itemBuilder: (_, index) {
                    final box = visible[index];
                    final contents = _maps(box['contents']);
                    return Card(
                        child: ExpansionTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text('${box['inventoryNumber']} · ${box['name']}'),
                      subtitle: Text(
                          '${box['placeCode']} · ${box['status']} · ${contents.length} Positionen'),
                      trailing: canWrite
                          ? PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'assign')
                                  _assignItem(initialBox: box);
                                if (value == 'codes') _showCodes(box);
                                if (value == 'edit') _editBox(box);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'assign',
                                    child: Text('Artikel hinzufügen')),
                                PopupMenuItem(
                                    value: 'codes',
                                    child: Text('QR-/Barcode und Etikett')),
                                PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Bearbeiten / verschieben')),
                              ],
                            )
                          : IconButton(
                              onPressed: () => _showCodes(box),
                              icon: const Icon(Icons.qr_code)),
                      children: contents.isEmpty
                          ? const [ListTile(title: Text('Kiste ist leer.'))]
                          : contents.map((entry) {
                              final item = _item(entry['entityType'].toString(),
                                  entry['entityId'].toString());
                              return ListTile(
                                contentPadding:
                                    const EdgeInsets.only(left: 54, right: 16),
                                title: Text(
                                    '${item?['inventoryNumber'] ?? ''} · ${item?['name'] ?? 'Unbekannter Artikel'}'),
                                subtitle: Text(
                                    'Menge: ${entry['quantity']} · ${entry['entityType'] == 'material' ? 'Inventar' : 'Kleiderkammer'}'),
                              );
                            }).toList(),
                    ));
                  },
                )),
    ]);
  }

  Widget _stocktakesTab() => stocktakes.isEmpty
      ? const Center(child: Text('Noch keine Inventuren geplant.'))
      : ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
          itemCount: stocktakes.length,
          itemBuilder: (_, index) {
            final stocktake = stocktakes[index];
            final entries = _maps(stocktake['entries']);
            final counted = entries
                .where((entry) => entry['resolvedQuantity'] != null)
                .length;
            return Card(
                child: ListTile(
              leading: Icon(stocktake['status'] == 'Abgeschlossen'
                  ? Icons.task_alt
                  : stocktake['status'] == 'Laufend'
                      ? Icons.fact_check
                      : Icons.event_note),
              title: Text(stocktake['name'].toString()),
              subtitle: Text(
                  '${stocktake['status']} · ${stocktake['scopeType']} · $counted/${entries.length} gezählt'),
              onTap: () => _showStocktake(stocktake),
              trailing: stocktake['status'] == 'Geplant' && canCount
                  ? FilledButton(
                      onPressed: () => _startStocktake(stocktake),
                      child: const Text('Starten'))
                  : const Icon(Icons.chevron_right),
            ));
          },
        );

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Lagerverwaltung'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.account_tree_outlined), text: 'Lagerstruktur'),
            Tab(icon: Icon(Icons.inventory_2_outlined), text: 'Kisten'),
            Tab(icon: Icon(Icons.fact_check_outlined), text: 'Inventuren'),
          ]),
          actions: [
            IconButton(
                onPressed: _load,
                tooltip: 'Aktualisieren',
                icon: const Icon(Icons.refresh))
          ],
        ),
        floatingActionButton: loading
            ? null
            : Column(mainAxisSize: MainAxisSize.min, children: [
                if (canWrite) ...[
                  FloatingActionButton.small(
                    heroTag: 'add-location',
                    tooltip: 'Standort anlegen',
                    onPressed: () => _editLocation(),
                    child: const Icon(Icons.add_location_alt),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton.small(
                    heroTag: 'add-box',
                    tooltip: 'Kiste anlegen',
                    onPressed: () => _editBox(),
                    child: const Icon(Icons.add_box_outlined),
                  ),
                  const SizedBox(height: 8),
                ],
                if (canCount)
                  FloatingActionButton.extended(
                    heroTag: 'add-stocktake',
                    onPressed: _createStocktake,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Inventur'),
                  ),
              ]),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [_structureTab(), _boxesTab(), _stocktakesTab()]),
      ),
    );
  }
}
