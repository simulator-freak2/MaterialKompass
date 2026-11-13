import 'package:flutter/material.dart';

import '../services/authenticated_api_client.dart';

/// Organization management of "MaterialKompass – Zentrale Verwaltung".
///
/// Only platform administrators working inside the central administration
/// reach this page. The server enforces the same restriction independently.
class PlatformOrganizationsPage extends StatefulWidget {
  const PlatformOrganizationsPage({required this.token, super.key});

  final String token;

  @override
  State<PlatformOrganizationsPage> createState() =>
      _PlatformOrganizationsPageState();
}

class _PlatformOrganizationsPageState extends State<PlatformOrganizationsPage> {
  late final AuthenticatedApiClient _api;
  late Future<List<Map<String, dynamic>>> _future;
  final _search = TextEditingController();
  bool _showDeleted = true;

  @override
  void initState() {
    super.initState();
    _api = AuthenticatedApiClient(widget.token);
    _future = _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final result = await _api.request('/api/platform/organizations') as List;
    return result
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _createOrganization() async {
    final values = await showOrganizationFormDialog(
      context,
      title: 'Organisation anlegen',
      confirmLabel: 'Anlegen',
    );
    if (values == null) return;
    try {
      final created = Map<String, dynamic>.from(
        await _api.request('/api/organizations', method: 'POST', body: values)
            as Map,
      );
      await _refresh();
      if (!mounted) return;
      await _openDetails(created['id'].toString());
    } catch (error) {
      _error(error);
    }
  }

  Future<void> _openDetails(String organizationId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlatformOrganizationDetailPage(
          token: widget.token,
          organizationId: organizationId,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  bool _matches(Map<String, dynamic> organization) {
    if (!_showDeleted && organization['status'] != 'active') return false;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      organization['name'],
      organization['shortName'],
      organization['edvNumber'],
    ].any((value) => (value?.toString() ?? '').toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Organisationsverwaltung'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createOrganization,
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Organisation anlegen'),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(snapshot.error.toString()),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Erneut laden'),
                  ),
                ],
              ),
            );
          }
          final organizations = snapshot.data!;
          final visible = organizations.where(_matches).toList();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
              children: [
                Text(
                  'Organisationen werden ausschließlich hier angelegt, '
                  'bearbeitet, gelöscht und wiederhergestellt. Die Einheiten '
                  'unterhalb einer Organisation verwalten deren '
                  'Organisationsadmins selbst.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 360,
                      child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: 'Name, Kurzname oder EDV-Nummer',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    FilterChip(
                      label: const Text('Gelöschte anzeigen'),
                      selected: _showDeleted,
                      onSelected: (value) =>
                          setState(() => _showDeleted = value),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (organizations.isEmpty)
                  const Text('Es sind noch keine Organisationen angelegt.')
                else if (visible.isEmpty)
                  const Text('Keine Organisation entspricht der Suche.'),
                for (final organization in visible)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        organization['status'] == 'active'
                            ? Icons.corporate_fare_outlined
                            : Icons.auto_delete_outlined,
                      ),
                      title: Text(organization['name']?.toString() ?? ''),
                      subtitle: Text(_summary(organization)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openDetails(organization['id'].toString()),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _summary(Map<String, dynamic> organization) {
  final parts = <String>[
    if ((organization['shortName']?.toString() ?? '').isNotEmpty)
      organization['shortName'].toString(),
    'EDV ${organization['edvNumber'] ?? '–'}',
    '${organization['unitCount'] ?? 0} Einheiten',
    '${organization['memberCount'] ?? 0} Mitglieder',
    '${organization['adminCount'] ?? 0} Admins',
  ];
  if (organization['status'] == 'archived') {
    parts.add(
      'gelöscht, endgültige Löschung am ${_date(organization['purgeAfter'])}',
    );
  }
  return parts.join(' · ');
}

String _date(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (parsed == null) return '–';
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(parsed.day)}.${two(parsed.month)}.${parsed.year}';
}

/// Dialog for the master data of an organization. Returns the request body or
/// `null` when cancelled.
Future<Map<String, String>?> showOrganizationFormDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  Map<String, dynamic> initial = const {},
}) async {
  final name = TextEditingController(text: initial['name']?.toString() ?? '');
  final shortName = TextEditingController(
    text: initial['shortName']?.toString() ?? '',
  );
  final edvNumber = TextEditingController(
    text: initial['edvNumber']?.toString() ?? '',
  );
  try {
    return await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final valid =
              name.text.trim().isNotEmpty &&
              shortName.text.trim().isNotEmpty &&
              edvNumber.text.trim().isNotEmpty;
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name *'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: shortName,
                    decoration: const InputDecoration(labelText: 'Kurzname *'),
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: edvNumber,
                    decoration: const InputDecoration(
                      labelText: 'EDV-Nummer *',
                      helperText: 'Eindeutig, z. B. 10050035',
                    ),
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.pop(dialogContext, {
                        'name': name.text.trim(),
                        'shortName': shortName.text.trim(),
                        'edvNumber': edvNumber.text.trim(),
                      })
                    : null,
                child: Text(confirmLabel),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    name.dispose();
    shortName.dispose();
    edvNumber.dispose();
  }
}

/// Details of a single organization in the central administration: master
/// data, key figures, organization admins and a read-only unit hierarchy.
class PlatformOrganizationDetailPage extends StatefulWidget {
  const PlatformOrganizationDetailPage({
    required this.token,
    required this.organizationId,
    super.key,
  });

  final String token;
  final String organizationId;

  @override
  State<PlatformOrganizationDetailPage> createState() =>
      _PlatformOrganizationDetailPageState();
}

class _PlatformOrganizationDetailPageState
    extends State<PlatformOrganizationDetailPage> {
  late final AuthenticatedApiClient _api;
  late Future<Map<String, dynamic>> _future;
  bool _busy = false;

  String get _path => '/api/platform/organizations/${widget.organizationId}';

  @override
  void initState() {
    super.initState();
    _api = AuthenticatedApiClient(widget.token);
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() async =>
      Map<String, dynamic>.from(await _api.request(_path) as Map);

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _refresh();
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> organization) async {
    final values = await showOrganizationFormDialog(
      context,
      title: 'Organisation bearbeiten',
      confirmLabel: 'Speichern',
      initial: organization,
    );
    if (values == null) return;
    await _run(() async {
      await _api.request(
        '/api/organizations/${widget.organizationId}',
        method: 'PUT',
        body: values,
      );
      _message('Stammdaten wurden gespeichert.');
    });
  }

  Future<void> _addAdmin(Map<String, dynamic> organization) async {
    final List<Map<String, dynamic>> accounts;
    try {
      accounts = (await _api.request('/api/users') as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .where((entry) => entry['active'] != false)
          .toList();
    } catch (error) {
      _message(error.toString());
      return;
    }
    if (!mounted) return;
    final existing = ((organization['admins'] as List?) ?? const [])
        .map((entry) => (entry as Map)['id'].toString())
        .toSet();
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AccountPickerDialog(
        accounts: accounts
            .where((entry) => !existing.contains(entry['id'].toString()))
            .toList(),
      ),
    );
    if (selected == null) return;
    await _run(() async {
      await _api.request(
        '$_path/admins',
        method: 'POST',
        body: {'userId': selected['id']},
      );
      _message('${_accountLabel(selected)} ist jetzt Organisationsadmin.');
    });
  }

  Future<void> _removeAdmin(Map<String, dynamic> admin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Organisationsadmin entfernen?'),
        content: Text(
          '${_accountLabel(admin)} verliert die Admin-Rolle auf der obersten '
          'Ebene dieser Organisation. Andere Freigaben und das zentrale Konto '
          'bleiben erhalten.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Entfernen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _api.request('$_path/admins/${admin['id']}', method: 'DELETE');
      _message('Admin-Rolle wurde entfernt.');
    });
  }

  Future<void> _delete(Map<String, dynamic> organization) async {
    final password = TextEditingController();
    final mfaCode = TextEditingController();
    final confirmation = TextEditingController();
    final organizationName = organization['name']?.toString() ?? 'Organisation';
    final expectedConfirmation =
        'ORGANISATION ${organization['edvNumber'] ?? ''} LÖSCHEN';
    try {
      final credentials = await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Organisation löschen'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '„$organizationName“ und alle Unterorganisationen werden '
                      'sofort gesperrt und nach Ablauf der Aufbewahrungsfrist '
                      'mit allen Daten endgültig gelöscht. Bis dahin kann die '
                      'Organisation hier wiederhergestellt werden. Konten '
                      'bleiben erhalten.',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Exportiere vorher eine Datensicherung.',
                      style: TextStyle(
                        color: Theme.of(dialogContext).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: password,
                      obscureText: true,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Aktuelles Admin-Passwort',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: mfaCode,
                      decoration: const InputDecoration(
                        labelText: '2-FA-Code (falls aktiviert)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: confirmation,
                      decoration: InputDecoration(
                        labelText:
                            'Zur Bestätigung „$expectedConfirmation“ eingeben',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setDialogState(() {}),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                ),
                onPressed:
                    password.text.isEmpty ||
                        confirmation.text != expectedConfirmation
                    ? null
                    : () => Navigator.pop(dialogContext, {
                        'currentPassword': password.text,
                        'mfaCode': mfaCode.text.trim(),
                        'confirmation': confirmation.text,
                      }),
                child: const Text('Organisation löschen'),
              ),
            ],
          ),
        ),
      );
      if (credentials == null || !mounted) return;
      await _run(() async {
        await _api.request(
          '/api/organizations/${widget.organizationId}',
          method: 'DELETE',
          body: credentials,
        );
        _message('$organizationName wurde gelöscht.');
      });
    } finally {
      password.dispose();
      mfaCode.dispose();
      confirmation.dispose();
    }
  }

  Future<void> _restore(Map<String, dynamic> organization) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Organisation wiederherstellen?'),
        content: Text(
          '„${organization['name']}“ und alle zusammen mit ihr gelöschten '
          'Einheiten werden wieder aktiviert. Mitglieder erhalten ihre '
          'bisherigen Freigaben zurück.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Wiederherstellen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _api.request('$_path/restore', method: 'POST');
      _message('${organization['name']} wurde wiederhergestellt.');
    });
  }

  List<Map<String, dynamic>> _orderedUnits(List<Map<String, dynamic>> units) {
    final result = <Map<String, dynamic>>[];
    final known = units.map((entry) => entry['id'].toString()).toSet();
    void append(String? parentId, int depth) {
      final children =
          units
              .where(
                (entry) =>
                    entry['parentId']?.toString() == parentId ||
                    (parentId == null &&
                        entry['parentId'] != null &&
                        !known.contains(entry['parentId'].toString())),
              )
              .toList()
            ..sort(
              (left, right) => (left['name']?.toString() ?? '').compareTo(
                right['name']?.toString() ?? '',
              ),
            );
      for (final child in children) {
        result.add({...child, '_depth': depth});
        append(child['id'].toString(), depth + 1);
      }
    }

    append(null, 0);
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        final organization = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(organization?['name']?.toString() ?? 'Organisation'),
            bottom: _busy
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(4),
                    child: LinearProgressIndicator(),
                  )
                : null,
          ),
          body: _body(context, snapshot),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AsyncSnapshot<Map<String, dynamic>> snapshot,
  ) {
    if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(snapshot.error.toString()),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Erneut laden'),
            ),
          ],
        ),
      );
    }
    final organization = snapshot.data!;
    final active = organization['status'] == 'active';
    final theme = Theme.of(context);
    final admins = ((organization['admins'] as List?) ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final units = _orderedUnits(
      ((organization['units'] as List?) ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(),
    );

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (!active)
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.auto_delete_outlined,
                  color: theme.colorScheme.onErrorContainer,
                ),
                title: Text(
                  'Gelöscht am ${_date(organization['archivedAt'])}',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                subtitle: Text(
                  organization['restorable'] == true
                      ? 'Endgültige Löschung am '
                            '${_date(organization['purgeAfter'])}. Bis dahin '
                            'ist eine Wiederherstellung möglich.'
                      : 'Die Aufbewahrungsfrist ist abgelaufen.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                trailing: organization['restorable'] == true
                    ? FilledButton.icon(
                        onPressed: _busy ? null : () => _restore(organization),
                        icon: const Icon(Icons.restore),
                        label: const Text('Wiederherstellen'),
                      )
                    : null,
              ),
            ),
          _Section(
            title: 'Stammdaten',
            action: active
                ? OutlinedButton.icon(
                    onPressed: _busy ? null : () => _edit(organization),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Bearbeiten'),
                  )
                : null,
            child: Column(
              children: [
                _Field('Name', organization['name']),
                _Field('Kurzname', organization['shortName']),
                _Field('EDV-Nummer', organization['edvNumber']),
                _Field('Status', active ? 'Aktiv' : 'Gelöscht'),
                _Field('Angelegt am', _date(organization['createdAt'])),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Figure(
                icon: Icons.account_tree_outlined,
                label: 'Aktive Einheiten',
                value: organization['unitCount'],
              ),
              _Figure(
                icon: Icons.people_outline,
                label: 'Mitglieder',
                value: organization['memberCount'],
              ),
              _Figure(
                icon: Icons.admin_panel_settings_outlined,
                label: 'Organisationsadmins',
                value: organization['adminCount'],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Organisationsadmins',
            action: active
                ? OutlinedButton.icon(
                    onPressed: _busy ? null : () => _addAdmin(organization),
                    icon: const Icon(Icons.person_add_alt_outlined),
                    label: const Text('Admin hinzufügen'),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Organisationsadmins haben die Rolle „Admin“ auf der '
                  'obersten Ebene inklusive aller Untereinheiten und verwalten '
                  'Einheiten, Rollen und Freigaben ihrer Organisation selbst.',
                ),
                const SizedBox(height: 8),
                if (admins.isEmpty)
                  Text(
                    'Diese Organisation hat keinen aktiven Admin.',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                for (final admin in admins)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(_accountLabel(admin)),
                    subtitle: Text(
                      [
                        admin['username'],
                        admin['email'],
                      ].whereType<Object>().join(' · '),
                    ),
                    trailing: active
                        ? IconButton(
                            tooltip: admins.length <= 1
                                ? 'Der letzte Admin kann nicht entfernt werden'
                                : 'Admin-Rolle entfernen',
                            onPressed: _busy || admins.length <= 1
                                ? null
                                : () => _removeAdmin(admin),
                            icon: const Icon(Icons.person_remove_outlined),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Einheiten',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Nur zur Ansicht. Änderungen an Einheiten nehmen die '
                  'Organisationsadmins in ihrer Organisation vor.',
                ),
                const SizedBox(height: 8),
                for (final unit in units)
                  Padding(
                    padding: EdgeInsets.only(
                      left: ((unit['_depth'] as int?) ?? 0) * 24.0,
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        unit['unitKind'] == 'youth'
                            ? Icons.diversity_3_outlined
                            : unit['parentId'] == null
                            ? Icons.corporate_fare_outlined
                            : Icons.account_tree_outlined,
                      ),
                      title: Text(unit['name']?.toString() ?? ''),
                      subtitle: Text(
                        '${unit['type'] ?? 'Einheit'} · '
                        'EDV ${unit['edvNumber'] ?? '–'}'
                        '${unit['status'] == 'active' ? '' : ' · archiviert'}',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (active) ...[
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: _busy ? null : () => _delete(organization),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Organisation löschen'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _accountLabel(Map<String, dynamic> account) {
  final name = account['name']?.toString().trim() ?? '';
  return name.isNotEmpty ? name : account['username']?.toString() ?? 'Konto';
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                ?action,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final text = value?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(text.isEmpty ? '–' : text)),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.icon, required this.label, this.value});

  final IconData icon;
  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: Card(
        child: ListTile(
          leading: Icon(icon),
          title: Text(
            '${value ?? 0}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          subtitle: Text(label),
        ),
      ),
    );
  }
}

class _AccountPickerDialog extends StatefulWidget {
  const _AccountPickerDialog({required this.accounts});

  final List<Map<String, dynamic>> accounts;

  @override
  State<_AccountPickerDialog> createState() => _AccountPickerDialogState();
}

class _AccountPickerDialogState extends State<_AccountPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final matches = widget.accounts
        .where(
          (account) =>
              query.isEmpty ||
              [account['username'], account['name'], account['email']].any(
                (value) =>
                    (value?.toString() ?? '').toLowerCase().contains(query),
              ),
        )
        .take(50)
        .toList();
    return AlertDialog(
      title: const Text('Organisationsadmin hinzufügen'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Wähle ein bestehendes zentrales Konto. Es erhält die Rolle '
              '„Admin“ auf der obersten Ebene dieser Organisation.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Nutzername, Name oder E-Mail',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: matches.isEmpty
                  ? const Center(child: Text('Kein passendes Konto gefunden.'))
                  : ListView(
                      children: [
                        for (final account in matches)
                          ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text(_accountLabel(account)),
                            subtitle: Text(
                              [
                                account['username'],
                                account['email'],
                              ].whereType<Object>().join(' · '),
                            ),
                            onTap: () => Navigator.pop(context, account),
                          ),
                      ],
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
      ],
    );
  }
}
