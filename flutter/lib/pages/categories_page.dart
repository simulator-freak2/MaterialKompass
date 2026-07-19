import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class CategoriesPage extends StatefulWidget {
  final String token;

  const CategoriesPage({required this.token, super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _sizesController = TextEditingController();
  final _inspectionIntervalController = TextEditingController();
  List<Map<String, dynamic>> _categories = [];
  String? _parentId;
  bool _useInWardrobe = false;
  bool _requiresPsageInspection = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void dispose() {
    _idController.dispose();
    _nameController.dispose();
    _sizesController.dispose();
    _inspectionIntervalController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _mainCategories => _categories
      .where((category) =>
          category['parentId'] == null ||
          category['parentId'].toString().isEmpty)
      .toList();

  bool _isWardrobeCategory(String? parentId, bool useInWardrobe) {
    if (parentId == null) return useInWardrobe;
    return _mainCategories.any((category) =>
        category['id']?.toString() == parentId &&
        category['useInWardrobe'] == true);
  }

  List<String> _sizesFromText(String value) => value
      .split(',')
      .map((size) => size.trim())
      .where((size) => size.isNotEmpty)
      .toSet()
      .toList();

  Future<void> _loadCategories() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/categories'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      setState(() {
        _categories = response.statusCode == 200
            ? (jsonDecode(response.body) as List)
                .map((item) => Map<String, dynamic>.from(item as Map))
                .toList()
            : [];
        _loading = false;
        if (_parentId != null &&
            !_categories.any((category) => category['id'] == _parentId)) {
          _parentId = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _categories = [];
        _loading = false;
      });
    }
  }

  Future<http.Response> _saveCategory({
    required String id,
    required String name,
    String? parentId,
    bool useInWardrobe = false,
    List<String> sizes = const [],
    int? inspectionIntervalMonths,
    bool requiresPsageInspection = false,
    bool editing = false,
  }) {
    final headers = {
      'Authorization': 'Bearer ${widget.token}',
      'Content-Type': 'application/json',
    };
    if (!editing) {
      return http.post(
        Uri.parse('$apiBaseUrl/api/categories'),
        headers: headers,
        body: jsonEncode({
          'id': id,
          'name': name,
          'parentId': parentId,
          'useInWardrobe': useInWardrobe,
          'sizes': sizes,
          'inspectionIntervalMonths': inspectionIntervalMonths,
          'requiresPsageInspection': requiresPsageInspection,
        }),
      );
    }
    return http.put(
      Uri.parse('$apiBaseUrl/api/categories/${Uri.encodeComponent(id)}'),
      headers: headers,
      body: jsonEncode({
        'name': name,
        'parentId': parentId,
        'useInWardrobe': useInWardrobe,
        'sizes': sizes,
        'inspectionIntervalMonths': inspectionIntervalMonths,
        'requiresPsageInspection': requiresPsageInspection,
      }),
    );
  }

  Future<void> _createCategory() async {
    final id = _idController.text.trim();
    final name = _nameController.text.trim();
    if (id.isEmpty || name.isEmpty) {
      _showMessage('Bitte ID und Name angeben.');
      return;
    }

    final response = await _saveCategory(
      id: id,
      name: name,
      parentId: _parentId,
      useInWardrobe: _parentId == null && _useInWardrobe,
      sizes: _sizesFromText(_sizesController.text),
      inspectionIntervalMonths:
          int.tryParse(_inspectionIntervalController.text.trim()),
      requiresPsageInspection: _parentId != null && _requiresPsageInspection,
    );
    if (!mounted) return;
    if (response.statusCode == 201) {
      _idController.clear();
      _nameController.clear();
      _sizesController.clear();
      _inspectionIntervalController.clear();
      setState(() {
        _parentId = null;
        _useInWardrobe = false;
        _requiresPsageInspection = false;
      });
      await _loadCategories();
      _showMessage('Kategorie wurde angelegt.');
    } else {
      _showMessage(
          'Kategorie konnte nicht angelegt werden. ID und Name müssen eindeutig sein.');
    }
  }

  Future<void> _editCategory(Map<String, dynamic> category) async {
    final id = category['id']?.toString() ?? '';
    final nameController = TextEditingController(
      text: category['name']?.toString() ?? '',
    );
    String? parentId = category['parentId']?.toString();
    var useInWardrobe = category['useInWardrobe'] == true;
    var requiresPsageInspection = category['requiresPsageInspection'] == true;
    final sizesController = TextEditingController(
      text: (category['sizes'] as List? ?? const []).join(', '),
    );
    final inspectionIntervalController = TextEditingController(
      text: category['inspectionIntervalMonths']?.toString() ?? '',
    );
    final hasChildren =
        _categories.any((entry) => entry['parentId']?.toString() == id);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Kategorie $id bearbeiten'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: parentId,
                  decoration: const InputDecoration(
                      labelText: 'Übergeordnete Hauptkategorie'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Hauptkategorie'),
                    ),
                    if (!hasChildren)
                      ..._mainCategories
                          .where((entry) => entry['id']?.toString() != id)
                          .map(
                            (entry) => DropdownMenuItem<String?>(
                              value: entry['id']?.toString(),
                              child: Text(
                                  entry['name']?.toString() ?? 'Unbenannt'),
                            ),
                          ),
                  ],
                  onChanged: hasChildren
                      ? null
                      : (value) => setDialogState(() {
                            parentId = value;
                            if (value != null) useInWardrobe = false;
                            if (!_isWardrobeCategory(parentId, useInWardrobe)) {
                              requiresPsageInspection = false;
                            }
                          }),
                ),
                if (parentId == null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('In Kleiderkammer nutzen'),
                    value: useInWardrobe,
                    onChanged: (value) => setDialogState(() {
                      useInWardrobe = value ?? false;
                      if (!useInWardrobe) requiresPsageInspection = false;
                    }),
                  ),
                if (_isWardrobeCategory(parentId, useInWardrobe)) ...[
                  TextField(
                    controller: sizesController,
                    decoration: const InputDecoration(
                      labelText: 'Vordefinierte Größen',
                      hintText: 'z. B. XS, S, M, L, XL',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: inspectionIntervalController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Prüfintervall (Monate)',
                      hintText: 'Leer = keine regelmäßige Prüfung',
                    ),
                  ),
                  if (parentId != null)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Prüfung nur durch Sachkundige PSAgE'),
                      value: requiresPsageInspection,
                      onChanged: (value) => setDialogState(
                          () => requiresPsageInspection = value ?? false),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'name': nameController.text.trim(),
                'parentId': parentId,
                'useInWardrobe': useInWardrobe,
                'sizes': _sizesFromText(sizesController.text),
                'inspectionIntervalMonths':
                    int.tryParse(inspectionIntervalController.text.trim()),
                'requiresPsageInspection': requiresPsageInspection,
              }),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    sizesController.dispose();
    inspectionIntervalController.dispose();

    final name = result?['name'];
    if (name == null || name.isEmpty) return;
    final response = await _saveCategory(
      id: id,
      name: name,
      parentId: result?['parentId'],
      useInWardrobe: result?['useInWardrobe'] == true,
      sizes: (result?['sizes'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(),
      inspectionIntervalMonths: result?['inspectionIntervalMonths'] as int?,
      requiresPsageInspection: result?['requiresPsageInspection'] == true,
      editing: true,
    );
    if (!mounted) return;
    if (response.statusCode == 200) {
      await _loadCategories();
      _showMessage('Kategorie wurde aktualisiert.');
    } else {
      _showMessage('Kategorie konnte nicht aktualisiert werden.');
    }
  }

  Future<void> _deleteCategory(Map<String, dynamic> category) async {
    final id = category['id']?.toString() ?? '';
    final response = await http.delete(
      Uri.parse('$apiBaseUrl/api/categories/${Uri.encodeComponent(id)}'),
      headers: {'Authorization': 'Bearer ${widget.token}'},
    );
    if (!mounted) return;
    if (response.statusCode == 200) {
      await _loadCategories();
      _showMessage('Kategorie wurde gelöscht.');
    } else {
      _showMessage(
          'Kategorien mit Unterkategorien oder verwendete Kategorien können nicht gelöscht werden.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _categoryActions(Map<String, dynamic> category) {
    return Wrap(
      children: [
        IconButton(
          tooltip: 'Bearbeiten',
          onPressed: () => _editCategory(category),
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: 'Löschen',
          onPressed: () => _deleteCategory(category),
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kategorieverwaltung')),
      body: RefreshIndicator(
        onRefresh: _loadCategories,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Globale Kategorien',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Lege Hauptkategorien und die zugehörigen Unterkategorien für die gesamte Anwendung fest.',
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Neue Kategorie',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fields = [
                          TextField(
                            controller: _idController,
                            decoration: const InputDecoration(
                                labelText: 'Kategorie-ID'),
                          ),
                          TextField(
                            controller: _nameController,
                            decoration:
                                const InputDecoration(labelText: 'Name'),
                          ),
                        ];
                        if (constraints.maxWidth < 600) {
                          return Column(
                            children: [
                              fields[0],
                              const SizedBox(height: 12),
                              fields[1],
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: fields[0]),
                            const SizedBox(width: 12),
                            Expanded(flex: 2, child: fields[1]),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      key: ValueKey(_parentId),
                      initialValue: _parentId,
                      decoration: const InputDecoration(
                          labelText: 'Übergeordnete Hauptkategorie'),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Als Hauptkategorie anlegen'),
                        ),
                        ..._mainCategories.map(
                          (category) => DropdownMenuItem<String?>(
                            value: category['id']?.toString(),
                            child: Text(
                                category['name']?.toString() ?? 'Unbenannt'),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        _parentId = value;
                        if (value != null) _useInWardrobe = false;
                        if (!_isWardrobeCategory(_parentId, _useInWardrobe)) {
                          _requiresPsageInspection = false;
                        }
                      }),
                    ),
                    if (_parentId == null)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('In Kleiderkammer nutzen'),
                        subtitle: const Text(
                            'Diese Hauptkategorie und ihre Unterkategorien stehen in der Kleiderkammer zur Auswahl.'),
                        value: _useInWardrobe,
                        onChanged: (value) => setState(() {
                          _useInWardrobe = value ?? false;
                          if (!_useInWardrobe) {
                            _requiresPsageInspection = false;
                          }
                        }),
                      ),
                    if (_isWardrobeCategory(_parentId, _useInWardrobe)) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _sizesController,
                        decoration: const InputDecoration(
                          labelText: 'Vordefinierte Größen',
                          hintText: 'z. B. XS, S, M, L, XL',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _inspectionIntervalController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Prüfintervall (Monate)',
                          hintText: 'Leer = keine regelmäßige Prüfung',
                        ),
                      ),
                      if (_parentId != null)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title:
                              const Text('Prüfung nur durch Sachkundige PSAgE'),
                          subtitle: const Text(
                              'Prüfungen dieser Unterkategorie werden serverseitig auf die PSAgE-Rolle beschränkt.'),
                          value: _requiresPsageInspection,
                          onChanged: (value) => setState(
                              () => _requiresPsageInspection = value ?? false),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _createCategory,
                        icon: const Icon(Icons.add),
                        label: const Text('Kategorie hinzufügen'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Bestehende Kategorien',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_mainCategories.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Noch keine Kategorien vorhanden.'),
                ),
              )
            else
              ..._mainCategories.map((category) {
                final id = category['id']?.toString() ?? '';
                final children = _categories
                    .where((entry) => entry['parentId']?.toString() == id)
                    .toList();
                return Card(
                  child: ExpansionTile(
                    initiallyExpanded: true,
                    title: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                            '${category['name']?.toString() ?? 'Unbenannt'}  ($id)'),
                        if (category['useInWardrobe'] == true)
                          const Chip(
                            avatar: Icon(Icons.checkroom, size: 18),
                            label: Text('Kleiderkammer'),
                          ),
                        if (category['inspectionIntervalMonths'] != null)
                          Chip(
                            avatar: const Icon(Icons.event_repeat, size: 18),
                            label: Text(
                                '${category['inspectionIntervalMonths']} Monate'),
                          ),
                      ],
                    ),
                    trailing: _categoryActions(category),
                    children: children
                        .map(
                          (child) => ListTile(
                            contentPadding:
                                const EdgeInsets.only(left: 32, right: 16),
                            leading: const Icon(Icons.subdirectory_arrow_right),
                            title: Wrap(
                              spacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                    '${child['name']?.toString() ?? 'Unbenannt'}  (${child['id']})'),
                                if (child['inspectionIntervalMonths'] != null)
                                  Chip(
                                    avatar: const Icon(Icons.event_repeat,
                                        size: 18),
                                    label: Text(
                                        '${child['inspectionIntervalMonths']} Monate'),
                                  ),
                                if (child['requiresPsageInspection'] == true)
                                  const Chip(
                                    avatar: Icon(Icons.verified_user, size: 18),
                                    label: Text('PSAgE-Sachkundige'),
                                  ),
                                if ((child['sizes'] as List? ?? const [])
                                    .isNotEmpty)
                                  Chip(
                                    avatar:
                                        const Icon(Icons.straighten, size: 18),
                                    label: Text(
                                        '${(child['sizes'] as List).length} Größen'),
                                  ),
                              ],
                            ),
                            trailing: _categoryActions(child),
                          ),
                        )
                        .toList(),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
