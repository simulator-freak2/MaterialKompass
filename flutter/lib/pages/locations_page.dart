import 'dart:convert';

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
  List<Map<String, dynamic>> locations = [];
  List<Map<String, dynamic>> stocks = [];
  bool loading = true;
  bool canWrite = false;

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final responses = await Future.wait([
        http.get(Uri.parse('$apiBaseUrl/api/locations'), headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/stock-structures'),
            headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: headers),
      ]);
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Lagerorte konnten nicht geladen werden.');
      }
      final user = jsonDecode(responses[2].body)['user'] as Map;
      if (!mounted) return;
      setState(() {
        locations = (jsonDecode(responses[0].body) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        stocks = (jsonDecode(responses[1].body) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        canWrite = (user['permissions'] as List? ?? const [])
            .contains('locations.write');
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      _message(error.toString().replaceFirst('Exception: ', ''), error: true);
    }
  }

  void _message(String value, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(value),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  Future<bool> _send(
      String path, String method, Map<String, dynamic>? body) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final response = switch (method) {
      'POST' => await http.post(uri, headers: headers, body: jsonEncode(body)),
      'PUT' => await http.put(uri, headers: headers, body: jsonEncode(body)),
      'DELETE' => await http.delete(uri, headers: headers),
      _ => throw ArgumentError('Nicht unterstützte Methode'),
    };
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    var message = 'Aktion fehlgeschlagen.';
    try {
      message = jsonDecode(response.body)['error']?.toString() ?? message;
    } catch (_) {}
    if (mounted) _message(message, error: true);
    return false;
  }

  Future<void> _editLocation([Map<String, dynamic>? location]) async {
    final name = TextEditingController(text: location?['name']?.toString());
    final code = TextEditingController(text: location?['code']?.toString());
    final type = TextEditingController(text: location?['type']?.toString());
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title:
            Text(location == null ? 'Lagerort anlegen' : 'Lagerort bearbeiten'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name *')),
            const SizedBox(height: 12),
            TextField(
                controller: code,
                decoration: const InputDecoration(labelText: 'Kürzel *')),
            const SizedBox(height: 12),
            TextField(
                controller: type,
                decoration: const InputDecoration(
                    labelText: 'Typ *', hintText: 'z. B. Lager oder Kleidung')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              final ok = await _send(
                location == null
                    ? '/api/locations'
                    : '/api/locations/${location['id']}',
                location == null ? 'POST' : 'PUT',
                {'name': name.text, 'code': code.text, 'type': type.text},
              );
              if (ok && dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    name.dispose();
    code.dispose();
    type.dispose();
    if (saved == true) _load();
  }

  Future<void> _editStock(String locationId,
      [Map<String, dynamic>? stock]) async {
    final name = TextEditingController(text: stock?['name']?.toString());
    final section = TextEditingController(text: stock?['section']?.toString());
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
            stock == null ? 'Regal/Fach anlegen' : 'Regal/Fach bearbeiten'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                decoration: const InputDecoration(
                    labelText: 'Bezeichnung *',
                    hintText: 'z. B. Kleiderregal')),
            const SizedBox(height: 12),
            TextField(
                controller: section,
                decoration: const InputDecoration(
                    labelText: 'Fach / Abschnitt *', hintText: 'z. B. K1')),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () async {
              final ok = await _send(
                stock == null
                    ? '/api/stock-structures'
                    : '/api/stock-structures/${stock['id']}',
                stock == null ? 'POST' : 'PUT',
                {
                  'name': name.text,
                  'section': section.text,
                  'locationId': locationId
                },
              );
              if (ok && dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    name.dispose();
    section.dispose();
    if (saved == true) _load();
  }

  Future<void> _delete(String label, String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label löschen?'),
        content: const Text(
            'Belegte Lagerorte und Fächer können nicht gelöscht werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true && await _send(path, 'DELETE', null)) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zentrale Lagerortverwaltung'),
        actions: [
          IconButton(
              onPressed: _load,
              tooltip: 'Aktualisieren',
              icon: const Icon(Icons.refresh))
        ],
      ),
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => _editLocation(),
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Lagerort'))
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : locations.isEmpty
              ? const Center(child: Text('Noch keine Lagerorte vorhanden.'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Card(
                        child: ListTile(
                      leading: Icon(Icons.hub_outlined),
                      title: Text('Gemeinsame Lagerstruktur'),
                      subtitle: Text(
                          'Diese Lagerorte und Regal/Fach-Strukturen werden in Kleiderkammer, Inventar und Beschaffung verwendet.'),
                    )),
                    const SizedBox(height: 8),
                    ...locations.map((location) {
                      final children = stocks
                          .where(
                              (entry) => entry['locationId'] == location['id'])
                          .toList();
                      return Card(
                        child: ExpansionTile(
                          leading: const Icon(Icons.warehouse_outlined),
                          title:
                              Text('${location['name']} (${location['code']})'),
                          subtitle: Text(
                              '${location['type']} · ${children.length} Regal/Fach-Einträge'),
                          trailing: canWrite
                              ? PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _editLocation(location);
                                    }
                                    if (value == 'add') {
                                      _editStock(location['id'].toString());
                                    }
                                    if (value == 'delete') {
                                      _delete('Lagerort',
                                          '/api/locations/${location['id']}');
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'add',
                                        child: Text('Regal/Fach hinzufügen')),
                                    PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Lagerort bearbeiten')),
                                    PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Lagerort löschen')),
                                  ],
                                )
                              : null,
                          children: children.isEmpty
                              ? const [
                                  ListTile(
                                      title: Text(
                                          'Keine Regal/Fach-Struktur angelegt.'))
                                ]
                              : children
                                  .map((stock) => ListTile(
                                        leading: const Icon(Icons.shelves),
                                        title: Text(
                                            stock['name']?.toString() ?? '-'),
                                        subtitle: Text(
                                            'Fach / Abschnitt: ${stock['section']}'),
                                        trailing: canWrite
                                            ? Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                    IconButton(
                                                        onPressed: () =>
                                                            _editStock(
                                                                location['id']
                                                                    .toString(),
                                                                stock),
                                                        tooltip: 'Bearbeiten',
                                                        icon: const Icon(Icons
                                                            .edit_outlined)),
                                                    IconButton(
                                                        onPressed: () => _delete(
                                                            'Regal/Fach',
                                                            '/api/stock-structures/${stock['id']}'),
                                                        tooltip: 'Löschen',
                                                        icon: const Icon(Icons
                                                            .delete_outline)),
                                                  ])
                                            : null,
                                      ))
                                  .toList(),
                        ),
                      );
                    }),
                    const SizedBox(height: 80),
                  ],
                ),
    );
  }
}
