import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';

class AdminNoticesPage extends StatefulWidget {
  final String token;

  const AdminNoticesPage({required this.token, super.key});

  @override
  State<AdminNoticesPage> createState() => _AdminNoticesPageState();
}

class _AdminNoticesPageState extends State<AdminNoticesPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _notices = [];

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/admin/notices'),
        headers: _headers,
      );
      if (response.statusCode != 200) throw Exception(_error(response));
      if (!mounted) return;
      setState(() {
        _notices = (jsonDecode(response.body) as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _error(http.Response response) {
    try {
      return jsonDecode(response.body)['error']?.toString() ??
          'Anfrage fehlgeschlagen';
    } catch (_) {
      return 'Anfrage fehlgeschlagen (${response.statusCode})';
    }
  }

  Future<void> _edit([Map<String, dynamic>? notice]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NoticeDialog(notice: notice),
    );
    if (result == null) return;
    final response = notice == null
        ? await http.post(
            Uri.parse('$apiBaseUrl/api/admin/notices'),
            headers: _headers,
            body: jsonEncode(result),
          )
        : await http.put(
            Uri.parse('$apiBaseUrl/api/admin/notices/${notice['id']}'),
            headers: _headers,
            body: jsonEncode(result),
          );
    if (!mounted) return;
    if (response.statusCode != 200 && response.statusCode != 201) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_error(response))));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              notice == null ? 'Hinweis erstellt.' : 'Hinweis gespeichert.')),
    );
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> notice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hinweis löschen?'),
        content: Text(
          '„${notice['title']?.toString().isNotEmpty == true ? notice['title'] : notice['message']}“ wird dauerhaft gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final response = await http.delete(
      Uri.parse('$apiBaseUrl/api/admin/notices/${notice['id']}'),
      headers: _headers,
    );
    if (!mounted) return;
    if (response.statusCode != 204) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_error(response))));
      return;
    }
    await _load();
  }

  String _period(Map<String, dynamic> notice) {
    String format(Object? value) {
      final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
      if (date == null) return '';
      String two(int number) => number.toString().padLeft(2, '0');
      return '${two(date.day)}.${two(date.month)}.${date.year}, ${two(date.hour)}:${two(date.minute)} Uhr';
    }

    final start = format(notice['startsAt']);
    final end = format(notice['endsAt']);
    if (start.isEmpty && end.isEmpty) return 'Ohne Zeitbegrenzung';
    if (start.isEmpty) return 'Bis $end';
    if (end.isEmpty) return 'Ab $start';
    return '$start bis $end';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hinweise verwalten')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Hinweis'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _notices.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Icon(Icons.campaign_outlined, size: 56),
                        SizedBox(height: 16),
                        Center(child: Text('Noch keine Hinweise vorhanden.')),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _notices.length,
                      itemBuilder: (context, index) {
                        final notice = _notices[index];
                        return Card(
                          child: ListTile(
                            leading:
                                Icon(_levelIcon(notice['level']?.toString())),
                            title: Text(
                              notice['title']?.toString().isNotEmpty == true
                                  ? notice['title'].toString()
                                  : 'Hinweis',
                            ),
                            subtitle: Text(
                              '${notice['message']}\n${_period(notice)}'
                              '${notice['active'] == false ? '\nDeaktiviert' : ''}',
                            ),
                            isThreeLine: true,
                            onTap: () => _edit(notice),
                            trailing: IconButton(
                              tooltip: 'Löschen',
                              onPressed: () => _delete(notice),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

IconData _levelIcon(String? level) {
  return switch (level) {
    'critical' => Icons.error_outline,
    'warning' => Icons.warning_amber_rounded,
    _ => Icons.info_outline,
  };
}

class _NoticeDialog extends StatefulWidget {
  final Map<String, dynamic>? notice;

  const _NoticeDialog({this.notice});

  @override
  State<_NoticeDialog> createState() => _NoticeDialogState();
}

class _NoticeDialogState extends State<_NoticeDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _message;
  late String _level;
  late bool _active;
  DateTime? _startsAt;
  DateTime? _endsAt;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.notice?['title']?.toString());
    _message =
        TextEditingController(text: widget.notice?['message']?.toString());
    _level = widget.notice?['level']?.toString() ?? 'info';
    _active = widget.notice?['active'] != false;
    _startsAt = DateTime.tryParse(widget.notice?['startsAt']?.toString() ?? '')
        ?.toLocal();
    _endsAt = DateTime.tryParse(widget.notice?['endsAt']?.toString() ?? '')
        ?.toLocal();
  }

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  String _format(DateTime? value) {
    if (value == null) return 'Nicht festgelegt';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.day)}.${two(value.month)}.${value.year}, ${two(value.hour)}:${two(value.minute)} Uhr';
  }

  Future<void> _pick(bool start) async {
    final current = (start ? _startsAt : _endsAt) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null) return;
    final value =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (start) {
        _startsAt = value;
      } else {
        _endsAt = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
          widget.notice == null ? 'Hinweis erstellen' : 'Hinweis bearbeiten'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _title,
                  maxLength: 120,
                  decoration:
                      const InputDecoration(labelText: 'Titel (optional)'),
                ),
                TextFormField(
                  controller: _message,
                  maxLength: 2000,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(labelText: 'Hinweistext *'),
                  validator: (value) => value?.trim().isEmpty == true
                      ? 'Bitte einen Hinweistext eingeben.'
                      : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _level,
                  decoration: const InputDecoration(labelText: 'Priorität'),
                  items: const [
                    DropdownMenuItem(value: 'info', child: Text('Information')),
                    DropdownMenuItem(value: 'warning', child: Text('Warnung')),
                    DropdownMenuItem(
                        value: 'critical', child: Text('Kritisch')),
                  ],
                  onChanged: (value) =>
                      setState(() => _level = value ?? 'info'),
                ),
                const SizedBox(height: 12),
                _DateRow(
                  label: 'Anzeigen ab',
                  value: _format(_startsAt),
                  onPick: () => _pick(true),
                  onClear: _startsAt == null
                      ? null
                      : () => setState(() => _startsAt = null),
                ),
                _DateRow(
                  label: 'Anzeigen bis',
                  value: _format(_endsAt),
                  onPick: () => _pick(false),
                  onClear: _endsAt == null
                      ? null
                      : () => setState(() => _endsAt = null),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hinweis aktiv'),
                  value: _active,
                  onChanged: (value) => setState(() => _active = value),
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
            if (!_formKey.currentState!.validate()) return;
            if (_startsAt != null &&
                _endsAt != null &&
                !_endsAt!.isAfter(_startsAt!)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Das Ende muss nach dem Beginn liegen.')),
              );
              return;
            }
            Navigator.pop(context, {
              'title': _title.text.trim(),
              'message': _message.text.trim(),
              'level': _level,
              'active': _active,
              'startsAt': _startsAt?.toUtc().toIso8601String(),
              'endsAt': _endsAt?.toUtc().toIso8601String(),
            });
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  const _DateRow({
    required this.label,
    required this.value,
    required this.onPick,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(value),
      onTap: onPick,
      trailing: onClear == null
          ? const Icon(Icons.calendar_today_outlined)
          : IconButton(
              tooltip: 'Zeitpunkt entfernen',
              onPressed: onClear,
              icon: const Icon(Icons.clear),
            ),
    );
  }
}
