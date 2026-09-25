import 'package:flutter/material.dart';

import '../services/authenticated_api_client.dart';
import '../widgets/keyboard_dropdown_button_form_field.dart';

class OrganizationsPage extends StatefulWidget {
  const OrganizationsPage({required this.token, super.key});

  final String token;

  @override
  State<OrganizationsPage> createState() => _OrganizationsPageState();
}

class _OrganizationsPageState extends State<OrganizationsPage> {
  late final AuthenticatedApiClient _api;
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _api = AuthenticatedApiClient(widget.token);
    _future = _load();
  }

  Future<Map<String, dynamic>> _load() async {
    final results = await Future.wait([
      _api.request('/api/organizations'),
      _api.request('/api/organization-units'),
      _api.request('/api/auth/me'),
    ]);
    return {
      'organizations': (results[0] as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(),
      'units': (results[1] as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(),
      'me': Map<String, dynamic>.from(results[2] as Map),
    };
  }

  Future<void> _refresh() async {
    final next = _load();
    setState(() => _future = next);
    await next;
  }

  void _error(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _createOrganization() async {
    final name = TextEditingController();
    final shortName = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Organisation anlegen'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: shortName,
                  decoration: const InputDecoration(labelText: 'Kurzname'),
                  textCapitalization: TextCapitalization.characters,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Anlegen'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await _api.request(
        '/api/organizations',
        method: 'POST',
        body: {'name': name.text, 'shortName': shortName.text},
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      shortName.dispose();
    }
  }

  Future<void> _createUnit(List<Map<String, dynamic>> units) async {
    final name = TextEditingController();
    final type = TextEditingController(text: 'Ortsgruppe');
    var parentId = units
        .firstWhere(
          (entry) => entry['parentId'] == null,
          orElse: () => units.first,
        )['id']
        .toString();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Organisationseinheit anlegen'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: type,
                    decoration: const InputDecoration(
                      labelText: 'Typ, z. B. Landesverband oder Ortsgruppe',
                    ),
                  ),
                  const SizedBox(height: 12),
                  KeyboardDropdownButtonFormField<String>(
                    initialValue: parentId,
                    decoration: const InputDecoration(
                      labelText: 'Übergeordnete Einheit',
                    ),
                    items: units
                        .where((entry) => entry['status'] == 'active')
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry['id'].toString(),
                            child: Text(entry['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => parentId = value);
                      }
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Anlegen'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      await _api.request(
        '/api/organization-units',
        method: 'POST',
        body: {'name': name.text, 'type': type.text, 'parentId': parentId},
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      type.dispose();
    }
  }

  Future<void> _editUnit(Map<String, dynamic> unit) async {
    final name = TextEditingController(text: unit['name']?.toString());
    final type = TextEditingController(text: unit['type']?.toString());
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Organisationseinheit bearbeiten'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: type,
                  decoration: const InputDecoration(labelText: 'Typ'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Speichern'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await _api.request(
        '/api/organization-units/${unit['id']}',
        method: 'PUT',
        body: {'name': name.text, 'type': type.text},
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      type.dispose();
    }
  }

  Future<void> _transferAndArchive(
    Map<String, dynamic> unit,
    List<Map<String, dynamic>> units,
  ) async {
    String? targetId;
    final targets = units
        .where(
          (entry) => entry['id'] != unit['id'] && entry['status'] == 'active',
        )
        .toList();
    if (targets.isNotEmpty) targetId = targets.first['id'].toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Einheit übertragen und archivieren'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Alle Daten werden zuerst in die ausgewählte aktive Einheit '
                  'übertragen. Die archivierte Einheit wird nach zwei Jahren gelöscht.',
                ),
                const SizedBox(height: 16),
                if (targets.isNotEmpty)
                  KeyboardDropdownButtonFormField<String>(
                    initialValue: targetId,
                    decoration: const InputDecoration(labelText: 'Zieleinheit'),
                    items: targets
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry['id'].toString(),
                            child: Text(entry['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => targetId = value),
                  )
                else
                  const Text('Es ist keine aktive Zieleinheit verfügbar.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: targetId == null
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Übertragen und archivieren'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || targetId == null) return;
    try {
      await _api.request(
        '/api/organization-units/${unit['id']}/transfer',
        method: 'POST',
        body: {'targetUnitId': targetId},
      );
      await _api.request(
        '/api/organization-units/${unit['id']}/archive',
        method: 'POST',
        body: const {},
      );
      await _refresh();
    } catch (error) {
      _error(error);
    }
  }

  List<Map<String, dynamic>> _orderedUnits(List<Map<String, dynamic>> units) {
    final result = <Map<String, dynamic>>[];
    void append(String? parentId, int depth) {
      final children =
          units
              .where((entry) => entry['parentId']?.toString() == parentId)
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
    return Scaffold(
      appBar: AppBar(title: const Text('Organisationen & Einheiten')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: FilledButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Erneut laden'),
              ),
            );
          }
          final data = snapshot.data!;
          final organizations = (data['organizations'] as List)
              .cast<Map<String, dynamic>>();
          final units = (data['units'] as List).cast<Map<String, dynamic>>();
          final me = Map<String, dynamic>.from(data['me'] as Map);
          final user = Map<String, dynamic>.from(
            me['user'] as Map? ?? const {},
          );
          final permissions = (user['permissions'] as List? ?? const [])
              .map((entry) => entry.toString())
              .toSet();
          final canManage = permissions.contains('users.write');
          final platformAdmin = user['platformAdmin'] == true;
          final ordered = _orderedUnits(units);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (platformAdmin)
                      FilledButton.icon(
                        onPressed: _createOrganization,
                        icon: const Icon(Icons.add_business_outlined),
                        label: const Text('Organisation anlegen'),
                      ),
                    if (canManage && units.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () => _createUnit(units),
                        icon: const Icon(Icons.account_tree_outlined),
                        label: const Text('Einheit anlegen'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Meine Organisationen',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final organization in organizations)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.corporate_fare_outlined),
                      title: Text(organization['name']?.toString() ?? ''),
                      subtitle: Text(
                        organization['shortName']?.toString() ?? '',
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Text(
                  'Hierarchie',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                for (final unit in ordered)
                  Padding(
                    padding: EdgeInsets.only(
                      left: ((unit['_depth'] as int?) ?? 0) * 24.0,
                    ),
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                          unit['parentId'] == null
                              ? Icons.corporate_fare_outlined
                              : Icons.account_tree_outlined,
                        ),
                        title: Text(unit['name']?.toString() ?? ''),
                        subtitle: Text(
                          '${unit['type'] ?? 'Einheit'} · ${unit['status'] ?? 'active'}',
                        ),
                        trailing: canManage && unit['status'] == 'active'
                            ? PopupMenuButton<String>(
                                tooltip: 'Aktionen für diese Einheit',
                                onSelected: (action) {
                                  if (action == 'edit') _editUnit(unit);
                                  if (action == 'archive') {
                                    _transferAndArchive(unit, units);
                                  }
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Bearbeiten'),
                                  ),
                                  if (unit['parentId'] != null)
                                    const PopupMenuItem(
                                      value: 'archive',
                                      child: Text('Übertragen und archivieren'),
                                    ),
                                ],
                              )
                            : null,
                      ),
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
