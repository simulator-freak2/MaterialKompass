import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'location_dialogs.dart';

class LocationsPage extends StatefulWidget {
  final String token;
  final http.Client? client;

  const LocationsPage({required this.token, this.client, super.key});

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  late final http.Client _client = widget.client ?? http.Client();
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _buildings = [];
  List<Map<String, dynamic>> _shelves = [];
  List<Map<String, dynamic>> _levels = [];
  List<Map<String, dynamic>> _positions = [];
  Map<String, List<Map<String, dynamic>>> _shelvesByBuilding = {};
  Map<String, List<Map<String, dynamic>>> _levelsByShelf = {};
  Map<String, List<Map<String, dynamic>>> _positionsByLevel = {};
  Map<String, int> _positionCountByBuilding = {};
  bool _loading = true;
  bool _canWrite = false;
  String? _loadError;
  String _query = '';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  String _value(Map<String, dynamic> entry, String key) =>
      entry[key]?.toString().trim() ?? '';

  List<Map<String, dynamic>> _mapList(Object? value) => (value as List? ?? [])
      .map((entry) => Map<String, dynamic>.from(entry as Map))
      .toList();

  void _sort(List<Map<String, dynamic>> values) {
    values.sort((a, b) {
      final code = _value(a, 'code')
          .toLowerCase()
          .compareTo(_value(b, 'code').toLowerCase());
      return code != 0
          ? code
          : _value(a, 'name')
              .toLowerCase()
              .compareTo(_value(b, 'name').toLowerCase());
    });
  }

  Map<String, List<Map<String, dynamic>>> _groupBy(
    List<Map<String, dynamic>> values,
    String key,
  ) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in values) {
      result.putIfAbsent(_value(entry, key), () => []).add(entry);
    }
    for (final entries in result.values) {
      _sort(entries);
    }
    return result;
  }

  void _replaceHierarchy(Map<String, dynamic> data) {
    _buildings = _mapList(data['locations']);
    _shelves = _mapList(data['shelves']);
    _levels = _mapList(data['storageLevels']);
    _positions = _mapList(data['stockStructures']);
    _sort(_buildings);
    _sort(_shelves);
    _sort(_levels);
    _sort(_positions);
    _shelvesByBuilding = _groupBy(_shelves, 'locationId');
    _levelsByShelf = _groupBy(_levels, 'shelfId');
    _positionsByLevel = _groupBy(_positions, 'levelId');
    _positionCountByBuilding = {};
    for (final position in _positions) {
      final buildingId = _value(position, 'locationId');
      _positionCountByBuilding.update(
        buildingId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final responses = await Future.wait([
        _client.get(Uri.parse('$apiBaseUrl/api/storage-hierarchy'),
            headers: _headers),
        _client.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: _headers),
      ]);
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Die Lagerstruktur konnte nicht geladen werden.');
      }
      final hierarchy =
          Map<String, dynamic>.from(jsonDecode(responses[0].body) as Map);
      final user = jsonDecode(responses[1].body)['user'] as Map;
      if (!mounted) return;
      setState(() {
        _replaceHierarchy(hierarchy);
        _canWrite = (user['permissions'] as List? ?? const [])
            .contains('locations.write');
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<String?> _send(
    String path,
    String method,
    Map<String, dynamic>? body,
  ) async {
    try {
      final uri = Uri.parse('$apiBaseUrl$path');
      final response = switch (method) {
        'POST' =>
          await _client.post(uri, headers: _headers, body: jsonEncode(body)),
        'PUT' =>
          await _client.put(uri, headers: _headers, body: jsonEncode(body)),
        'DELETE' => await _client.delete(uri, headers: _headers),
        _ => throw ArgumentError('Nicht unterstützte Methode'),
      };
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      try {
        return jsonDecode(response.body)['error']?.toString() ??
            'Aktion fehlgeschlagen.';
      } catch (_) {
        return 'Aktion fehlgeschlagen.';
      }
    } catch (_) {
      return 'Der Server ist derzeit nicht erreichbar.';
    }
  }

  void _message(String value, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(value),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<void> _afterChange(String message) async {
    _message(message);
    await _load();
  }

  Future<void> _editBuilding([Map<String, dynamic>? building]) async {
    final id = Uri.encodeComponent(_value(building ?? {}, 'id'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => BuildingDialog(
        token: widget.token,
        building: building,
        onSubmit: (values) => _send(
          building == null ? '/api/locations' : '/api/locations/$id',
          building == null ? 'POST' : 'PUT',
          values,
        ),
      ),
    );
    if (saved == true) {
      await _afterChange(building == null
          ? 'Gebäude wurde angelegt.'
          : 'Gebäude wurde aktualisiert.');
    }
  }

  Future<void> _editShelf(String buildingId,
      [Map<String, dynamic>? shelf]) async {
    final id = Uri.encodeComponent(_value(shelf ?? {}, 'id'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StorageNodeDialog(
        title: shelf == null ? 'Neues Regal' : 'Regal bearbeiten',
        parentLabel: 'Gebäude',
        parentIdKey: 'locationId',
        parents: _buildings,
        initialParentId: _value(shelf ?? {}, 'locationId').isEmpty
            ? buildingId
            : _value(shelf!, 'locationId'),
        node: shelf,
        onSubmit: (values) => _send(
          shelf == null ? '/api/shelves' : '/api/shelves/$id',
          shelf == null ? 'POST' : 'PUT',
          values,
        ),
      ),
    );
    if (saved == true) {
      await _afterChange(shelf == null
          ? 'Regal wurde angelegt.'
          : 'Regal wurde aktualisiert.');
    }
  }

  Future<void> _editLevel(String shelfId, [Map<String, dynamic>? level]) async {
    final id = Uri.encodeComponent(_value(level ?? {}, 'id'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StorageNodeDialog(
        title: level == null ? 'Neue Ebene' : 'Ebene bearbeiten',
        parentLabel: 'Regal',
        parentIdKey: 'shelfId',
        parents: _shelves,
        initialParentId: _value(level ?? {}, 'shelfId').isEmpty
            ? shelfId
            : _value(level!, 'shelfId'),
        node: level,
        onSubmit: (values) => _send(
          level == null ? '/api/storage-levels' : '/api/storage-levels/$id',
          level == null ? 'POST' : 'PUT',
          values,
        ),
      ),
    );
    if (saved == true) {
      await _afterChange(level == null
          ? 'Ebene wurde angelegt.'
          : 'Ebene wurde aktualisiert.');
    }
  }

  Future<void> _editPosition(String levelId,
      [Map<String, dynamic>? position]) async {
    final id = Uri.encodeComponent(_value(position ?? {}, 'id'));
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StorageNodeDialog(
        title: position == null ? 'Neuer Lagerplatz' : 'Lagerplatz bearbeiten',
        parentLabel: 'Ebene',
        parentIdKey: 'levelId',
        parents: _levels,
        initialParentId: _value(position ?? {}, 'levelId').isEmpty
            ? levelId
            : _value(position!, 'levelId'),
        node: position,
        onSubmit: (values) => _send(
          position == null
              ? '/api/stock-structures'
              : '/api/stock-structures/$id',
          position == null ? 'POST' : 'PUT',
          values,
        ),
      ),
    );
    if (saved == true) {
      await _afterChange(position == null
          ? 'Lagerplatz wurde angelegt.'
          : 'Lagerplatz wurde aktualisiert.');
    }
  }

  Future<void> _bulkCreate(Map<String, dynamic> building) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => BulkStorageDialog(
        buildingName: _value(building, 'name'),
        locationId: _value(building, 'id'),
        onSubmit: (values) =>
            _send('/api/storage-hierarchy/bulk', 'POST', values),
      ),
    );
    if (saved == true) {
      await _afterChange('Die Lagerstruktur wurde angelegt.');
    }
  }

  Future<void> _delete(String label, String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline,
            color: Theme.of(context).colorScheme.error),
        title: Text('$label löschen?'),
        content: Text(
          'Leere Unterstrukturen werden ebenfalls entfernt. Sobald ein enthaltener Lagerplatz verwendet wird, wird der gesamte Vorgang abgebrochen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Endgültig löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await _send(path, 'DELETE', null);
    if (error != null) {
      _message(error, error: true);
      return;
    }
    await _afterChange('$label wurde gelöscht.');
  }

  String _address(Map<String, dynamic> building) {
    final firstLine = [
      _value(building, 'street'),
      _value(building, 'houseNumber'),
    ].where((value) => value.isNotEmpty).join(' ');
    final secondLine = [
      _value(building, 'postalCode'),
      _value(building, 'city'),
    ].where((value) => value.isNotEmpty).join(' ');
    return [firstLine, secondLine, _value(building, 'country')]
        .where((value) => value.isNotEmpty)
        .join(', ');
  }

  int _positionCountForBuilding(String buildingId) =>
      _positionCountByBuilding[buildingId] ?? 0;

  List<Map<String, dynamic>> get _visibleBuildings {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _buildings;
    final matchingBuildingIds = <String>{};
    for (final entry in [..._shelves, ..._levels, ..._positions]) {
      if (_value(entry, 'path').toLowerCase().contains(query)) {
        matchingBuildingIds.add(_value(entry, 'locationId'));
      }
    }
    return _buildings.where((building) {
      final id = _value(building, 'id');
      return matchingBuildingIds.contains(id) ||
          [
            _value(building, 'name'),
            _value(building, 'code'),
            _address(building)
          ].any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  PopupMenuButton<String> _actions({
    required String tooltip,
    required List<PopupMenuEntry<String>> items,
    required ValueChanged<String> onSelected,
  }) =>
      PopupMenuButton<String>(
        tooltip: tooltip,
        onSelected: onSelected,
        itemBuilder: (_) => items,
      );

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label,
  ) =>
      PopupMenuItem(
        value: value,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon),
          title: Text(label),
        ),
      );

  Widget _positionTile(Map<String, dynamic> position) {
    final id = Uri.encodeComponent(_value(position, 'id'));
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 60, right: 12),
      leading: const Icon(Icons.inventory_2_outlined, size: 20),
      title: Text(_value(position, 'name')),
      subtitle: Text(_value(position, 'fullCode')),
      trailing: _canWrite
          ? _actions(
              tooltip: 'Lagerplatzaktionen',
              items: [
                _menuItem('edit', Icons.drive_file_move_outlined,
                    'Bearbeiten oder verschieben'),
                _menuItem('delete', Icons.delete_outline, 'Löschen'),
              ],
              onSelected: (action) {
                if (action == 'edit') {
                  _editPosition(_value(position, 'levelId'), position);
                } else {
                  _delete('Lagerplatz', '/api/stock-structures/$id');
                }
              },
            )
          : null,
    );
  }

  Widget _levelTile(Map<String, dynamic> level) {
    final id = _value(level, 'id');
    final encodedId = Uri.encodeComponent(id);
    final positions = _positionsByLevel[id] ?? const [];
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: ExpansionTile(
        key: ValueKey('level-$id-${_query.isNotEmpty}'),
        initiallyExpanded: _query.isNotEmpty,
        leading: const Icon(Icons.layers_outlined),
        title: Text(_value(level, 'name')),
        subtitle: Text('${_value(level, 'code')} · ${positions.length} Plätze'),
        trailing: _canWrite
            ? _actions(
                tooltip: 'Ebenenaktionen',
                items: [
                  _menuItem(
                      'add', Icons.add_box_outlined, 'Lagerplatz hinzufügen'),
                  _menuItem('edit', Icons.drive_file_move_outlined,
                      'Bearbeiten oder verschieben'),
                  _menuItem('delete', Icons.delete_outline, 'Löschen'),
                ],
                onSelected: (action) {
                  if (action == 'add') _editPosition(id);
                  if (action == 'edit') {
                    _editLevel(_value(level, 'shelfId'), level);
                  }
                  if (action == 'delete') {
                    _delete('Ebene', '/api/storage-levels/$encodedId');
                  }
                },
              )
            : null,
        children: positions.isEmpty
            ? [
                _emptyBranch(
                  'Keine Lagerplätze angelegt.',
                  () => _editPosition(id),
                ),
              ]
            : positions.map(_positionTile).toList(),
      ),
    );
  }

  Widget _shelfTile(Map<String, dynamic> shelf) {
    final id = _value(shelf, 'id');
    final encodedId = Uri.encodeComponent(id);
    final levels = _levelsByShelf[id] ?? const [];
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: ExpansionTile(
        key: ValueKey('shelf-$id-${_query.isNotEmpty}'),
        initiallyExpanded: _query.isNotEmpty,
        leading: const Icon(Icons.shelves),
        title: Text(_value(shelf, 'name')),
        subtitle: Text('${_value(shelf, 'code')} · ${levels.length} Ebenen'),
        trailing: _canWrite
            ? _actions(
                tooltip: 'Regalaktionen',
                items: [
                  _menuItem('add', Icons.add, 'Ebene hinzufügen'),
                  _menuItem('edit', Icons.drive_file_move_outlined,
                      'Bearbeiten oder verschieben'),
                  _menuItem('delete', Icons.delete_outline, 'Löschen'),
                ],
                onSelected: (action) {
                  if (action == 'add') _editLevel(id);
                  if (action == 'edit') {
                    _editShelf(_value(shelf, 'locationId'), shelf);
                  }
                  if (action == 'delete') {
                    _delete('Regal', '/api/shelves/$encodedId');
                  }
                },
              )
            : null,
        children: levels.isEmpty
            ? [_emptyBranch('Keine Ebenen angelegt.', () => _editLevel(id))]
            : levels.map(_levelTile).toList(),
      ),
    );
  }

  Widget _emptyBranch(String message, VoidCallback onAdd) => Padding(
        padding: const EdgeInsets.fromLTRB(56, 12, 16, 16),
        child: Row(children: [
          Expanded(child: Text(message)),
          if (_canWrite)
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Anlegen'),
            ),
        ]),
      );

  Widget _buildingCard(Map<String, dynamic> building) {
    final id = _value(building, 'id');
    final encodedId = Uri.encodeComponent(id);
    final shelves = _shelvesByBuilding[id] ?? const [];
    final address = _address(building);
    final positionCount = _positionCountForBuilding(id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: ValueKey('building-$id-${_query.isNotEmpty}'),
        initiallyExpanded: _query.isNotEmpty,
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(Icons.apartment_outlined,
              color: Theme.of(context).colorScheme.onPrimaryContainer),
        ),
        title: Text(_value(building, 'name'),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(address.isEmpty ? 'Adresse noch nicht hinterlegt' : address),
            Text(
                '${_value(building, 'code')} · ${shelves.length} Regale · $positionCount Lagerplätze'),
          ],
        ),
        trailing: _canWrite
            ? _actions(
                tooltip: 'Gebäudeaktionen',
                items: [
                  _menuItem('add', Icons.add, 'Regal hinzufügen'),
                  _menuItem('bulk', Icons.auto_awesome_outlined,
                      'Struktur automatisch anlegen'),
                  _menuItem('edit', Icons.edit_outlined, 'Gebäude bearbeiten'),
                  _menuItem('delete', Icons.delete_outline, 'Gebäude löschen'),
                ],
                onSelected: (action) {
                  if (action == 'add') _editShelf(id);
                  if (action == 'bulk') _bulkCreate(building);
                  if (action == 'edit') _editBuilding(building);
                  if (action == 'delete') {
                    _delete('Gebäude', '/api/locations/$encodedId');
                  }
                },
              )
            : null,
        children: [
          const Divider(height: 1),
          if (address.isEmpty && _canWrite)
            ListTile(
              leading: Icon(Icons.warning_amber_outlined,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Adresse ergänzen'),
              subtitle: const Text(
                  'Dieses Gebäude wurde aus einer älteren Lagerstruktur übernommen.'),
              trailing: TextButton(
                onPressed: () => _editBuilding(building),
                child: const Text('Bearbeiten'),
              ),
            ),
          if (shelves.isEmpty)
            _emptyBranch('Keine Regale angelegt.', () => _editShelf(id))
          else
            ...shelves.map(_shelfTile),
        ],
      ),
    );
  }

  Widget _metric(IconData icon, int value, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Text('$value', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 5),
          Text(label),
        ]),
      );

  Widget _overview() => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gebäude und Lagerstruktur',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              const Text(
                  'Gebäude → Regal → Ebene → Lagerplatz. Artikel können weiterhin auch nur einem Gebäude zugeordnet werden.'),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _metric(Icons.apartment_outlined, _buildings.length, 'Gebäude'),
                _metric(Icons.shelves, _shelves.length, 'Regale'),
                _metric(Icons.layers_outlined, _levels.length, 'Ebenen'),
                _metric(Icons.inventory_2_outlined, _positions.length,
                    'Lagerplätze'),
              ]),
              const SizedBox(height: 16),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  labelText: 'Lagerstruktur durchsuchen',
                  hintText: 'Gebäude, Adresse, Regal, Ebene oder Lagerplatz',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Suche leeren',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.clear),
                        ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _emptyState() {
    final filtering = _query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(filtering ? Icons.search_off : Icons.apartment_outlined, size: 52),
        const SizedBox(height: 12),
        Text(filtering
            ? 'Keine passende Lagerstruktur gefunden.'
            : 'Noch keine Gebäude vorhanden.'),
        const SizedBox(height: 8),
        if (filtering)
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() => _query = '');
            },
            child: const Text('Suche zurücksetzen'),
          )
        else if (_canWrite)
          FilledButton.icon(
            onPressed: _editBuilding,
            icon: const Icon(Icons.add_business_outlined),
            label: const Text('Erstes Gebäude anlegen'),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleBuildings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lagerorte'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: 'Aktualisieren',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _canWrite && !_loading && _loadError == null
          ? FloatingActionButton.extended(
              onPressed: _editBuilding,
              icon: const Icon(Icons.add_business_outlined),
              label: const Text('Neues Gebäude'),
            )
          : null,
      body: _loading && _buildings.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null && _buildings.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.cloud_off_outlined,
                        size: 52, color: Theme.of(context).colorScheme.error),
                    const SizedBox(height: 12),
                    Text(_loadError!),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Erneut versuchen'),
                    ),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                    itemCount: visible.isEmpty ? 3 : visible.length + 2,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: _overview(),
                          ),
                        );
                      }
                      if (index == 1) return const SizedBox(height: 8);
                      final buildingIndex = index - 2;
                      if (visible.isEmpty) return _emptyState();
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1100),
                          child: _buildingCard(visible[buildingIndex]),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
