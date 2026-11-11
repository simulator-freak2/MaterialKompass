import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/authenticated_api_client.dart';
import '../services/document_output_service.dart';

const labelFieldNames = {
  'serialNumber': 'Seriennummer',
  'inventoryNumber': 'Inventarnummer',
  'name': 'Bezeichnung',
  'manufacturingYear': 'Baujahr',
  'size': 'Größe',
};
const labelScopeNames = {
  'private': 'Nicht freigegeben',
  'organization': 'Gesamte Organisation',
  'descendants': 'Eigene und unterliegende Einheiten',
  'users': 'Ausgewählte zugeordnete Nutzer',
};

class LabelTemplatesPage extends StatefulWidget {
  const LabelTemplatesPage({required this.token, this.apiClient, super.key});
  final String token;
  final AuthenticatedApiClient? apiClient;

  @override
  State<LabelTemplatesPage> createState() => _LabelTemplatesPageState();
}

class _LabelTemplatesPageState extends State<LabelTemplatesPage> {
  late final _api = widget.apiClient ?? AuthenticatedApiClient(widget.token);
  List<Map<String, dynamic>> _templates = [];
  Map<String, dynamic> _options = {};
  bool _loading = true;
  String? _error;
  String _search = '', _type = '', _manufacturer = '';

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
      final results = await Future.wait([
        _api.request('/api/label-templates'),
        _api.request('/api/label-templates/options'),
      ]);
      if (!mounted) return;
      setState(() {
        _templates = (results[0] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _options = Map<String, dynamic>.from(results[1] as Map);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _edit([Map<String, dynamic>? template]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _TemplateEditor(api: _api, options: _options, template: template),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _download(Map<String, dynamic> template) async {
    try {
      final result = await _api.request(
        '/api/label-templates/${template['id']}/file',
      );
      await DocumentOutputService.instance.savePayload(result as Map);
      _message('Vorlagendatei gespeichert.');
    } catch (e) {
      _message(e.toString());
    }
  }

  Future<void> _delete(Map<String, dynamic> template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Vorlage löschen?'),
        content: Text(
          '„${template['name']}“ wird für alle bisherigen Empfänger entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.request(
        '/api/label-templates/${template['id']}',
        method: 'DELETE',
      );
      if (mounted) await _load();
    } catch (e) {
      _message(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final manageable = (_options['manageableTypes'] as List? ?? []).isNotEmpty;
    final filtered = _templates
        .where(
          (t) =>
              (_type.isEmpty || t['type'] == _type) &&
              (_manufacturer.isEmpty || t['manufacturer'] == _manufacturer) &&
              '${t['name']} ${t['fileName']}'.toLowerCase().contains(
                _search.toLowerCase(),
              ),
        )
        .toList();
    final categories = _options['categories'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Etikettenvorlagen'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  TextButton(
                    onPressed: _load,
                    child: const Text('Erneut versuchen'),
                  ),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 20,
                  runSpacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Eigene Etiketten für Ihre Organisation',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Im Herstellerprogramm gestalten, hier hochladen und freigeben.',
                        ),
                      ],
                    ),
                    if (manageable)
                      FilledButton.icon(
                        onPressed: () => _edit(),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Vorlage hochladen'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _options['rendererAvailable'] == true
                                ? 'Originalvorlagen werden über den Herstellerdienst verarbeitet. Größe und Layout kommen aus der Datei; gedruckt wird über den System-Druckdialog.'
                                : 'Vorlagen können gespeichert, zugeordnet und freigegeben werden. Für Vorschau und Druck der Originaldateien muss der Herstellerdienst eingerichtet werden.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 280,
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Vorlagen suchen',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _type,
                        decoration: const InputDecoration(
                          labelText: 'Bereich',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: '',
                            child: Text('Alle Bereiche'),
                          ),
                          DropdownMenuItem(
                            value: 'inventory',
                            child: Text('Material'),
                          ),
                          DropdownMenuItem(
                            value: 'clothing',
                            child: Text('Kleidung'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _type = v ?? ''),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _manufacturer,
                        decoration: const InputDecoration(
                          labelText: 'Hersteller',
                          border: OutlineInputBorder(),
                        ),
                        items: ['', 'Zebra', 'DYMO', 'Epson', 'Brother']
                            .map(
                              (v) => DropdownMenuItem(
                                value: v,
                                child: Text(v.isEmpty ? 'Alle Hersteller' : v),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _manufacturer = v ?? ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  '${filtered.length} Vorlagen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                if (filtered.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Keine passenden Vorlagen. Laden Sie eine Herstellerdatei hoch oder lassen Sie sich eine Vorlage freigeben.',
                      ),
                    ),
                  ),
                ...filtered.map(
                  (t) => Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              t['type'] == 'clothing'
                                  ? Icons.checkroom
                                  : Icons.inventory_2_outlined,
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                            title: Text(t['name'].toString()),
                            subtitle: Text(
                              '${t['manufacturer']} · ${t['fileName']} · ${((t['fileBytes'] as num) / 1024).toStringAsFixed(1)} KB',
                            ),
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: (t['categoryIds'] as List)
                                .map(
                                  (id) => Chip(
                                    label: Text(
                                      categories
                                              .cast<Map>()
                                              .where((c) => c['id'] == id)
                                              .firstOrNull?['name']
                                              ?.toString() ??
                                          id.toString(),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${labelScopeNames[t['scope']]} · ${(t['variables'] as List).length} Variablen',
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Etikettengröße und Layout: aus der Originaldatei, hier noch nicht ausgelesen.',
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _download(t),
                                icon: const Icon(Icons.download),
                                label: const Text('Originaldatei'),
                              ),
                              if (t['canManage'] == true)
                                OutlinedButton.icon(
                                  onPressed: () => _edit(t),
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('Bearbeiten'),
                                ),
                              if (t['canManage'] == true)
                                TextButton.icon(
                                  onPressed: () => _delete(t),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Löschen'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Formate: Zebra .nlbl / .lbl · DYMO .dymo / .label · Epson .leb · Brother .lbx / .lbl. Die Dateiendung allein bestätigt keine Druckkompatibilität.',
                ),
              ],
            ),
    );
  }
}

class _VariableInput {
  _VariableInput(String name, this.field)
    : name = TextEditingController(text: name);
  final TextEditingController name;
  String field;
}

class _TemplateEditor extends StatefulWidget {
  const _TemplateEditor({
    required this.api,
    required this.options,
    this.template,
  });
  final AuthenticatedApiClient api;
  final Map<String, dynamic> options;
  final Map<String, dynamic>? template;
  @override
  State<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends State<_TemplateEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late String _manufacturer, _type, _scope, _fileName;
  String? _fileBase64, _error;
  bool _busy = false;
  late Set<String> _categories, _users;
  late final List<_VariableInput> _variables;
  final List<_VariableInput> _removedVariables = [];
  List get _types => widget.options['manageableTypes'] as List;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _name = TextEditingController(text: t?['name']?.toString() ?? '');
    _manufacturer = t?['manufacturer']?.toString() ?? 'Zebra';
    _type = t?['type']?.toString() ?? _types.first.toString();
    _scope = t?['scope']?.toString() ?? 'private';
    _fileName = t?['fileName']?.toString() ?? '';
    _categories = (t?['categoryIds'] as List? ?? [])
        .map((e) => e.toString())
        .toSet();
    _users = (t?['userIds'] as List? ?? []).map((e) => e.toString()).toSet();
    _variables = (t?['variables'] as List? ?? [])
        .map((v) => _VariableInput(v['name'].toString(), v['field'].toString()))
        .toList();
  }

  @override
  void dispose() {
    _name.dispose();
    for (final v in [..._variables, ..._removedVariables]) {
      v.name.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['nlbl', 'lbl', 'dymo', 'label', 'leb', 'lbx'],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
        throw Exception('Bitte eine Datei zwischen 1 Byte und 5 MB wählen.');
      }
      final ext = file.name.split('.').last.toLowerCase();
      setState(() {
        _fileName = file.name;
        _fileBase64 = base64Encode(bytes);
        _error = null;
        _manufacturer =
            {
              'nlbl': 'Zebra',
              'dymo': 'DYMO',
              'label': 'DYMO',
              'leb': 'Epson',
              'lbx': 'Brother',
            }[ext] ??
            _manufacturer;
        if (_name.text.isEmpty) {
          _name.text = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_fileName.isEmpty ||
        _categories.isEmpty ||
        _scope == 'users' && _users.isEmpty) {
      setState(
        () => _error =
            'Bitte Datei, mindestens eine Kategorie und gegebenenfalls Empfänger auswählen.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.request(
        widget.template == null
            ? '/api/label-templates'
            : '/api/label-templates/${widget.template!['id']}',
        method: widget.template == null ? 'POST' : 'PUT',
        body: {
          'name': _name.text.trim(),
          'manufacturer': _manufacturer,
          'type': _type,
          'scope': _scope,
          'categoryIds': _categories.toList(),
          'userIds': _users.toList(),
          'fileName': _fileName,
          if (_fileBase64 != null) 'fileBase64': _fileBase64,
          if (widget.template != null)
            'updatedAt': widget.template!['updatedAt'],
          'variables': _variables
              .map((v) => {'name': v.name.text.trim(), 'field': v.field})
              .toList(),
        },
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = (widget.options['categories'] as List)
        .cast<Map>()
        .where((c) => c['type'] == _type)
        .toList();
    final scopes = labelScopeNames.entries.where(
      (e) =>
          e.key != 'organization' ||
          widget.options['organizationSharingAllowed'] == true,
    );
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          widget.template == null
              ? 'Etikettenvorlage hochladen'
              : 'Etikettenvorlage bearbeiten',
        ),
        content: SizedBox(
          width: 660,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Erstellen Sie das Layout im Herstellerprogramm. Die Originaldatei legt Größe und Gestaltung fest.',
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pick,
                    icon: const Icon(Icons.upload_file),
                    label: Text(
                      _fileName.isEmpty
                          ? 'Datei auswählen · maximal 5 MB'
                          : _fileName,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    enabled: !_busy,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Vorlagenname',
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Bitte einen Namen eingeben.'
                        : null,
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _manufacturer,
                    key: ValueKey(_manufacturer),
                    decoration: const InputDecoration(labelText: 'Hersteller'),
                    items: ['Zebra', 'DYMO', 'Epson', 'Brother']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _manufacturer = v!),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Bereich'),
                    items: _types
                        .map(
                          (v) => DropdownMenuItem(
                            value: v.toString(),
                            child: Text(
                              v == 'inventory' ? 'Material' : 'Kleidung',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                            _type = v!;
                            _categories.clear();
                          }),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Kategorien · Mehrfachauswahl',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Wrap(
                    spacing: 8,
                    children: categories
                        .map(
                          (c) => FilterChip(
                            label: Text(c['name'].toString()),
                            selected: _categories.contains(c['id']),
                            onSelected: _busy
                                ? null
                                : (selected) => setState(() {
                                    selected
                                        ? _categories.add(c['id'].toString())
                                        : _categories.remove(c['id']);
                                  }),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Variablen zuordnen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Text(
                    'Exakte Variablennamen aus dem Herstellerprogramm eingeben. Automatisches Auslesen ist hier noch nicht verfügbar.',
                  ),
                  ..._variables.map(
                    (v) => Padding(
                      key: ObjectKey(v),
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: v.name,
                              enabled: !_busy,
                              maxLength: 80,
                              decoration: const InputDecoration(
                                labelText: 'Name in der Vorlage',
                              ),
                              validator: (s) => s == null || s.trim().isEmpty
                                  ? 'Name erforderlich'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: v.field,
                              decoration: const InputDecoration(
                                labelText: 'MaterialKompass-Feld',
                              ),
                              items: labelFieldNames.entries
                                  .map(
                                    (e) => DropdownMenuItem(
                                      value: e.key,
                                      child: Text(e.value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (f) => setState(() => v.field = f!),
                            ),
                          ),
                          IconButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _variables.remove(v);
                                    _removedVariables.add(v);
                                  }),
                            icon: const Icon(Icons.remove_circle_outline),
                            tooltip: 'Zuordnung entfernen',
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy || _variables.length >= 50
                        ? null
                        : () => setState(
                            () => _variables.add(
                              _VariableInput('', 'inventoryNumber'),
                            ),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('Variable hinzufügen'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _scope,
                    decoration: const InputDecoration(labelText: 'Freigabe'),
                    items: scopes
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _scope = v!),
                  ),
                  if (_scope == 'users') ...[
                    const SizedBox(height: 8),
                    ...(widget.options['users'] as List).map(
                      (u) => CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(u['name'].toString()),
                        value: _users.contains(u['id']),
                        onChanged: _busy
                            ? null
                            : (v) => setState(() {
                                v == true
                                    ? _users.add(u['id'].toString())
                                    : _users.remove(u['id']);
                              }),
                      ),
                    ),
                  ],
                  if (_scope == 'organization' || _scope == 'descendants')
                    const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text(
                        'Für Freigaben über Einheiten hinweg bitte organisationsweite Kategorien verwenden.',
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
  }
}
