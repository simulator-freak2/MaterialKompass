import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class LocationsPage extends StatefulWidget {
  final String token;
  const LocationsPage({required this.token, super.key});
  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  List<Map<String, dynamic>> locations = [],
      shelves = [],
      levels = [],
      positions = [];
  bool loading = true, canWrite = false;
  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };

  List<Map<String, dynamic>> _list(http.Response response) =>
      (jsonDecode(response.body) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final responses = await Future.wait([
        for (final path in [
          'locations',
          'shelves',
          'storage-levels',
          'storage-positions',
          'auth/me'
        ])
          http.get(Uri.parse('$apiBaseUrl/api/$path'), headers: headers),
      ]);
      if (responses.any((r) => r.statusCode != 200)) {
        throw Exception('Lagerstruktur konnte nicht geladen werden.');
      }
      final user = jsonDecode(responses[4].body)['user'] as Map;
      if (!mounted) return;
      setState(() {
        locations = _list(responses[0]);
        shelves = _list(responses[1]);
        levels = _list(responses[2]);
        positions = _list(responses[3]);
        canWrite = (user['permissions'] as List? ?? const [])
            .contains('locations.write');
        loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => loading = false);
        _message(error.toString().replaceFirst('Exception: ', ''), error: true);
      }
    }
  }

  void _message(String text, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(text),
          backgroundColor: error ? Colors.red.shade700 : null));

  Future<bool> _send(
      String path, String method, Map<String, dynamic>? body) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final response = switch (method) {
      'POST' => await http.post(uri, headers: headers, body: jsonEncode(body)),
      'PUT' => await http.put(uri, headers: headers, body: jsonEncode(body)),
      'DELETE' => await http.delete(uri, headers: headers),
      _ => throw ArgumentError('Methode'),
    };
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    String text = 'Aktion fehlgeschlagen.';
    try {
      text = jsonDecode(response.body)['error'] ?? text;
    } catch (_) {}
    if (mounted) _message(text, error: true);
    return false;
  }

  Future<void> _editLocation([Map<String, dynamic>? item]) async {
    final keys = [
      'name',
      'street',
      'houseNumber',
      'postalCode',
      'city',
      'code',
      'type'
    ];
    final labels = [
      'Name *',
      'Straße *',
      'Hausnummer *',
      'Postleitzahl *',
      'Ortsname *',
      'Kürzel *',
      'Typ *'
    ];
    final controls = {
      for (final key in keys)
        key: TextEditingController(text: item?[key]?.toString())
    };
    final saved = await _formDialog(
        item == null ? 'Ort anlegen' : 'Ort bearbeiten',
        [
          for (var i = 0; i < keys.length; i++)
            TextField(
                controller: controls[keys[i]],
                decoration: InputDecoration(labelText: labels[i])),
        ],
        () => _send(
            item == null ? '/api/locations' : '/api/locations/${item['id']}',
            item == null ? 'POST' : 'PUT',
            {for (final key in keys) key: controls[key]!.text}));
    for (final control in controls.values) {
      control.dispose();
    }
    if (saved) {
      _load();
    }
  }

  Future<void> _editNode(
      {required String kind,
      required String path,
      required String parentField,
      required String parentId,
      Map<String, dynamic>? item,
      List<Map<String, dynamic>>? parents}) async {
    final name = TextEditingController(text: item?['name']?.toString());
    final code = TextEditingController(text: item?['code']?.toString());
    String selectedParent = item?[parentField]?.toString() ?? parentId;
    final saved = await _formDialog(
        item == null ? '$kind anlegen' : '$kind bearbeiten',
        [
          TextField(
              controller: name,
              decoration: InputDecoration(
                  labelText: kind == 'Regal' ? 'Name *' : 'Bezeichnung *')),
          TextField(
              controller: code,
              decoration: const InputDecoration(
                  labelText: 'Kürzel *',
                  hintText: 'Buchstaben, Zahlen, _ oder -')),
          if (parents != null)
            DropdownButtonFormField<String>(
                initialValue: selectedParent,
                isExpanded: true,
                decoration: InputDecoration(
                    labelText:
                        '${kind == 'Regal' ? 'Ort' : kind == 'Ebene' ? 'Regal' : 'Ebene'} *'),
                items: parents
                    .map((e) => DropdownMenuItem(
                        value: e['id'].toString(),
                        child: Text('${e['name']} (${e['code']})')))
                    .toList(),
                onChanged: (value) {
                  if (value != null) selectedParent = value;
                }),
        ],
        () => _send(item == null ? path : '$path/${item['id']}',
                item == null ? 'POST' : 'PUT', {
              'name': name.text,
              'code': code.text,
              parentField: selectedParent
            }));
    name.dispose();
    code.dispose();
    if (saved) _load();
  }

  Future<bool> _formDialog(String title, List<Widget> fields,
          Future<bool> Function() save) async =>
      await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
                  title: Text(title),
                  content: SizedBox(
                      width: 480,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final field in fields) ...[
                          field,
                          const SizedBox(height: 12)
                        ]
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Abbrechen')),
                    FilledButton(
                        onPressed: () async {
                          if (await save() && dialogContext.mounted) {
                            Navigator.pop(dialogContext, true);
                          }
                        },
                        child: const Text('Speichern'))
                  ])) ??
      false;

  Future<void> _delete(String label, String path) async {
    final yes = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: Text('$label löschen?'),
                    content: const Text(
                        'Leere Unterstrukturen werden ebenfalls gelöscht. Belegte oder in Inventuren verwendete Strukturen bleiben geschützt.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Abbrechen')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Löschen'))
                    ])) ??
        false;
    if (yes && await _send(path, 'DELETE', null)) _load();
  }

  void _showBarcode(Map<String, dynamic> position) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
              title: Text(position['fullCode']?.toString() ?? 'Lagercode'),
              content: SizedBox(
                  width: 480,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(position['path']?.toString() ??
                        position['name'].toString()),
                    const SizedBox(height: 24),
                    bw.BarcodeWidget(
                        barcode: bw.Barcode.code128(),
                        data: position['fullCode'].toString(),
                        width: 420,
                        height: 110,
                        drawText: true),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Schließen'))
              ]));

  PopupMenuButton<String> menu(
          void Function(String) selected, List<(String, String)> items) =>
      PopupMenuButton<String>(
          onSelected: selected,
          itemBuilder: (_) => items
              .map((e) => PopupMenuItem(value: e.$1, child: Text(e.$2)))
              .toList());

  Widget _positionTile(
          Map<String, dynamic> position, Map<String, dynamic> level) =>
      ListTile(
        leading: const Icon(Icons.place_outlined),
        title: Text('${position['name']} · ${position['fullCode']}'),
        subtitle: Text(position['path']?.toString() ?? ''),
        onTap: () => _showBarcode(position),
        trailing: canWrite
            ? Wrap(children: [
                IconButton(
                    onPressed: () => _showBarcode(position),
                    tooltip: 'Barcode anzeigen',
                    icon: const Icon(Icons.barcode_reader)),
                IconButton(
                    onPressed: () => _editNode(
                        kind: 'Lagerplatz',
                        path: '/api/storage-positions',
                        parentField: 'levelId',
                        parentId: level['id'].toString(),
                        item: position,
                        parents: levels),
                    tooltip: 'Bearbeiten/verschieben',
                    icon: const Icon(Icons.edit_outlined)),
                IconButton(
                    onPressed: () => _delete('Lagerplatz',
                        '/api/storage-positions/${position['id']}'),
                    tooltip: 'Löschen',
                    icon: const Icon(Icons.delete_outline)),
              ])
            : IconButton(
                onPressed: () => _showBarcode(position),
                tooltip: 'Barcode anzeigen',
                icon: const Icon(Icons.barcode_reader)),
      );

  Widget _levelTile(Map<String, dynamic> level, Map<String, dynamic> shelf) =>
      Padding(
        padding: const EdgeInsets.only(left: 16),
        child: ExpansionTile(
          leading: const Icon(Icons.view_stream_outlined),
          title: Text('${level['name']} (${level['code']})'),
          trailing: canWrite
              ? menu((value) {
                  if (value == 'add') {
                    _editNode(
                        kind: 'Lagerplatz',
                        path: '/api/storage-positions',
                        parentField: 'levelId',
                        parentId: level['id'].toString());
                  }
                  if (value == 'edit') {
                    _editNode(
                        kind: 'Ebene',
                        path: '/api/storage-levels',
                        parentField: 'shelfId',
                        parentId: shelf['id'].toString(),
                        item: level,
                        parents: shelves);
                  }
                  if (value == 'delete') {
                    _delete('Ebene', '/api/storage-levels/${level['id']}');
                  }
                }, [
                  ('add', 'Lagerplatz hinzufügen'),
                  ('edit', 'Ebene bearbeiten/verschieben'),
                  ('delete', 'Ebene löschen')
                ])
              : null,
          children: positions
              .where((e) => e['levelId'] == level['id'])
              .map((position) => _positionTile(position, level))
              .toList(),
        ),
      );

  Widget _shelfTile(
          Map<String, dynamic> shelf, Map<String, dynamic> location) =>
      Padding(
        padding: const EdgeInsets.only(left: 16),
        child: ExpansionTile(
          leading: const Icon(Icons.shelves),
          title: Text('${shelf['name']} (${shelf['code']})'),
          trailing: canWrite
              ? menu((value) {
                  if (value == 'add') {
                    _editNode(
                        kind: 'Ebene',
                        path: '/api/storage-levels',
                        parentField: 'shelfId',
                        parentId: shelf['id'].toString());
                  }
                  if (value == 'edit') {
                    _editNode(
                        kind: 'Regal',
                        path: '/api/shelves',
                        parentField: 'locationId',
                        parentId: location['id'].toString(),
                        item: shelf,
                        parents: locations);
                  }
                  if (value == 'delete') {
                    _delete('Regal', '/api/shelves/${shelf['id']}');
                  }
                }, [
                  ('add', 'Ebene hinzufügen'),
                  ('edit', 'Regal bearbeiten/verschieben'),
                  ('delete', 'Regal löschen')
                ])
              : null,
          children: levels
              .where((e) => e['shelfId'] == shelf['id'])
              .map((level) => _levelTile(level, shelf))
              .toList(),
        ),
      );

  Widget _locationCard(Map<String, dynamic> location) => Card(
        child: ExpansionTile(
          leading: const Icon(Icons.apartment),
          title: Text('${location['name']} (${location['code']})'),
          subtitle: Text(
              '${location['street']} ${location['houseNumber']}, ${location['postalCode']} ${location['city']} · ${location['type']}'),
          trailing: canWrite
              ? menu((value) {
                  if (value == 'add') {
                    _editNode(
                        kind: 'Regal',
                        path: '/api/shelves',
                        parentField: 'locationId',
                        parentId: location['id'].toString());
                  }
                  if (value == 'edit') {
                    _editLocation(location);
                  }
                  if (value == 'delete') {
                    _delete('Ort', '/api/locations/${location['id']}');
                  }
                }, [
                  ('add', 'Regal hinzufügen'),
                  ('edit', 'Ort bearbeiten'),
                  ('delete', 'Ort löschen')
                ])
              : null,
          children: shelves
              .where((e) => e['locationId'] == location['id'])
              .map((shelf) => _shelfTile(shelf, location))
              .toList(),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Lagerstruktur'), actions: [
          IconButton(
              onPressed: _load,
              tooltip: 'Aktualisieren',
              icon: const Icon(Icons.refresh))
        ]),
        floatingActionButton: canWrite
            ? FloatingActionButton.extended(
                onPressed: () => _editLocation(),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Ort'))
            : null,
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : locations.isEmpty
                ? const Center(child: Text('Noch keine Orte vorhanden.'))
                : ListView(padding: const EdgeInsets.all(16), children: [
                    const Card(
                        child: ListTile(
                            leading: Icon(Icons.account_tree_outlined),
                            title: Text('Ort → Regal → Ebene → Lagerplatz'),
                            subtitle: Text(
                                'Lagerplätze werden über ihren vollständigen Lagercode gesucht oder gescannt.'))),
                    const SizedBox(height: 8),
                    ...locations.map(_locationCard),
                    const SizedBox(height: 80),
                  ]),
      );
}
