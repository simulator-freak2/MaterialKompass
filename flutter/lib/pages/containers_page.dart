import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';
import '../services/authenticated_api_client.dart';
import '../services/document_output_service.dart';
import '../services/download_service.dart';

typedef ContainerRequest =
    Future<dynamic> Function(String path, {String method, Object? body});

const containerCheckResults = <String>[
  'vorhanden',
  'fehlt',
  'beschädigt',
  'abgelaufen',
];

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : <Map<String, dynamic>>[];

String _text(Object? value, [String fallback = '-']) {
  final result = value?.toString().trim() ?? '';
  return result.isEmpty ? fallback : result;
}

String _germanDate(Object? value) {
  final raw = value?.toString() ?? '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw.isEmpty ? '-' : raw;
  final local = raw.length <= 10 ? parsed : parsed.toLocal();
  final date =
      '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
  if (raw.length <= 10) return date;
  return '$date ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

Color _completenessColor(BuildContext context, String status) {
  switch (status) {
    case 'Vollständig':
      return Colors.green.shade700;
    case 'Unvollständig':
      return Theme.of(context).colorScheme.error;
    default:
      return Colors.blueGrey;
  }
}

Widget _chip(
  BuildContext context,
  String label, {
  Color? color,
  IconData? icon,
}) {
  final effective = color ?? Theme.of(context).colorScheme.primary;
  return Chip(
    visualDensity: VisualDensity.compact,
    avatar: icon == null ? null : Icon(icon, size: 16, color: effective),
    label: Text(label),
    side: BorderSide(color: effective.withValues(alpha: 0.5)),
    labelStyle: TextStyle(color: effective, fontSize: 12),
  );
}

List<Widget> containerStatusChips(
  BuildContext context,
  Map<String, dynamic> container,
) {
  final completeness = _text(container['completenessStatus'], 'Ungeprüft');
  final safety = _map(container['safetyStatus']);
  final expired = int.tryParse('${container['expiredCount'] ?? 0}') ?? 0;
  final soon = int.tryParse('${container['expiringSoonCount'] ?? 0}') ?? 0;
  final missing = int.tryParse('${container['packListMissingCount'] ?? ''}');
  return [
    _chip(
      context,
      completeness,
      color: _completenessColor(context, completeness),
      icon: completeness == 'Vollständig'
          ? Icons.verified_outlined
          : Icons.rule_outlined,
    ),
    if (container['needsStorageAssignment'] == true)
      _chip(
        context,
        'Kein Lagerplatz',
        color: Theme.of(context).colorScheme.error,
        icon: Icons.location_off_outlined,
      ),
    if (missing != null && missing > 0)
      _chip(
        context,
        '$missing Soll-Abweichung${missing == 1 ? '' : 'en'}',
        color: Colors.orange.shade800,
        icon: Icons.playlist_remove,
      ),
    if (expired > 0)
      _chip(
        context,
        '$expired abgelaufen',
        color: Theme.of(context).colorScheme.error,
        icon: Icons.event_busy_outlined,
      ),
    if (soon > 0)
      _chip(
        context,
        '$soon läuft bald ab',
        color: Colors.orange.shade800,
        icon: Icons.schedule_outlined,
      ),
    if (safety['blocked'] == true)
      _chip(
        context,
        'Gesperrter Inhalt',
        color: Theme.of(context).colorScheme.error,
        icon: Icons.block,
      ),
  ];
}

Future<String?> showContainerScanDialog(BuildContext context) async {
  final manual = TextEditingController();
  var completed = false;
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Kiste scannen'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: manual,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Handscanner / Kisten- oder Inventarnummer',
                helperText:
                    'Kiste oder einen darin gelagerten Artikel scannen.',
              ),
              onSubmitted: (value) => Navigator.pop(context, value.trim()),
            ),
            if (isCameraScanningSupported) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 260,
                child: MobileScanner(
                  onDetect: (capture) {
                    final code = capture.barcodes.firstOrNull?.rawValue;
                    if (code != null && !completed) {
                      completed = true;
                      Navigator.pop(context, code);
                    }
                  },
                ),
              ),
            ] else
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Am PC kann ein USB-Handscanner verwendet werden.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, manual.text.trim()),
          child: const Text('Übernehmen'),
        ),
      ],
    ),
  );
  manual.dispose();
  final code = value?.trim() ?? '';
  return code.isEmpty ? null : code;
}

/// Lagerplätze, Gebäude und Kisten, die als Ziel ausgewählt werden können.
class ContainerStorageTargets {
  const ContainerStorageTargets({
    this.locations = const [],
    this.stockStructures = const [],
    this.containers = const [],
  });

  factory ContainerStorageTargets.fromJson(Object? value) {
    final data = _map(value);
    return ContainerStorageTargets(
      locations: _maps(data['locations']),
      stockStructures: _maps(data['stockStructures']),
      containers: _maps(data['containers']),
    );
  }

  final List<Map<String, dynamic>> locations;
  final List<Map<String, dynamic>> stockStructures;
  final List<Map<String, dynamic>> containers;
}

Future<ContainerStorageTargets> _loadTargets(ContainerRequest request) async {
  final result = await request('/api/containers/storage-targets');
  return ContainerStorageTargets.fromJson(result);
}

String _containerTitle(Map<String, dynamic> container) =>
    '${_text(container['code'])} · ${_text(container['name'], 'Kiste')}';

class ContainersPage extends StatefulWidget {
  const ContainersPage({required this.token, this.request, super.key});

  final String token;
  final ContainerRequest? request;

  @override
  State<ContainersPage> createState() => _ContainersPageState();
}

class _ContainersPageState extends State<ContainersPage> {
  late final AuthenticatedApiClient api;
  List<Map<String, dynamic>> containers = [];
  List<Map<String, dynamic>> expiring = [];
  Set<String> permissions = {};
  bool loading = true;
  bool showExpiring = false;
  String query = '';

  bool can(String permission) => permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    api = AuthenticatedApiClient(widget.token);
    unawaited(_load());
  }

  Future<dynamic> _request(
    String path, {
    String method = 'GET',
    Object? body,
    bool quiet = false,
  }) async {
    try {
      return await (widget.request?.call(path, method: method, body: body) ??
          api.request(path, method: method, body: body));
    } on AuthenticatedApiException catch (error) {
      if (mounted && !quiet) _message(error.message, error: true);
      return null;
    } on DownloadException catch (error) {
      if (mounted && !quiet) _message(error.message, error: true);
      return null;
    }
  }

  void _message(String value, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    final results = await Future.wait([
      _request('/api/auth/me', quiet: true),
      _request('/api/containers', quiet: true),
      _request('/api/containers/expiring?days=60', quiet: true),
    ]);
    if (!mounted) return;
    final user = _map(_map(results[0])['user']);
    setState(() {
      permissions = (user['permissions'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toSet();
      containers = _maps(results[1]);
      expiring = _maps(results[2]);
      loading = false;
    });
  }

  List<Map<String, dynamic>> get filtered {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return containers;
    return containers
        .where(
          (entry) => [
            entry['code'],
            entry['name'],
            entry['containerType'],
            entry['storagePath'],
          ].any((value) => '${value ?? ''}'.toLowerCase().contains(needle)),
        )
        .toList();
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContainerDetailPage(
          containerId: id,
          permissions: permissions,
          request: (path, {method = 'GET', body}) =>
              _request(path, method: method, body: body),
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _scan() async {
    final code = await showContainerScanDialog(context);
    if (code == null || !mounted) return;
    final result = await _request(
      '/api/containers/lookup?code=${Uri.encodeQueryComponent(code)}',
    );
    if (result is! Map || !mounted) return;
    final data = Map<String, dynamic>.from(result);
    final container = _map(data['container']);
    if (container['id'] != null) {
      if (data['match'] == 'content') {
        _message('Der Artikel liegt in Kiste ${container['code']}.');
      }
      await _open(container['id'].toString());
    } else {
      _message(
        '${data['inventoryNumber']} ist keiner Kiste zugeordnet.',
        error: true,
      );
    }
  }

  Future<void> _create() async {
    final targets = await _loadTargets(
      (path, {method = 'GET', body}) =>
          _request(path, method: method, body: body),
    );
    if (!mounted) return;
    if (targets.stockStructures.isEmpty) {
      _message(
        'Es sind noch keine Lagerplätze angelegt. Eine Kiste muss einem '
        'Lagerplatz zugewiesen werden.',
        error: true,
      );
      return;
    }
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          ContainerSettingsDialog(stockStructures: targets.stockStructures),
    );
    if (values == null) return;
    final created = await _request(
      '/api/containers',
      method: 'POST',
      body: values,
    );
    if (created is Map && mounted) {
      _message('Kiste ${created['code']} wurde angelegt.');
      await _open(created['id'].toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kisten'),
        actions: [
          IconButton(
            tooltip: 'Kiste scannen',
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner),
          ),
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: can('containers.manage')
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Kiste anlegen'),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Kisten durchsuchen',
                    ),
                    onChanged: (value) => setState(() => query = value),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: [
                      const ButtonSegment(
                        value: false,
                        icon: Icon(Icons.inventory_2_outlined),
                        label: Text('Kisten'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: const Icon(Icons.event_busy_outlined),
                        label: Text('Ablaufende Inhalte (${expiring.length})'),
                      ),
                    ],
                    selected: {showExpiring},
                    onSelectionChanged: (value) =>
                        setState(() => showExpiring = value.first),
                  ),
                  const SizedBox(height: 12),
                  if (!showExpiring) ...[
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            'Noch keine Kisten vorhanden. Eine Kiste ist ein '
                            'eigener Lagerort und wird einem Lagerplatz '
                            'zugewiesen.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ...list.map(
                      (entry) => Card(
                        child: ListTile(
                          leading: const CircleAvatar(
                            child: Icon(Icons.inventory_2_outlined),
                          ),
                          title: Text(_containerTitle(entry)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_text(entry['containerType'], 'Kiste')} · '
                                '${entry['itemCount'] ?? 0} mit Inventarnummer · '
                                '${entry['contentCount'] ?? 0} ohne Inventarnummer\n'
                                'Lagerplatz: ${_text(entry['stockStructureName'] ?? entry['locationName'], 'nicht zugewiesen')}',
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: containerStatusChips(context, entry),
                              ),
                            ],
                          ),
                          isThreeLine: true,
                          onTap: () => _open(entry['id'].toString()),
                        ),
                      ),
                    ),
                  ] else ...[
                    if (expiring.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            'In den nächsten 60 Tagen läuft kein Inhalt ab.',
                          ),
                        ),
                      ),
                    ...expiring.map(
                      (entry) => Card(
                        child: ListTile(
                          leading: Icon(
                            entry['expiryState'] == 'abgelaufen'
                                ? Icons.event_busy
                                : Icons.schedule,
                            color: entry['expiryState'] == 'abgelaufen'
                                ? Theme.of(context).colorScheme.error
                                : Colors.orange.shade800,
                          ),
                          title: Text(_text(entry['name'])),
                          subtitle: Text(
                            'Kiste ${entry['containerCode']} · '
                            '${entry['containerName']}\n'
                            '${entry['quantity']} ${entry['unit']} · '
                            '${entry['expiryState']}: ${_germanDate(entry['expiresAt'])}',
                          ),
                          isThreeLine: true,
                          onTap: () => _open(entry['containerId'].toString()),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class ContainerDetailPage extends StatefulWidget {
  const ContainerDetailPage({
    required this.containerId,
    required this.permissions,
    required this.request,
    super.key,
  });

  final String containerId;
  final Set<String> permissions;
  final ContainerRequest request;

  @override
  State<ContainerDetailPage> createState() => _ContainerDetailPageState();
}

class _ContainerDetailPageState extends State<ContainerDetailPage> {
  Map<String, dynamic>? container;
  bool loading = true;

  bool can(String permission) => widget.permissions.contains(permission);

  String get _base => '/api/containers/${widget.containerId}';

  List<String> get _compartments =>
      (container?['compartments'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toList();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _message(String value, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _load() async {
    final result = await widget.request(_base);
    if (!mounted) return;
    setState(() {
      container = result is Map ? Map<String, dynamic>.from(result) : null;
      loading = false;
    });
  }

  bool _queued(Object? result) =>
      result is Map && result['offlineQueued'] == true;

  Future<bool> _mutate(
    String path, {
    String method = 'POST',
    Object? body,
    String? success,
  }) async {
    final result = await widget.request(path, method: method, body: body);
    if (result == null || !mounted) return false;
    if (_queued(result)) {
      _message('Offline vorgemerkt – wird bei Verbindung übertragen.');
    } else if (success != null) {
      _message(success);
    }
    await _load();
    return true;
  }

  Future<void> _edit() async {
    final current = container;
    if (current == null) return;
    final targets = await _loadTargets(widget.request);
    if (!mounted) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContainerSettingsDialog(
        container: current,
        stockStructures: targets.stockStructures,
      ),
    );
    if (values == null) return;
    await _mutate(
      _base,
      method: 'PUT',
      body: values,
      success: values['stockStructureId'] != current['stockStructureId']
          ? 'Kiste wurde umgesetzt. Die Artikel mit Inventarnummer wurden mitgebucht.'
          : 'Kiste wurde gespeichert.',
    );
  }

  Future<void> _dissolve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kiste auflösen?'),
        content: const Text(
          'Die leere Kiste wird als Lagerort aufgelöst. Aktive Packlisten '
          'werden beendet, Prüfprotokolle bleiben erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Auflösen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await widget.request(_base, method: 'DELETE');
    if (result != null && mounted) Navigator.of(context).pop();
  }

  Future<void> _bookIn() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => BookItemDialog(
        loadCandidates: (query) async {
          final result = await widget.request(
            '$_base/candidates?query=${Uri.encodeQueryComponent(query)}',
          );
          return _maps(result);
        },
      ),
    );
    if (values == null) return;
    await _mutate(
      '$_base/items',
      body: values,
      success: 'Artikel wurde in die Kiste gebucht.',
    );
  }

  Future<void> _relocateItem(Map<String, dynamic> item) async {
    final targets = await _loadTargets(widget.request);
    if (!mounted) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RelocateItemDialog(
        item: item,
        targets: targets,
        currentContainerId: widget.containerId,
      ),
    );
    if (values == null) return;
    await _mutate(
      '$_base/items/${item['entityType']}/${item['entityId']}/relocate',
      body: values,
      success: '${item['inventoryNumber']} wurde umgebucht.',
    );
  }

  Future<void> _addContent() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContentEditDialog(compartments: _compartments),
    );
    if (values == null) return;
    await _mutate(
      '$_base/contents',
      body: values,
      success: 'Inhalt wurde erfasst.',
    );
  }

  Future<void> _editContent(Map<String, dynamic> entry) async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          ContentEditDialog(entry: entry, compartments: _compartments),
    );
    if (values == null) return;
    await _mutate(
      '$_base/contents/${entry['id']}',
      method: 'PUT',
      body: values,
      success: 'Inhalt wurde gespeichert.',
    );
  }

  Future<void> _removeContent(Map<String, dynamic> entry) async {
    var reason = 'Verbraucht';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Inhalt ausbuchen?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${entry['quantity']} ${entry['unit']} ${entry['name']} werden '
                'aus der Kiste ausgebucht. Inhalte ohne Inventarnummer können '
                'nicht auf andere Lagerorte umgebucht werden.',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: reason,
                decoration: const InputDecoration(labelText: 'Grund'),
                items: const ['Verbraucht', 'Entsorgt', 'Verloren']
                    .map(
                      (value) =>
                          DropdownMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => reason = value ?? 'Verbraucht'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Ausbuchen'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _mutate(
      '$_base/contents/${entry['id']}?reason=${Uri.encodeQueryComponent(reason)}',
      method: 'DELETE',
      success: 'Inhalt wurde ausgebucht.',
    );
  }

  Future<void> _createPackList() async {
    final current = container;
    if (current == null) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PackListDialog(container: current),
    );
    if (values == null) return;
    await _mutate(
      '$_base/pack-lists',
      body: values,
      success: 'Packliste wurde gespeichert.',
    );
  }

  Future<void> _activatePackList(Map<String, dynamic> list) async {
    await _mutate(
      '$_base/pack-lists/${list['id']}/activate',
      body: const {},
      success: 'Packliste Version ${list['version']} ist aktiv.',
    );
  }

  Future<void> _check() async {
    final current = container;
    if (current == null) return;
    final template = _map(current['checkTemplate']);
    if (_maps(template['items']).isEmpty) {
      _message(
        'Die Kiste hat weder eine Packliste noch einen Inhalt.',
        error: true,
      );
      return;
    }
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContainerCheckDialog(template: template),
    );
    if (values == null) return;
    final result = await widget.request(
      '$_base/checks',
      method: 'POST',
      body: values,
    );
    if (result is! Map || !mounted) return;
    if (_queued(result)) {
      _message('Prüfung offline vorgemerkt – wird bei Verbindung übertragen.');
      return;
    }
    final complete = result['complete'] == true;
    final defects = (result['defectNumbers'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toList();
    _message(
      complete
          ? 'Kiste ist vollständig.'
          : 'Kiste ist unvollständig'
                '${defects.isNotEmpty ? ' – Mangel ${defects.join(', ')} angelegt' : ''}.',
      error: !complete,
    );
    setState(() => container = _map(result['container']));
  }

  Future<void> _print({required bool save}) async {
    final result = await widget.request('$_base/pack-list/print');
    if (result is! Map) return;
    try {
      if (save) {
        await DocumentOutputService.instance.savePayload(result);
      } else {
        await DocumentOutputService.instance.printPdfPayload(
          result,
          fallbackFileName: 'packliste.pdf',
        );
      }
    } on DownloadException catch (error) {
      if (mounted) _message(error.message, error: true);
    }
  }

  Widget _section(
    String title,
    List<Widget> children, {
    Widget? action,
    String? subtitle,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?action,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _itemTile(Map<String, dynamic> item, bool editable) {
    final safety = _map(item['safetyStatus']);
    final details = <String>[
      if (item['itemType'] == 'bulk') '${item['quantity']} ${item['unit']}',
      if (item['entityType'] == 'ClothingItem')
        'Kleidung${item['size'] != null ? ' · Größe ${item['size']}' : ''}',
      if (item['issued'] == true) 'Ausgegeben',
      if (_text(item['status'], '') != '' &&
          item['status'] != 'Lagernd' &&
          item['issued'] != true)
        '${item['status']}',
      if (safety['blocked'] == true) 'Sicherheitsbedingt gesperrt',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        item['entityType'] == 'ClothingItem'
            ? Icons.checkroom
            : Icons.qr_code_2_outlined,
        color: safety['blocked'] == true
            ? Theme.of(context).colorScheme.error
            : null,
      ),
      title: Text('${_text(item['inventoryNumber'])} · ${item['name']}'),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      trailing: editable && item['relocatable'] == true
          ? IconButton(
              tooltip: 'Umbuchen',
              onPressed: item['issued'] == true
                  ? null
                  : () => _relocateItem(item),
              icon: const Icon(Icons.move_up_outlined),
            )
          : null,
    );
  }

  Widget _contentTile(Map<String, dynamic> entry, bool editable) {
    final expiry = entry['expiryState']?.toString();
    final details = <String>[
      '${entry['quantity']} ${entry['unit']}',
      if (_text(entry['position'], '') != '') 'Fach ${entry['position']}',
      if (entry['expiresAt'] != null)
        'Ablauf ${_germanDate(entry['expiresAt'])}${expiry != null ? ' ($expiry)' : ''}',
      if (_text(entry['batchNumber'], '') != '')
        'Charge ${entry['batchNumber']}',
      if (_text(entry['notes'], '') != '') '${entry['notes']}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.category_outlined,
        color: expiry == 'abgelaufen'
            ? Theme.of(context).colorScheme.error
            : expiry != null
            ? Colors.orange.shade800
            : null,
      ),
      title: Text(_text(entry['name'])),
      subtitle: Text(details.join(' · ')),
      trailing: editable
          ? PopupMenuButton<String>(
              tooltip: 'Aktionen',
              onSelected: (value) {
                if (value == 'edit') unawaited(_editContent(entry));
                if (value == 'remove') unawaited(_removeContent(entry));
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                PopupMenuItem(value: 'remove', child: Text('Ausbuchen')),
              ],
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = container;
    if (loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kiste')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (current == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kiste')),
        body: const Center(child: Text('Die Kiste wurde nicht gefunden.')),
      );
    }
    final items = _maps(current['items']);
    final contents = _maps(current['contents']);
    final deviation = _map(current['packListDeviation']);
    final packLists = _maps(current['packLists']);
    final checks = _maps(current['checks']);
    final safety = _map(current['safetyStatus']);
    final warnings = (safety['warnings'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toList();
    final reasons = (safety['reasons'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toList();
    final editable = can('containers.pack');
    final assigned = current['needsStorageAssignment'] != true;
    return Scaffold(
      appBar: AppBar(
        title: Text(_containerTitle(current)),
        actions: [
          if (can('containers.print'))
            PopupMenuButton<String>(
              tooltip: 'Packliste ausgeben',
              icon: const Icon(Icons.print_outlined),
              onSelected: (value) => _print(save: value == 'save'),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'print', child: Text('Packliste drucken')),
                PopupMenuItem(
                  value: 'save',
                  child: Text('Packliste als PDF speichern'),
                ),
              ],
            ),
          if (can('containers.manage'))
            PopupMenuButton<String>(
              tooltip: 'Kiste verwalten',
              onSelected: (value) {
                if (value == 'edit') unawaited(_edit());
                if (value == 'dissolve') unawaited(_dissolve());
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Text('Bearbeiten / Lagerplatz ändern'),
                ),
                PopupMenuItem(
                  value: 'dissolve',
                  enabled: items.isEmpty && contents.isEmpty,
                  child: const Text('Kiste auflösen'),
                ),
              ],
            ),
        ],
      ),
      floatingActionButton: can('containers.check')
          ? FloatingActionButton.extended(
              onPressed: _check,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Vollständigkeit prüfen'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            _section('Kiste ${_text(current['code'])}', [
              Text(
                '${_text(current['containerType'], 'Kiste')} · Lagerplatz: '
                '${_text(current['stockStructureName'] ?? current['locationName'], 'nicht zugewiesen')}',
              ),
              if (_text(current['fullCode'], '') != '')
                Text('Lagerortkennung: ${current['fullCode']}'),
              if (!assigned)
                Text(
                  'Die Kiste ist noch keinem Lagerplatz zugewiesen. Bitte über '
                  '„Bearbeiten / Lagerplatz ändern“ zuweisen.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (current['lastCheckAt'] != null)
                Text(
                  'Zuletzt geprüft: ${_germanDate(current['lastCheckAt'])} '
                  'durch ${_text(current['lastCheckBy'])}',
                ),
              if (_text(current['containerNotes'], '') != '')
                Text(current['containerNotes'].toString()),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: containerStatusChips(context, current),
              ),
              ...reasons.map(
                (reason) => Text(
                  reason,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              ...warnings.map(
                (warning) => Text(
                  warning,
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
            ]),
            _section(
              'Artikel mit Inventarnummer (${items.length})',
              [
                if (items.isEmpty)
                  const Text('Keine inventarisierten Artikel in der Kiste.'),
                ...items.map((entry) => _itemTile(entry, editable)),
              ],
              subtitle:
                  'Die Kiste ist ihr Lagerort. Sie können wie bei jedem '
                  'anderen Lagerort umgebucht werden.',
              action: editable && assigned
                  ? FilledButton.tonalIcon(
                      onPressed: _bookIn,
                      icon: const Icon(Icons.move_down_outlined),
                      label: const Text('Einlagern'),
                    )
                  : null,
            ),
            _section(
              'Inhalt ohne Inventarnummer (${contents.length})',
              [
                if (contents.isEmpty)
                  const Text('Kein Inhalt ohne Inventarnummer erfasst.'),
                ...contents.map((entry) => _contentTile(entry, editable)),
              ],
              subtitle:
                  'Gehört fest zur Kiste und kann nicht auf andere Lagerorte '
                  'umgebucht, sondern nur geändert oder ausgebucht werden.',
              action: editable
                  ? FilledButton.tonalIcon(
                      onPressed: _addContent,
                      icon: const Icon(Icons.add),
                      label: const Text('Inhalt erfassen'),
                    )
                  : null,
            ),
            _section(
              deviation.isEmpty
                  ? 'Soll-Packliste'
                  : 'Soll/Ist – ${deviation['name']} (Version ${deviation['version']})',
              [
                if (deviation.isEmpty)
                  const Text(
                    'Keine aktive Packliste. Die Prüfung erfolgt gegen den '
                    'aktuellen Inhalt.',
                  )
                else
                  ..._maps(deviation['rows']).map((row) {
                    final difference =
                        int.tryParse('${row['deviation'] ?? 0}') ?? 0;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        difference < 0
                            ? Icons.remove_circle_outline
                            : difference > 0
                            ? Icons.add_circle_outline
                            : Icons.check_circle_outline,
                        color: difference < 0
                            ? Theme.of(context).colorScheme.error
                            : difference > 0
                            ? Colors.orange.shade800
                            : Colors.green.shade700,
                      ),
                      title: Text(
                        row['inventoryNumber'] == null
                            ? _text(row['name'])
                            : '${row['inventoryNumber']} · ${row['name']}',
                      ),
                      subtitle: Text(
                        'Soll ${row['targetQuantity']} · Ist ${row['actualQuantity']} '
                        '${row['unit']}${_text(row['position'], '') != '' ? ' · Fach ${row['position']}' : ''}',
                      ),
                    );
                  }),
                if (packLists.isNotEmpty) ...[
                  const Divider(),
                  Text(
                    'Versionen',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  ...packLists.map(
                    (list) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Version ${list['version']} · ${list['name']}',
                      ),
                      subtitle: Text(
                        '${list['status']} · ${(list['items'] as List? ?? const []).length} Position(en) · '
                        '${_germanDate(list['createdAt'])} · ${list['createdBy']}',
                      ),
                      trailing:
                          list['status'] == 'Entwurf' &&
                              can('containers.packlists')
                          ? TextButton(
                              onPressed: () => _activatePackList(list),
                              child: const Text('Aktivieren'),
                            )
                          : null,
                    ),
                  ),
                ],
              ],
              action: can('containers.packlists')
                  ? FilledButton.tonalIcon(
                      onPressed: _createPackList,
                      icon: const Icon(Icons.playlist_add),
                      label: const Text('Neue Version'),
                    )
                  : null,
            ),
            _section('Prüfprotokolle', [
              if (checks.isEmpty)
                const Text('Noch keine Prüfung durchgeführt.'),
              ...checks.map(
                (check) => ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: Icon(
                    check['complete'] == true
                        ? Icons.verified_outlined
                        : Icons.report_problem_outlined,
                    color: check['complete'] == true
                        ? Colors.green.shade700
                        : Theme.of(context).colorScheme.error,
                  ),
                  title: Text(
                    '${_germanDate(check['checkedAt'])} · ${check['checkedByName']}',
                  ),
                  subtitle: Text(
                    check['complete'] == true
                        ? 'Vollständig'
                        : '${check['deviationCount']} Abweichung(en)'
                              '${(check['defectIds'] as List? ?? const []).isNotEmpty || check['defectId'] != null ? ' · Mangel angelegt' : ''}',
                  ),
                  children: [
                    ..._maps(check['results']).map(
                      (row) => ListTile(
                        dense: true,
                        title: Text(
                          row['inventoryNumber'] == null
                              ? _text(row['name'])
                              : '${row['inventoryNumber']} · ${row['name']}',
                        ),
                        subtitle: Text(
                          '${row['result']} · Soll ${row['targetQuantity']} · Ist ${row['actualQuantity']}'
                          '${_text(row['notes'], '') != '' ? ' · ${row['notes']}' : ''}',
                        ),
                      ),
                    ),
                    if (_text(check['notes'], '') != '')
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(check['notes'].toString()),
                      ),
                  ],
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Auswahl eines Lagerplatzes mit Suchfeld.
class _StockStructurePicker extends StatefulWidget {
  const _StockStructurePicker({
    required this.stockStructures,
    required this.value,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> stockStructures;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  State<_StockStructurePicker> createState() => _StockStructurePickerState();
}

class _StockStructurePickerState extends State<_StockStructurePicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final options = widget.stockStructures
        .where(
          (entry) =>
              entry['id'].toString() == widget.value ||
              needle.isEmpty ||
              '${entry['path']} ${entry['fullCode'] ?? ''}'
                  .toLowerCase()
                  .contains(needle),
        )
        .take(200)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.stockStructures.length > 10)
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Lagerplatz suchen',
            ),
            onChanged: (value) => setState(() => query = value),
          ),
        DropdownButtonFormField<String>(
          key: ValueKey('stock-${options.length}-${widget.value}'),
          initialValue: options.any((e) => e['id'].toString() == widget.value)
              ? widget.value
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Lagerplatz *'),
          items: options
              .map(
                (entry) => DropdownMenuItem(
                  value: entry['id'].toString(),
                  child: Text(
                    _text(entry['path']),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: widget.onChanged,
        ),
      ],
    );
  }
}

class ContainerSettingsDialog extends StatefulWidget {
  const ContainerSettingsDialog({
    this.container,
    this.stockStructures = const [],
    super.key,
  });

  final Map<String, dynamic>? container;
  final List<Map<String, dynamic>> stockStructures;

  @override
  State<ContainerSettingsDialog> createState() =>
      _ContainerSettingsDialogState();
}

class _ContainerSettingsDialogState extends State<ContainerSettingsDialog> {
  late final TextEditingController name;
  late final TextEditingController code;
  late final TextEditingController type;
  late final TextEditingController compartments;
  late final TextEditingController warningDays;
  late final TextEditingController notes;
  String? stockStructureId;
  String? error;

  @override
  void initState() {
    super.initState();
    final current = widget.container ?? const {};
    name = TextEditingController(text: current['name']?.toString());
    code = TextEditingController(text: current['code']?.toString());
    type = TextEditingController(text: current['containerType']?.toString());
    compartments = TextEditingController(
      text: (current['compartments'] as List? ?? const []).join(', '),
    );
    warningDays = TextEditingController(
      text: '${current['expiryWarningDays'] ?? 30}',
    );
    notes = TextEditingController(text: current['containerNotes']?.toString());
    stockStructureId = current['stockStructureId']?.toString();
  }

  @override
  void dispose() {
    for (final controller in [
      name,
      code,
      type,
      compartments,
      warningDays,
      notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final days = int.tryParse(warningDays.text.trim());
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Bitte eine Bezeichnung angeben.');
      return;
    }
    if (stockStructureId == null) {
      setState(() => error = 'Bitte einen Lagerplatz wählen.');
      return;
    }
    if (days == null || days < 0 || days > 365) {
      setState(() => error = 'Die Vorwarnzeit muss 0 bis 365 Tage betragen.');
      return;
    }
    Navigator.pop(context, {
      'name': name.text.trim(),
      if (code.text.trim().isNotEmpty) 'code': code.text.trim(),
      'stockStructureId': stockStructureId,
      'containerType': type.text.trim(),
      'compartments': compartments.text
          .split(',')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toList(),
      'expiryWarningDays': days,
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.container == null;
    return AlertDialog(
      title: Text(creating ? 'Kiste anlegen' : 'Kiste bearbeiten'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                creating
                    ? 'Eine Kiste ist ein eigener Lagerort und steht auf einem '
                          'Lagerplatz.'
                    : 'Wird der Lagerplatz geändert, werden alle Artikel mit '
                          'Inventarnummer in der Kiste mitgebucht.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Bezeichnung *'),
              ),
              TextField(
                controller: code,
                decoration: InputDecoration(
                  labelText: 'Kistennummer',
                  helperText: creating
                      ? 'Leer lassen für automatische Vergabe (K-001, K-002 …)'
                      : null,
                ),
              ),
              _StockStructurePicker(
                stockStructures: widget.stockStructures,
                value: stockStructureId,
                onChanged: (value) => setState(() => stockStructureId = value),
              ),
              TextField(
                controller: type,
                decoration: const InputDecoration(
                  labelText: 'Kistenart',
                  hintText: 'z. B. Sanitätskiste, Wurfsackkiste',
                ),
              ),
              TextField(
                controller: compartments,
                decoration: const InputDecoration(
                  labelText: 'Fächer (kommagetrennt, optional)',
                  hintText: 'Deckel, Boden, Seitenfach',
                ),
              ),
              TextField(
                controller: warningDays,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Vorwarnzeit für Ablaufdaten (Tage)',
                ),
              ),
              TextField(
                controller: notes,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Hinweise'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Speichern')),
      ],
    );
  }
}

Future<String?> _pickDate(BuildContext context, String? current) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: DateTime.tryParse(current ?? '') ?? now,
    firstDate: DateTime(now.year - 10),
    lastDate: DateTime(now.year + 30),
  );
  return date == null ? null : _isoDate(date);
}

/// Bucht einen Artikel mit Inventarnummer in die Kiste.
class BookItemDialog extends StatefulWidget {
  const BookItemDialog({required this.loadCandidates, super.key});

  final Future<List<Map<String, dynamic>>> Function(String query)
  loadCandidates;

  @override
  State<BookItemDialog> createState() => _BookItemDialogState();
}

class _BookItemDialogState extends State<BookItemDialog> {
  final search = TextEditingController();
  final notes = TextEditingController();
  List<Map<String, dynamic>> candidates = [];
  Map<String, dynamic>? selected;
  String? error;
  bool loading = true;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => loading = true);
    final result = await widget.loadCandidates(search.text.trim());
    if (!mounted) return;
    setState(() {
      candidates = result;
      loading = false;
    });
  }

  Future<void> _scan() async {
    final code = await showContainerScanDialog(context);
    if (code == null || !mounted) return;
    search.text = code;
    await _search();
    if (candidates.length == 1 && mounted) {
      setState(() => selected = candidates.first);
    }
  }

  void _submit() {
    final item = selected;
    if (item == null) {
      setState(() => error = 'Bitte einen Artikel wählen.');
      return;
    }
    Navigator.pop(context, {
      'entityType': item['entityType'],
      'entityId': item['entityId'],
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = selected;
    return AlertDialog(
      title: const Text('In Kiste einlagern'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nur Artikel mit Inventarnummer werden in die Kiste gebucht. '
                'Mengenartikel wechseln vollständig in die Kiste. Inhalt ohne '
                'Inventarnummer wird über „Inhalt erfassen“ angelegt.',
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Inventarnummer oder Bezeichnung',
                      ),
                      onChanged: (_) {
                        debounce?.cancel();
                        debounce = Timer(
                          const Duration(milliseconds: 300),
                          () => unawaited(_search()),
                        );
                      },
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Scannen',
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner),
                  ),
                ],
              ),
              SizedBox(
                height: 240,
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : candidates.isEmpty
                    ? const Center(child: Text('Keine verfügbaren Artikel.'))
                    : ListView(
                        children: candidates.map((entry) {
                          final active =
                              item != null &&
                              item['entityType'] == entry['entityType'] &&
                              item['entityId'] == entry['entityId'];
                          return ListTile(
                            dense: true,
                            selected: active,
                            leading: Icon(
                              entry['entityType'] == 'ClothingItem'
                                  ? Icons.checkroom
                                  : Icons.qr_code_2_outlined,
                            ),
                            title: Text(
                              '${entry['inventoryNumber']} · ${entry['name']}',
                            ),
                            subtitle: Text(
                              entry['itemType'] == 'bulk'
                                  ? '${entry['quantity']} ${entry['unit']} · ${_text(entry['locationName'])}'
                                  : _text(entry['locationName']),
                            ),
                            trailing: active ? const Icon(Icons.check) : null,
                            onTap: () => setState(() {
                              selected = entry;
                              error = null;
                            }),
                          );
                        }).toList(),
                      ),
              ),
              if (item != null)
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'Notiz'),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Einlagern')),
      ],
    );
  }
}

/// Bucht einen Artikel mit Inventarnummer aus der Kiste auf einen anderen
/// Lagerort: Lagerplatz, Gebäude oder eine andere Kiste.
class RelocateItemDialog extends StatefulWidget {
  const RelocateItemDialog({
    required this.item,
    required this.targets,
    required this.currentContainerId,
    super.key,
  });

  final Map<String, dynamic> item;
  final ContainerStorageTargets targets;
  final String currentContainerId;

  @override
  State<RelocateItemDialog> createState() => _RelocateItemDialogState();
}

class _RelocateItemDialogState extends State<RelocateItemDialog> {
  final notes = TextEditingController();
  String query = '';
  String? target;
  String? error;

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  List<MapEntry<String, String>> get _options => [
    ...widget.targets.containers
        .where((entry) => entry['id'].toString() != widget.currentContainerId)
        .map(
          (entry) => MapEntry(
            'container:${entry['id']}',
            'Kiste ${_containerTitle(entry)} (${_text(entry['path'])})',
          ),
        ),
    ...widget.targets.stockStructures.map(
      (entry) => MapEntry('stock:${entry['id']}', _text(entry['path'])),
    ),
    ...widget.targets.locations.map(
      (entry) => MapEntry(
        'location:${entry['id']}',
        '${_text(entry['path'])} (ohne Lagerplatz)',
      ),
    ),
  ];

  void _submit() {
    final selected = target;
    if (selected == null) {
      setState(() => error = 'Bitte einen Ziel-Lagerort wählen.');
      return;
    }
    final separator = selected.indexOf(':');
    final kind = selected.substring(0, separator);
    final id = selected.substring(separator + 1);
    final body = <String, dynamic>{'notes': notes.text.trim()};
    if (kind == 'container') {
      body['containerId'] = id;
    } else if (kind == 'stock') {
      final stock = widget.targets.stockStructures.firstWhere(
        (entry) => entry['id'].toString() == id,
      );
      body['locationId'] = stock['locationId'];
      body['stockStructureId'] = id;
    } else {
      body['locationId'] = id;
    }
    Navigator.pop(context, body);
  }

  @override
  Widget build(BuildContext context) {
    final needle = query.trim().toLowerCase();
    final options = _options
        .where(
          (entry) =>
              entry.key == target ||
              needle.isEmpty ||
              entry.value.toLowerCase().contains(needle),
        )
        .take(200)
        .toList();
    return AlertDialog(
      title: const Text('Artikel umbuchen'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.item['inventoryNumber']} · ${widget.item['name']}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Ziel suchen',
              ),
              onChanged: (value) => setState(() => query = value),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('target-${options.length}-$target'),
              initialValue: target,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ziel-Lagerort'),
              items: options
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                target = value;
                error = null;
              }),
            ),
            TextField(
              controller: notes,
              decoration: const InputDecoration(labelText: 'Notiz'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Umbuchen')),
      ],
    );
  }
}

/// Erfasst oder bearbeitet Kisteninhalt ohne Inventarnummer.
class ContentEditDialog extends StatefulWidget {
  const ContentEditDialog({this.entry, required this.compartments, super.key});

  final Map<String, dynamic>? entry;
  final List<String> compartments;

  @override
  State<ContentEditDialog> createState() => _ContentEditDialogState();
}

class _ContentEditDialogState extends State<ContentEditDialog> {
  late final TextEditingController name;
  late final TextEditingController quantity;
  late final TextEditingController unit;
  late final TextEditingController batch;
  late final TextEditingController notes;
  String? position;
  String? expiresAt;
  String? error;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry ?? const <String, dynamic>{};
    name = TextEditingController(text: entry['name']?.toString());
    quantity = TextEditingController(text: '${entry['quantity'] ?? 1}');
    unit = TextEditingController(text: _text(entry['unit'], 'Stück'));
    batch = TextEditingController(text: entry['batchNumber']?.toString());
    notes = TextEditingController(text: entry['notes']?.toString());
    final current = entry['position']?.toString() ?? '';
    position = current.isEmpty ? null : current;
    expiresAt = entry['expiresAt']?.toString();
  }

  @override
  void dispose() {
    for (final controller in [name, quantity, unit, batch, notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final amount = int.tryParse(quantity.text.trim());
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Bitte eine Bezeichnung angeben.');
      return;
    }
    if (amount == null || amount < 1) {
      setState(() => error = 'Bitte eine gültige Menge angeben.');
      return;
    }
    if (widget.compartments.isNotEmpty && position == null) {
      setState(() => error = 'Bitte ein Fach wählen.');
      return;
    }
    Navigator.pop(context, {
      'name': name.text.trim(),
      'quantity': amount,
      'unit': unit.text.trim().isEmpty ? 'Stück' : unit.text.trim(),
      'position': position ?? '',
      'expiresAt': expiresAt,
      'batchNumber': batch.text.trim(),
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = {...widget.compartments, ?position}.toList();
    return AlertDialog(
      title: Text(
        widget.entry == null
            ? 'Inhalt ohne Inventarnummer erfassen'
            : '${widget.entry!['name']} bearbeiten',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Bezeichnung *',
                  hintText: 'z. B. Pflasterstrips, Kompresse 10x10',
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: quantity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Menge *'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: unit,
                      decoration: const InputDecoration(labelText: 'Einheit'),
                    ),
                  ),
                ],
              ),
              if (options.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: position,
                  decoration: const InputDecoration(labelText: 'Fach'),
                  items: options
                      .map(
                        (entry) =>
                            DropdownMenuItem(value: entry, child: Text(entry)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => position = value),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ablaufdatum / Mindesthaltbarkeit'),
                subtitle: Text(
                  expiresAt == null
                      ? 'Kein Ablaufdatum'
                      : _germanDate(expiresAt),
                ),
                trailing: Wrap(
                  children: [
                    if (expiresAt != null)
                      IconButton(
                        tooltip: 'Ablaufdatum entfernen',
                        onPressed: () => setState(() => expiresAt = null),
                        icon: const Icon(Icons.clear),
                      ),
                    IconButton(
                      tooltip: 'Datum wählen',
                      onPressed: () async {
                        final value = await _pickDate(context, expiresAt);
                        if (value != null) setState(() => expiresAt = value);
                      },
                      icon: const Icon(Icons.event),
                    ),
                  ],
                ),
              ),
              TextField(
                controller: batch,
                decoration: const InputDecoration(
                  labelText: 'Charge / Los (optional)',
                ),
              ),
              TextField(
                controller: notes,
                decoration: const InputDecoration(labelText: 'Notiz'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Speichern')),
      ],
    );
  }
}

class _PackListRow {
  _PackListRow({
    required this.entityType,
    required this.entityId,
    required this.name,
    required this.unit,
    required this.label,
    required this.individual,
    required int target,
    required this.position,
  }) : quantity = TextEditingController(text: '$target');

  final String entityType;
  final String? entityId;
  final String name;
  final String unit;
  final String label;
  final bool individual;
  final String position;
  final TextEditingController quantity;
  bool included = true;

  String get key => entityType == 'Content'
      ? 'Content:${name.trim().toLowerCase()}'
      : '$entityType:$entityId';
}

class PackListDialog extends StatefulWidget {
  const PackListDialog({required this.container, super.key});

  final Map<String, dynamic> container;

  @override
  State<PackListDialog> createState() => _PackListDialogState();
}

class _PackListDialogState extends State<PackListDialog> {
  final name = TextEditingController();
  final rows = <_PackListRow>[];
  bool activateNow = true;
  String? error;

  @override
  void initState() {
    super.initState();
    final active = _maps(widget.container['packLists']).firstWhere(
      (entry) => entry['status'] == 'Aktiv',
      orElse: () => <String, dynamic>{},
    );
    name.text = _text(active['name'], 'Packliste');
    final individual = <String>{
      for (final item in _maps(widget.container['items']))
        if (item['itemType'] != 'bulk')
          '${item['entityType']}:${item['entityId']}',
    };
    void add(_PackListRow row) {
      if (rows.any((entry) => entry.key == row.key)) {
        row.quantity.dispose();
        return;
      }
      rows.add(row);
    }

    for (final item in _maps(active['items'])) {
      final content = item['entityType'] == 'Content';
      final entityType = item['entityType'].toString();
      final entityId = content ? null : item['entityId']?.toString();
      add(
        _PackListRow(
          entityType: entityType,
          entityId: entityId,
          name: _text(item['name'] ?? item['nameSnapshot'], ''),
          unit: _text(item['unit'], 'Stück'),
          label: content
              ? _text(item['name'])
              : '${_text(item['inventoryNumberSnapshot'])} · ${item['nameSnapshot']}',
          individual: !content && individual.contains('$entityType:$entityId'),
          target: int.tryParse('${item['targetQuantity']}') ?? 1,
          position: item['position']?.toString() ?? '',
        ),
      );
    }
    for (final item in _maps(widget.container['items'])) {
      add(
        _PackListRow(
          entityType: item['entityType'].toString(),
          entityId: item['entityId'].toString(),
          name: _text(item['name'], ''),
          unit: _text(item['unit'], 'Stück'),
          label: '${_text(item['inventoryNumber'])} · ${item['name']}',
          individual: item['itemType'] != 'bulk',
          target: int.tryParse('${item['quantity']}') ?? 1,
          position: '',
        ),
      );
    }
    final grouped = <String, Map<String, dynamic>>{};
    for (final entry in _maps(widget.container['contents'])) {
      final key = '${entry['name']}'.trim().toLowerCase();
      final current = grouped.putIfAbsent(key, () => {...entry, 'sum': 0});
      current['sum'] =
          (current['sum'] as int) + (int.tryParse('${entry['quantity']}') ?? 1);
    }
    for (final item in grouped.values) {
      add(
        _PackListRow(
          entityType: 'Content',
          entityId: null,
          name: _text(item['name'], ''),
          unit: _text(item['unit'], 'Stück'),
          label: _text(item['name']),
          individual: false,
          target: item['sum'] as int,
          position: item['position']?.toString() ?? '',
        ),
      );
    }
  }

  @override
  void dispose() {
    name.dispose();
    for (final row in rows) {
      row.quantity.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final items = <Map<String, dynamic>>[];
    for (final row in rows.where((entry) => entry.included)) {
      final target = row.individual
          ? 1
          : int.tryParse(row.quantity.text.trim());
      if (target == null || target < 1) {
        setState(
          () => error = 'Bitte für ${row.label} eine Sollmenge angeben.',
        );
        return;
      }
      items.add({
        'entityType': row.entityType,
        if (row.entityId != null) 'entityId': row.entityId,
        if (row.entityType == 'Content') 'name': row.name,
        if (row.entityType == 'Content') 'unit': row.unit,
        'targetQuantity': target,
        'position': row.position,
      });
    }
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Bitte eine Bezeichnung angeben.');
      return;
    }
    Navigator.pop(context, {
      'name': name.text.trim(),
      'items': items,
      'activate': activateNow,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Neue Packlisten-Version'),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Bezeichnung'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Grundlage sind die aktive Packliste und der aktuelle Inhalt '
              '(mit und ohne Inventarnummer).',
            ),
            const SizedBox(height: 8),
            Flexible(
              child: rows.isEmpty
                  ? const Text(
                      'Die Kiste ist leer. Bitte zuerst Inhalt erfassen oder '
                      'Artikel einlagern.',
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: rows
                          .map(
                            (row) => Row(
                              children: [
                                Checkbox(
                                  value: row.included,
                                  onChanged: (value) => setState(
                                    () => row.included = value ?? false,
                                  ),
                                ),
                                Expanded(child: Text(row.label)),
                                SizedBox(
                                  width: 90,
                                  child: TextField(
                                    controller: row.quantity,
                                    enabled: !row.individual && row.included,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Soll',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                          .toList(),
                    ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: activateNow,
              onChanged: (value) => setState(() => activateNow = value),
              title: const Text('Sofort aktivieren'),
              subtitle: const Text(
                'Sonst wird die Version als Entwurf gespeichert.',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: rows.isEmpty ? null : _submit,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class _CheckRow {
  _CheckRow(this.item)
    : quantity = TextEditingController(text: '${item['targetQuantity']}'),
      notes = TextEditingController(),
      result = _defaultResult(item);

  static String _defaultResult(Map<String, dynamic> item) {
    final expiry = DateTime.tryParse('${item['earliestExpiry'] ?? ''}');
    final today = DateTime.now();
    if (expiry != null &&
        expiry.isBefore(DateTime(today.year, today.month, today.day))) {
      return 'abgelaufen';
    }
    final expected = int.tryParse('${item['expectedQuantity'] ?? 0}') ?? 0;
    return expected <= 0 ? 'fehlt' : 'vorhanden';
  }

  final Map<String, dynamic> item;
  final TextEditingController quantity;
  final TextEditingController notes;
  String result;
}

class ContainerCheckDialog extends StatefulWidget {
  const ContainerCheckDialog({required this.template, super.key});

  final Map<String, dynamic> template;

  @override
  State<ContainerCheckDialog> createState() => _ContainerCheckDialogState();
}

class _ContainerCheckDialogState extends State<ContainerCheckDialog> {
  late final List<_CheckRow> rows;
  final notes = TextEditingController();
  bool createDefect = false;
  String priority = 'Normal';
  String? error;

  @override
  void initState() {
    super.initState();
    rows = _maps(widget.template['items']).map(_CheckRow.new).toList();
    for (final row in rows) {
      final expected =
          int.tryParse('${row.item['expectedQuantity'] ?? 0}') ?? 0;
      final target = int.tryParse('${row.item['targetQuantity'] ?? 0}') ?? 0;
      row.quantity.text = '${expected < target ? expected : target}';
    }
  }

  @override
  void dispose() {
    notes.dispose();
    for (final row in rows) {
      row.quantity.dispose();
      row.notes.dispose();
    }
    super.dispose();
  }

  bool get incomplete => rows.any((row) {
    final target = int.tryParse('${row.item['targetQuantity']}') ?? 0;
    final actual = int.tryParse(row.quantity.text.trim()) ?? 0;
    return row.result != 'vorhanden' || actual < target;
  });

  void _submit() {
    final results = <Map<String, dynamic>>[];
    for (final row in rows) {
      final actual = int.tryParse(row.quantity.text.trim());
      if (actual == null || actual < 0) {
        setState(
          () => error =
              'Bitte für ${row.item['name']} eine gültige Ist-Menge angeben.',
        );
        return;
      }
      results.add({
        'key': row.item['key'],
        'result': row.result,
        'actualQuantity': actual,
        'notes': row.notes.text.trim(),
      });
    }
    Navigator.pop(context, {
      'results': results,
      'notes': notes.text.trim(),
      if (createDefect && incomplete) 'createDefect': {'priority': priority},
    });
  }

  @override
  Widget build(BuildContext context) {
    final version = widget.template['packListVersion'];
    return AlertDialog(
      title: const Text('Vollständigkeitsprüfung'),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              version == null
                  ? 'Prüfung gegen den aktuellen Inhalt (keine aktive Packliste).'
                  : 'Prüfung gegen Packliste Version $version.',
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: rows
                    .map(
                      (row) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              row.item['inventoryNumber'] == null
                                  ? '${row.item['name']} (ohne Inventarnummer)'
                                  : '${row.item['inventoryNumber']} · ${row.item['name']}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(
                              'Soll ${row.item['targetQuantity']} ${row.item['unit']}'
                              '${_text(row.item['position'], '') != '' ? ' · Fach ${row.item['position']}' : ''}'
                              '${row.item['earliestExpiry'] != null ? ' · Ablauf ${_germanDate(row.item['earliestExpiry'])}' : ''}',
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    initialValue: row.result,
                                    decoration: const InputDecoration(
                                      labelText: 'Ergebnis',
                                    ),
                                    items: containerCheckResults
                                        .map(
                                          (entry) => DropdownMenuItem(
                                            value: entry,
                                            child: Text(entry),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (value) => setState(() {
                                      row.result = value ?? 'vorhanden';
                                      if (row.result == 'fehlt') {
                                        row.quantity.text = '0';
                                      }
                                    }),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 90,
                                  child: TextField(
                                    controller: row.quantity,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Ist',
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                              ],
                            ),
                            TextField(
                              controller: row.notes,
                              decoration: const InputDecoration(
                                labelText: 'Bemerkung',
                                isDense: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            TextField(
              controller: notes,
              decoration: const InputDecoration(labelText: 'Notiz zur Prüfung'),
            ),
            if (incomplete) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: createDefect,
                onChanged: (value) =>
                    setState(() => createDefect = value ?? false),
                title: const Text(
                  'Mängel für betroffene Artikel mit Inventarnummer anlegen',
                ),
                subtitle: const Text(
                  'Nur „Kritisch“ setzt den Artikel auf „Defekt“. Fehlender '
                  'Inhalt ohne Inventarnummer steht im Prüfprotokoll.',
                ),
              ),
              if (createDefect)
                DropdownButtonFormField<String>(
                  initialValue: priority,
                  decoration: const InputDecoration(labelText: 'Priorität'),
                  items: const ['Niedrig', 'Normal', 'Hoch', 'Kritisch']
                      .map(
                        (entry) =>
                            DropdownMenuItem(value: entry, child: Text(entry)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => priority = value ?? 'Normal'),
                ),
            ],
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Prüfung speichern'),
        ),
      ],
    );
  }
}
