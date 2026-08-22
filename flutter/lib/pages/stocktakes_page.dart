import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';
import '../constants.dart';
import '../services/file_save_mime_type.dart';

class StocktakesPage extends StatefulWidget {
  final String token;
  final VoidCallback? onLogout;

  const StocktakesPage({required this.token, this.onLogout, super.key});

  @override
  State<StocktakesPage> createState() => _StocktakesPageState();
}

class _StocktakesPageState extends State<StocktakesPage> {
  List<Map<String, dynamic>> stocktakes = [];
  List<Map<String, dynamic>> unassignedEmails = [];
  Map<String, dynamic> options = {};
  Set<String> permissions = {};
  bool loading = true;

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  bool can(String permission) => permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _request(String path,
      {String method = 'GET', Object? body, bool quiet = false}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'POST' => await http.post(uri, headers: headers, body: encoded),
      'PUT' => await http.put(uri, headers: headers, body: encoded),
      _ => await http.get(uri, headers: headers),
    };
    if (response.statusCode == 401) {
      widget.onLogout?.call();
      return null;
    }
    final data =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (!quiet && mounted) {
        _message(
            data is Map
                ? data['error']?.toString() ?? 'Aktion fehlgeschlagen.'
                : 'Aktion fehlgeschlagen.',
            error: true);
      }
      return null;
    }
    return data;
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final responses = await Future.wait([
        http.get(Uri.parse('$apiBaseUrl/api/stocktakes'), headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/stocktakes/options'),
            headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: headers),
        http.get(Uri.parse('$apiBaseUrl/api/stocktake-email-imports'),
            headers: headers),
      ]);
      if (responses.any((response) => response.statusCode == 401)) {
        widget.onLogout?.call();
        return;
      }
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Inventuren konnten nicht geladen werden.');
      }
      final user = jsonDecode(responses[2].body)['user'];
      if (!mounted) return;
      setState(() {
        stocktakes = (jsonDecode(responses[0].body) as List)
            .cast<Map<String, dynamic>>();
        options = Map<String, dynamic>.from(jsonDecode(responses[1].body));
        permissions = (user['permissions'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toSet();
        unassignedEmails = (jsonDecode(responses[3].body) as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .where((entry) => entry['stocktakeId'] == null)
            .toList();
        loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      _message(error.toString(), error: true);
    }
  }

  void _message(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  String _date(dynamic raw) {
    final value = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
    if (value == null) return '-';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.day)}.${two(value.month)}.${value.year}';
  }

  Color _statusColor(String status) => switch (status) {
        'In Arbeit' => Colors.blue,
        'Auswertung' => Colors.orange.shade800,
        'Abgeschlossen' => Colors.green.shade700,
        _ => Colors.blueGrey,
      };

  Future<void> _create() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CreateStocktakeDialog(options: options),
    );
    if (created == null) return;
    final result =
        await _request('/api/stocktakes', method: 'POST', body: created);
    if (result != null) {
      _message('Inventur wurde angelegt.');
      await _load();
      if (mounted) await _open(Map<String, dynamic>.from(result));
    }
  }

  Future<void> _open(Map<String, dynamic> stocktake) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StocktakeDetailPage(
        token: widget.token,
        stocktakeId: stocktake['id'].toString(),
        options: options,
        permissions: permissions,
        onLogout: widget.onLogout,
      ),
    ));
    await _load();
  }

  Future<void> _assignEmail(Map<String, dynamic> email) async {
    String? selectedId =
        stocktakes.isEmpty ? null : stocktakes.first['id']?.toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Eingescannte Liste zuordnen'),
          content: DropdownButtonFormField<String>(
            initialValue: selectedId,
            decoration: const InputDecoration(labelText: 'Inventur'),
            items: stocktakes
                .where((entry) => entry['status'] != 'Abgeschlossen')
                .map((entry) => DropdownMenuItem(
                    value: entry['id'].toString(),
                    child: Text(entry['name'].toString())))
                .toList(),
            onChanged: (value) => setDialogState(() => selectedId = value),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: selectedId == null
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Zuordnen')),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final result = await _request(
        '/api/stocktake-email-imports/${email['id']}/assign',
        method: 'POST',
        body: {'stocktakeId': selectedId});
    if (result != null) {
      _message('Eingescannte Liste wurde zugeordnet.');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventuren'),
        actions: [
          IconButton(
              onPressed: _load,
              tooltip: 'Aktualisieren',
              icon: const Icon(Icons.refresh))
        ],
      ),
      floatingActionButton: can('stocktakes.create')
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Inventur anlegen'))
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: stocktakes.isEmpty && unassignedEmails.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 140),
                      Icon(Icons.fact_check_outlined,
                          size: 64, color: Colors.blueGrey),
                      SizedBox(height: 16),
                      Center(child: Text('Noch keine Inventur angelegt.')),
                    ])
                  : LayoutBuilder(builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 1100
                          ? 3
                          : constraints.maxWidth >= 680
                              ? 2
                              : 1;
                      return ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                          children: [
                            if (unassignedEmails.isNotEmpty &&
                                can('stocktakes.email.import'))
                              Card(
                                color: Colors.orange.shade50,
                                child: ExpansionTile(
                                  leading: const Icon(
                                      Icons.mark_email_unread_outlined),
                                  title: Text(
                                      '${unassignedEmails.length} nicht zugeordnete Inventur-E-Mail(s)'),
                                  subtitle: const Text(
                                      'Inventur-ID oder Bezeichnung konnte nicht erkannt werden.'),
                                  children: unassignedEmails
                                      .map((email) => ListTile(
                                            title: Text(
                                                email['subject']?.toString() ??
                                                    'Ohne Betreff'),
                                            subtitle: Text(
                                                email['sender']?.toString() ??
                                                    ''),
                                            trailing: TextButton(
                                                onPressed: () =>
                                                    _assignEmail(email),
                                                child: const Text('Zuordnen')),
                                          ))
                                      .toList(),
                                ),
                              ),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                crossAxisSpacing: 14,
                                mainAxisSpacing: 14,
                                childAspectRatio: columns == 1 ? 2.15 : 1.65,
                              ),
                              itemCount: stocktakes.length,
                              itemBuilder: (_, index) {
                                final item = stocktakes[index];
                                final progress = Map<String, dynamic>.from(
                                    item['progress'] as Map? ?? const {});
                                final total = num.tryParse(
                                            progress['total']?.toString() ?? '')
                                        ?.toInt() ??
                                    0;
                                final counted = num.tryParse(
                                            progress['counted']?.toString() ??
                                                '')
                                        ?.toInt() ??
                                    0;
                                final ratio =
                                    total == 0 ? 0.0 : counted / total;
                                final status =
                                    item['status']?.toString() ?? 'Angelegt';
                                return Card(
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () => _open(item),
                                    child: Padding(
                                      padding: const EdgeInsets.all(18),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(children: [
                                              Expanded(
                                                  child: Text(
                                                      item['name']
                                                              ?.toString() ??
                                                          '',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleLarge)),
                                              Chip(
                                                avatar: Icon(Icons.circle,
                                                    size: 10,
                                                    color:
                                                        _statusColor(status)),
                                                label: Text(status),
                                                visualDensity:
                                                    VisualDensity.compact,
                                              ),
                                            ]),
                                            Text(
                                                '${item['entityTypes']?.toString().contains('MaterialItem') == true ? 'Inventar' : ''}'
                                                '${item['entityTypes']?.toString().contains('MaterialItem') == true && item['entityTypes']?.toString().contains('ClothingItem') == true ? ' & ' : ''}'
                                                '${item['entityTypes']?.toString().contains('ClothingItem') == true ? 'Kleiderkammer' : ''} · ${item['method'] == 'offline' ? 'Papier/Offline' : 'Digital'}'),
                                            const Spacer(),
                                            LinearProgressIndicator(
                                                value: ratio),
                                            const SizedBox(height: 8),
                                            Text(
                                                '$counted von $total Positionen gezählt · ${progress['discrepancies'] ?? 0} Abweichungen'),
                                            const SizedBox(height: 6),
                                            Text(
                                                'Beginn ${_date(item['startDate'])} · ${item['responsibleName'] ?? '-'}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall),
                                          ]),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ]);
                    }),
            ),
    );
  }
}

class _CreateStocktakeDialog extends StatefulWidget {
  final Map<String, dynamic> options;
  const _CreateStocktakeDialog({required this.options});

  @override
  State<_CreateStocktakeDialog> createState() => _CreateStocktakeDialogState();
}

class _CreateStocktakeDialogState extends State<_CreateStocktakeDialog> {
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final notes = TextEditingController();
  late final TextEditingController startDate;
  String? responsibleUserId;
  String method = 'online';
  String countMode = 'blind';
  final entityTypes = <String>{};
  final locationIds = <String>{};
  final stockIds = <String>{};
  final departments = <String>{};

  List<Map<String, dynamic>> list(String key) =>
      (widget.options[key] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    startDate = TextEditingController(
        text:
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}');
    final people = list('responsibleUsers');
    if (people.isNotEmpty) responsibleUserId = people.first['id']?.toString();
    final allowed = (widget.options['allowedEntityTypes'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    if (allowed.isNotEmpty) entityTypes.add(allowed.first);
  }

  @override
  void dispose() {
    name.dispose();
    notes.dispose();
    startDate.dispose();
    super.dispose();
  }

  Widget chips(
      String title, List<Map<String, dynamic>> values, Set<String> selected,
      {String idKey = 'id'}) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(
          spacing: 8,
          runSpacing: 4,
          children: values.map((entry) {
            final value = entry[idKey]?.toString() ?? entry['name'].toString();
            return FilterChip(
              label: Text(entry['path']?.toString() ??
                  entry['name']?.toString() ??
                  value),
              selected: selected.contains(value),
              onSelected: (checked) => setState(
                  () => checked ? selected.add(value) : selected.remove(value)),
            );
          }).toList()),
      const SizedBox(height: 14),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Inventur anlegen'),
      content: SizedBox(
        width: 700,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                TextFormField(
                    controller: name,
                    decoration:
                        const InputDecoration(labelText: 'Bezeichnung *'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? 'Pflichtfeld'
                        : null),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: responsibleUserId,
                  decoration: const InputDecoration(
                      labelText: 'Verantwortliche Person *'),
                  items: list('responsibleUsers')
                      .map((person) => DropdownMenuItem(
                          value: person['id'].toString(),
                          child: Text(person['name']?.toString() ??
                              person['username'].toString())))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => responsibleUserId = value),
                  validator: (value) => value == null ? 'Pflichtfeld' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                    controller: startDate,
                    decoration: const InputDecoration(
                        labelText: 'Beginn (JJJJ-MM-TT) *'),
                    validator: (value) =>
                        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value ?? '')
                            ? null
                            : 'Datum im Format JJJJ-MM-TT'),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: DropdownButtonFormField<String>(
                          initialValue: method,
                          decoration: const InputDecoration(labelText: 'Art *'),
                          items: const [
                            DropdownMenuItem(
                                value: 'online', child: Text('Digital')),
                            DropdownMenuItem(
                                value: 'offline', child: Text('Papier/Offline'))
                          ],
                          onChanged: (value) =>
                              setState(() => method = value!))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: DropdownButtonFormField<String>(
                          initialValue: countMode,
                          decoration:
                              const InputDecoration(labelText: 'Zählmodus'),
                          items: const [
                            DropdownMenuItem(
                                value: 'blind', child: Text('Blindzählung')),
                            DropdownMenuItem(
                                value: 'open',
                                child: Text('Sollbestand sichtbar'))
                          ],
                          onChanged: (value) =>
                              setState(() => countMode = value!))),
                ]),
                const SizedBox(height: 16),
                const Text('Bereiche *',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(spacing: 8, children: [
                  if ((widget.options['allowedEntityTypes'] as List? ??
                          const [])
                      .contains('MaterialItem'))
                    FilterChip(
                        label: const Text('Inventar'),
                        selected: entityTypes.contains('MaterialItem'),
                        onSelected: (value) => setState(() => value
                            ? entityTypes.add('MaterialItem')
                            : entityTypes.remove('MaterialItem'))),
                  if ((widget.options['allowedEntityTypes'] as List? ??
                          const [])
                      .contains('ClothingItem'))
                    FilterChip(
                        label: const Text('Kleiderkammer'),
                        selected: entityTypes.contains('ClothingItem'),
                        onSelected: (value) => setState(() => value
                            ? entityTypes.add('ClothingItem')
                            : entityTypes.remove('ClothingItem'))),
                ]),
                const SizedBox(height: 12),
                Text(
                    'Ohne Auswahl werden alle Positionen des gewählten Bereichs aufgenommen.',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                chips('Standorte', list('locations'), locationIds),
                chips('Lagerorte / Lagerplätze', list('stockStructures'),
                    stockIds),
                chips('Fachbereiche', list('departments'), departments,
                    idKey: 'name'),
                TextField(
                    controller: notes,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Notizen')),
              ])),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            if (entityTypes.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Mindestens einen Bereich auswählen.')));
              return;
            }
            Navigator.pop(context, {
              'name': name.text.trim(),
              'responsibleUserId': responsibleUserId,
              'method': method,
              'countMode': countMode,
              'startDate': startDate.text,
              'notes': notes.text.trim(),
              'entityTypes': entityTypes.toList(),
              'scope': {
                'locationIds': locationIds.toList(),
                'stockStructureIds': stockIds.toList(),
                'departments': departments.toList()
              },
            });
          },
          child: const Text('Anlegen'),
        ),
      ],
    );
  }
}

class StocktakeDetailPage extends StatefulWidget {
  final String token;
  final String stocktakeId;
  final Map<String, dynamic> options;
  final Set<String> permissions;
  final VoidCallback? onLogout;

  const StocktakeDetailPage(
      {required this.token,
      required this.stocktakeId,
      required this.options,
      required this.permissions,
      this.onLogout,
      super.key});

  @override
  State<StocktakeDetailPage> createState() => _StocktakeDetailPageState();
}

class _StocktakeDetailPageState extends State<StocktakeDetailPage> {
  Map<String, dynamic>? stocktake;
  List<Map<String, dynamic>> emailImports = [];
  bool loading = true;
  String query = '';
  String filter = 'Alle';
  final handScanner = TextEditingController();
  final handScannerFocus = FocusNode();

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };
  bool can(String permission) => widget.permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    handScanner.dispose();
    handScannerFocus.dispose();
    super.dispose();
  }

  void message(String value, {bool error = false}) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(value),
          backgroundColor: error ? Colors.red.shade700 : null));

  Future<dynamic> request(String path,
      {String method = 'GET', Object? body}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    final response = method == 'POST'
        ? await http.post(uri, headers: headers, body: encoded)
        : method == 'PUT'
            ? await http.put(uri, headers: headers, body: encoded)
            : await http.get(uri, headers: headers);
    if (response.statusCode == 401) {
      widget.onLogout?.call();
      return null;
    }
    final data =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      message(
          data is Map
              ? data['error']?.toString() ?? 'Aktion fehlgeschlagen.'
              : 'Aktion fehlgeschlagen.',
          error: true);
      return null;
    }
    return data;
  }

  Future<void> _load() async {
    final results = await Future.wait([
      request('/api/stocktakes/${widget.stocktakeId}'),
      request('/api/stocktake-email-imports?stocktakeId=${widget.stocktakeId}'),
    ]);
    if (!mounted) return;
    setState(() {
      stocktake =
          results[0] == null ? null : Map<String, dynamic>.from(results[0]);
      emailImports = (results[1] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();
      loading = false;
    });
  }

  Future<void> _downloadEmailAttachment(
      Map<String, dynamic> email, Map<String, dynamic> attachment) async {
    final data = await request(
        '/api/stocktake-email-imports/${email['id']}/attachments/${attachment['id']}');
    if (data == null) return;
    final fileName = data['fileName'].toString();
    final extension = fileName.contains('.') ? fileName.split('.').last : 'pdf';
    await FileSaver.instance.saveFile(
      name: fileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: extension,
      mimeType: MimeType.custom,
      customMimeType: data['mimeType']?.toString() ?? fileMimeType(extension),
    );
  }

  Future<void> _markEmailProcessed(Map<String, dynamic> email) async {
    final data = await request(
        '/api/stocktake-email-imports/${email['id']}/processed',
        method: 'POST',
        body: {});
    if (data != null) {
      message('Eingescannte Liste wurde als verarbeitet markiert.');
      await _load();
    }
  }

  List<Map<String, dynamic>> get entries {
    final source = (stocktake?['entries'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map));
    final normalized = query.trim().toLowerCase();
    return source.where((entry) {
      final found = normalized.isEmpty ||
          '${entry['inventoryNumber']} ${entry['name']} ${entry['expectedLocationName']} ${entry['expectedStockStructureName']}'
              .toLowerCase()
              .contains(normalized);
      final counted = entry['countedAt'] != null;
      final different =
          (entry['discrepancies'] as List? ?? const []).isNotEmpty;
      return found &&
          (filter == 'Alle' ||
              filter == 'Offen' && !counted ||
              filter == 'Gezählt' && counted ||
              filter == 'Abweichung' && different);
    }).toList();
  }

  Future<void> _transition(String action, {Object? body}) async {
    final labels = {
      'start': 'Inventur starten?',
      'evaluate': 'Zählung beenden und Auswertung starten?',
      'complete': 'Inventur revisionssicher abschließen?'
    };
    var apply = true;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
                  title: Text(labels[action]!),
                  content: action == 'complete'
                      ? CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: apply,
                          title: const Text(
                              'Bestands- und Standortkorrekturen übernehmen'),
                          subtitle: const Text(
                              'Die Korrektur wird protokolliert und kann nicht über diese Inventur rückgängig gemacht werden.'),
                          onChanged: (value) =>
                              setDialogState(() => apply = value ?? false),
                        )
                      : null,
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Abbrechen')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(action == 'complete'
                            ? 'Abschließen'
                            : 'Bestätigen'))
                  ],
                )));
    if (confirmed != true) return;
    final result = await request(
        '/api/stocktakes/${widget.stocktakeId}/$action',
        method: 'POST',
        body: action == 'complete' ? {'applyCorrections': apply} : body ?? {});
    if (result != null) {
      setState(() => stocktake = Map<String, dynamic>.from(result));
      message(action == 'start'
          ? 'Inventur ist jetzt in Arbeit.'
          : action == 'evaluate'
              ? 'Auswertung wurde gestartet und Vorgänge wurden erzeugt.'
              : 'Inventur wurde abgeschlossen.');
    }
  }

  Future<void> _scan([String? supplied]) async {
    String? value = supplied;
    if (value == null) {
      final manual = TextEditingController();
      var completed = false;
      value = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Inventarnummer scannen'),
                content: SizedBox(
                    width: 520,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: manual,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: 'Handscanner / Inventarnummer'),
                          onSubmitted: (value) =>
                              Navigator.pop(context, value.trim())),
                      if (isCameraScanningSupported) ...[
                        const SizedBox(height: 14),
                        SizedBox(
                            height: 260,
                            child: MobileScanner(onDetect: (capture) {
                              final code =
                                  capture.barcodes.firstOrNull?.rawValue;
                              if (code != null && !completed) {
                                completed = true;
                                Navigator.pop(context, code);
                              }
                            }))
                      ] else
                        const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                                'Am PC kann ein USB-Handscanner verwendet werden.')),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, manual.text.trim()),
                      child: const Text('Übernehmen'))
                ],
              ));
      manual.dispose();
    }
    if (value == null || value.trim().isEmpty) return;
    final match = (stocktake?['entries'] as List? ?? const [])
        .cast<Map>()
        .where((entry) =>
            entry['inventoryNumber'].toString().toLowerCase() ==
            value!.trim().toLowerCase())
        .firstOrNull;
    if (match != null) {
      await _count(Map<String, dynamic>.from(match));
    } else {
      if (!mounted) return;
      final note = TextEditingController();
      final save = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Unbekannter Gegenstand'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                      '„$value“ gehört nicht zu dieser Inventur und kann als Fundstück vorgemerkt werden.'),
                  TextField(
                      controller: note,
                      decoration: const InputDecoration(labelText: 'Notiz'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Verwerfen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Fundstück vormerken'))
                ],
              ));
      if (save == true) {
        final result = await request(
            '/api/stocktakes/${widget.stocktakeId}/findings',
            method: 'POST',
            body: {'inventoryNumber': value, 'notes': note.text});
        if (result != null) {
          message('Fundstück wurde vorgemerkt.');
          await _load();
        }
      }
      note.dispose();
    }
    handScanner.clear();
    handScannerFocus.requestFocus();
  }

  Future<void> _count(Map<String, dynamic> entry) async {
    final bulk = entry['itemType'] == 'bulk';
    final quantity =
        TextEditingController(text: entry['actualQuantity']?.toString() ?? '');
    final notes = TextEditingController(text: entry['notes']?.toString() ?? '');
    String result = entry['result']?.toString() ?? 'vorhanden';
    String? locationId = entry['actualLocationId']?.toString() ??
        entry['expectedLocationId']?.toString();
    String? stockId = entry['actualStockStructureId']?.toString() ??
        entry['expectedStockStructureId']?.toString();
    final locations =
        (widget.options['locations'] as List? ?? const []).cast<Map>();
    final stocks =
        (widget.options['stockStructures'] as List? ?? const []).cast<Map>();
    final values = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            StatefulBuilder(builder: (context, setDialogState) {
              final locationStocks = stocks
                  .where((stock) => stock['locationId'] == locationId)
                  .toList();
              return AlertDialog(
                title: Text('${entry['inventoryNumber']} · ${entry['name']}'),
                content: SizedBox(
                    width: 520,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      if (stocktake?['countMode'] == 'open' ||
                          entry['countedAt'] != null)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                                'Soll: ${entry['expectedQuantity']} ${entry['unit']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                      const SizedBox(height: 12),
                      if (bulk)
                        TextField(
                            controller: quantity,
                            autofocus: true,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: InputDecoration(
                                labelText: 'Ist-Menge (${entry['unit']}) *'))
                      else
                        DropdownButtonFormField<String>(
                            initialValue: result,
                            decoration:
                                const InputDecoration(labelText: 'Ergebnis *'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'vorhanden', child: Text('Vorhanden')),
                              DropdownMenuItem(
                                  value: 'beschädigt',
                                  child: Text('Beschädigt')),
                              DropdownMenuItem(
                                  value: 'nicht vorhanden',
                                  child: Text('Nicht vorhanden'))
                            ],
                            onChanged: (value) =>
                                setDialogState(() => result = value!)),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          initialValue: locationId,
                          decoration: const InputDecoration(
                              labelText: 'Gefundener Standort'),
                          items: locations
                              .map((location) => DropdownMenuItem(
                                  value: location['id'].toString(),
                                  child: Text(location['name'].toString())))
                              .toList(),
                          onChanged: (value) => setDialogState(() {
                                locationId = value;
                                stockId = null;
                              })),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          initialValue: locationStocks
                                  .any((stock) => stock['id'] == stockId)
                              ? stockId
                              : null,
                          decoration: const InputDecoration(
                              labelText: 'Gefundener Lagerplatz'),
                          items: [
                            const DropdownMenuItem<String>(
                                value: null, child: Text('Kein Lagerplatz')),
                            ...locationStocks.map((stock) => DropdownMenuItem(
                                value: stock['id'].toString(),
                                child: Text(stock['path']?.toString() ??
                                    stock['name'].toString())))
                          ],
                          onChanged: (value) =>
                              setDialogState(() => stockId = value)),
                      const SizedBox(height: 12),
                      TextField(
                          controller: notes,
                          minLines: 2,
                          maxLines: 4,
                          decoration:
                              const InputDecoration(labelText: 'Notizen')),
                      if ((entry['attempts'] as List? ?? const []).isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                    'Nachzählung ${((entry['attempts'] as List).length) + 1}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall))),
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () {
                        if (bulk &&
                            double.tryParse(
                                    quantity.text.replaceAll(',', '.')) ==
                                null) {
                          message('Bitte eine gültige Ist-Menge eingeben.',
                              error: true);
                          return;
                        }
                        Navigator.pop(context, {
                          'actualQuantity': bulk
                              ? double.parse(quantity.text.replaceAll(',', '.'))
                              : null,
                          'result': bulk ? null : result,
                          'actualLocationId': locationId,
                          'actualStockStructureId': stockId,
                          'notes': notes.text.trim()
                        });
                      },
                      child: Text(entry['countedAt'] == null
                          ? 'Zählung speichern'
                          : 'Nachzählung speichern'))
                ],
              );
            }));
    quantity.dispose();
    notes.dispose();
    if (values == null) return;
    final data = await request(
        '/api/stocktakes/${widget.stocktakeId}/entries/${entry['id']}',
        method: 'PUT',
        body: values);
    if (data != null) {
      setState(() => stocktake = Map<String, dynamic>.from(data));
    }
  }

  Future<void> _export(String selection) async {
    final parts = selection.split(':');
    final format = parts[0];
    final differences = parts.contains('differences');
    final blank = parts.contains('blank');
    final data = await request(
        '/api/stocktakes/${widget.stocktakeId}/export?format=$format&blank=$blank&differences=$differences');
    if (data == null) return;
    await FileSaver.instance.saveFile(
        name: data['fileName'].toString().replaceFirst(RegExp(r'\.[^.]+$'), ''),
        bytes: base64Decode(data['fileBase64']),
        fileExtension: format,
        mimeType: MimeType.custom,
        customMimeType: fileMimeType(format));
    message('Datei wurde erstellt.');
  }

  Future<void> _import() async {
    final file = await FilePicker.pickFile(
        type: FileType.custom, allowedExtensions: const ['xlsx', 'ods']);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final data = await request('/api/stocktakes/${widget.stocktakeId}/import',
        method: 'POST',
        body: {'fileName': file.name, 'fileBase64': base64Encode(bytes)});
    if (data != null) {
      message(
          '${data['imported']} Positionen importiert, ${data['skipped']} übersprungen.');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Scaffold(
          appBar: AppBar(title: const Text('Inventur')),
          body: const Center(child: CircularProgressIndicator()));
    }
    final data = stocktake;
    if (data == null) {
      return Scaffold(
          appBar: AppBar(title: const Text('Inventur')),
          body: const Center(child: Text('Inventur nicht gefunden.')));
    }
    final status = data['status']?.toString() ?? '';
    final progress =
        Map<String, dynamic>.from(data['progress'] as Map? ?? const {});
    return Scaffold(
      appBar:
          AppBar(title: Text(data['name']?.toString() ?? 'Inventur'), actions: [
        if (can('stocktakes.export'))
          PopupMenuButton<String>(
              tooltip: 'Listen und Berichte',
              onSelected: _export,
              itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'pdf:blank', child: Text('Zählliste als PDF')),
                    PopupMenuItem(
                        value: 'xlsx:blank', child: Text('Zählliste als XLSX')),
                    PopupMenuItem(
                        value: 'ods:blank', child: Text('Zählliste als ODS')),
                    PopupMenuDivider(),
                    PopupMenuItem(
                        value: 'pdf', child: Text('Ergebnis als PDF')),
                    PopupMenuItem(
                        value: 'xlsx', child: Text('Ergebnis als XLSX')),
                    PopupMenuItem(
                        value: 'ods', child: Text('Ergebnis als ODS')),
                    PopupMenuDivider(),
                    PopupMenuItem(
                        value: 'pdf:differences',
                        child: Text('Differenzliste als PDF')),
                    PopupMenuItem(
                        value: 'xlsx:differences',
                        child: Text('Differenzliste als XLSX')),
                    PopupMenuItem(
                        value: 'ods:differences',
                        child: Text('Differenzliste als ODS')),
                  ]),
        IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren'),
      ]),
      floatingActionButton: status == 'In Arbeit' && can('stocktakes.count')
          ? FloatingActionButton.extended(
              onPressed: () => _scan(),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scannen'))
          : null,
      body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Chip(label: Text(status)),
                                    Chip(
                                        avatar: const Icon(Icons.person_outline,
                                            size: 18),
                                        label: Text(data['responsibleName']
                                                ?.toString() ??
                                            '-')),
                                    Chip(
                                        avatar: Icon(data['method'] == 'offline'
                                            ? Icons.print_outlined
                                            : Icons.smartphone),
                                        label: Text(data['method'] == 'offline'
                                            ? 'Papier/Offline'
                                            : 'Digital')),
                                    Chip(
                                        label: Text(data['countMode'] == 'blind'
                                            ? 'Blindzählung'
                                            : 'Offene Zählung')),
                                  ]),
                              const SizedBox(height: 10),
                              LinearProgressIndicator(
                                  value: (num.tryParse(progress['total']
                                                      ?.toString() ??
                                                  '') ??
                                              0) ==
                                          0
                                      ? 0
                                      : (num.tryParse(progress['counted']
                                                      ?.toString() ??
                                                  '') ??
                                              0) /
                                          (num.tryParse(progress['total']
                                                      ?.toString() ??
                                                  '') ??
                                              1)),
                              const SizedBox(height: 8),
                              Text(
                                  '${progress['counted']} von ${progress['total']} gezählt · ${progress['discrepancies']} Abweichungen · ${(data['findings'] as List? ?? const []).length} Fundstücke'),
                              if ((data['notes']?.toString() ?? '').isNotEmpty)
                                Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(data['notes'].toString())),
                              const SizedBox(height: 12),
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                if (status == 'Angelegt' &&
                                    can('stocktakes.count'))
                                  FilledButton.icon(
                                      onPressed: () => _transition('start'),
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('Inventur starten')),
                                if (status == 'In Arbeit' &&
                                    can('stocktakes.evaluate'))
                                  FilledButton.icon(
                                      onPressed: () => _transition('evaluate'),
                                      icon:
                                          const Icon(Icons.analytics_outlined),
                                      label: const Text('Auswertung starten')),
                                if (status == 'Auswertung' &&
                                    can('stocktakes.evaluate'))
                                  FilledButton.icon(
                                      onPressed: () => _transition('complete'),
                                      icon: const Icon(Icons.verified_outlined),
                                      label: const Text('Abschließen')),
                                if (status == 'In Arbeit' &&
                                    data['method'] == 'offline' &&
                                    can('stocktakes.count'))
                                  OutlinedButton.icon(
                                      onPressed: _import,
                                      icon: const Icon(Icons.upload_file),
                                      label: const Text(
                                          'Ausgefüllte Tabelle importieren')),
                              ]),
                            ]))),
                const SizedBox(height: 12),
                if (status == 'In Arbeit')
                  TextField(
                    controller: handScanner,
                    focusNode: handScannerFocus,
                    decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.barcode_reader),
                        labelText: 'Handscanner: Inventarnummer scannen',
                        suffixIcon: IconButton(
                            onPressed: () => _scan(handScanner.text),
                            icon: const Icon(Icons.arrow_forward))),
                    onSubmitted: _scan,
                  ),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  SizedBox(
                      width: 330,
                      child: TextField(
                          decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              labelText: 'Positionen durchsuchen'),
                          onChanged: (value) => setState(() => query = value))),
                  SizedBox(
                      width: 180,
                      child: DropdownButtonFormField<String>(
                          initialValue: filter,
                          decoration:
                              const InputDecoration(labelText: 'Filter'),
                          items: const [
                            'Alle',
                            'Offen',
                            'Gezählt',
                            'Abweichung'
                          ]
                              .map((value) => DropdownMenuItem(
                                  value: value, child: Text(value)))
                              .toList(),
                          onChanged: (value) =>
                              setState(() => filter = value!))),
                ]),
                const SizedBox(height: 12),
                ...entries.map((entry) {
                  final discrepancies =
                      (entry['discrepancies'] as List? ?? const [])
                          .map((value) => value.toString())
                          .toList();
                  final counted = entry['countedAt'] != null;
                  return Card(
                      child: ListTile(
                    leading: CircleAvatar(
                        backgroundColor: discrepancies.isNotEmpty
                            ? Colors.orange.shade100
                            : counted
                                ? Colors.green.shade100
                                : Colors.grey.shade200,
                        child: Icon(discrepancies.isNotEmpty
                            ? Icons.warning_amber
                            : counted
                                ? Icons.check
                                : Icons.hourglass_empty)),
                    title:
                        Text('${entry['inventoryNumber']} · ${entry['name']}'),
                    subtitle: Text(
                        '${entry['expectedLocationName'] ?? '-'} / ${entry['expectedStockStructureName'] ?? '-'}\n${counted ? entry['itemType'] == 'bulk' ? 'Ist: ${entry['actualQuantity']} ${entry['unit']}' : 'Ergebnis: ${entry['result']}' : 'Noch nicht gezählt'}${discrepancies.isNotEmpty ? ' · ${discrepancies.join(', ')}' : ''}${counted ? '\n${entry['countedByName']} · ${entry['attempts']?.length ?? 1}. Zählung' : ''}'),
                    isThreeLine: true,
                    trailing: status == 'In Arbeit' && can('stocktakes.count')
                        ? IconButton(
                            onPressed: () => _count(entry),
                            tooltip: counted ? 'Nachzählen' : 'Zählen',
                            icon: Icon(
                                counted ? Icons.replay : Icons.edit_outlined))
                        : null,
                    onTap: status == 'In Arbeit' && can('stocktakes.count')
                        ? () => _count(entry)
                        : null,
                  ));
                }),
                if (entries.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(32),
                      child:
                          Center(child: Text('Keine passenden Positionen.'))),
                if ((data['findings'] as List? ?? const []).isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text('Unbekannte Fundstücke',
                      style: Theme.of(context).textTheme.titleLarge),
                  ...(data['findings'] as List).map((finding) => ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: Text(finding['inventoryNumber'].toString()),
                      subtitle: Text(finding['notes']?.toString() ?? ''))),
                ],
                if (data['method'] == 'offline') ...[
                  const SizedBox(height: 18),
                  Text('Eingescannte Listen',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                      'PDF-, JPG-, PNG-, XLSX- oder ODS-Datei an inventur@materialkompass.org senden. Betreff oder Dateiname muss „${data['id']}“ enthalten.',
                      style: Theme.of(context).textTheme.bodySmall),
                  if (emailImports.isEmpty)
                    const ListTile(
                        leading: Icon(Icons.mark_email_unread_outlined),
                        title:
                            Text('Noch keine Liste per E-Mail eingegangen.')),
                  ...emailImports.map((email) => Card(
                        child: ExpansionTile(
                          leading: Icon(email['status'] == 'verarbeitet'
                              ? Icons.mark_email_read_outlined
                              : Icons.mark_email_unread_outlined),
                          title: Text(
                              email['subject']?.toString() ?? 'Inventurliste'),
                          subtitle: Text(
                              '${email['senderName'] ?? email['sender'] ?? ''} · ${email['status']}'),
                          children: [
                            ...(email['attachments'] as List? ?? const [])
                                .map((attachment) => ListTile(
                                      leading: const Icon(Icons.attach_file),
                                      title: Text(
                                          attachment['fileName'].toString()),
                                      subtitle: Text(
                                          '${((attachment['sizeBytes'] ?? 0) / 1024).round()} KB'),
                                      trailing: IconButton(
                                        tooltip: 'Anhang öffnen/herunterladen',
                                        icon: const Icon(Icons.download),
                                        onPressed: () =>
                                            _downloadEmailAttachment(
                                                email,
                                                Map<String, dynamic>.from(
                                                    attachment as Map)),
                                      ),
                                    )),
                            if (email['status'] != 'verarbeitet' &&
                                can('stocktakes.count'))
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: FilledButton.icon(
                                  onPressed: () => _markEmailProcessed(email),
                                  icon: const Icon(Icons.done_all),
                                  label: const Text(
                                      'Nach Übertragung als verarbeitet markieren'),
                                ),
                              ),
                          ],
                        ),
                      )),
                ],
              ])),
    );
  }
}
