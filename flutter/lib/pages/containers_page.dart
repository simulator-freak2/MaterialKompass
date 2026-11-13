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
    if (container['issued'] == true)
      _chip(context, 'Ausgegeben', icon: Icons.outbox_outlined),
    if (container['vehicleId'] != null)
      _chip(context, 'Auf Fahrzeug', icon: Icons.local_shipping_outlined),
    if (container['parentContainerId'] != null)
      _chip(context, 'In Kiste', icon: Icons.inventory_2_outlined),
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
                labelText: 'Handscanner / Inventarnummer',
                helperText: 'Kiste oder einen darin gepackten Artikel scannen.',
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
            entry['inventoryNumber'],
            entry['name'],
            entry['containerType'],
            entry['locationName'],
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
        _message('Der Artikel liegt in Kiste ${container['inventoryNumber']}.');
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
    final materials = await _request('/api/material?archived=false');
    if (materials is! List || !mounted) return;
    final candidates = _maps(materials)
        .where(
          (entry) =>
              entry['itemType'] == 'individual' &&
              entry['isContainer'] != true &&
              entry['readOnly'] != true,
        )
        .toList();
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContainerSettingsDialog(candidates: candidates),
    );
    if (values == null) return;
    final created = await _request(
      '/api/containers',
      method: 'POST',
      body: values,
    );
    if (created is Map && mounted) {
      _message('Kiste wurde angelegt.');
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
                            'Noch keine Kisten vorhanden. Ein Einzelstück aus '
                            'dem Inventar kann als Kiste angelegt werden.',
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
                          title: Text(
                            '${entry['inventoryNumber']} · ${entry['name']}',
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_text(entry['containerType'], 'Kiste')} · '
                                '${entry['contentCount']} Position(en) · '
                                '${_text(entry['locationName'])}'
                                '${entry['stockStructureName'] != null ? ' / ${entry['stockStructureName']}' : ''}',
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
                          title: Text(
                            '${_text(entry['inventoryNumber'])} · ${entry['name']}',
                          ),
                          subtitle: Text(
                            'Kiste ${entry['containerInventoryNumber']} · '
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
    final result = await widget.request(
      '/api/containers/${widget.containerId}',
    );
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
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContainerSettingsDialog(container: current),
    );
    if (values == null) return;
    await _mutate(
      '/api/containers/${widget.containerId}',
      method: 'PUT',
      body: values,
      success: 'Kiste wurde gespeichert.',
    );
  }

  Future<void> _dissolve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kiste auflösen?'),
        content: const Text(
          'Der Artikel bleibt im Inventar erhalten, wird aber nicht mehr als '
          'Kiste geführt. Aktive Packlisten werden beendet.',
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
    final result = await widget.request(
      '/api/containers/${widget.containerId}',
      method: 'DELETE',
    );
    if (result != null && mounted) Navigator.of(context).pop();
  }

  Future<void> _pack() async {
    final current = container;
    if (current == null) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PackItemDialog(
        compartments: (current['compartments'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toList(),
        loadCandidates: (query) async {
          final result = await widget.request(
            '/api/containers/${widget.containerId}/candidates?query=${Uri.encodeQueryComponent(query)}',
          );
          return _maps(result);
        },
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/containers/${widget.containerId}/contents',
      body: values,
      success: 'Artikel wurde gepackt.',
    );
  }

  Future<void> _editContent(Map<String, dynamic> entry) async {
    final current = container;
    if (current == null) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ContentEditDialog(
        entry: entry,
        compartments: (current['compartments'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(),
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/containers/${widget.containerId}/contents/${entry['id']}',
      method: 'PUT',
      body: values,
      success: 'Inhalt wurde gespeichert.',
    );
  }

  Future<void> _unpack(Map<String, dynamic> entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aus Kiste entnehmen?'),
        content: Text(
          entry['itemType'] == 'bulk'
              ? '${entry['quantity']} ${entry['unit']} ${entry['name']} werden '
                    'wieder dem freien Bestand zugerechnet.'
              : '${entry['name']} wird an seinen vorherigen Lagerort '
                    'zurückgebucht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Entnehmen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mutate(
      '/api/containers/${widget.containerId}/contents/${entry['id']}/unpack',
      body: const {},
      success: 'Artikel wurde entnommen.',
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
      '/api/containers/${widget.containerId}/pack-lists',
      body: values,
      success: 'Packliste wurde gespeichert.',
    );
  }

  Future<void> _activatePackList(Map<String, dynamic> list) async {
    await _mutate(
      '/api/containers/${widget.containerId}/pack-lists/${list['id']}/activate',
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
      '/api/containers/${widget.containerId}/checks',
      method: 'POST',
      body: values,
    );
    if (result is! Map || !mounted) return;
    if (_queued(result)) {
      _message('Prüfung offline vorgemerkt – wird bei Verbindung übertragen.');
      return;
    }
    final complete = result['complete'] == true;
    final defect = result['defectNumber'];
    _message(
      complete
          ? 'Kiste ist vollständig.'
          : 'Kiste ist unvollständig${defect != null ? ' – Mangel $defect angelegt' : ''}.',
      error: !complete,
    );
    setState(() => container = _map(result['container']));
  }

  Future<void> _print({required bool save}) async {
    final result = await widget.request(
      '/api/containers/${widget.containerId}/pack-list/print',
    );
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

  void _openNested(Map<String, dynamic> entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContainerDetailPage(
          containerId: entry['entityId'].toString(),
          permissions: widget.permissions,
          request: widget.request,
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? action}) {
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
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _contentTile(Map<String, dynamic> entry, bool editable) {
    final expiry = entry['expiryState']?.toString();
    final safety = _map(entry['safetyStatus']);
    final details = <String>[
      if (entry['itemType'] == 'bulk') '${entry['quantity']} ${entry['unit']}',
      if (_text(entry['position'], '') != '') 'Fach ${entry['position']}',
      if (entry['expiresAt'] != null)
        'Ablauf ${_germanDate(entry['expiresAt'])}${expiry != null ? ' ($expiry)' : ''}',
      if (_text(entry['batchNumber'], '') != '')
        'Charge ${entry['batchNumber']}',
      if (entry['entityType'] == 'ClothingItem')
        'Kleidung${entry['size'] != null ? ' · Größe ${entry['size']}' : ''}',
      if (entry['isContainer'] == true)
        'Unterkiste mit ${entry['nestedContentCount']} Position(en)',
      if (safety['blocked'] == true) 'Sicherheitsbedingt gesperrt',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        entry['isContainer'] == true
            ? Icons.inventory_2_outlined
            : entry['entityType'] == 'ClothingItem'
            ? Icons.checkroom
            : Icons.category_outlined,
        color: expiry == 'abgelaufen' || safety['blocked'] == true
            ? Theme.of(context).colorScheme.error
            : expiry != null
            ? Colors.orange.shade800
            : null,
      ),
      title: Text('${_text(entry['inventoryNumber'])} · ${entry['name']}'),
      subtitle: details.isEmpty ? null : Text(details.join(' · ')),
      onTap: entry['isContainer'] == true ? () => _openNested(entry) : null,
      trailing: editable
          ? PopupMenuButton<String>(
              tooltip: 'Aktionen',
              onSelected: (value) {
                if (value == 'edit') unawaited(_editContent(entry));
                if (value == 'unpack') unawaited(_unpack(entry));
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                PopupMenuItem(value: 'unpack', child: Text('Entnehmen')),
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
    final issued = current['issued'] == true;
    final editable = can('containers.pack') && !issued;
    return Scaffold(
      appBar: AppBar(
        title: Text(_text(current['name'], 'Kiste')),
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
                const PopupMenuItem(value: 'edit', child: Text('Bearbeiten')),
                PopupMenuItem(
                  value: 'dissolve',
                  enabled: contents.isEmpty,
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
            _section('${current['inventoryNumber']}', [
              Text(
                '${_text(current['containerType'], 'Kiste')} · '
                '${_text(current['locationName'])}'
                '${current['stockStructureName'] != null ? ' / ${current['stockStructureName']}' : ''}',
              ),
              if (current['parentContainerName'] != null)
                Text('Liegt in Kiste ${current['parentContainerName']}'),
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
              if (issued)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Die Kiste ist ausgegeben. Der Inhalt kann erst nach der '
                    'Rückgabe geändert werden.',
                  ),
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
              'Inhalt (${contents.length})',
              [
                if (contents.isEmpty) const Text('Die Kiste ist leer.'),
                ...contents.map((entry) => _contentTile(entry, editable)),
              ],
              action: editable
                  ? FilledButton.tonalIcon(
                      onPressed: _pack,
                      icon: const Icon(Icons.add),
                      label: const Text('Packen'),
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
                        '${_text(row['inventoryNumber'])} · ${row['name']}',
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
                              '${check['defectId'] != null ? ' · Mangel angelegt' : ''}',
                  ),
                  children: [
                    ..._maps(check['results']).map(
                      (row) => ListTile(
                        dense: true,
                        title: Text(
                          '${_text(row['inventoryNumber'])} · ${row['name']}',
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

class ContainerSettingsDialog extends StatefulWidget {
  const ContainerSettingsDialog({this.container, this.candidates, super.key});

  final Map<String, dynamic>? container;
  final List<Map<String, dynamic>>? candidates;

  @override
  State<ContainerSettingsDialog> createState() =>
      _ContainerSettingsDialogState();
}

class _ContainerSettingsDialogState extends State<ContainerSettingsDialog> {
  late final TextEditingController type;
  late final TextEditingController compartments;
  late final TextEditingController warningDays;
  late final TextEditingController notes;
  final search = TextEditingController();
  String? materialId;
  String? error;

  @override
  void initState() {
    super.initState();
    final current = widget.container ?? const {};
    type = TextEditingController(text: current['containerType']?.toString());
    compartments = TextEditingController(
      text: (current['compartments'] as List? ?? const []).join(', '),
    );
    warningDays = TextEditingController(
      text: '${current['expiryWarningDays'] ?? 30}',
    );
    notes = TextEditingController(text: current['containerNotes']?.toString());
  }

  @override
  void dispose() {
    for (final controller in [type, compartments, warningDays, notes, search]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final creating = widget.container == null;
    final days = int.tryParse(warningDays.text.trim());
    if (creating && materialId == null) {
      setState(() => error = 'Bitte einen Artikel wählen.');
      return;
    }
    if (days == null || days < 0 || days > 365) {
      setState(() => error = 'Die Vorwarnzeit muss 0 bis 365 Tage betragen.');
      return;
    }
    Navigator.pop(context, {
      'materialId': ?materialId,
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
    final needle = search.text.trim().toLowerCase();
    final candidates = (widget.candidates ?? const <Map<String, dynamic>>[])
        .where(
          (entry) =>
              needle.isEmpty ||
              '${entry['inventoryNumber']} ${entry['name']}'
                  .toLowerCase()
                  .contains(needle),
        )
        .take(50)
        .toList();
    return AlertDialog(
      title: Text(creating ? 'Kiste anlegen' : 'Kiste bearbeiten'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (creating) ...[
                const Text(
                  'Eine Kiste ist ein inventarisiertes Einzelstück. Bitte den '
                  'Artikel wählen, der als Kiste geführt werden soll.',
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Artikel suchen',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                SizedBox(
                  height: 220,
                  child: candidates.isEmpty
                      ? const Center(
                          child: Text('Keine passenden Einzelstücke.'),
                        )
                      : RadioGroup<String>(
                          groupValue: materialId,
                          onChanged: (value) =>
                              setState(() => materialId = value),
                          child: ListView(
                            children: candidates
                                .map(
                                  (entry) => RadioListTile<String>(
                                    dense: true,
                                    value: entry['id'].toString(),
                                    title: Text(
                                      '${entry['inventoryNumber']} · ${entry['name']}',
                                    ),
                                    subtitle: Text(
                                      _text(entry['locationName']),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                ),
                const SizedBox(height: 8),
              ],
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

class PackItemDialog extends StatefulWidget {
  const PackItemDialog({
    required this.compartments,
    required this.loadCandidates,
    super.key,
  });

  final List<String> compartments;
  final Future<List<Map<String, dynamic>>> Function(String query)
  loadCandidates;

  @override
  State<PackItemDialog> createState() => _PackItemDialogState();
}

class _PackItemDialogState extends State<PackItemDialog> {
  final search = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final batch = TextEditingController();
  final notes = TextEditingController();
  List<Map<String, dynamic>> candidates = [];
  Map<String, dynamic>? selected;
  String? position;
  String? expiresAt;
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
    for (final controller in [search, quantity, batch, notes]) {
      controller.dispose();
    }
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
    final bulk = item['itemType'] == 'bulk';
    final amount = bulk ? int.tryParse(quantity.text.trim()) : 1;
    final available = int.tryParse('${item['availableQuantity'] ?? 0}') ?? 0;
    if (amount == null || amount < 1 || amount > available) {
      setState(
        () => error = 'Bitte eine Menge zwischen 1 und $available angeben.',
      );
      return;
    }
    if (widget.compartments.isNotEmpty && position == null) {
      setState(() => error = 'Bitte ein Fach wählen.');
      return;
    }
    Navigator.pop(context, {
      'entityType': item['entityType'],
      'entityId': item['entityId'],
      'quantity': amount,
      'position': position ?? '',
      'expiresAt': expiresAt,
      'batchNumber': batch.text.trim(),
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = selected;
    return AlertDialog(
      title: const Text('In Kiste packen'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                height: 220,
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
                              entry['isContainer'] == true
                                  ? Icons.inventory_2_outlined
                                  : entry['entityType'] == 'ClothingItem'
                                  ? Icons.checkroom
                                  : Icons.category_outlined,
                            ),
                            title: Text(
                              '${entry['inventoryNumber']} · ${entry['name']}',
                            ),
                            subtitle: Text(
                              entry['itemType'] == 'bulk'
                                  ? '${entry['availableQuantity']} ${entry['unit']} frei · ${_text(entry['locationName'])}'
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
              if (item != null) ...[
                const Divider(),
                if (item['itemType'] == 'bulk')
                  TextField(
                    controller: quantity,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText:
                          'Menge (${item['availableQuantity']} ${item['unit']} frei)',
                    ),
                  ),
                if (widget.compartments.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: position,
                    decoration: const InputDecoration(labelText: 'Fach'),
                    items: widget.compartments
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry,
                            child: Text(entry),
                          ),
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
              ],
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
        FilledButton(onPressed: _submit, child: const Text('Packen')),
      ],
    );
  }
}

class ContentEditDialog extends StatefulWidget {
  const ContentEditDialog({
    required this.entry,
    required this.compartments,
    super.key,
  });

  final Map<String, dynamic> entry;
  final List<String> compartments;

  @override
  State<ContentEditDialog> createState() => _ContentEditDialogState();
}

class _ContentEditDialogState extends State<ContentEditDialog> {
  late final TextEditingController quantity;
  late final TextEditingController batch;
  late final TextEditingController notes;
  String? position;
  String? expiresAt;
  String? error;

  @override
  void initState() {
    super.initState();
    quantity = TextEditingController(text: '${widget.entry['quantity'] ?? 1}');
    batch = TextEditingController(
      text: widget.entry['batchNumber']?.toString(),
    );
    notes = TextEditingController(text: widget.entry['notes']?.toString());
    final current = widget.entry['position']?.toString() ?? '';
    position = current.isEmpty ? null : current;
    expiresAt = widget.entry['expiresAt']?.toString();
  }

  @override
  void dispose() {
    quantity.dispose();
    batch.dispose();
    notes.dispose();
    super.dispose();
  }

  void _submit() {
    final bulk = widget.entry['itemType'] == 'bulk';
    final amount = int.tryParse(quantity.text.trim());
    if (bulk && (amount == null || amount < 1)) {
      setState(() => error = 'Bitte eine gültige Menge angeben.');
      return;
    }
    Navigator.pop(context, {
      if (bulk) 'quantity': amount,
      'position': position ?? '',
      'expiresAt': expiresAt,
      'batchNumber': batch.text.trim(),
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bulk = widget.entry['itemType'] == 'bulk';
    final options = {...widget.compartments, ?position}.toList();
    return AlertDialog(
      title: Text('${widget.entry['name']} bearbeiten'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bulk)
              TextField(
                controller: quantity,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Menge (${widget.entry['unit']})',
                ),
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
                expiresAt == null ? 'Kein Ablaufdatum' : _germanDate(expiresAt),
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
              decoration: const InputDecoration(labelText: 'Charge / Los'),
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
        FilledButton(onPressed: _submit, child: const Text('Speichern')),
      ],
    );
  }
}

class _PackListRow {
  _PackListRow({
    required this.entityType,
    required this.entityId,
    required this.label,
    required this.individual,
    required int target,
    required this.position,
  }) : quantity = TextEditingController(text: '$target');

  final String entityType;
  final String entityId;
  final String label;
  final bool individual;
  final String position;
  final TextEditingController quantity;
  bool included = true;
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
    final seen = <String>{};
    for (final item in _maps(active['items'])) {
      final key = '${item['entityType']}:${item['entityId']}';
      seen.add(key);
      rows.add(
        _PackListRow(
          entityType: item['entityType'].toString(),
          entityId: item['entityId'].toString(),
          label:
              '${_text(item['inventoryNumberSnapshot'])} · ${item['nameSnapshot']}',
          individual: false,
          target: int.tryParse('${item['targetQuantity']}') ?? 1,
          position: item['position']?.toString() ?? '',
        ),
      );
    }
    final grouped = <String, Map<String, dynamic>>{};
    for (final entry in _maps(widget.container['contents'])) {
      final key = '${entry['entityType']}:${entry['entityId']}';
      final current = grouped.putIfAbsent(key, () => {...entry, 'sum': 0});
      current['sum'] =
          (current['sum'] as int) + (int.tryParse('${entry['quantity']}') ?? 1);
    }
    for (final entry in grouped.entries) {
      final item = entry.value;
      final individual = item['itemType'] != 'bulk';
      final index = rows.indexWhere(
        (row) => '${row.entityType}:${row.entityId}' == entry.key,
      );
      if (index >= 0) {
        final previous = rows[index];
        rows[index] = _PackListRow(
          entityType: previous.entityType,
          entityId: previous.entityId,
          label: previous.label,
          individual: individual,
          target: int.tryParse(previous.quantity.text) ?? 1,
          position: previous.position,
        );
        previous.quantity.dispose();
        continue;
      }
      if (seen.contains(entry.key)) continue;
      rows.add(
        _PackListRow(
          entityType: item['entityType'].toString(),
          entityId: item['entityId'].toString(),
          label: '${_text(item['inventoryNumber'])} · ${item['name']}',
          individual: individual,
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
        'entityId': row.entityId,
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
              'Grundlage sind die aktive Packliste und der aktuelle Inhalt. '
              'Weitere Artikel zuerst in die Kiste packen.',
            ),
            const SizedBox(height: 8),
            Flexible(
              child: rows.isEmpty
                  ? const Text(
                      'Die Kiste ist leer. Bitte zuerst Inhalt packen.',
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
                              '${_text(row.item['inventoryNumber'])} · ${row.item['name']}',
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
                title: const Text('Mangel in der Mängelverwaltung anlegen'),
                subtitle: const Text(
                  'Nur „Kritisch“ setzt die Kiste auf „Defekt“.',
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
