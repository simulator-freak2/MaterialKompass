import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class AdminDataManagementPage extends StatefulWidget {
  final String token;

  const AdminDataManagementPage({required this.token, super.key});

  @override
  State<AdminDataManagementPage> createState() =>
      _AdminDataManagementPageState();
}

class _AdminDataManagementPageState extends State<AdminDataManagementPage> {
  bool _loading = true;
  bool _deleting = false;
  String? _error;
  String _confirmationPhrase = 'DATEN LÖSCHEN';
  String _preserved = '';
  List<Map<String, dynamic>> _areas = [];
  final Set<String> _selected = {};

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/admin/data-management'),
        headers: _headers,
      );
      final body = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode != 200) {
        throw Exception(
            body['error'] ?? 'Datenbereiche konnten nicht geladen werden.');
      }
      if (!mounted) return;
      setState(() {
        _areas = (body['areas'] as List? ?? const [])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        _confirmationPhrase =
            body['confirmationPhrase']?.toString() ?? 'DATEN LÖSCHEN';
        _preserved = body['preserved']?.toString() ?? '';
        _selected.removeWhere(
            (id) => !_areas.any((area) => area['id']?.toString() == id));
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmDeletion() async {
    if (_selected.isEmpty || _deleting) return;
    final password = TextEditingController();
    final confirmation = TextEditingController();
    final allSelected = _selected.length == _areas.length;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.red),
        title: Text(allSelected
            ? 'Alle Anwendungsdaten löschen?'
            : 'Ausgewählte Daten dauerhaft löschen?'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Diese Aktion kann nicht rückgängig gemacht werden. Erstelle bei Bedarf vorher eine Datenbanksicherung.',
                ),
                const SizedBox(height: 12),
                if (_preserved.isNotEmpty)
                  Text(_preserved,
                      style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 20),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Aktuelles Admin-Passwort',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmation,
                  decoration: InputDecoration(
                    labelText:
                        'Zur Bestätigung „$_confirmationPhrase“ eingeben',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              if (password.text.isEmpty ||
                  confirmation.text != _confirmationPhrase) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      'Passwort und Bestätigung „$_confirmationPhrase“ sind erforderlich.'),
                ));
                return;
              }
              Navigator.pop(dialogContext, true);
            },
            icon: const Icon(Icons.delete_forever),
            label: const Text('Dauerhaft löschen'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      password.dispose();
      confirmation.dispose();
      return;
    }

    setState(() => _deleting = true);
    final passwordValue = password.text;
    final confirmationValue = confirmation.text;
    password.dispose();
    confirmation.dispose();
    try {
      final response = await http.delete(
        Uri.parse('$apiBaseUrl/api/admin/data-management'),
        headers: _headers,
        body: jsonEncode({
          'scopes': _selected.toList(),
          'currentPassword': passwordValue,
          'confirmation': confirmationValue,
        }),
      );
      final body = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (!mounted) return;
      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(body['error']?.toString() ?? 'Löschen fehlgeschlagen.'),
        ));
        return;
      }
      _selected.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Die ausgewählten Datenbereiche wurden gelöscht.'),
      ));
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Die Daten konnten nicht gelöscht werden.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Daten löschen')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _load,
                            child: const Text('Erneut versuchen')),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Gefahrenbereich',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    const SizedBox(height: 4),
                                    const Text(
                                        'Wähle einzelne Bereiche oder alle Bereiche aus. Gelöschte Daten lassen sich nur aus einer Sicherung wiederherstellen.'),
                                    if (_preserved.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(_preserved),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      CheckboxListTile(
                        value: _areas.isNotEmpty &&
                            _selected.length == _areas.length,
                        tristate: true,
                        title: const Text('Alle Bereiche auswählen'),
                        subtitle: const Text(
                            'Löscht alle Anwendungsdaten in einem Schritt'),
                        secondary: const Icon(Icons.delete_sweep_outlined),
                        onChanged: _deleting
                            ? null
                            : (selected) => setState(() {
                                  if (selected == true) {
                                    _selected.addAll(_areas
                                        .map((area) => area['id'].toString()));
                                  } else {
                                    _selected.clear();
                                  }
                                }),
                      ),
                      const Divider(),
                      ..._areas.map((area) {
                        final id = area['id'].toString();
                        final count = area['count'] as num? ?? 0;
                        return CheckboxListTile(
                          value: _selected.contains(id),
                          title: Text(area['label'].toString()),
                          subtitle: Text(
                              '${area['description']}\n${count.toInt()} Datensätze'),
                          isThreeLine: true,
                          onChanged: _deleting
                              ? null
                              : (selected) => setState(() {
                                    if (selected == true) {
                                      _selected.add(id);
                                    } else {
                                      _selected.remove(id);
                                    }
                                  }),
                        );
                      }),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                            minimumSize: const Size.fromHeight(52)),
                        onPressed: _selected.isEmpty || _deleting
                            ? null
                            : _confirmDeletion,
                        icon: _deleting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.delete_forever),
                        label: Text(_deleting
                            ? 'Daten werden gelöscht …'
                            : 'Ausgewählte Bereiche dauerhaft löschen'),
                      ),
                    ],
                  ),
      );
}
