import 'dart:async';

import 'package:flutter/material.dart';

import '../services/authenticated_api_client.dart';
import '../services/document_output_service.dart';
import '../services/download_service.dart';

typedef VehicleRequest =
    Future<dynamic> Function(String path, {String method, Object? body});

const _vehicleKinds = <String>[
  'Kraftfahrzeug',
  'Boot',
  'Anhänger',
  'Sonstige Fahrzeugart',
];
const _defaultVehicleUsages = <String>['Einsatzfahrt', 'sonstige Verwendung'];

String _vehicleKindOf(Map<String, dynamic> vehicle) {
  final stored = vehicle['vehicleKind']?.toString();
  if (_vehicleKinds.contains(stored)) return stored!;
  final legacyType = vehicle['type']?.toString();
  if (const ['Kraftfahrzeug', 'Boot', 'Anhänger'].contains(legacyType)) {
    return legacyType!;
  }
  if (const ['Einsatzfahrzeug', 'Vereinsfahrzeug'].contains(legacyType)) {
    return 'Kraftfahrzeug';
  }
  return 'Sonstige Fahrzeugart';
}

String _vehicleUsageOf(Map<String, dynamic> vehicle) {
  final stored = vehicle['usage']?.toString().trim() ?? '';
  if (stored.isNotEmpty) return stored;
  return vehicle['type'] == 'Einsatzfahrzeug'
      ? 'Einsatzfahrt'
      : 'sonstige Verwendung';
}

/// Text value without the literal "null" that `toString()` produces.
String _text(dynamic value) => value?.toString().trim() ?? '';

String _parkingOf(Map<String, dynamic> vehicle) {
  final details = _text(vehicle['parkingDetails']);
  if (details.isNotEmpty) return details;
  return [
    _text(vehicle['parkingLocationName']),
    _text(vehicle['parkingSpaceName']),
  ].where((entry) => entry.isNotEmpty).join(' / ');
}

String _vehicleDisplayName(Map<String, dynamic> vehicle) {
  for (final key in ['registrationNumber', 'radioCallName', 'type']) {
    final value = vehicle[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return 'Fahrzeug';
}

class VehiclesPage extends StatefulWidget {
  const VehiclesPage({required this.token, this.request, super.key});

  final String token;
  final VehicleRequest? request;

  @override
  State<VehiclesPage> createState() => _VehiclesPageState();
}

class _VehiclesPageState extends State<VehiclesPage> {
  late final AuthenticatedApiClient api;
  List<Map<String, dynamic>> vehicles = [];
  Map<String, dynamic> options = {};
  Set<String> permissions = {};
  String? activeUnitId;
  String? currentUserId;
  bool loading = true;
  bool showArchived = false;
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
      _request('/api/vehicles?includeArchived=$showArchived', quiet: true),
      _request('/api/vehicles/options', quiet: true),
    ]);
    if (!mounted) return;
    final me = results[0] is Map
        ? Map<String, dynamic>.from(results[0] as Map)
        : <String, dynamic>{};
    final user = Map<String, dynamic>.from(me['user'] as Map? ?? const {});
    final contextData = Map<String, dynamic>.from(
      me['context'] as Map? ?? const {},
    );
    final unit = Map<String, dynamic>.from(
      contextData['unit'] as Map? ?? const {},
    );
    setState(() {
      permissions = (user['permissions'] as List? ?? const [])
          .map((entry) => entry.toString())
          .toSet();
      activeUnitId = unit['id']?.toString();
      currentUserId = user['id']?.toString();
      vehicles = results[1] is List
          ? (results[1] as List)
                .map((entry) => Map<String, dynamic>.from(entry as Map))
                .toList()
          : [];
      options = results[2] is Map
          ? Map<String, dynamic>.from(results[2] as Map)
          : {};
      loading = false;
    });
  }

  List<Map<String, dynamic>> get filteredVehicles {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return vehicles;
    return vehicles.where((vehicle) {
      return [
        vehicle['registrationNumber'],
        vehicle['vin'],
        vehicle['radioCallName'],
        vehicle['manufacturer'],
        vehicle['model'],
        vehicle['vehicleKind'],
        vehicle['usage'],
        vehicle['type'],
        vehicle['ownerUnitName'],
      ].any((entry) => _text(entry).toLowerCase().contains(needle));
    }).toList();
  }

  Future<void> _editVehicle([Map<String, dynamic>? vehicle]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VehicleFormDialog(options: options, vehicle: vehicle),
    );
    if (result == null) return;
    final response = await _request(
      vehicle == null ? '/api/vehicles' : '/api/vehicles/${vehicle['id']}',
      method: vehicle == null ? 'POST' : 'PUT',
      body: result,
    );
    if (response != null) {
      _message(
        vehicle == null ? 'Fahrzeug angelegt.' : 'Fahrzeug gespeichert.',
      );
      await _load();
    }
  }

  Future<void> _openVehicle(Map<String, dynamic> vehicle) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _VehicleDetailDialog(
        vehicleId: vehicle['id'].toString(),
        request: _request,
        permissions: permissions,
        activeUnitId: activeUnitId,
        currentUserId: currentUserId,
        options: options,
        onEdit: _editVehicle,
      ),
    );
    await _load();
  }

  Future<void> _settings() async {
    final settings = Map<String, dynamic>.from(
      options['organizationSettings'] as Map? ?? const {},
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VehicleSettingsDialog(
        settings: settings,
        canManageUsages: can('organizations.write'),
        canManageVehicleTypes: can('vehicles.write'),
      ),
    );
    if (result == null) return;
    final response = await _request(
      '/api/vehicle-settings',
      method: 'PUT',
      body: result,
    );
    if (response != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fahrzeugverwaltung'),
        actions: [
          if (can('organizations.write') || can('vehicles.write'))
            IconButton(
              onPressed: _settings,
              tooltip: 'Fahrzeug-Einstellungen',
              icon: const Icon(Icons.settings_outlined),
            ),
          IconButton(
            onPressed: _load,
            tooltip: 'Aktualisieren',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: can('vehicles.write')
          ? FloatingActionButton.extended(
              onPressed: () => _editVehicle(),
              icon: const Icon(Icons.add),
              label: const Text('Fahrzeug'),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SizedBox(
                                width: 360,
                                child: TextField(
                                  decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    labelText: 'Fahrzeuge durchsuchen',
                                  ),
                                  onChanged: (value) =>
                                      setState(() => query = value),
                                ),
                              ),
                              FilterChip(
                                selected: showArchived,
                                avatar: const Icon(Icons.archive_outlined),
                                label: const Text('Außer Dienst'),
                                onSelected: (value) async {
                                  showArchived = value;
                                  await _load();
                                },
                              ),
                              Chip(
                                avatar: const Icon(Icons.directions_car),
                                label: Text(
                                  '${filteredVehicles.length} Fahrzeuge',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (filteredVehicles.isEmpty)
                            const Card(
                              child: Padding(
                                padding: EdgeInsets.all(32),
                                child: Text(
                                  'Keine Fahrzeuge gefunden.',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          else
                            ...filteredVehicles.map(_vehicleCard),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _vehicleCard(Map<String, dynamic> vehicle) {
    final safety = Map<String, dynamic>.from(
      vehicle['safetyStatus'] as Map? ?? const {},
    );
    final blocked = safety['blocked'] == true;
    final subtitle = [
      if (_text(vehicle['radioCallName']).isNotEmpty) vehicle['radioCallName'],
      [
        _vehicleKindOf(vehicle),
        _vehicleUsageOf(vehicle),
        _text(vehicle['type']),
      ].where((entry) => entry.isNotEmpty).join(' · '),
      if ('${_text(vehicle['manufacturer'])} ${_text(vehicle['model'])}'
          .trim()
          .isNotEmpty)
        '${_text(vehicle['manufacturer'])} ${_text(vehicle['model'])}'.trim(),
      'Stellplatz: ${_parkingOf(vehicle).isEmpty ? '-' : _parkingOf(vehicle)}',
      if (_text(vehicle['status']).isNotEmpty &&
          vehicle['status'] != 'Verfügbar')
        'Status: ${vehicle['status']}',
      if (vehicle['unitId'] != activeUnitId)
        'Freigegeben durch ${vehicle['ownerUnitName'] ?? 'andere Gliederung'}',
    ].join('\n');
    return Card(
      child: ListTile(
        minVerticalPadding: 12,
        leading: CircleAvatar(
          backgroundColor: blocked
              ? Theme.of(context).colorScheme.errorContainer
              : Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            _vehicleKindOf(vehicle) == 'Boot'
                ? Icons.directions_boat_outlined
                : _vehicleKindOf(vehicle) == 'Anhänger'
                ? Icons.rv_hookup_outlined
                : Icons.directions_car_outlined,
          ),
        ),
        title: Text(
          _vehicleDisplayName(vehicle),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        isThreeLine: true,
        trailing: blocked
            ? const Tooltip(
                message: 'Fahrzeug ist gesperrt',
                child: Icon(Icons.warning_amber, color: Colors.red),
              )
            : const Icon(Icons.chevron_right),
        onTap: () => _openVehicle(vehicle),
      ),
    );
  }
}

class _VehicleSettingsDialog extends StatefulWidget {
  const _VehicleSettingsDialog({
    required this.settings,
    required this.canManageUsages,
    required this.canManageVehicleTypes,
  });

  final Map<String, dynamic> settings;
  final bool canManageUsages;
  final bool canManageVehicleTypes;

  @override
  State<_VehicleSettingsDialog> createState() => _VehicleSettingsDialogState();
}

class _VehicleSettingsDialogState extends State<_VehicleSettingsDialog> {
  late bool approvalRequired =
      widget.settings['primaryVehicleApprovalRequired'] == true;
  late final List<String> usages = {
    ..._defaultVehicleUsages,
    ...(widget.settings['usages'] as List? ?? const []).map(
      (entry) => entry.toString(),
    ),
  }.toList();
  late final Map<String, List<String>> typesByUsage = {
    for (final usage in usages)
      usage:
          ((widget.settings['vehicleTypesByUsage'] as Map?)?[usage] as List? ??
                  const [])
              .map((entry) => entry.toString())
              .toSet()
              .toList(),
  };
  late String selectedUsage = usages.first;
  final usageController = TextEditingController();
  final typeController = TextEditingController();

  @override
  void dispose() {
    usageController.dispose();
    typeController.dispose();
    super.dispose();
  }

  void _addUsage() {
    final value = usageController.text.trim();
    if (value.isEmpty || usages.contains(value)) return;
    setState(() {
      usages.add(value);
      typesByUsage[value] = ['Sonstiger Fahrzeugtyp'];
      selectedUsage = value;
      usageController.clear();
    });
  }

  void _removeUsage(String usage) {
    if (_defaultVehicleUsages.contains(usage)) return;
    setState(() {
      usages.remove(usage);
      typesByUsage.remove(usage);
      if (selectedUsage == usage) selectedUsage = usages.first;
    });
  }

  void _addType() {
    final value = typeController.text.trim();
    final values = typesByUsage[selectedUsage] ??= [];
    if (value.isEmpty || values.contains(value)) return;
    setState(() {
      values.add(value);
      typeController.clear();
    });
  }

  void _removeType(String type) {
    final values = typesByUsage[selectedUsage] ??= [];
    if (values.length <= 1) return;
    setState(() => values.remove(type));
  }

  @override
  Widget build(BuildContext context) {
    final activeTypes = typesByUsage[selectedUsage] ?? const <String>[];
    return AlertDialog(
      title: const Text('Fahrzeug-Einstellungen'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.canManageUsages)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: approvalRequired,
                  onChanged: (value) =>
                      setState(() => approvalRequired = value),
                  title: const Text('TLE-Zweitfreigabe'),
                  subtitle: const Text(
                    'Reservierungen primär ausrückender Fahrzeuge benötigen '
                    'zusätzlich die Zustimmung des Technischen Leiters Einsatz.',
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Verwendungen',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: usages
                    .map(
                      (usage) => InputChip(
                        label: Text(usage),
                        onDeleted:
                            widget.canManageUsages &&
                                !_defaultVehicleUsages.contains(usage)
                            ? () => _removeUsage(usage)
                            : null,
                      ),
                    )
                    .toList(),
              ),
              if (widget.canManageUsages) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: usageController,
                        decoration: const InputDecoration(
                          labelText: 'Verwendung ergänzen',
                        ),
                        onSubmitted: (_) => _addUsage(),
                      ),
                    ),
                    IconButton(
                      onPressed: _addUsage,
                      tooltip: 'Verwendung hinzufügen',
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Fahrzeugtypen nach Verwendung',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: ValueKey('settings-usage-$selectedUsage-${usages.length}'),
                isExpanded: true,
                initialValue: selectedUsage,
                decoration: const InputDecoration(labelText: 'Verwendung'),
                items: usages
                    .map(
                      (usage) =>
                          DropdownMenuItem(value: usage, child: Text(usage)),
                    )
                    .toList(),
                onChanged: (value) =>
                    setState(() => selectedUsage = value ?? selectedUsage),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: activeTypes
                    .map(
                      (type) => InputChip(
                        label: Text(type),
                        onDeleted:
                            widget.canManageVehicleTypes &&
                                activeTypes.length > 1
                            ? () => _removeType(type)
                            : null,
                      ),
                    )
                    .toList(),
              ),
              if (widget.canManageVehicleTypes) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: typeController,
                        decoration: const InputDecoration(
                          labelText: 'Fahrzeugtyp ergänzen',
                        ),
                        onSubmitted: (_) => _addType(),
                      ),
                    ),
                    IconButton(
                      onPressed: _addType,
                      tooltip: 'Fahrzeugtyp hinzufügen',
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            final result = <String, dynamic>{};
            if (widget.canManageUsages) {
              result['primaryVehicleApprovalRequired'] = approvalRequired;
              result['usages'] = usages;
            }
            if (widget.canManageVehicleTypes) {
              result['vehicleTypesByUsage'] = {
                for (final usage in usages) usage: typesByUsage[usage] ?? [],
              };
            }
            Navigator.pop(context, result);
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class _VehicleFormDialog extends StatefulWidget {
  const _VehicleFormDialog({required this.options, this.vehicle});

  final Map<String, dynamic> options;
  final Map<String, dynamic>? vehicle;

  @override
  State<_VehicleFormDialog> createState() => _VehicleFormDialogState();
}

class _VehicleFormDialogState extends State<_VehicleFormDialog> {
  final formKey = GlobalKey<FormState>();
  late final registration = TextEditingController(
    text: widget.vehicle?['registrationNumber']?.toString(),
  );
  late final vin = TextEditingController(
    text: widget.vehicle?['vin']?.toString(),
  );
  late final radio = TextEditingController(
    text: widget.vehicle?['radioCallName']?.toString(),
  );
  late final year = TextEditingController(
    text: widget.vehicle?['year']?.toString(),
  );
  late final manufacturer = TextEditingController(
    text: widget.vehicle?['manufacturer']?.toString(),
  );
  late final model = TextEditingController(
    text: widget.vehicle?['model']?.toString(),
  );
  late final mileage = TextEditingController(
    text: widget.vehicle?['mileage']?.toString(),
  );
  late final hours = TextEditingController(
    text: widget.vehicle?['operatingHours']?.toString(),
  );
  late final storagePositions = TextEditingController(
    text: (widget.vehicle?['storagePositions'] as List? ?? const []).join('\n'),
  );
  late final parkingDetails = TextEditingController(
    text: widget.vehicle?['parkingDetails']?.toString(),
  );
  late final notes = TextEditingController(
    text: widget.vehicle?['notes']?.toString(),
  );
  late String vehicleKind = widget.vehicle == null
      ? 'Kraftfahrzeug'
      : _vehicleKindOf(widget.vehicle!);
  late String usage = widget.vehicle == null
      ? 'Einsatzfahrt'
      : _vehicleUsageOf(widget.vehicle!);
  late String type = widget.vehicle?['type']?.toString() ?? 'Einsatzfahrzeug';
  late String status = widget.vehicle?['status']?.toString() ?? 'Verfügbar';
  late String? parkingSpaceId = widget.vehicle?['parkingSpaceId']?.toString();
  late String? parkingLocationId = widget.vehicle?['parkingLocationId']
      ?.toString();
  late bool primary = widget.vehicle?['primaryResponseVehicle'] == true;

  List<String> get availableUsages {
    final configured = (widget.options['usages'] as List? ?? const [])
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList();
    return configured.isEmpty ? [..._defaultVehicleUsages] : configured;
  }

  List<String> availableTypes(String selectedUsage) {
    final configured = widget.options['vehicleTypesByUsage'] as Map?;
    final values = (configured?[selectedUsage] as List? ?? const [])
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList();
    if (values.isNotEmpty) return values;
    final legacy = (widget.options['types'] as List? ?? const [])
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList();
    return legacy.isEmpty ? ['Sonstiger Fahrzeugtyp'] : legacy;
  }

  bool get identifiersRequired =>
      vehicleKind == 'Kraftfahrzeug' || vehicleKind == 'Anhänger';

  @override
  void dispose() {
    for (final controller in [
      registration,
      vin,
      radio,
      year,
      manufacturer,
      model,
      mileage,
      hours,
      parkingDetails,
      storagePositions,
      notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kinds = (widget.options['vehicleKinds'] as List? ?? _vehicleKinds)
        .map((entry) => entry.toString())
        .toList();
    final usages = availableUsages;
    if (!kinds.contains(vehicleKind)) vehicleKind = kinds.first;
    if (!usages.contains(usage)) usage = usages.first;
    final types = availableTypes(usage);
    if (!types.contains(type)) type = types.first;
    final statuses = (widget.options['statuses'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toList();
    final parking = (widget.options['parkingLocations'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    return AlertDialog(
      title: Text(
        widget.vehicle == null ? 'Fahrzeug anlegen' : 'Fahrzeug bearbeiten',
      ),
      content: SizedBox(
        width: 720,
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _field(
                  registration,
                  identifiersRequired ? 'Kennzeichen *' : 'Kennzeichen',
                  required: identifiersRequired,
                ),
                _field(
                  vin,
                  identifiersRequired
                      ? 'Fahrgestellnummer *'
                      : 'Fahrgestellnummer',
                  required: identifiersRequired,
                ),
                _field(radio, 'Funkrufname'),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('vehicle-kind'),
                    isExpanded: true,
                    initialValue: vehicleKind,
                    decoration: const InputDecoration(labelText: 'Fahrzeugart'),
                    items: kinds
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => vehicleKind = value ?? vehicleKind),
                  ),
                ),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String>(
                    key: const ValueKey('vehicle-usage'),
                    isExpanded: true,
                    initialValue: usage,
                    decoration: const InputDecoration(labelText: 'Verwendung'),
                    items: usages
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        usage = value;
                        type = availableTypes(value).first;
                      });
                    },
                  ),
                ),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('vehicle-type-$usage'),
                    isExpanded: true,
                    initialValue: type,
                    decoration: const InputDecoration(labelText: 'Fahrzeugtyp'),
                    items: types
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => type = value ?? type,
                  ),
                ),
                _field(manufacturer, 'Hersteller'),
                _field(model, 'Modell'),
                _field(year, 'Baujahr', number: true),
                _field(mileage, 'Kilometerstand', number: true),
                _field(hours, 'Betriebsstunden', number: true),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String?>(
                    initialValue: parkingLocationId,
                    decoration: const InputDecoration(
                      labelText: 'Gebäude / Fahrzeugstandort',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Kein Gebäude'),
                      ),
                      ...parking.map(
                        (entry) => DropdownMenuItem<String?>(
                          value: entry['id'].toString(),
                          child: Text(
                            entry['path']?.toString() ??
                                entry['name'].toString(),
                          ),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      parkingLocationId = value;
                      parkingSpaceId = null;
                    }),
                  ),
                ),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String?>(
                    key: ValueKey('parking-space-$parkingLocationId'),
                    initialValue: parkingSpaceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Fahrzeugstellplatz',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Kein bestimmter Stellplatz'),
                      ),
                      for (final building in parking.where(
                        (entry) => entry['id'] == parkingLocationId,
                      ))
                        for (final space
                            in (building['parkingSpaces'] as List? ?? const []))
                          DropdownMenuItem<String?>(
                            value: space['id'].toString(),
                            child: Text(space['name'].toString()),
                          ),
                    ],
                    onChanged: parkingLocationId == null
                        ? null
                        : (value) => setState(() => parkingSpaceId = value),
                  ),
                ),
                _field(parkingDetails, 'Stellplatz-Details'),
                TextFormField(
                  controller: storagePositions,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Lagermöglichkeiten im Fahrzeug',
                    helperText: 'Ein Fach oder Lagerplatz pro Zeile.',
                  ),
                ),
                SizedBox(
                  width: 330,
                  child: DropdownButtonFormField<String>(
                    initialValue: statuses.contains(status)
                        ? status
                        : statuses.firstOrNull,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: statuses
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => status = value ?? status,
                  ),
                ),
                SizedBox(
                  width: 330,
                  child: SwitchListTile(
                    value: primary,
                    onChanged: (value) => setState(() => primary = value),
                    title: const Text('Primär ausrückendes Fahrzeug'),
                    subtitle: const Text(
                      'Kann eine zusätzliche TLE-Freigabe erfordern.',
                    ),
                  ),
                ),
                SizedBox(
                  width: 672,
                  child: TextFormField(
                    controller: notes,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(labelText: 'Notizen'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton.icon(
          onPressed: () {
            if (formKey.currentState?.validate() != true) return;
            Navigator.pop(context, {
              'registrationNumber': registration.text,
              'vin': vin.text,
              'radioCallName': radio.text,
              'vehicleKind': vehicleKind,
              'usage': usage,
              'type': type,
              'manufacturer': manufacturer.text,
              'model': model.text,
              'year': year.text,
              'mileage': mileage.text,
              'operatingHours': hours.text,
              'parkingLocationId': parkingLocationId,
              'parkingSpaceId': parkingSpaceId,
              'parkingDetails': parkingDetails.text,
              'storagePositions': storagePositions.text
                  .split('\n')
                  .map((e) => e.trim())
                  .where((e) => e.isNotEmpty)
                  .toList(),
              'status': status,
              'primaryResponseVehicle': primary,
              'notes': notes.text,
            });
          },
          icon: const Icon(Icons.save_outlined),
          label: const Text('Speichern'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool number = false,
  }) {
    return SizedBox(
      width: 330,
      child: TextFormField(
        controller: controller,
        keyboardType: number ? TextInputType.number : null,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (value) => value?.trim().isEmpty != false ? 'Pflichtfeld' : null
            : null,
      ),
    );
  }
}

class _VehicleDetailDialog extends StatefulWidget {
  const _VehicleDetailDialog({
    required this.vehicleId,
    required this.request,
    required this.permissions,
    required this.activeUnitId,
    required this.options,
    required this.onEdit,
    this.currentUserId,
  });

  final String vehicleId;
  final Future<dynamic> Function(
    String path, {
    String method,
    Object? body,
    bool quiet,
  })
  request;
  final Set<String> permissions;
  final String? activeUnitId;
  final String? currentUserId;
  final Map<String, dynamic> options;
  final Future<void> Function([Map<String, dynamic>? vehicle]) onEdit;

  @override
  State<_VehicleDetailDialog> createState() => _VehicleDetailDialogState();
}

class _VehicleDetailDialogState extends State<_VehicleDetailDialog> {
  Map<String, dynamic>? vehicle;
  bool loading = true;

  bool can(String permission) => widget.permissions.contains(permission);
  bool get ownsVehicle => vehicle?['unitId']?.toString() == widget.activeUnitId;
  bool get mayOverride =>
      ownsVehicle &&
      (can('vehicle_maintenance.manage') || can('vehicle_reservations.manage'));
  Map<String, dynamic> get safety =>
      Map<String, dynamic>.from(vehicle?['safetyStatus'] as Map? ?? const {});

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final result = await widget.request('/api/vehicles/${widget.vehicleId}');
    if (!mounted) return;
    setState(() {
      vehicle = result is Map ? Map<String, dynamic>.from(result) : null;
      loading = false;
    });
  }

  Future<bool> _mutate(
    String path, {
    String method = 'POST',
    Object? body,
  }) async {
    final result = await widget.request(path, method: method, body: body);
    if (result != null) await _load();
    return result != null;
  }

  Future<void> _reserve() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ReservationDialog(
        allowOverride: mayOverride && can('vehicle_maintenance.manage'),
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/vehicle-reservations',
      body: {'vehicleId': widget.vehicleId, ...values},
    );
  }

  Future<void> _maintenance() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _MaintenanceDialog(),
    );
    if (values == null) return;
    await _mutate(
      '/api/vehicles/${widget.vehicleId}/maintenance',
      body: values,
    );
  }

  Future<void> _loadMaterial() async {
    final materials = await widget.request(
      '/api/vehicles/${widget.vehicleId}/load-materials',
    );
    if (materials is! List || !mounted) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoadMaterialDialog(
        positions: (vehicle?['storagePositions'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        materials: materials
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(),
      ),
    );
    if (values == null) return;
    await _mutate('/api/vehicles/${widget.vehicleId}/load', body: values);
  }

  Future<void> _requestLoad() async {
    final materials = await widget.request(
      '/api/vehicles/${widget.vehicleId}/load-materials',
    );
    if (materials is! List || !mounted) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoadMaterialDialog(
        title: 'Materialbuchung anfragen',
        submitLabel: 'Anfragen',
        hint:
            'Die besitzende Gliederung muss die Buchung freigeben. Erst danach '
            'wird das Material auf das Fahrzeug gebucht.',
        positions: (vehicle?['storagePositions'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        materials: materials
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(),
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/vehicles/${widget.vehicleId}/load-requests',
      body: values,
    );
  }

  Future<void> _createLoadList() async {
    final assignments = (vehicle?['loadAssignments'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _LoadListDialog(assignments: assignments),
    );
    if (values == null) return;
    await _mutate('/api/vehicles/${widget.vehicleId}/load-lists', body: values);
  }

  Future<void> _print({required bool save, String? listId}) async {
    final result = await widget.request(
      listId == null
          ? '/api/vehicles/${widget.vehicleId}/load-list/print'
          : '/api/vehicles/${widget.vehicleId}/load-lists/$listId/print',
    );
    if (result is! Map) return;
    try {
      if (save) {
        await DocumentOutputService.instance.savePayload(result);
      } else {
        await DocumentOutputService.instance.printPdfPayload(
          result,
          fallbackFileName: 'beladungsliste.pdf',
        );
      }
    } on DownloadException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _share() async {
    final candidates = await widget.request('/api/vehicles/sharing-candidates');
    if (candidates is! List || !mounted || vehicle == null) return;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _SharingDialog(
        candidates: candidates
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(),
        viewIds: (vehicle!['viewAllowedUnitIds'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toSet(),
        reservationIds:
            (vehicle!['reservationAllowedUnitIds'] as List? ?? const [])
                .map((entry) => entry.toString())
                .toSet(),
        loadIds: (vehicle!['loadAllowedUnitIds'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toSet(),
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/vehicles/${widget.vehicleId}/sharing',
      method: 'PUT',
      body: values,
    );
  }

  Future<void> _reportDefect({String? description}) async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _VehicleDefectDialog(description: description),
    );
    if (values == null) return;
    await _mutate(
      '/api/defects',
      body: {'entityType': 'Vehicle', 'entityId': widget.vehicleId, ...values},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            tooltip: 'Schließen',
          ),
          title: Text(
            vehicle == null ? 'Fahrzeug' : _vehicleDisplayName(vehicle!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (vehicle != null && ownsVehicle && can('vehicles.share'))
              IconButton(
                onPressed: _share,
                tooltip: 'Für Gliederungen freigeben',
                icon: const Icon(Icons.share_outlined),
              ),
            if (vehicle != null && ownsVehicle && can('vehicles.write'))
              IconButton(
                onPressed: () async {
                  await widget.onEdit(vehicle);
                  await _load();
                },
                tooltip: 'Fahrzeug bearbeiten',
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : vehicle == null
            ? const Center(child: Text('Fahrzeug konnte nicht geladen werden.'))
            : _body(),
      ),
    );
  }

  Widget _body() {
    final value = vehicle!;
    final safety = this.safety;
    final reservations = (value['reservations'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final maintenance = (value['maintenance'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final loads = (value['loadAssignments'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final lists = (value['loadLists'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final loadRequests = (value['loadRequests'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final openLoadRequests = loadRequests
        .where((entry) => entry['status'] == 'Ausstehend')
        .toList();
    final decidedLoadRequests = loadRequests
        .where((entry) => entry['status'] != 'Ausstehend')
        .take(10)
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (safety['blocked'] == true)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber),
                      title: const Text('Fahrzeug ist gesperrt'),
                      subtitle: Text(
                        (safety['reasons'] as List? ?? const []).join('\n'),
                      ),
                    ),
                  ),
                _section('Stammdaten', Icons.directions_car_outlined, [
                  _facts({
                    'Kennzeichen': value['registrationNumber'],
                    'Funkrufname': value['radioCallName'],
                    'Fahrgestellnummer': value['vin'],
                    'Fahrzeugart': _vehicleKindOf(value),
                    'Verwendung': _vehicleUsageOf(value),
                    'Fahrzeugtyp': value['type'],
                    'Hersteller/Modell':
                        '${_text(value['manufacturer'])} ${_text(value['model'])}',
                    'Baujahr': value['year'],
                    'Stellplatz': _parkingOf(value),
                    'Zugewiesener Fahrzeugstellplatz':
                        value['parkingSpaceName'] ?? 'Keiner',
                    'Kilometerstand': value['mileage'],
                    'Betriebsstunden': value['operatingHours'],
                    'Status': value['status'],
                    'Besitzende Gliederung': value['ownerUnitName'],
                  }),
                ]),
                _section('Reservierungen', Icons.event_available_outlined, [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (can('vehicle_reservations.create') &&
                          value['archivedAt'] == null)
                        FilledButton.icon(
                          onPressed: _reserve,
                          icon: const Icon(Icons.add),
                          label: const Text('Reservieren'),
                        ),
                    ],
                  ),
                  if (reservations.isEmpty)
                    const Text('Keine Reservierungen vorhanden.')
                  else
                    ...reservations.map(_reservationTile),
                ]),
                _section('Wartung', Icons.build_outlined, [
                  if (ownsVehicle && can('vehicle_maintenance.manage'))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _maintenance,
                        icon: const Icon(Icons.add),
                        label: const Text('Wartung planen'),
                      ),
                    ),
                  if (maintenance.isEmpty)
                    const Text('Keine Wartungen vorhanden.')
                  else
                    ...maintenance.map(_maintenanceTile),
                ]),
                if (can('vehicles.load.read'))
                  _section('Beladung', Icons.inventory_2_outlined, [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (ownsVehicle &&
                            can('vehicles.load.manage') &&
                            value['archivedAt'] == null)
                          FilledButton.tonalIcon(
                            onPressed: _loadMaterial,
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text('Inventar buchen'),
                          ),
                        if (!ownsVehicle &&
                            value['materialLoadAllowed'] == true &&
                            can('vehicles.load.manage'))
                          FilledButton.tonalIcon(
                            onPressed: _requestLoad,
                            icon: const Icon(Icons.add_box_outlined),
                            label: const Text('Material anfragen'),
                          ),
                        if (ownsVehicle && can('vehicles.load.manage'))
                          OutlinedButton.icon(
                            onPressed: loads.isEmpty ? null : _createLoadList,
                            icon: const Icon(Icons.playlist_add_check),
                            label: const Text('Soll-Liste erstellen'),
                          ),
                        if (can('vehicles.print')) ...[
                          OutlinedButton.icon(
                            onPressed:
                                lists.any((entry) => entry['status'] == 'Aktiv')
                                ? () => _print(save: false)
                                : null,
                            icon: const Icon(Icons.print_outlined),
                            label: const Text('Drucken'),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                lists.any((entry) => entry['status'] == 'Aktiv')
                                ? () => _print(save: true)
                                : null,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('PDF'),
                          ),
                        ],
                      ],
                    ),
                    if (loads.isEmpty)
                      const Text('Kein Inventar auf dieses Fahrzeug gebucht.')
                    else
                      ...loads.map(_loadTile),
                    if (openLoadRequests.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        ownsVehicle
                            ? 'Offene Buchungsanfragen anderer Gliederungen'
                            : 'Offene Buchungsanfragen',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      ...openLoadRequests.map(_loadRequestTile),
                    ],
                    if (decidedLoadRequests.isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Entschiedene Buchungsanfragen'),
                        children: decidedLoadRequests
                            .map(_loadRequestTile)
                            .toList(),
                      ),
                    if (lists.isNotEmpty) ...[
                      Text(
                        'Beladungslisten',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      ...lists.map(_loadListTile),
                    ],
                  ]),
                _section('Mängel', Icons.report_problem_outlined, [
                  if (can('defects.report'))
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _reportDefect,
                        icon: const Icon(Icons.report_outlined),
                        label: const Text('Mangel melden'),
                      ),
                    ),
                  ...((value['defects'] as List? ?? const []).map((entry) {
                    final defect = Map<String, dynamic>.from(entry as Map);
                    return ListTile(
                      leading: const Icon(Icons.warning_amber),
                      title: Text(
                        '${defect['defectNumber']} · ${defect['title']}',
                      ),
                      subtitle: Text(
                        '${defect['priority']} · ${defect['status']}',
                      ),
                    );
                  })),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title, IconData icon, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...children.map(
              (child) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _facts(Map<String, dynamic> values) {
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: values.entries
          .map(
            (entry) => SizedBox(
              width: 240,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Text(
                    entry.value?.toString().trim().isNotEmpty == true
                        ? entry.value.toString()
                        : '-',
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _loadListTile(Map<String, dynamic> entry) {
    final id = entry['id'].toString();
    final items = entry['items'] as List? ?? const [];
    return ListTile(
      dense: true,
      leading: Icon(
        entry['status'] == 'Aktiv'
            ? Icons.check_circle_outline
            : entry['status'] == 'Entwurf'
            ? Icons.edit_note
            : Icons.history,
      ),
      title: Text('v${entry['version']} · ${_text(entry['name'])}'),
      subtitle: Text('${entry['status']} · ${items.length} Positionen'),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (ownsVehicle &&
              can('vehicles.load.manage') &&
              entry['status'] != 'Aktiv')
            TextButton(
              onPressed: () => _mutate(
                '/api/vehicles/${widget.vehicleId}/load-lists/$id/activate',
              ),
              child: const Text('Aktivieren'),
            ),
          if (can('vehicles.print'))
            IconButton(
              tooltip: 'Diese Version als PDF',
              onPressed: () => _print(save: true, listId: id),
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
        ],
      ),
    );
  }

  Widget _reservationTile(Map<String, dynamic> entry) {
    final status = entry['status']?.toString();
    final manages = ownsVehicle && can('vehicle_reservations.manage');
    final ownRequest =
        widget.currentUserId != null &&
        entry['requesterUserId']?.toString() == widget.currentUserId;
    final open = !const [
      'Abgeschlossen',
      'Abgelehnt',
      'Storniert',
      'Ausgegeben',
    ].contains(status);
    final actions = <PopupMenuEntry<String>>[
      if (manages && entry['vehicleApprovedAt'] == null && open)
        const PopupMenuItem(
          value: 'approve',
          child: Text('Fahrzeug freigeben'),
        ),
      if (can('vehicle_reservations.operational_approve') &&
          entry['operationalApprovalRequired'] == true &&
          entry['operationalApprovedAt'] == null &&
          open)
        const PopupMenuItem(value: 'tle', child: Text('TLE-Freigabe erteilen')),
      if (manages && open)
        const PopupMenuItem(value: 'reject', child: Text('Ablehnen')),
      if (!manages &&
          can('vehicle_reservations.operational_approve') &&
          entry['operationalApprovalRequired'] == true &&
          open)
        const PopupMenuItem(value: 'tle-reject', child: Text('TLE: Ablehnen')),
      if (manages && status == 'Freigegeben')
        const PopupMenuItem(value: 'issue', child: Text('Übergeben')),
      if (manages && status == 'Ausgegeben')
        const PopupMenuItem(value: 'return', child: Text('Zurücknehmen')),
      if ((ownRequest || manages) && open)
        const PopupMenuItem(value: 'cancel', child: Text('Stornieren')),
    ];
    final details = [
      _text(entry['purpose']),
      _text(entry['destination']),
      _text(entry['requesterName']),
    ].where((value) => value.isNotEmpty).join(' · ');
    final reason = _text(entry['decisionReason']);
    return Card.outlined(
      child: ListTile(
        leading: const Icon(Icons.event_outlined),
        title: Text('${_text(entry['title'] ?? entry['purpose'])} · $status'),
        subtitle: Text(
          [
            '${_date(entry['startAt'])} – ${_date(entry['endAt'])}',
            if (details.isNotEmpty) details,
            if (reason.isNotEmpty) 'Begründung: $reason',
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: actions.isEmpty
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Aktionen',
                onSelected: (action) => _reservationAction(entry, action),
                itemBuilder: (_) => actions,
              ),
      ),
    );
  }

  Future<void> _reservationAction(
    Map<String, dynamic> entry,
    String action,
  ) async {
    final id = entry['id'];
    if (action == 'approve') {
      await _mutate(
        '/api/vehicle-reservations/$id/decision',
        body: {'approved': true},
      );
    } else if (action == 'tle') {
      await _mutate(
        '/api/vehicle-reservations/$id/operational-decision',
        body: {'approved': true},
      );
    } else if (action == 'reject' || action == 'tle-reject') {
      final reason = await _reason('Reservierung ablehnen');
      if (reason == null) return;
      await _mutate(
        action == 'reject'
            ? '/api/vehicle-reservations/$id/decision'
            : '/api/vehicle-reservations/$id/operational-decision',
        body: {'approved': false, 'reason': reason},
      );
    } else if (action == 'issue') {
      final blocked = safety['blocked'] == true;
      final handover = await _handover(
        'Fahrzeug übergeben',
        overrideReasons: blocked && safety['critical'] != true && mayOverride
            ? (safety['reasons'] as List? ?? const [])
                  .map((entry) => entry.toString())
                  .toList()
            : null,
      );
      if (handover != null) {
        await _mutate('/api/vehicle-reservations/$id/issue', body: handover);
      }
    } else if (action == 'return') {
      final handover = await _handover(
        'Fahrzeug zurücknehmen',
        allowDamage: true,
      );
      if (handover == null) return;
      final returned = await _mutate(
        '/api/vehicle-reservations/$id/return',
        body: handover,
      );
      if (returned && handover['damageReported'] == true && mounted) {
        if (can('defects.report')) {
          await _reportDefect(
            description: _text(handover['notes']).isEmpty
                ? 'Schaden bei Rückgabe festgestellt.'
                : handover['notes'].toString(),
          );
        }
      }
    } else if (action == 'cancel') {
      await _mutate('/api/vehicle-reservations/$id/cancel');
    }
  }

  Widget _maintenanceTile(Map<String, dynamic> entry) {
    final open = !['Abgeschlossen', 'Abgebrochen'].contains(entry['status']);
    final period = entry['startAt'] != null
        ? '${_date(entry['startAt'])} – ${_date(entry['endAt'])}'
        : null;
    return ListTile(
      leading: Icon(
        entry['safetyCritical'] == true
            ? Icons.health_and_safety
            : Icons.build_outlined,
      ),
      title: Text('${_text(entry['type'])} · ${entry['status']}'),
      subtitle: Text(
        [
          ?period,
          if (entry['dueDate'] != null) 'Fällig ${entry['dueDate']}',
          if (_text(entry['provider']).isNotEmpty) _text(entry['provider']),
          if (_text(entry['result']).isNotEmpty)
            'Ergebnis: ${_text(entry['result'])}',
          if (entry['nextDueDate'] != null)
            'Folgetermin ${entry['nextDueDate']}',
        ].join(' · '),
      ),
      trailing: ownsVehicle && can('vehicle_maintenance.manage') && open
          ? PopupMenuButton<String>(
              tooltip: 'Wartung bearbeiten',
              onSelected: (action) => _maintenanceAction(entry, action),
              itemBuilder: (_) => [
                if (entry['status'] == 'Geplant')
                  const PopupMenuItem(
                    value: 'start',
                    child: Text('In Arbeit setzen'),
                  ),
                const PopupMenuItem(
                  value: 'complete',
                  child: Text('Abschließen'),
                ),
                const PopupMenuItem(value: 'abort', child: Text('Abbrechen')),
              ],
            )
          : null,
    );
  }

  Future<void> _maintenanceAction(
    Map<String, dynamic> entry,
    String action,
  ) async {
    final path = '/api/vehicles/${widget.vehicleId}/maintenance/${entry['id']}';
    if (action == 'start') {
      await _mutate(path, method: 'PUT', body: {'status': 'In Arbeit'});
    } else if (action == 'abort') {
      final reason = await _reason('Wartung abbrechen');
      if (reason == null) return;
      await _mutate(
        path,
        method: 'PUT',
        body: {'status': 'Abgebrochen', 'result': reason},
      );
    } else if (action == 'complete') {
      final values = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _MaintenanceCompletionDialog(entry: entry),
      );
      if (values == null) return;
      await _mutate(
        path,
        method: 'PUT',
        body: {'status': 'Abgeschlossen', ...values},
      );
    }
  }

  Widget _loadTile(Map<String, dynamic> entry) {
    final foreign = entry['foreignMaterial'] == true;
    final ownMaterial = entry['unitId']?.toString() == widget.activeUnitId;
    final position = entry['position']?.toString() ?? '';
    return ListTile(
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text('${entry['inventoryNumber']} · ${entry['materialName']}'),
      subtitle: Text(
        '${entry['quantity']} ${_text(entry['unit'])} · ${position.isEmpty ? 'Keine Position' : position}'
        '${foreign ? ' · Material von ${entry['materialUnitName'] ?? 'anderer Gliederung'}' : ''}',
      ),
      trailing: (ownsVehicle || ownMaterial) && can('vehicles.load.manage')
          ? IconButton(
              tooltip: 'Vom Fahrzeug abbuchen',
              onPressed: () async {
                // Foreign material returns to its previous storage location
                // unless the owning unit of the material chooses one itself.
                final location = foreign && !ownMaterial
                    ? entry['previousLocationId']?.toString()
                    : await _destination();
                if (location != null) {
                  await _mutate(
                    '/api/vehicles/${widget.vehicleId}/load/${entry['id']}/unload',
                    body: {if (location.isNotEmpty) 'locationId': location},
                  );
                }
              },
              icon: const Icon(Icons.output_outlined),
            )
          : null,
    );
  }

  Widget _loadRequestTile(Map<String, dynamic> entry) {
    final status = entry['status']?.toString() ?? '';
    final pending = status == 'Ausstehend';
    final position = entry['position']?.toString() ?? '';
    final requester = entry['requesterUnitName'] ?? entry['requesterName'];
    final details = [
      '${entry['quantity']} ${entry['unit'] ?? 'Stück'}',
      position.isEmpty ? 'Keine Position' : position,
      'angefragt von $requester',
      if ((entry['notes']?.toString() ?? '').isNotEmpty) entry['notes'],
      if ((entry['decisionReason']?.toString() ?? '').isNotEmpty)
        'Begründung: ${entry['decisionReason']}',
    ].join(' · ');
    Widget? trailing;
    if (pending && ownsVehicle && can('vehicles.load.manage')) {
      trailing = Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Buchung freigeben',
            icon: const Icon(Icons.check_circle_outline),
            onPressed: () => _mutate(
              '/api/vehicle-load-requests/${entry['id']}/decision',
              body: {'approved': true},
            ),
          ),
          IconButton(
            tooltip: 'Buchung ablehnen',
            icon: const Icon(Icons.cancel_outlined),
            onPressed: () async {
              final reason = await _reason('Buchungsanfrage ablehnen');
              if (reason != null) {
                await _mutate(
                  '/api/vehicle-load-requests/${entry['id']}/decision',
                  body: {'approved': false, 'reason': reason},
                );
              }
            },
          ),
        ],
      );
    } else if (pending &&
        entry['requesterUnitId']?.toString() == widget.activeUnitId &&
        can('vehicles.load.manage')) {
      trailing = IconButton(
        tooltip: 'Anfrage zurückziehen',
        icon: const Icon(Icons.undo),
        onPressed: () =>
            _mutate('/api/vehicle-load-requests/${entry['id']}/cancel'),
      );
    }
    return Card.outlined(
      child: ListTile(
        leading: Icon(pending ? Icons.pending_actions_outlined : Icons.history),
        title: Text(
          '${entry['inventoryNumber']} · ${entry['materialName']} · $status',
        ),
        subtitle: Text(details),
        trailing: trailing,
      ),
    );
  }

  Future<String?> _destination() async {
    final locations = (widget.options['parkingLocations'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    // An empty id sends the item back to where it was loaded from.
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Ziel-Lagerort wählen'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Zurück an den ursprünglichen Lagerort'),
          ),
          ...locations.map(
            (entry) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry['id'].toString()),
              child: Text(_text(entry['path'] ?? entry['name'])),
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> _reason(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Begründung *'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Bestätigen'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<Map<String, dynamic>?> _handover(
    String title, {
    bool allowDamage = false,
    List<String>? overrideReasons,
  }) async {
    final mileage = TextEditingController(text: _text(vehicle?['mileage']));
    final fuel = TextEditingController();
    final notes = TextEditingController();
    final override = TextEditingController();
    var damage = false;
    var missingOverride = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (overrideReasons != null) ...[
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.warning_amber),
                      title: const Text('Fahrzeug ist gesperrt'),
                      subtitle: Text(overrideReasons.join('\n')),
                    ),
                  ),
                  TextField(
                    controller: override,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: 'Begründung der Übersteuerung *',
                      errorText: missingOverride ? 'Pflichtfeld' : null,
                    ),
                  ),
                ],
                TextField(
                  controller: mileage,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Kilometerstand',
                  ),
                ),
                TextField(
                  controller: fuel,
                  decoration: const InputDecoration(
                    labelText: 'Tank-/Ladezustand',
                  ),
                ),
                TextField(
                  controller: notes,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notizen'),
                ),
                if (allowDamage)
                  CheckboxListTile(
                    value: damage,
                    onChanged: (value) =>
                        setDialogState(() => damage = value == true),
                    title: const Text('Schaden festgestellt'),
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
              onPressed: () {
                if (overrideReasons != null && override.text.trim().isEmpty) {
                  setDialogState(() => missingOverride = true);
                  return;
                }
                Navigator.pop(context, {
                  'mileage': mileage.text.trim(),
                  'fuelLevel': fuel.text,
                  'notes': notes.text,
                  if (allowDamage) 'damageReported': damage,
                  if (overrideReasons != null)
                    'overrideReason': override.text.trim(),
                });
              },
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    mileage.dispose();
    fuel.dispose();
    notes.dispose();
    override.dispose();
    return result;
  }

  String _date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '-';
    return '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }
}

class _ReservationDialog extends StatefulWidget {
  const _ReservationDialog({this.allowOverride = false});

  /// Owners with maintenance rights may justify a non-critical conflict.
  final bool allowOverride;

  @override
  State<_ReservationDialog> createState() => _ReservationDialogState();
}

class _ReservationDialogState extends State<_ReservationDialog> {
  final formKey = GlobalKey<FormState>();
  final title = TextEditingController();
  final purpose = TextEditingController();
  final destination = TextEditingController();
  final contact = TextEditingController();
  final note = TextEditingController();
  final overrideReason = TextEditingController();
  DateTime start = DateTime.now().add(const Duration(days: 1));
  DateTime end = DateTime.now().add(const Duration(days: 1, hours: 2));
  String? periodError;

  @override
  void dispose() {
    title.dispose();
    purpose.dispose();
    destination.dispose();
    contact.dispose();
    note.dispose();
    overrideReason.dispose();
    super.dispose();
  }

  Future<void> pick(bool isStart) async {
    final current = isStart ? start : end;
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      initialDate: current,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isStart) {
        start = value;
        if (!end.isAfter(start)) end = start.add(const Duration(hours: 2));
      } else {
        end = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fahrzeug reservieren'),
    content: SizedBox(
      width: 620,
      child: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pick(true),
                      icon: const Icon(Icons.event),
                      label: Text('Beginn: ${_short(start)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => pick(false),
                      icon: const Icon(Icons.event),
                      label: Text('Ende: ${_short(end)}'),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Titel *'),
                validator: _required,
              ),
              TextFormField(
                controller: purpose,
                decoration: const InputDecoration(labelText: 'Zweck *'),
                validator: _required,
              ),
              TextFormField(
                controller: destination,
                decoration: const InputDecoration(labelText: 'Ziel *'),
                validator: _required,
              ),
              TextFormField(
                controller: contact,
                decoration: const InputDecoration(labelText: 'Kontakt *'),
                validator: _required,
              ),
              TextFormField(
                controller: note,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notiz'),
              ),
              if (widget.allowOverride)
                TextFormField(
                  controller: overrideReason,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Begründung bei Wartungskonflikt (optional)',
                    helperText:
                        'Nur für nicht sicherheitskritische Sperren wirksam.',
                  ),
                ),
              if (periodError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    periodError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () {
          final error = !end.isAfter(start)
              ? 'Das Ende muss nach dem Beginn liegen.'
              : !end.isAfter(DateTime.now())
              ? 'Der Zeitraum liegt in der Vergangenheit.'
              : null;
          setState(() => periodError = error);
          if (formKey.currentState?.validate() != true || error != null) {
            return;
          }
          Navigator.pop(context, {
            'startAt': start.toUtc().toIso8601String(),
            'endAt': end.toUtc().toIso8601String(),
            'title': title.text,
            'purpose': purpose.text,
            'destination': destination.text,
            'contact': contact.text,
            'note': note.text,
            if (overrideReason.text.trim().isNotEmpty)
              'overrideReason': overrideReason.text.trim(),
          });
        },
        child: const Text('Beantragen'),
      ),
    ],
  );

  static String? _required(String? value) =>
      value?.trim().isEmpty != false ? 'Pflichtfeld' : null;
  static String _short(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

String? _validDateOnly(String value) {
  final raw = value.trim();
  if (raw.isEmpty) return '';
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return null;
  final parsed = DateTime.utc(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
  );
  return parsed.toIso8601String().substring(0, 10) == raw ? raw : null;
}

String? _optionalNumber(String? value, {bool integer = false}) {
  final raw = value?.trim().replaceAll(',', '.') ?? '';
  if (raw.isEmpty) return null;
  final parsed = num.tryParse(raw);
  if (parsed == null || parsed < 0 || (integer && parsed % 1 != 0)) {
    return integer ? 'Ganze Zahl ≥ 0' : 'Zahl ≥ 0';
  }
  return null;
}

class _MaintenanceDialog extends StatefulWidget {
  const _MaintenanceDialog();

  @override
  State<_MaintenanceDialog> createState() => _MaintenanceDialogState();
}

class _MaintenanceDialogState extends State<_MaintenanceDialog> {
  final formKey = GlobalKey<FormState>();
  final type = TextEditingController();
  final due = TextEditingController();
  final provider = TextEditingController();
  final interval = TextEditingController();
  final mileage = TextEditingController();
  final cost = TextEditingController();
  final description = TextEditingController();
  DateTime start = DateTime.now().add(const Duration(days: 1));
  DateTime end = DateTime.now().add(const Duration(days: 1, hours: 4));

  /// Only a real workshop slot blocks reservations; a pure due date does not.
  bool withPeriod = false;
  bool critical = false;
  String? formError;

  @override
  void dispose() {
    for (final controller in [
      type,
      due,
      provider,
      interval,
      mileage,
      cost,
      description,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool isStart) async {
    final current = isStart ? start : end;
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: current,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (isStart) {
        start = value;
        if (!end.isAfter(start)) end = start.add(const Duration(hours: 4));
      } else {
        end = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Wartung planen'),
    content: SizedBox(
      width: 620,
      child: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextFormField(
                controller: type,
                decoration: const InputDecoration(labelText: 'Wartungsart *'),
                validator: _ReservationDialogState._required,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: withPeriod,
                onChanged: (value) => setState(() => withPeriod = value),
                title: const Text('Werkstatttermin mit Zeitraum'),
                subtitle: const Text(
                  'Das Fahrzeug ist in diesem Zeitraum nicht reservierbar.',
                ),
              ),
              if (withPeriod)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pick(true),
                        icon: const Icon(Icons.event),
                        label: Text(
                          'Beginn: ${_ReservationDialogState._short(start)}',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => pick(false),
                        icon: const Icon(Icons.event),
                        label: Text(
                          'Ende: ${_ReservationDialogState._short(end)}',
                        ),
                      ),
                    ),
                  ],
                ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: due,
                      decoration: InputDecoration(
                        labelText: withPeriod
                            ? 'Fälligkeit (JJJJ-MM-TT)'
                            : 'Fälligkeit (JJJJ-MM-TT) *',
                      ),
                      validator: (value) {
                        final parsed = _validDateOnly(value ?? '');
                        if (parsed == null) return 'Ungültiges Datum';
                        if (parsed.isEmpty && !withPeriod) return 'Pflichtfeld';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: interval,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Intervall Monate',
                        helperText: 'Legt beim Abschluss den Folgetermin an.',
                      ),
                      validator: (value) =>
                          _optionalNumber(value, integer: true),
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: provider,
                decoration: const InputDecoration(
                  labelText: 'Ausführende Stelle',
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: mileage,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Kilometerstand',
                      ),
                      validator: _optionalNumber,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: cost,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Kosten'),
                      validator: _optionalNumber,
                    ),
                  ),
                ],
              ),
              TextFormField(
                controller: description,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Beschreibung'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: critical,
                onChanged: (value) => setState(() => critical = value),
                title: const Text('Sicherheitskritische Wartung'),
                subtitle: const Text(
                  'Sperrt das Fahrzeug ohne Übersteuerung, sobald die Wartung '
                  'aktiv oder überfällig ist.',
                ),
              ),
              if (formError != null)
                Text(
                  formError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () {
          final error = withPeriod && !end.isAfter(start)
              ? 'Das Ende muss nach dem Beginn liegen.'
              : null;
          setState(() => formError = error);
          if (formKey.currentState?.validate() != true || error != null) {
            return;
          }
          Navigator.pop(context, {
            'type': type.text.trim(),
            'status': 'Geplant',
            if (withPeriod) 'startAt': start.toUtc().toIso8601String(),
            if (withPeriod) 'endAt': end.toUtc().toIso8601String(),
            'dueDate': due.text.trim(),
            'intervalMonths': interval.text.trim(),
            'mileage': mileage.text.trim().replaceAll(',', '.'),
            'provider': provider.text,
            'cost': cost.text.trim().replaceAll(',', '.'),
            'description': description.text,
            'safetyCritical': critical,
          });
        },
        child: const Text('Speichern'),
      ),
    ],
  );
}

class _MaintenanceCompletionDialog extends StatefulWidget {
  const _MaintenanceCompletionDialog({required this.entry});

  final Map<String, dynamic> entry;

  @override
  State<_MaintenanceCompletionDialog> createState() =>
      _MaintenanceCompletionDialogState();
}

class _MaintenanceCompletionDialogState
    extends State<_MaintenanceCompletionDialog> {
  final formKey = GlobalKey<FormState>();
  late final result = TextEditingController(
    text: _text(widget.entry['result']),
  );
  late final cost = TextEditingController(text: _text(widget.entry['cost']));
  late final mileage = TextEditingController(
    text: _text(widget.entry['mileage']),
  );
  late final nextDue = TextEditingController(
    text: _text(widget.entry['nextDueDate']),
  );

  @override
  void dispose() {
    result.dispose();
    cost.dispose();
    mileage.dispose();
    nextDue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final interval = _text(widget.entry['intervalMonths']);
    return AlertDialog(
      title: Text('Wartung „${_text(widget.entry['type'])}“ abschließen'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: result,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Ergebnis *'),
                validator: _ReservationDialogState._required,
              ),
              TextFormField(
                controller: mileage,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Kilometerstand'),
                validator: _optionalNumber,
              ),
              TextFormField(
                controller: cost,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Kosten'),
                validator: _optionalNumber,
              ),
              TextFormField(
                controller: nextDue,
                decoration: InputDecoration(
                  labelText: 'Folgetermin (JJJJ-MM-TT)',
                  helperText: interval.isEmpty
                      ? 'Legt automatisch eine neue geplante Wartung an.'
                      : 'Leer lassen: automatisch in $interval Monaten.',
                ),
                validator: (value) => _validDateOnly(value ?? '') == null
                    ? 'Ungültiges Datum'
                    : null,
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
        FilledButton(
          onPressed: () {
            if (formKey.currentState?.validate() != true) return;
            Navigator.pop(context, {
              'result': result.text.trim(),
              'mileage': mileage.text.trim().replaceAll(',', '.'),
              'cost': cost.text.trim().replaceAll(',', '.'),
              'nextDueDate': nextDue.text.trim(),
            });
          },
          child: const Text('Abschließen'),
        ),
      ],
    );
  }
}

class _LoadMaterialDialog extends StatefulWidget {
  const _LoadMaterialDialog({
    required this.materials,
    required this.positions,
    this.title = 'Inventar auf Fahrzeug buchen',
    this.submitLabel = 'Buchen',
    this.hint,
  });
  final List<String> positions;
  final List<Map<String, dynamic>> materials;
  final String title;
  final String submitLabel;
  final String? hint;
  @override
  State<_LoadMaterialDialog> createState() => _LoadMaterialDialogState();
}

class _LoadMaterialDialogState extends State<_LoadMaterialDialog> {
  String? materialId;
  final quantity = TextEditingController(text: '1');
  final position = TextEditingController();
  final notes = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(widget.hint!),
            ),
          DropdownButtonFormField<String>(
            initialValue: materialId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Material'),
            items: widget.materials
                .where(
                  (entry) =>
                      (num.tryParse(
                            entry['availableQuantity']?.toString() ?? '',
                          ) ??
                          0) >
                      0,
                )
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry['id'].toString(),
                    child: Text(
                      '${entry['inventoryNumber']} · ${entry['name']} (${entry['availableQuantity']} verfügbar)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => materialId = value),
          ),
          TextField(
            controller: quantity,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Menge'),
          ),
          if (widget.positions.isNotEmpty)
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Fahrzeugfach'),
              items: widget.positions
                  .map(
                    (value) =>
                        DropdownMenuItem(value: value, child: Text(value)),
                  )
                  .toList(),
              onChanged: (value) => setState(() => position.text = value ?? ''),
            )
          else
            TextField(
              controller: position,
              decoration: const InputDecoration(
                labelText: 'Beladungsposition/Fach',
              ),
            ),
          TextField(
            controller: notes,
            decoration: const InputDecoration(labelText: 'Notiz'),
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
        onPressed: materialId == null
            ? null
            : () => Navigator.pop(context, {
                'materialId': materialId,
                'quantity': quantity.text,
                'position': position.text,
                'notes': notes.text,
              }),
        child: Text(widget.submitLabel),
      ),
    ],
  );
}

class _LoadListDialog extends StatefulWidget {
  const _LoadListDialog({required this.assignments});
  final List<Map<String, dynamic>> assignments;
  @override
  State<_LoadListDialog> createState() => _LoadListDialogState();
}

class _LoadListDialogState extends State<_LoadListDialog> {
  final name = TextEditingController(text: 'Standardbeladung');
  bool activateNow = true;
  late final quantities = widget.assignments
      .map((entry) => TextEditingController(text: entry['quantity'].toString()))
      .toList();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Soll-Beladungsliste erstellen'),
    content: SizedBox(
      width: 680,
      height: 480,
      child: Column(
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Bezeichnung'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: activateNow,
            onChanged: (value) => setState(() => activateNow = value),
            title: const Text('Sofort aktivieren'),
            subtitle: const Text(
              'Ersetzt die bisher aktive Liste. Sonst als Entwurf speichern.',
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: widget.assignments.length,
              itemBuilder: (_, index) {
                final entry = widget.assignments[index];
                return ListTile(
                  title: Text(
                    '${entry['inventoryNumber']} · ${entry['materialName']}',
                  ),
                  subtitle: Text(_text(entry['position'])),
                  trailing: SizedBox(
                    width: 100,
                    child: TextField(
                      controller: quantities[index],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Soll'),
                    ),
                  ),
                );
              },
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
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'name': name.text,
          'activate': activateNow,
          'items': List.generate(
            widget.assignments.length,
            (index) => {
              'materialId': widget.assignments[index]['materialId'],
              'targetQuantity': quantities[index].text,
              'position': widget.assignments[index]['position'],
              'notes': widget.assignments[index]['notes'],
            },
          ),
        }),
        child: Text(activateNow ? 'Aktivieren' : 'Als Entwurf speichern'),
      ),
    ],
  );
}

class _SharingDialog extends StatefulWidget {
  const _SharingDialog({
    required this.candidates,
    required this.viewIds,
    required this.reservationIds,
    this.loadIds = const {},
  });
  final List<Map<String, dynamic>> candidates;
  final Set<String> viewIds;
  final Set<String> reservationIds;
  final Set<String> loadIds;
  @override
  State<_SharingDialog> createState() => _SharingDialogState();
}

class _SharingDialogState extends State<_SharingDialog> {
  late final viewIds = {...widget.viewIds};
  late final reservationIds = {...widget.reservationIds};
  late final loadIds = {...widget.loadIds};
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Gliederungsfreigaben'),
    content: SizedBox(
      width: 680,
      height: 480,
      child: widget.candidates.isEmpty
          ? const Center(child: Text('Keine weiteren Gliederungen vorhanden.'))
          : ListView(
              children: widget.candidates.map((entry) {
                final id = entry['id'].toString();
                return Card.outlined(
                  child: Column(
                    children: [
                      ListTile(
                        title: Text(entry['name'].toString()),
                        subtitle: Text(entry['type']?.toString() ?? ''),
                      ),
                      CheckboxListTile(
                        value: viewIds.contains(id),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            viewIds.add(id);
                          } else {
                            viewIds.remove(id);
                            reservationIds.remove(id);
                            loadIds.remove(id);
                          }
                        }),
                        title: const Text('Darf Fahrzeug sehen'),
                      ),
                      CheckboxListTile(
                        value: reservationIds.contains(id),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            reservationIds.add(id);
                            viewIds.add(id);
                          } else {
                            reservationIds.remove(id);
                          }
                        }),
                        title: const Text('Darf Fahrzeug reservieren'),
                      ),
                      CheckboxListTile(
                        value: loadIds.contains(id),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            loadIds.add(id);
                            viewIds.add(id);
                          } else {
                            loadIds.remove(id);
                          }
                        }),
                        title: const Text('Darf eigenes Material buchen'),
                        subtitle: const Text(
                          'Jede Buchung muss von dieser Gliederung freigegeben werden.',
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'viewUnitIds': viewIds.toList(),
          'reservationUnitIds': reservationIds.toList(),
          'loadUnitIds': loadIds.toList(),
        }),
        child: const Text('Speichern'),
      ),
    ],
  );
}

class _VehicleDefectDialog extends StatefulWidget {
  const _VehicleDefectDialog({this.description});

  final String? description;
  @override
  State<_VehicleDefectDialog> createState() => _VehicleDefectDialogState();
}

class _VehicleDefectDialogState extends State<_VehicleDefectDialog> {
  final title = TextEditingController();
  late final description = TextEditingController(text: widget.description);
  String priority = 'Normal';
  bool notOperational = true;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Fahrzeugmangel melden'),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: 'Titel *'),
          ),
          TextField(
            controller: description,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Beschreibung *'),
          ),
          DropdownButtonFormField<String>(
            initialValue: priority,
            decoration: const InputDecoration(labelText: 'Priorität'),
            items: const ['Niedrig', 'Normal', 'Hoch', 'Kritisch']
                .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)),
                )
                .toList(),
            onChanged: (value) => setState(() => priority = value ?? priority),
          ),
          SwitchListTile(
            value: notOperational,
            onChanged: (value) => setState(() => notOperational = value),
            title: const Text('Fahrzeug nicht einsatzfähig'),
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
        onPressed: () {
          if (title.text.trim().isNotEmpty &&
              description.text.trim().isNotEmpty) {
            Navigator.pop(context, {
              'title': title.text,
              'description': description.text,
              'priority': priority,
              'affectedQuantity': 1,
              'operationalSafety': notOperational
                  ? 'Nicht einsatzfähig'
                  : 'Einsatzfähig',
            });
          }
        },
        child: const Text('Melden'),
      ),
    ],
  );
}
