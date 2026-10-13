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
      ].any((entry) => entry.toString().toLowerCase().contains(needle));
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
      if (vehicle['radioCallName'].toString().isNotEmpty)
        vehicle['radioCallName'],
      '${_vehicleKindOf(vehicle)} · ${_vehicleUsageOf(vehicle)} · ${vehicle['type']}'
          .trim(),
      '${vehicle['manufacturer']} ${vehicle['model']}'.trim(),
      'Stellplatz: ${vehicle['parkingDetails'].toString().isNotEmpty ? vehicle['parkingDetails'] : vehicle['parkingLocationName'] ?? '-'}',
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
                      labelText: 'Stellplatz-Lagerort',
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Kein Lagerort'),
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
                    onChanged: (value) => parkingLocationId = value,
                  ),
                ),
                _field(parkingDetails, 'Stellplatz-Details'),
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
              'parkingDetails': parkingDetails.text,
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

  Future<void> _mutate(
    String path, {
    String method = 'POST',
    Object? body,
  }) async {
    final result = await widget.request(path, method: method, body: body);
    if (result != null) await _load();
  }

  Future<void> _reserve() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ReservationDialog(),
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
      builder: (_) => _MaintenanceDialog(),
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
        materials: materials
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(),
      ),
    );
    if (values == null) return;
    await _mutate('/api/vehicles/${widget.vehicleId}/load', body: values);
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

  Future<void> _print({required bool save}) async {
    final result = await widget.request(
      '/api/vehicles/${widget.vehicleId}/load-list/print',
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
      ),
    );
    if (values == null) return;
    await _mutate(
      '/api/vehicles/${widget.vehicleId}/sharing',
      method: 'PUT',
      body: values,
    );
  }

  Future<void> _reportDefect() async {
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _VehicleDefectDialog(),
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
    final safety = Map<String, dynamic>.from(
      value['safetyStatus'] as Map? ?? const {},
    );
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
                        '${value['manufacturer']} ${value['model']}',
                    'Baujahr': value['year'],
                    'Stellplatz': value['parkingDetails'].toString().isNotEmpty
                        ? value['parkingDetails']
                        : value['parkingLocationName'],
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
                _section('Beladung', Icons.inventory_2_outlined, [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (ownsVehicle && can('vehicles.load.manage'))
                        FilledButton.tonalIcon(
                          onPressed: _loadMaterial,
                          icon: const Icon(Icons.add_box_outlined),
                          label: const Text('Inventar buchen'),
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
                  if (lists.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Beladungslisten: ${lists.map((entry) => 'v${entry['version']} ${entry['status']}').join(' · ')}',
                      ),
                    ),
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

  Widget _reservationTile(Map<String, dynamic> entry) {
    final status = entry['status']?.toString();
    return Card.outlined(
      child: ListTile(
        leading: const Icon(Icons.event_outlined),
        title: Text('${entry['title'] ?? entry['purpose']} · $status'),
        subtitle: Text(
          '${_date(entry['startAt'])} – ${_date(entry['endAt'])}\n${entry['purpose']} · ${entry['destination']} · ${entry['requesterName']}',
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            if (action == 'approve') {
              await _mutate(
                '/api/vehicle-reservations/${entry['id']}/decision',
                body: {'approved': true},
              );
            } else if (action == 'tle') {
              await _mutate(
                '/api/vehicle-reservations/${entry['id']}/operational-decision',
                body: {'approved': true},
              );
            } else if (action == 'reject') {
              final reason = await _reason('Reservierung ablehnen');
              if (reason != null) {
                await _mutate(
                  '/api/vehicle-reservations/${entry['id']}/decision',
                  body: {'approved': false, 'reason': reason},
                );
              }
            } else if (action == 'issue') {
              final handover = await _handover('Fahrzeug übergeben');
              if (handover != null) {
                await _mutate(
                  '/api/vehicle-reservations/${entry['id']}/issue',
                  body: handover,
                );
              }
            } else if (action == 'return') {
              final handover = await _handover(
                'Fahrzeug zurücknehmen',
                allowDamage: true,
              );
              if (handover != null) {
                await _mutate(
                  '/api/vehicle-reservations/${entry['id']}/return',
                  body: handover,
                );
              }
            } else if (action == 'cancel') {
              await _mutate('/api/vehicle-reservations/${entry['id']}/cancel');
            }
          },
          itemBuilder: (_) => [
            if (ownsVehicle &&
                can('vehicle_reservations.manage') &&
                status == 'Ausstehend')
              const PopupMenuItem(
                value: 'approve',
                child: Text('Fahrzeug freigeben'),
              ),
            if (can('vehicle_reservations.operational_approve') &&
                status == 'TLE-Freigabe ausstehend')
              const PopupMenuItem(
                value: 'tle',
                child: Text('TLE-Freigabe erteilen'),
              ),
            if (ownsVehicle &&
                can('vehicle_reservations.manage') &&
                ['Ausstehend', 'TLE-Freigabe ausstehend'].contains(status))
              const PopupMenuItem(value: 'reject', child: Text('Ablehnen')),
            if (ownsVehicle &&
                can('vehicle_reservations.manage') &&
                status == 'Freigegeben')
              const PopupMenuItem(value: 'issue', child: Text('Übergeben')),
            if (ownsVehicle &&
                can('vehicle_reservations.manage') &&
                status == 'Ausgegeben')
              const PopupMenuItem(value: 'return', child: Text('Zurücknehmen')),
            if (![
              'Abgeschlossen',
              'Abgelehnt',
              'Storniert',
              'Ausgegeben',
            ].contains(status))
              const PopupMenuItem(value: 'cancel', child: Text('Stornieren')),
          ],
        ),
      ),
    );
  }

  Widget _maintenanceTile(Map<String, dynamic> entry) {
    return ListTile(
      leading: Icon(
        entry['safetyCritical'] == true
            ? Icons.health_and_safety
            : Icons.build_outlined,
      ),
      title: Text('${entry['type']} · ${entry['status']}'),
      subtitle: Text(
        [
          if (entry['dueDate'] != null) 'Fällig ${entry['dueDate']}',
          if (entry['provider'].toString().isNotEmpty) entry['provider'],
          if (entry['nextDueDate'] != null)
            'Folgetermin ${entry['nextDueDate']}',
        ].join(' · '),
      ),
      trailing:
          ownsVehicle &&
              can('vehicle_maintenance.manage') &&
              !['Abgeschlossen', 'Abgebrochen'].contains(entry['status'])
          ? TextButton(
              onPressed: () => _mutate(
                '/api/vehicles/${widget.vehicleId}/maintenance/${entry['id']}',
                method: 'PUT',
                body: {'status': 'Abgeschlossen'},
              ),
              child: const Text('Abschließen'),
            )
          : null,
    );
  }

  Widget _loadTile(Map<String, dynamic> entry) {
    return ListTile(
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text('${entry['inventoryNumber']} · ${entry['materialName']}'),
      subtitle: Text(
        '${entry['quantity']} ${entry['unit']} · ${entry['position'].toString().isEmpty ? 'Keine Position' : entry['position']}',
      ),
      trailing: ownsVehicle && can('vehicles.load.manage')
          ? IconButton(
              tooltip: 'Vom Fahrzeug abbuchen',
              onPressed: () async {
                final location = await _destination();
                if (location != null) {
                  await _mutate(
                    '/api/vehicles/${widget.vehicleId}/load/${entry['id']}/unload',
                    body: {'locationId': location},
                  );
                }
              },
              icon: const Icon(Icons.output_outlined),
            )
          : null,
    );
  }

  Future<String?> _destination() async {
    final locations = (widget.options['parkingLocations'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    if (locations.isEmpty) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Ziel-Lagerort wählen'),
        children: locations
            .map(
              (entry) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry['id'].toString()),
                child: Text(
                  entry['path']?.toString() ?? entry['name'].toString(),
                ),
              ),
            )
            .toList(),
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
  }) async {
    final mileage = TextEditingController();
    final fuel = TextEditingController();
    final notes = TextEditingController();
    var damage = false;
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
              onPressed: () => Navigator.pop(context, {
                'mileage': mileage.text,
                'fuelLevel': fuel.text,
                'notes': notes.text,
                if (allowDamage) 'damageReported': damage,
              }),
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
    mileage.dispose();
    fuel.dispose();
    notes.dispose();
    return result;
  }

  String _date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '-';
    return '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }
}

class _ReservationDialog extends StatefulWidget {
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
  DateTime start = DateTime.now().add(const Duration(days: 1));
  DateTime end = DateTime.now().add(const Duration(days: 1, hours: 2));

  @override
  void dispose() {
    title.dispose();
    purpose.dispose();
    destination.dispose();
    contact.dispose();
    note.dispose();
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
          if (formKey.currentState?.validate() != true || !end.isAfter(start)) {
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

class _MaintenanceDialog extends StatefulWidget {
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
  bool critical = false;

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
              TextFormField(
                controller: type,
                decoration: const InputDecoration(labelText: 'Wartungsart *'),
                validator: _ReservationDialogState._required,
              ),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: due,
                      decoration: const InputDecoration(
                        labelText: 'Fälligkeit (JJJJ-MM-TT)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: interval,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Intervall Monate',
                      ),
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
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: cost,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Kosten'),
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
                value: critical,
                onChanged: (value) => setState(() => critical = value),
                title: const Text('Sicherheitskritische Wartung'),
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
          if (formKey.currentState?.validate() != true) return;
          Navigator.pop(context, {
            'type': type.text,
            'status': 'Geplant',
            'startAt': start.toUtc().toIso8601String(),
            'endAt': end.toUtc().toIso8601String(),
            'dueDate': due.text,
            'intervalMonths': interval.text,
            'mileage': mileage.text,
            'provider': provider.text,
            'cost': cost.text,
            'description': description.text,
            'safetyCritical': critical,
          });
        },
        child: const Text('Speichern'),
      ),
    ],
  );
}

class _LoadMaterialDialog extends StatefulWidget {
  const _LoadMaterialDialog({required this.materials});
  final List<Map<String, dynamic>> materials;
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
    title: const Text('Inventar auf Fahrzeug buchen'),
    content: SizedBox(
      width: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
        child: const Text('Buchen'),
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
                  subtitle: Text(entry['position']?.toString() ?? ''),
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
          'activate': true,
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
        child: const Text('Aktivieren'),
      ),
    ],
  );
}

class _SharingDialog extends StatefulWidget {
  const _SharingDialog({
    required this.candidates,
    required this.viewIds,
    required this.reservationIds,
  });
  final List<Map<String, dynamic>> candidates;
  final Set<String> viewIds;
  final Set<String> reservationIds;
  @override
  State<_SharingDialog> createState() => _SharingDialogState();
}

class _SharingDialogState extends State<_SharingDialog> {
  late final viewIds = {...widget.viewIds};
  late final reservationIds = {...widget.reservationIds};
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
        }),
        child: const Text('Speichern'),
      ),
    ],
  );
}

class _VehicleDefectDialog extends StatefulWidget {
  const _VehicleDefectDialog();
  @override
  State<_VehicleDefectDialog> createState() => _VehicleDefectDialogState();
}

class _VehicleDefectDialogState extends State<_VehicleDefectDialog> {
  final title = TextEditingController();
  final description = TextEditingController();
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
