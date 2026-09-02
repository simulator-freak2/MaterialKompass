import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart' hide DropdownButtonFormField;

import '../services/authenticated_api_client.dart';
import '../widgets/keyboard_dropdown_button_form_field.dart';

enum CalendarViewMode { month, week, list }

class CalendarPage extends StatefulWidget {
  const CalendarPage({required this.token, super.key});

  final String token;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late final AuthenticatedApiClient api = AuthenticatedApiClient(widget.token);
  DateTime anchor = DateTime.now();
  CalendarViewMode mode = CalendarViewMode.month;
  List<Map<String, dynamic>> events = [];
  List<Map<String, dynamic>> materials = [];
  List<Map<String, dynamic>> locations = [];
  List<String> departments = [];
  Set<String> permissions = {};
  bool loading = true;
  String kindFilter = 'Alle', statusFilter = 'Alle';
  String? locationFilter, departmentFilter;
  final materialFilter = TextEditingController();

  bool can(String permission) => permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    materialFilter.dispose();
    super.dispose();
  }

  DateTime get _rangeStart {
    if (mode == CalendarViewMode.week) return _weekStart(anchor);
    if (mode == CalendarViewMode.list) {
      return DateTime(
        anchor.year,
        anchor.month,
        anchor.day,
      ).subtract(const Duration(days: 30));
    }
    final first = DateTime(anchor.year, anchor.month, 1);
    return first.subtract(Duration(days: first.weekday - 1));
  }

  DateTime get _rangeEnd => switch (mode) {
    CalendarViewMode.month => _rangeStart.add(const Duration(days: 42)),
    CalendarViewMode.week => _rangeStart.add(const Duration(days: 7)),
    CalendarViewMode.list => _rangeStart.add(const Duration(days: 180)),
  };

  DateTime _weekStart(DateTime date) => DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: date.weekday - 1));

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final query = Uri(
        queryParameters: {
          'from': _rangeStart.toUtc().toIso8601String(),
          'to': _rangeEnd.toUtc().toIso8601String(),
        },
      ).query;
      final results = await Future.wait([
        api.request('/api/calendar?$query'),
        api.request('/api/calendar/materials?limit=100'),
        api.request('/api/auth/me'),
      ]);
      final calendar = Map<String, dynamic>.from(results[0] as Map);
      final options = Map<String, dynamic>.from(
        calendar['filterOptions'] as Map? ?? const {},
      );
      final user = Map<String, dynamic>.from(
        (results[2] as Map)['user'] as Map? ?? const {},
      );
      if (!mounted) return;
      setState(() {
        events = (calendar['events'] as List? ?? const [])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        materials = (results[1] as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        locations = (options['locations'] as List? ?? const [])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        departments = (options['departments'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toList();
        permissions = (user['permissions'] as List? ?? const [])
            .map((entry) => entry.toString())
            .toSet();
        loading = false;
      });
    } on AuthenticatedApiException catch (error) {
      if (!mounted) return;
      setState(() => loading = false);
      _message(error.message, error: true);
    }
  }

  List<Map<String, dynamic>> get filteredEvents {
    final query = materialFilter.text.trim().toLowerCase();
    return events.where((entry) {
      final kind = entry['kind']?.toString() ?? '';
      if (kindFilter == 'Reservierungen' && kind != 'reservation') return false;
      if (kindFilter == 'Wartungen' &&
          !['maintenance', 'maintenance-due'].contains(kind))
        return false;
      if (kindFilter == 'Prüfungen' && kind != 'inspection') return false;
      if (statusFilter != 'Alle' && entry['status'] != statusFilter) {
        return false;
      }
      final eventLocations = (entry['locationIds'] as List? ?? const []).map(
        (value) => value.toString(),
      );
      if (locationFilter != null && !eventLocations.contains(locationFilter)) {
        return false;
      }
      final eventDepartments = (entry['departments'] as List? ?? const []).map(
        (value) => value.toString(),
      );
      if (departmentFilter != null &&
          !eventDepartments.contains(departmentFilter))
        return false;
      if (query.isNotEmpty) {
        final haystack = [
          entry['inventoryNumber'],
          entry['materialName'],
          ...(entry['inventoryNumbers'] as List? ?? const []),
          ...(entry['materialNames'] as List? ?? const []),
        ].join(' ').toLowerCase();
        if (!haystack.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _mutate(String path, {Object? body}) async {
    try {
      await api.request(path, method: 'POST', body: body ?? const {});
      await _load();
    } on AuthenticatedApiException catch (error) {
      if (mounted) _message(error.message, error: true);
    }
  }

  Future<void> _createReservation([Map<String, dynamic>? existing]) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          ReservationDialog(materials: materials, existing: existing),
    );
    if (body == null) return;
    try {
      await api.request(
        existing == null
            ? '/api/reservations'
            : '/api/reservations/${existing['id']}',
        method: existing == null ? 'POST' : 'PUT',
        body: body,
      );
      if (mounted)
        _message(
          existing == null
              ? 'Reservierung wurde angelegt.'
              : 'Reservierung wurde aktualisiert.',
        );
      await _load();
    } on AuthenticatedApiException catch (error) {
      if (mounted) _message(error.message, error: true);
    }
  }

  Future<void> _editMaintenance([Map<String, dynamic>? existing]) async {
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          MaintenanceDialog(materials: materials, existing: existing),
    );
    if (body == null) return;
    try {
      await api.request(
        existing == null
            ? '/api/maintenance'
            : '/api/maintenance/${existing['id']}',
        method: existing == null ? 'POST' : 'PUT',
        body: body,
      );
      if (mounted) _message('Wartung wurde gespeichert.');
      await _load();
    } on AuthenticatedApiException catch (error) {
      if (error.statusCode == 409 && mounted) {
        final reason = await _overrideReason(error.message);
        if (reason != null) {
          body['overrideConflict'] = true;
          body['overrideReason'] = reason;
          try {
            await api.request(
              existing == null
                  ? '/api/maintenance'
                  : '/api/maintenance/${existing['id']}',
              method: existing == null ? 'POST' : 'PUT',
              body: body,
            );
            await _load();
            return;
          } on AuthenticatedApiException catch (retryError) {
            if (mounted) _message(retryError.message, error: true);
            return;
          }
        }
      }
      if (mounted) _message(error.message, error: true);
    }
  }

  Future<String?> _overrideReason(String conflict) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Konflikt übersteuern?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(conflict),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Begründung *',
                border: OutlineInputBorder(),
              ),
            ),
          ],
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
            child: const Text('Übersteuern'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _export() async {
    try {
      final query = Uri(
        queryParameters: {
          'from': _rangeStart.toUtc().toIso8601String(),
          'to': _rangeEnd.toUtc().toIso8601String(),
        },
      ).query;
      final data = Map<String, dynamic>.from(
        await api.request('/api/calendar/export?$query') as Map,
      );
      final fileName = data['fileName'].toString();
      await FileSaver.instance.saveFile(
        name: fileName.replaceFirst(RegExp(r'\.ics$'), ''),
        bytes: base64Decode(data['fileBase64'].toString()),
        fileExtension: 'ics',
        mimeType: MimeType.custom,
        customMimeType: 'text/calendar;charset=utf-8',
      );
      if (mounted) _message('$fileName wurde exportiert.');
    } on AuthenticatedApiException catch (error) {
      if (mounted) _message(error.message, error: true);
    }
  }

  void _move(int direction) {
    setState(() {
      anchor = switch (mode) {
        CalendarViewMode.month => DateTime(
          anchor.year,
          anchor.month + direction,
          1,
        ),
        CalendarViewMode.week => anchor.add(Duration(days: 7 * direction)),
        CalendarViewMode.list => anchor.add(Duration(days: 30 * direction)),
      };
    });
    _load();
  }

  String get _title => switch (mode) {
    CalendarViewMode.month => '${_month(anchor.month)} ${anchor.year}',
    CalendarViewMode.week =>
      '${_date(_rangeStart)} – ${_date(_rangeEnd.subtract(const Duration(days: 1)))}',
    CalendarViewMode.list => 'Termine ab ${_date(_rangeStart)}',
  };

  @override
  Widget build(BuildContext context) {
    final visible = filteredEvents;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reservierungs- und Wartungskalender'),
        actions: [
          IconButton(
            tooltip: 'ICS exportieren',
            onPressed: _export,
            icon: const Icon(Icons.event_available_outlined),
          ),
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton:
          can('reservations.create') || can('maintenance.manage')
          ? PopupMenuButton<String>(
              tooltip: 'Termin anlegen',
              onSelected: (value) => value == 'reservation'
                  ? _createReservation()
                  : _editMaintenance(),
              itemBuilder: (_) => [
                if (can('reservations.create'))
                  const PopupMenuItem(
                    value: 'reservation',
                    child: ListTile(
                      leading: Icon(Icons.bookmark_add_outlined),
                      title: Text('Reservierung'),
                    ),
                  ),
                if (can('maintenance.manage'))
                  const PopupMenuItem(
                    value: 'maintenance',
                    child: ListTile(
                      leading: Icon(Icons.build_outlined),
                      title: Text('Wartung'),
                    ),
                  ),
              ],
              child: const FloatingActionButton(
                onPressed: null,
                child: Icon(Icons.add),
              ),
            )
          : null,
      body: Column(
        children: [
          _toolbar(),
          _filters(),
          if (_dueEvents().isNotEmpty)
            MaterialBanner(
              leading: const Icon(Icons.notifications_active_outlined),
              content: Text(
                '${_dueEvents().length} Termin(e) sind überfällig oder innerhalb der nächsten 7 Tage fällig.',
              ),
              actions: [
                TextButton(onPressed: () {}, child: const Text('Beachten')),
              ],
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : switch (mode) {
                    CalendarViewMode.month => _monthView(visible),
                    CalendarViewMode.week => _weekView(visible),
                    CalendarViewMode.list => _listView(visible),
                  },
          ),
        ],
      ),
    );
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          onPressed: () => _move(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        OutlinedButton(
          onPressed: () {
            setState(() => anchor = DateTime.now());
            _load();
          },
          child: const Text('Heute'),
        ),
        IconButton(
          onPressed: () => _move(1),
          icon: const Icon(Icons.chevron_right),
        ),
        SizedBox(
          width: 220,
          child: Text(_title, style: Theme.of(context).textTheme.titleMedium),
        ),
        SegmentedButton<CalendarViewMode>(
          segments: const [
            ButtonSegment(value: CalendarViewMode.month, label: Text('Monat')),
            ButtonSegment(value: CalendarViewMode.week, label: Text('Woche')),
            ButtonSegment(value: CalendarViewMode.list, label: Text('Liste')),
          ],
          selected: {mode},
          onSelectionChanged: (value) {
            setState(() => mode = value.first);
            _load();
          },
        ),
      ],
    ),
  );

  Widget _filters() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _dropdown('Typ', kindFilter, [
          'Alle',
          'Reservierungen',
          'Wartungen',
          'Prüfungen',
        ], (value) => setState(() => kindFilter = value!)),
        _dropdown('Status', statusFilter, [
          'Alle',
          'Ausstehend',
          'Freigegeben',
          'Geplant',
          'In Arbeit',
          'Ausgegeben',
          'Abgeschlossen',
          'Storniert',
          'Abgelehnt',
          'Abgebrochen',
        ], (value) => setState(() => statusFilter = value!)),
        SizedBox(
          width: 190,
          child: DropdownButtonFormField<String?>(
            initialValue: locationFilter,
            decoration: const InputDecoration(
              labelText: 'Standort',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Alle')),
              ...locations.map(
                (entry) => DropdownMenuItem(
                  value: entry['id']?.toString(),
                  child: Text(entry['name']?.toString() ?? ''),
                ),
              ),
            ],
            onChanged: (value) => setState(() => locationFilter = value),
          ),
        ),
        SizedBox(
          width: 190,
          child: DropdownButtonFormField<String?>(
            initialValue: departmentFilter,
            decoration: const InputDecoration(
              labelText: 'Fachbereich',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('Alle')),
              ...departments.map(
                (value) => DropdownMenuItem(value: value, child: Text(value)),
              ),
            ],
            onChanged: (value) => setState(() => departmentFilter = value),
          ),
        ),
        SizedBox(
          width: 230,
          child: TextField(
            controller: materialFilter,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Material / Inventarnummer',
              isDense: true,
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    ValueChanged<String?> changed,
  ) => SizedBox(
    width: 170,
    child: DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: values
          .map((entry) => DropdownMenuItem(value: entry, child: Text(entry)))
          .toList(),
      onChanged: changed,
    ),
  );

  Widget _monthView(List<Map<String, dynamic>> visible) {
    return Column(
      children: [
        Row(
          children: ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So']
              .map(
                (day) => Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        day,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: .9,
            ),
            itemCount: 42,
            itemBuilder: (_, index) {
              final day = _rangeStart.add(Duration(days: index));
              final dayEvents = visible
                  .where(
                    (entry) => _sameDay(
                      DateTime.parse(entry['startAt'].toString()).toLocal(),
                      day,
                    ),
                  )
                  .toList();
              return Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  color: day.month == anchor.month
                      ? null
                      : Theme.of(context).colorScheme.surfaceContainerLow,
                ),
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${day.day}', textAlign: TextAlign.right),
                    ...dayEvents.take(3).map(_eventChip),
                    if (dayEvents.length > 3)
                      Text('+${dayEvents.length - 3} weitere'),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _weekView(List<Map<String, dynamic>> visible) => ListView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.all(8),
    children: List.generate(7, (index) {
      final day = _rangeStart.add(Duration(days: index));
      final dayEvents = visible
          .where(
            (entry) => _sameDay(
              DateTime.parse(entry['startAt'].toString()).toLocal(),
              day,
            ),
          )
          .toList();
      return SizedBox(
        width: 240,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_weekday(day.weekday)}, ${_date(day)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Divider(),
                Expanded(
                  child: ListView(children: dayEvents.map(_eventCard).toList()),
                ),
              ],
            ),
          ),
        ),
      );
    }),
  );

  Widget _listView(List<Map<String, dynamic>> visible) => visible.isEmpty
      ? const Center(child: Text('Keine Termine im gewählten Zeitraum.'))
      : ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: visible.length,
          itemBuilder: (_, index) => _eventCard(visible[index]),
        );

  Widget _eventChip(Map<String, dynamic> event) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: InkWell(
      onTap: () => _showEvent(event),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        decoration: BoxDecoration(
          color: _eventColor(event).withValues(alpha: .18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          event['title']?.toString() ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
      ),
    ),
  );

  Widget _eventCard(Map<String, dynamic> event) => Card(
    child: ListTile(
      onTap: () => _showEvent(event),
      leading: Icon(_eventIcon(event), color: _eventColor(event)),
      title: Text(event['title']?.toString() ?? ''),
      subtitle: Text(
        '${_dateTime(event['startAt'])} – ${_dateTime(event['endAt'])}\n${_materialLabel(event)}',
      ),
      isThreeLine: true,
      trailing: Chip(label: Text(event['status']?.toString() ?? '')),
    ),
  );

  Future<void> _showEvent(Map<String, dynamic> event) async {
    final kind = event['kind']?.toString();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(event['title']?.toString() ?? 'Termin'),
        content: SizedBox(
          width: 560,
          child: ListView(
            shrinkWrap: true,
            children: [
              _detail('Typ', _kindLabel(kind)),
              _detail('Status', event['status']),
              _detail(
                'Zeitraum',
                '${_dateTime(event['startAt'])} – ${_dateTime(event['endAt'])}',
              ),
              _detail('Material', _materialLabel(event)),
              if (event['requesterName'] != null)
                _detail('Reservierende Person', event['requesterName']),
              if (event['responsible'] != null)
                _detail('Verantwortlich', event['responsible']),
              if (event['description'] != null)
                _detail('Beschreibung', event['description']),
              if (event['provider']?.toString().isNotEmpty == true)
                _detail('Dienstleister', event['provider']),
              if (event['cost'] != null)
                _detail('Kosten', '${event['cost']} €'),
              if (event['note']?.toString().isNotEmpty == true)
                _detail('Notiz', event['note']),
            ],
          ),
        ),
        actions: [
          if (kind == 'reservation' &&
              event['status'] == 'Ausstehend' &&
              event['canManage'] == true)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _mutate(
                  '/api/reservations/${event['id']}/decision',
                  body: {'approved': false},
                );
              },
              child: const Text('Ablehnen'),
            ),
          if (kind == 'reservation' &&
              event['status'] == 'Ausstehend' &&
              event['canManage'] == true)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _mutate(
                  '/api/reservations/${event['id']}/decision',
                  body: {'approved': true},
                );
              },
              child: const Text('Freigeben'),
            ),
          if (kind == 'reservation' &&
              ['Ausstehend', 'Freigegeben'].contains(event['status']) &&
              (event['canManage'] == true || event['canEditOwn'] == true))
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _mutate('/api/reservations/${event['id']}/cancel');
              },
              child: const Text('Stornieren'),
            ),
          if (kind == 'reservation' &&
              event['status'] == 'Freigegeben' &&
              event['canManage'] == true)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _mutate('/api/reservations/${event['id']}/issue');
              },
              child: const Text('Ausgeben'),
            ),
          if (kind == 'reservation' &&
              event['status'] == 'Ausgegeben' &&
              event['canManage'] == true)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _mutate('/api/reservations/${event['id']}/return');
              },
              child: const Text('Rückgabe buchen'),
            ),
          if (kind == 'maintenance' && can('maintenance.manage'))
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _editMaintenance(event);
              },
              child: const Text('Bearbeiten'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, Object? value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SelectableText('$label: ${value ?? '–'}'),
  );

  List<Map<String, dynamic>> _dueEvents() {
    final now = DateTime.now();
    final warning = now.add(const Duration(days: 7));
    return events.where((event) {
      if (![
        'inspection',
        'maintenance',
        'maintenance-due',
      ].contains(event['kind']))
        return false;
      if (['Abgeschlossen', 'Abgebrochen'].contains(event['status']))
        return false;
      final start = DateTime.tryParse(
        event['startAt']?.toString() ?? '',
      )?.toLocal();
      return start != null && start.isBefore(warning);
    }).toList();
  }

  Color _eventColor(Map<String, dynamic> event) => switch (event['kind']) {
    'reservation' => Colors.blue,
    'inspection' => Colors.orange,
    _ => Colors.deepPurple,
  };
  IconData _eventIcon(Map<String, dynamic> event) => switch (event['kind']) {
    'reservation' => Icons.bookmark_outline,
    'inspection' => Icons.fact_check_outlined,
    _ => Icons.build_outlined,
  };
}

class ReservationDialog extends StatefulWidget {
  const ReservationDialog({required this.materials, this.existing, super.key});
  final List<Map<String, dynamic>> materials;
  final Map<String, dynamic>? existing;

  @override
  State<ReservationDialog> createState() => _ReservationDialogState();
}

class _ReservationDialogState extends State<ReservationDialog> {
  final formKey = GlobalKey<FormState>();
  late final purpose = TextEditingController(
    text:
        widget.existing?['title']?.toString() ??
        widget.existing?['purpose']?.toString() ??
        '',
  );
  late final note = TextEditingController(
    text: widget.existing?['note']?.toString() ?? '',
  );
  late DateTime start = widget.existing?['startAt'] == null
      ? DateTime.now().add(const Duration(hours: 1))
      : DateTime.parse(widget.existing!['startAt'].toString()).toLocal();
  late DateTime end = widget.existing?['endAt'] == null
      ? start.add(const Duration(hours: 2))
      : DateTime.parse(widget.existing!['endAt'].toString()).toLocal();
  late final Map<String, int> selected = {
    for (final item in widget.existing?['items'] as List? ?? const [])
      (item as Map)['materialId'].toString():
          int.tryParse(item['quantity'].toString()) ?? 1,
  };

  @override
  void dispose() {
    purpose.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null
          ? 'Reservierung anlegen'
          : 'Reservierung bearbeiten',
    ),
    content: SizedBox(
      width: 680,
      child: Form(
        key: formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            TextFormField(
              controller: purpose,
              maxLength: 255,
              decoration: const InputDecoration(
                labelText: 'Zweck / Veranstaltung *',
              ),
              validator: _required,
            ),
            const SizedBox(height: 8),
            DateTimeTile(
              label: 'Beginn',
              value: start,
              onChanged: (value) => setState(() => start = value),
            ),
            DateTimeTile(
              label: 'Ende',
              value: end,
              onChanged: (value) => setState(() => end = value),
            ),
            const SizedBox(height: 8),
            const Text(
              'Material mit Inventarnummer *',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            ...widget.materials.map((item) {
              final id = item['id'].toString();
              final chosen = selected.containsKey(id);
              return CheckboxListTile(
                value: chosen,
                title: Text('${item['inventoryNumber']} · ${item['name']}'),
                subtitle: item['reservationApprovalRequired'] == true
                    ? const Text('Freigabe durch Materialwart erforderlich')
                    : null,
                onChanged: (value) => setState(() {
                  if (value == true) {
                    selected[id] = 1;
                  } else {
                    selected.remove(id);
                  }
                }),
                secondary: chosen && (item['quantity'] as num? ?? 1) > 1
                    ? SizedBox(
                        width: 80,
                        child: TextFormField(
                          initialValue: '${selected[id]}',
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Menge'),
                          onChanged: (value) =>
                              selected[id] = int.tryParse(value) ?? 0,
                        ),
                      )
                    : null,
              );
            }),
            TextFormField(
              controller: note,
              maxLength: 5000,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notiz (optional)'),
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
      FilledButton(onPressed: _save, child: const Text('Speichern')),
    ],
  );

  void _save() {
    if (formKey.currentState?.validate() != true) return;
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mindestens ein Material auswählen.')),
      );
      return;
    }
    if (!end.isAfter(start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Das Ende muss nach dem Beginn liegen.')),
      );
      return;
    }
    Navigator.pop(context, {
      'purpose': purpose.text.trim(),
      'note': note.text.trim(),
      'startAt': start.toUtc().toIso8601String(),
      'endAt': end.toUtc().toIso8601String(),
      'items': selected.entries
          .map((entry) => {'materialId': entry.key, 'quantity': entry.value})
          .toList(),
    });
  }
}

class MaintenanceDialog extends StatefulWidget {
  const MaintenanceDialog({required this.materials, this.existing, super.key});
  final List<Map<String, dynamic>> materials;
  final Map<String, dynamic>? existing;
  @override
  State<MaintenanceDialog> createState() => _MaintenanceDialogState();
}

class _MaintenanceDialogState extends State<MaintenanceDialog> {
  final formKey = GlobalKey<FormState>();
  late String? materialId = widget.existing?['materialId']?.toString();
  late String status = widget.existing?['status']?.toString() ?? 'Geplant';
  late DateTime start = widget.existing?['startAt'] == null
      ? DateTime.now().add(const Duration(days: 1))
      : DateTime.parse(widget.existing!['startAt'].toString()).toLocal();
  late DateTime end = widget.existing?['endAt'] == null
      ? start.add(const Duration(hours: 2))
      : DateTime.parse(widget.existing!['endAt'].toString()).toLocal();
  late final type = TextEditingController(
    text: widget.existing?['type']?.toString() ?? 'Wartung',
  );
  late final responsible = TextEditingController(
    text: widget.existing?['responsible']?.toString() ?? '',
  );
  late final description = TextEditingController(
    text: widget.existing?['description']?.toString() ?? '',
  );
  late final provider = TextEditingController(
    text: widget.existing?['provider']?.toString() ?? '',
  );
  late final cost = TextEditingController(
    text: widget.existing?['cost']?.toString() ?? '',
  );
  late final completion = TextEditingController(
    text: widget.existing?['completionNote']?.toString() ?? '',
  );

  @override
  void dispose() {
    for (final value in [
      type,
      responsible,
      description,
      provider,
      cost,
      completion,
    ]) {
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Wartung planen' : 'Wartung bearbeiten',
    ),
    content: SizedBox(
      width: 650,
      child: Form(
        key: formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            DropdownButtonFormField<String>(
              initialValue: materialId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Inventarnummer / Material *',
              ),
              items: widget.materials
                  .map(
                    (item) => DropdownMenuItem(
                      value: item['id'].toString(),
                      child: Text(
                        '${item['inventoryNumber']} · ${item['name']}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: widget.existing == null
                  ? (value) => materialId = value
                  : null,
              validator: (value) => value == null ? 'Pflichtfeld' : null,
            ),
            TextFormField(
              controller: type,
              maxLength: 255,
              decoration: const InputDecoration(labelText: 'Art *'),
              validator: _required,
            ),
            TextFormField(
              controller: responsible,
              maxLength: 255,
              decoration: const InputDecoration(
                labelText: 'Verantwortlicher *',
              ),
              validator: _required,
            ),
            DateTimeTile(
              label: 'Beginn',
              value: start,
              onChanged: (value) => setState(() => start = value),
            ),
            DateTimeTile(
              label: 'Ende',
              value: end,
              onChanged: (value) => setState(() => end = value),
            ),
            DropdownButtonFormField<String>(
              initialValue: status,
              decoration: const InputDecoration(labelText: 'Status *'),
              items: ['Geplant', 'In Arbeit', 'Abgeschlossen', 'Abgebrochen']
                  .map(
                    (value) =>
                        DropdownMenuItem(value: value, child: Text(value)),
                  )
                  .toList(),
              onChanged: (value) => setState(() => status = value!),
            ),
            TextFormField(
              controller: description,
              maxLength: 5000,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Beschreibung *'),
              validator: _required,
            ),
            TextFormField(
              controller: provider,
              maxLength: 255,
              decoration: const InputDecoration(
                labelText: 'Dienstleister (optional)',
              ),
            ),
            TextFormField(
              controller: cost,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Kosten (optional)'),
            ),
            TextFormField(
              controller: completion,
              maxLength: 5000,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Abschlussnotiz (optional)',
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
      FilledButton(onPressed: _save, child: const Text('Speichern')),
    ],
  );

  void _save() {
    if (formKey.currentState?.validate() != true || materialId == null) return;
    if (!end.isAfter(start)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Das Ende muss nach dem Beginn liegen.')),
      );
      return;
    }
    Navigator.pop(context, {
      'materialId': materialId,
      'type': type.text.trim(),
      'responsible': responsible.text.trim(),
      'startAt': start.toUtc().toIso8601String(),
      'endAt': end.toUtc().toIso8601String(),
      'status': status,
      'description': description.text.trim(),
      'provider': provider.text.trim(),
      'cost': cost.text.trim().replaceAll(',', '.'),
      'completionNote': completion.text.trim(),
    });
  }
}

class DateTimeTile extends StatelessWidget {
  const DateTimeTile({
    required this.label,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  Future<void> _pick(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      locale: const Locale('de', 'DE'),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time != null)
      onChanged(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      );
  }

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.event_outlined),
    title: Text(label),
    subtitle: Text(_dateTime(value)),
    trailing: const Icon(Icons.edit_calendar_outlined),
    onTap: () => _pick(context),
  );
}

String? _required(String? value) =>
    value == null || value.trim().isEmpty ? 'Pflichtfeld' : null;
bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
String _two(int value) => value.toString().padLeft(2, '0');
String _date(Object? value) {
  final date = value is DateTime
      ? value
      : DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  return date == null
      ? '–'
      : '${_two(date.day)}.${_two(date.month)}.${date.year}';
}

String _dateTime(Object? value) {
  final date = value is DateTime
      ? value
      : DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  return date == null
      ? '–'
      : '${_date(date)}, ${_two(date.hour)}:${_two(date.minute)} Uhr';
}

String _month(int month) => const [
  'Januar',
  'Februar',
  'März',
  'April',
  'Mai',
  'Juni',
  'Juli',
  'August',
  'September',
  'Oktober',
  'November',
  'Dezember',
][month - 1];
String _weekday(int day) => const [
  'Montag',
  'Dienstag',
  'Mittwoch',
  'Donnerstag',
  'Freitag',
  'Samstag',
  'Sonntag',
][day - 1];
String _kindLabel(String? kind) => switch (kind) {
  'reservation' => 'Reservierung',
  'inspection' => 'Prüfung',
  'maintenance-due' => 'Wartungstermin',
  _ => 'Wartung',
};
String _materialLabel(Map<String, dynamic> event) {
  final values =
      [
            event['inventoryNumber'],
            ...(event['inventoryNumbers'] as List? ?? const []),
          ]
          .where((value) => value != null && value.toString().isNotEmpty)
          .map((value) => value.toString())
          .toSet();
  return values.isEmpty ? '–' : values.join(', ');
}
