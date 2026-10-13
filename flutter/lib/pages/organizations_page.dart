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
    final edvNumber = TextEditingController();
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
                const SizedBox(height: 12),
                TextField(
                  controller: edvNumber,
                  decoration: const InputDecoration(
                    labelText: 'EDV-Nummer *',
                    helperText: 'Eindeutig, z. B. 10050035',
                  ),
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
        body: {
          'name': name.text,
          'shortName': shortName.text,
          'edvNumber': edvNumber.text,
        },
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      shortName.dispose();
      edvNumber.dispose();
    }
  }

  Future<void> _createUnit(
    List<Map<String, dynamic>> units, {
    String? initialParentId,
    bool youth = false,
  }) async {
    final name = TextEditingController();
    final type = TextEditingController(
      text: youth ? 'Jugendorganisation' : 'Ortsgruppe',
    );
    final edvNumber = TextEditingController();
    final existingYouthBases = units
        .where((entry) => entry['unitKind'] == 'youth')
        .map((entry) => entry['baseUnitId']?.toString())
        .whereType<String>()
        .toSet();
    final possibleParents = units
        .where(
          (entry) =>
              entry['status'] == 'active' &&
              entry['canManageStructure'] == true &&
              entry['unitKind'] != 'youth' &&
              (!youth || !existingYouthBases.contains(entry['id'].toString())),
        )
        .toList();
    if (possibleParents.isEmpty) {
      _error(
        youth
            ? 'Es ist keine Stammgliederung ohne Jugendorganisation verfügbar.'
            : 'Es ist keine geeignete übergeordnete Einheit verfügbar.',
      );
      return;
    }
    var parentId =
        initialParentId ??
        possibleParents
            .firstWhere(
              (entry) => entry['parentId'] == null,
              orElse: () => possibleParents.first,
            )['id']
            .toString();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
              youth
                  ? 'Jugendorganisation anlegen'
                  : 'Organisationseinheit anlegen',
            ),
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
                  if (!youth) ...[
                    TextField(
                      controller: type,
                      decoration: const InputDecoration(
                        labelText: 'Typ, z. B. Landesverband oder Ortsgruppe',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: edvNumber,
                    decoration: const InputDecoration(
                      labelText: 'EDV-Nummer *',
                      helperText: 'Eindeutig innerhalb aller Organisationen',
                    ),
                    textCapitalization: TextCapitalization.characters,
                  ),
                  const SizedBox(height: 12),
                  KeyboardDropdownButtonFormField<String>(
                    initialValue: parentId,
                    decoration: InputDecoration(
                      labelText: youth
                          ? 'Stammgliederung'
                          : 'Übergeordnete Einheit',
                    ),
                    items: possibleParents
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
        body: {
          'name': name.text,
          'type': type.text,
          'edvNumber': edvNumber.text,
          'parentId': parentId,
          'unitKind': youth ? 'youth' : 'standard',
        },
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      type.dispose();
      edvNumber.dispose();
    }
  }

  Set<String> _relatedUnitIds(
    Map<String, dynamic> source,
    List<Map<String, dynamic>> units,
  ) {
    final byId = {for (final unit in units) unit['id'].toString(): unit};
    final result = <String>{};
    final descendants = <String>{};
    final descendantParents = <String>{source['id'].toString()};
    var current = source;
    while (current['parentId'] != null) {
      final parentId = current['parentId'].toString();
      final parent = byId[parentId];
      if (parent == null || !result.add(parentId)) break;
      current = parent;
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final unit in units) {
        final parentId = unit['parentId']?.toString();
        if (descendantParents.contains(parentId)) {
          final id = unit['id'].toString();
          if (descendants.add(id)) {
            descendantParents.add(id);
            changed = true;
          }
        }
      }
    }
    result.addAll(descendants);
    result.remove(source['id']?.toString());
    return result;
  }

  Future<void> _editInventoryVisibility(
    Map<String, dynamic> unit,
    List<Map<String, dynamic>> units,
  ) async {
    final eligibleIds = _relatedUnitIds(unit, units);
    final eligible = units
        .where(
          (entry) =>
              eligibleIds.contains(entry['id']?.toString()) &&
              entry['status'] == 'active',
        )
        .toList();
    final selected = ((unit['inventoryVisibleToUnitIds'] as List?) ?? const [])
        .map((entry) => entry.toString())
        .where(eligibleIds.contains)
        .toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Inventar von ${unit['name']} freigeben'),
          content: SizedBox(
            width: 560,
            child: eligible.isEmpty
                ? const Text(
                    'Für diese Einheit gibt es keine aktive über- oder '
                    'untergeordnete Ebene.',
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ausgewählte Ebenen dürfen dieses Inventar ansehen. '
                          'Änderungen bleiben ausschließlich in der '
                          'inventarführenden Ebene möglich.',
                        ),
                        const SizedBox(height: 12),
                        for (final target in eligible)
                          CheckboxListTile(
                            value: selected.contains(target['id'].toString()),
                            title: Text(target['name']?.toString() ?? ''),
                            subtitle: Text(
                              target['type']?.toString() ?? 'Einheit',
                            ),
                            onChanged: (value) => setDialogState(() {
                              final id = target['id'].toString();
                              if (value == true) {
                                selected.add(id);
                              } else {
                                selected.remove(id);
                              }
                            }),
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
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Freigaben speichern'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.request(
        '/api/organization-units/${unit['id']}/inventory-visibility',
        method: 'PUT',
        body: {'visibleToUnitIds': selected.toList()},
      );
      await _refresh();
    } catch (error) {
      _error(error);
    }
  }

  Future<void> _editUnit(Map<String, dynamic> unit) async {
    final name = TextEditingController(text: unit['name']?.toString());
    final type = TextEditingController(text: unit['type']?.toString());
    final edvNumber = TextEditingController(
      text: unit['edvNumber']?.toString(),
    );
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
                const SizedBox(height: 12),
                TextField(
                  controller: edvNumber,
                  decoration: const InputDecoration(labelText: 'EDV-Nummer *'),
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
              child: const Text('Speichern'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await _api.request(
        '/api/organization-units/${unit['id']}',
        method: 'PUT',
        body: {
          'name': name.text,
          'type': type.text,
          'edvNumber': edvNumber.text,
        },
      );
      await _refresh();
    } catch (error) {
      _error(error);
    } finally {
      name.dispose();
      type.dispose();
      edvNumber.dispose();
    }
  }

  Future<void> _convertToYouth(Map<String, dynamic> unit) async {
    final parentId = unit['parentId']?.toString();
    if (parentId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Als Jugendorganisation kennzeichnen?'),
        content: const Text(
          'Die Einheit wird fest mit ihrer direkten Stammgliederung verknüpft. '
          'Beide Seiten können gegenseitig Lagerorte suchen, Inventar und '
          'Fahrzeuge reservieren sowie Mängel melden. Andere Zugriffe bleiben '
          'getrennt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Verknüpfen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.request(
        '/api/organization-units/${unit['id']}',
        method: 'PUT',
        body: {
          'name': unit['name'],
          'type': 'Jugendorganisation',
          'edvNumber': unit['edvNumber'],
          'parentId': parentId,
          'unitKind': 'youth',
        },
      );
      await _refresh();
    } catch (error) {
      _error(error);
    }
  }

  Future<void> _transferAndArchive(
    Map<String, dynamic> unit,
    List<Map<String, dynamic>> units,
  ) async {
    String? targetId;
    final targets = units
        .where(
          (entry) =>
              entry['id'] != unit['id'] &&
              entry['status'] == 'active' &&
              entry['canManageUnit'] == true,
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

  bool _canConvertToYouth(
    Map<String, dynamic> unit,
    List<Map<String, dynamic>> units,
  ) {
    final parentId = unit['parentId']?.toString();
    if (parentId == null || unit['unitKind'] == 'youth') return false;
    final hasChildren = units.any(
      (entry) =>
          entry['parentId']?.toString() == unit['id']?.toString() &&
          entry['status'] == 'active',
    );
    final parentAlreadyLinked = units.any(
      (entry) =>
          entry['unitKind'] == 'youth' &&
          entry['baseUnitId']?.toString() == parentId &&
          entry['status'] == 'active',
    );
    return !hasChildren && !parentAlreadyLinked;
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
          final roles = (user['roles'] as List? ?? const [])
              .map((entry) => entry.toString())
              .toSet();
          final platformAdmin = user['platformAdmin'] == true;
          final canCreateOrganizationStructure =
              roles.contains('Admin') &&
              permissions.contains('organizations.write');
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
                    if (platformAdmin && canCreateOrganizationStructure)
                      FilledButton.icon(
                        onPressed: _createOrganization,
                        icon: const Icon(Icons.add_business_outlined),
                        label: const Text('Organisation anlegen'),
                      ),
                    if (canCreateOrganizationStructure && units.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () => _createUnit(units),
                        icon: const Icon(Icons.account_tree_outlined),
                        label: const Text('Einheit anlegen'),
                      ),
                    if (canCreateOrganizationStructure && units.isNotEmpty)
                      FilledButton.icon(
                        onPressed: () => _createUnit(units, youth: true),
                        icon: const Icon(Icons.diversity_3_outlined),
                        label: const Text('Jugendorganisation anlegen'),
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
                        '${organization['shortName'] ?? ''} · EDV ${organization['edvNumber'] ?? '–'}',
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
                          unit['unitKind'] == 'youth'
                              ? Icons.diversity_3_outlined
                              : unit['parentId'] == null
                              ? Icons.corporate_fare_outlined
                              : Icons.account_tree_outlined,
                        ),
                        title: Text(unit['name']?.toString() ?? ''),
                        subtitle: Text(
                          '${unit['type'] ?? 'Einheit'} · EDV ${unit['edvNumber'] ?? '–'} · '
                          '${unit['unitKind'] == 'youth' ? 'mit Stammgliederung verknüpft · ' : ''}'
                          '${((unit['inventoryVisibleToUnitIds'] as List?) ?? const []).isEmpty ? 'Inventar nicht freigegeben' : 'Inventar für ${(unit['inventoryVisibleToUnitIds'] as List).length} Ebene(n) freigegeben'} · '
                          '${unit['status'] ?? 'active'}',
                        ),
                        trailing:
                            (unit['canManageUnit'] == true ||
                                    unit['canManageStructure'] == true) &&
                                unit['status'] == 'active'
                            ? PopupMenuButton<String>(
                                tooltip: 'Aktionen für diese Einheit',
                                onSelected: (action) {
                                  if (action == 'create-child') {
                                    _createUnit(
                                      units,
                                      initialParentId: unit['id'].toString(),
                                    );
                                  }
                                  if (action == 'convert-youth') {
                                    _convertToYouth(unit);
                                  }
                                  if (action == 'inventory-visibility') {
                                    _editInventoryVisibility(unit, units);
                                  }
                                  if (action == 'edit') _editUnit(unit);
                                  if (action == 'archive') {
                                    _transferAndArchive(unit, units);
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (unit['canManageStructure'] == true &&
                                      unit['unitKind'] != 'youth')
                                    const PopupMenuItem(
                                      value: 'create-child',
                                      child: Text('Unterebene anlegen'),
                                    ),
                                  if (unit['canManageStructure'] == true)
                                    const PopupMenuItem(
                                      value: 'inventory-visibility',
                                      child: Text('Inventar freigeben'),
                                    ),
                                  if (unit['canManageStructure'] == true &&
                                      _canConvertToYouth(unit, units))
                                    const PopupMenuItem(
                                      value: 'convert-youth',
                                      child: Text(
                                        'Als Jugendorganisation kennzeichnen',
                                      ),
                                    ),
                                  if (unit['canManageUnit'] == true)
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Text('Bearbeiten'),
                                    ),
                                  if (unit['canManageUnit'] == true &&
                                      unit['parentId'] != null)
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
