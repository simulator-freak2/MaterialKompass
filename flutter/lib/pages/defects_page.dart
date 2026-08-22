import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/authenticated_api_client.dart';
import '../services/debouncer.dart';
import '../services/file_save_mime_type.dart';
import '../widgets/date_input_field.dart';

const _statuses = <String>[
  'Neu',
  'In Prüfung',
  'Zugewiesen',
  'In Bearbeitung',
  'Behoben',
  'Geprüft/Geschlossen',
];
const _priorities = <String>['Niedrig', 'Normal', 'Hoch', 'Kritisch'];
const _nextStatus = <String, String>{
  'Neu': 'In Prüfung',
  'In Prüfung': 'Zugewiesen',
  'Zugewiesen': 'In Bearbeitung',
  'In Bearbeitung': 'Behoben',
  'Behoben': 'Geprüft/Geschlossen',
};

typedef DefectRequest = Future<dynamic> Function(
  String path, {
  String method,
  Map<String, dynamic>? body,
});

class DefectsPage extends StatefulWidget {
  final String token;
  final String? initialEntityType;
  final String? initialEntityId;
  final DefectRequest? request;

  const DefectsPage({
    required this.token,
    this.initialEntityType,
    this.initialEntityId,
    this.request,
    super.key,
  });

  @override
  State<DefectsPage> createState() => _DefectsPageState();
}

class _DefectsPageState extends State<DefectsPage> {
  final _searchDebouncer = Debouncer();
  bool _loading = true;
  bool _showArchived = false;
  String _search = '';
  String _status = 'Alle';
  String _priority = 'Alle';
  String _entityType = 'Alle';
  String? _currentUserId;
  bool _onlyMine = false;
  String? _selectedDefectId;
  Map<String, dynamic>? _selectedDetail;
  bool _detailLoading = false;
  List<Map<String, dynamic>> _defects = [];
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _notifications = [];
  List<Map<String, dynamic>> _emailImports = [];
  Set<String> _permissions = {};
  Set<String> _roles = {};
  bool _initialCreateOpened = false;

  AuthenticatedApiClient get _api => AuthenticatedApiClient(widget.token);

  bool _can(String permission) =>
      _roles.contains('Admin') || _permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebouncer.dispose();
    super.dispose();
  }

  Future<dynamic> _request(String path,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    try {
      if (widget.request != null) {
        return await widget.request!(path, method: method, body: body);
      }
      return await _api.request(path, method: method, body: body);
    } on AuthenticatedApiException catch (error) {
      if (mounted) _message(error.message);
      return null;
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final me = await _request('/api/auth/me');
    if (me is! Map) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final user = Map<String, dynamic>.from(me['user'] as Map);
    _currentUserId = user['id']?.toString();
    _permissions = (user['permissions'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet();
    _roles = (user['roles'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet();

    final requests = <Future<dynamic>>[
      _request('/api/defects?archived=${_showArchived ? 'all' : 'false'}'),
      _request('/api/notifications'),
      _request('/api/defect-email-imports'),
      _request('/api/defect-report-items'),
    ];
    final results = await Future.wait(requests);
    if (!mounted) return;
    setState(() {
      _defects = results[0] is List
          ? (results[0] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : [];
      _notifications = results[1] is List
          ? (results[1] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : [];
      _emailImports = results[2] is List
          ? (results[2] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : [];
      _items = results[3] is List
          ? (results[3] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : [];
      if (_selectedDefectId != null) _selectedDetail = null;
      _loading = false;
    });
    await _ensureSelection();
    if (!_initialCreateOpened && widget.initialEntityId != null) {
      _initialCreateOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _create(
            initialEntityType: widget.initialEntityType,
            initialEntityId: widget.initialEntityId,
          );
        }
      });
    }
  }

  Future<void> _ensureSelection() async {
    if (!mounted) return;
    final visible = _filtered;
    if (visible.isEmpty) {
      if (_selectedDefectId != null || _selectedDetail != null) {
        setState(() {
          _selectedDefectId = null;
          _selectedDetail = null;
          _detailLoading = false;
        });
      }
      return;
    }
    final selectedStillVisible =
        visible.any((entry) => entry['id']?.toString() == _selectedDefectId);
    if (!selectedStillVisible) {
      await _selectDefect(visible.first, openOnCompact: false);
    } else if (_selectedDetail == null && !_detailLoading) {
      await _selectDefect(
        visible.firstWhere(
            (entry) => entry['id']?.toString() == _selectedDefectId),
        openOnCompact: false,
      );
    }
  }

  void _changeFilter(VoidCallback change) {
    setState(change);
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelection());
  }

  Future<void> _selectDefect(Map<String, dynamic> summary,
      {bool openOnCompact = true}) async {
    final compact = MediaQuery.sizeOf(context).width < 1050;
    if (openOnCompact && compact) {
      await _showDetail(summary);
      return;
    }
    final id = summary['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() {
      _selectedDefectId = id;
      _detailLoading = true;
      if (_selectedDetail?['id']?.toString() != id) _selectedDetail = null;
    });
    final loaded = await _request('/api/defects/$id');
    if (!mounted || _selectedDefectId != id) return;
    setState(() {
      _selectedDetail = loaded is Map
          ? Map<String, dynamic>.from(loaded)
          : Map<String, dynamic>.from(summary);
      _detailLoading = false;
    });
  }

  Future<void> _refreshSelected() async {
    final id = _selectedDefectId;
    if (id == null) return;
    final summary = _defects.cast<Map<String, dynamic>?>().firstWhere(
          (entry) => entry?['id']?.toString() == id,
          orElse: () => _selectedDetail,
        );
    if (summary != null) await _selectDefect(summary, openOnCompact: false);
  }

  Future<void> _replaceSelected(dynamic result,
      {bool reloadList = true}) async {
    if (result is! Map || !mounted) return;
    final updated = Map<String, dynamic>.from(result);
    setState(() {
      _selectedDefectId = updated['id']?.toString();
      _selectedDetail = updated;
      final index = _defects.indexWhere(
          (entry) => entry['id']?.toString() == updated['id']?.toString());
      if (index >= 0) _defects[index] = updated;
    });
    if (reloadList) {
      final data = await _request(
          '/api/defects?archived=${_showArchived ? 'all' : 'false'}');
      if (data is List && mounted) {
        setState(() {
          _defects = data
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList();
        });
      }
      final selectedId = _selectedDefectId;
      if (selectedId != null) {
        final full = await _request('/api/defects/$selectedId');
        if (full is Map && mounted && _selectedDefectId == selectedId) {
          setState(() => _selectedDetail = Map<String, dynamic>.from(full));
        }
      }
      await _ensureSelection();
    }
  }

  List<Map<String, dynamic>> get _filtered => _defects.where((defect) {
        final haystack = [
          defect['defectNumber'],
          defect['title'],
          defect['description'],
          defect['entityName'],
          defect['inventoryNumber'],
          defect['assignee'],
          defect['contactName'],
          defect['contactEmail'],
          defect['contactPhone'],
        ].join(' ').toLowerCase();
        return haystack.contains(_search.toLowerCase()) &&
            (_status == 'Alle' || defect['status'] == _status) &&
            (_priority == 'Alle' || defect['priority'] == _priority) &&
            (_entityType == 'Alle' || defect['entityType'] == _entityType) &&
            (!_onlyMine || defect['assigneeUserId'] == _currentUserId);
      }).toList();

  Future<void> _create(
      {String? initialEntityType, String? initialEntityId}) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _DefectFormDialog(
        items: _items,
        initialEntityType: initialEntityType,
        initialEntityId: initialEntityId,
      ),
    );
    if (payload == null) return;
    final pendingImages =
        (payload.remove('_pendingImages') as List? ?? const [])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
    final created =
        await _request('/api/defects', method: 'POST', body: payload);
    if (created is Map) {
      if (created['offlineQueued'] == true) {
        _message(pendingImages.isEmpty
            ? 'Mangel wurde offline gespeichert und wird später synchronisiert.'
            : 'Mangel wurde offline gespeichert. Bilder werden offline nicht übernommen.');
        await _load();
        return;
      }
      var uploadedImages = 0;
      for (final image in pendingImages) {
        final uploaded = await _request('/api/defects/${created['id']}/images',
            method: 'POST', body: image);
        if (uploaded != null) uploadedImages += 1;
      }
      _message(pendingImages.isEmpty
          ? 'Mangel wurde erfasst und der Artikel als defekt markiert.'
          : 'Mangel wurde erfasst; $uploadedImages von ${pendingImages.length} Bildern wurden hochgeladen.');
      await _load();
    }
  }

  Future<void> _export(String format) async {
    final data = await _request('/api/defects/export?format=$format');
    if (data is! Map) return;
    final fileName = data['fileName'].toString();
    final dot = fileName.lastIndexOf('.');
    await FileSaver.instance.saveFile(
      name: dot > 0 ? fileName.substring(0, dot) : fileName,
      bytes: base64Decode(data['fileBase64'].toString()),
      fileExtension: dot > 0 ? fileName.substring(dot + 1) : format,
      mimeType: MimeType.custom,
      customMimeType: data['mimeType']?.toString() ?? fileMimeType(format),
    );
    if (mounted) _message('$fileName wurde erstellt.');
  }

  Future<void> _saveDownloadPayload(Map data) async {
    final fileName = data['fileName'].toString();
    final dot = fileName.lastIndexOf('.');
    await FileSaver.instance.saveFile(
      name: dot > 0 ? fileName.substring(0, dot) : fileName,
      bytes: base64Decode(data['fileBase64'].toString()),
      fileExtension: dot > 0 ? fileName.substring(dot + 1) : 'bin',
      mimeType: MimeType.custom,
      customMimeType:
          data['mimeType']?.toString() ?? 'application/octet-stream',
    );
    if (mounted) _message('$fileName wurde heruntergeladen.');
  }

  Future<void> _downloadTemplate() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mängelbericht herunterladen'),
        content: const Text(
            'Die Vorlage kann leer oder mit Inventarnummer und Kontaktdaten vorbefüllt erstellt werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          OutlinedButton(
              onPressed: () => Navigator.pop(context, 'blank'),
              child: const Text('Leere Vorlage')),
          FilledButton(
              onPressed: _items.isEmpty
                  ? null
                  : () => Navigator.pop(context, 'prefilled'),
              child: const Text('Vorbefüllt')),
        ],
      ),
    );
    if (choice == null) return;
    if (!mounted) return;
    String path = '/api/defect-report-template';
    if (choice == 'prefilled') {
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Artikel auswählen'),
          content: SizedBox(
            width: 560,
            height: 420,
            child: ListView(
              children: ([..._items]..sort((left, right) =>
                      left['inventoryNumber']
                          .toString()
                          .compareTo(right['inventoryNumber'].toString())))
                  .map((item) => ListTile(
                        leading: Icon(item['entityType'] == 'MaterialItem'
                            ? Icons.inventory_2_outlined
                            : Icons.checkroom_outlined),
                        title: Text(item['name']?.toString() ?? ''),
                        subtitle:
                            Text(item['inventoryNumber']?.toString() ?? ''),
                        onTap: () => Navigator.pop(context, item),
                      ))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
          ],
        ),
      );
      if (selected == null) return;
      path =
          '/api/defect-report-template?entityType=${Uri.encodeQueryComponent(selected['entityType'].toString())}'
          '&entityId=${Uri.encodeQueryComponent(selected['id'].toString())}';
    }
    final data = await _request(path);
    if (data is Map) await _saveDownloadPayload(data);
  }

  Future<void> _showNotifications() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Benachrichtigungen'),
        content: SizedBox(
          width: 520,
          child: _notifications.isEmpty
              ? const Text('Keine Benachrichtigungen vorhanden.')
              : ListView(
                  shrinkWrap: true,
                  children: _notifications
                      .map((notification) => ListTile(
                            leading: Icon(notification['readAt'] == null
                                ? Icons.notifications_active
                                : Icons.notifications_none),
                            title:
                                Text(notification['title']?.toString() ?? ''),
                            subtitle:
                                Text(notification['message']?.toString() ?? ''),
                            onTap: () async {
                              await _request(
                                  '/api/notifications/${notification['id']}/read',
                                  method: 'PATCH');
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                              await _load();
                            },
                          ))
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Schließen')),
        ],
      ),
    );
  }

  Future<void> _showEmailQueue() async {
    final pending =
        _emailImports.where((entry) => entry['status'] == 'pending').toList();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Prüfwarteschlange (${pending.length})'),
        content: SizedBox(
          width: 680,
          height: 480,
          child: pending.isEmpty
              ? const Center(
                  child: Text('Keine E-Mail-Meldungen müssen geprüft werden.'))
              : ListView.separated(
                  itemCount: pending.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final entry = pending[index];
                    final problems =
                        (entry['problems'] as List? ?? const []).length;
                    return ListTile(
                      leading: const Icon(Icons.mark_email_unread_outlined),
                      title: Text(
                          entry['subject']?.toString().isNotEmpty == true
                              ? entry['subject'].toString()
                              : 'Mängelmeldung ohne Betreff'),
                      subtitle: Text(
                          '${entry['sender']?.toString().isNotEmpty == true ? entry['sender'] : 'Unbekannter Absender'}'
                          ' · $problems Prüfhinweis${problems == 1 ? '' : 'e'}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        Navigator.pop(dialogContext);
                        await _reviewEmailImport(entry);
                        await _load();
                        if (mounted) await _showEmailQueue();
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Schließen')),
        ],
      ),
    );
  }

  Future<void> _reviewEmailImport(Map<String, dynamic> summary) async {
    final response =
        await _request('/api/defect-email-imports/${summary['id']}');
    if (response is! Map || !mounted) return;
    final entry = Map<String, dynamic>.from(response);
    final extracted =
        Map<String, dynamic>.from(entry['extractedData'] as Map? ?? const {});
    Map<String, dynamic>? selectedItem;
    for (final item in _items) {
      if (item['inventoryNumber']?.toString() ==
          extracted['inventoryNumber']?.toString()) {
        selectedItem = item;
        break;
      }
    }
    final description =
        TextEditingController(text: extracted['description']?.toString() ?? '');
    final measuresTaken = TextEditingController(
        text: extracted['measuresTaken']?.toString() ??
            extracted['cause']?.toString() ??
            '');
    final name =
        TextEditingController(text: extracted['contactName']?.toString() ?? '');
    final email = TextEditingController(
        text: extracted['contactEmail']?.toString() ?? '');
    final phone = TextEditingController(
        text: extracted['contactPhone']?.toString() ?? '');
    final reason = TextEditingController();
    const safetyValues = [
      'Nicht einsatzfähig',
      'Eingeschränkt',
      'Einsatzfähig'
    ];
    String? safety = safetyValues.contains(extracted['operationalSafety'])
        ? extracted['operationalSafety'].toString()
        : null;
    final completed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final problems = (entry['problems'] as List? ?? const [])
              .map((value) => value.toString());
          final attachments = (entry['attachments'] as List? ?? const [])
              .map((value) => Map<String, dynamic>.from(value as Map));
          return AlertDialog(
            title: const Text('E-Mail-Meldung prüfen'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry['subject']?.toString() ?? '',
                        style: Theme.of(context).textTheme.titleMedium),
                    Text(
                        '${entry['senderName'] ?? ''} <${entry['sender'] ?? ''}>'),
                    if (problems.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Automatische Prüfung',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              ...problems.map((problem) => Text('• $problem')),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    DropdownButtonFormField<Map<String, dynamic>>(
                      initialValue: selectedItem,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'Betroffener Artikel *'),
                      items: _items
                          .map((item) => DropdownMenuItem(
                                value: item,
                                child: Text(
                                    '${item['inventoryNumber']} · ${item['name']}'),
                              ))
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => selectedItem = value),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: description,
                      maxLines: 5,
                      decoration:
                          const InputDecoration(labelText: 'Beschreibung *'),
                    ),
                    TextField(
                      controller: measuresTaken,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'Getroffene Maßnahmen'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: safety,
                      decoration: const InputDecoration(
                          labelText: 'Einsatzbereitschaft *'),
                      items: safetyValues
                          .map((value) => DropdownMenuItem(
                              value: value, child: Text(value)))
                          .toList(),
                      onChanged: (value) =>
                          setDialogState(() => safety = value),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                        controller: name,
                        decoration: const InputDecoration(
                            labelText: 'Name der meldenden Person *')),
                    TextField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                            labelText: 'E-Mail der meldenden Person *')),
                    TextField(
                        controller: phone,
                        decoration:
                            const InputDecoration(labelText: 'Telefonnummer')),
                    const SizedBox(height: 16),
                    Text('Anhänge',
                        style: Theme.of(context).textTheme.titleMedium),
                    Wrap(
                      spacing: 8,
                      children: attachments
                          .map((attachment) => ActionChip(
                                avatar: Icon(attachment['role'] == 'report'
                                    ? Icons.description_outlined
                                    : Icons.image_outlined),
                                label: Text(
                                    attachment['fileName']?.toString() ?? ''),
                                onPressed: attachment['fileBase64'] == null
                                    ? null
                                    : () => _saveDownloadPayload({
                                          'fileName': attachment['fileName'],
                                          'mimeType': attachment['mimeType'],
                                          'fileBase64':
                                              attachment['fileBase64'],
                                        }),
                              ))
                          .toList(),
                    ),
                    if (entry['emailText']?.toString().isNotEmpty == true) ...[
                      const SizedBox(height: 16),
                      Text('E-Mail-Text',
                          style: Theme.of(context).textTheme.titleMedium),
                      SelectableText(entry['emailText'].toString()),
                    ],
                    if (_can('defects.edit')) ...[
                      const SizedBox(height: 16),
                      TextField(
                          controller: reason,
                          decoration: const InputDecoration(
                              labelText: 'Grund beim Verwerfen')),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Schließen')),
              if (_can('defects.edit'))
                TextButton.icon(
                    onPressed: () async {
                      final discarded = await _request(
                          '/api/defect-email-imports/${entry['id']}/discard',
                          method: 'POST',
                          body: {'reason': reason.text.trim()});
                      if (discarded != null && dialogContext.mounted) {
                        Navigator.pop(dialogContext, true);
                      }
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Verwerfen')),
              if (_can('defects.report'))
                FilledButton.icon(
                    onPressed: () async {
                      if (selectedItem == null ||
                          description.text.trim().isEmpty ||
                          safety == null ||
                          name.text.trim().isEmpty ||
                          email.text.trim().isEmpty) {
                        _message('Bitte alle Pflichtfelder ergänzen.');
                        return;
                      }
                      final created = await _request(
                          '/api/defect-email-imports/${entry['id']}/process',
                          method: 'POST',
                          body: {
                            'inventoryNumber':
                                selectedItem!['inventoryNumber'].toString(),
                            'description': description.text.trim(),
                            'measuresTaken': measuresTaken.text.trim(),
                            'operationalSafety': safety,
                            'contactName': name.text.trim(),
                            'contactEmail': email.text.trim(),
                            'contactPhone': phone.text.trim(),
                          });
                      if (created != null && dialogContext.mounted) {
                        _message('E-Mail-Meldung wurde als Mangel angelegt.');
                        Navigator.pop(dialogContext, true);
                      }
                    },
                    icon: const Icon(Icons.check),
                    label: const Text('Mangel anlegen')),
            ],
          );
        },
      ),
    );
    description.dispose();
    measuresTaken.dispose();
    name.dispose();
    email.dispose();
    phone.dispose();
    reason.dispose();
    if (completed == true) await _load();
  }

  Future<bool> _saveSelected(Map<String, dynamic> payload) async {
    final detail = _selectedDetail;
    if (detail == null) return false;
    final result = await _request('/api/defects/${detail['id']}',
        method: 'PUT', body: payload);
    if (result is! Map) return false;
    await _replaceSelected(result);
    if (mounted) _message('Änderungen wurden gespeichert.');
    return true;
  }

  Future<void> _assignSelected({bool assignToMe = false}) async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final entityType = detail['entityType']?.toString() ?? '';
    final result = await _request(
        '/api/defects/assignees?entityType=${Uri.encodeQueryComponent(entityType)}');
    if (result is! List || !mounted) return;
    final assignees =
        result.map((entry) => Map<String, dynamic>.from(entry as Map)).toList();
    Map<String, dynamic>? payload;
    if (assignToMe) {
      final currentIsAssignable =
          assignees.any((entry) => entry['id']?.toString() == _currentUserId);
      if (!currentIsAssignable) {
        _message('Du kannst für diesen Mängelbereich nicht zugewiesen werden.');
        return;
      }
      payload = {
        'assigneeUserId': _currentUserId,
        'responsibleDepartment':
            detail['responsibleDepartment']?.toString() ?? '',
        'dueDate': detail['dueDate'],
      };
    } else {
      payload = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _DefectAssignmentDialog(
          defect: detail,
          assignees: assignees,
        ),
      );
    }
    if (payload == null) return;
    await _replaceSelected(await _request('/api/defects/${detail['id']}/assign',
        method: 'POST', body: payload));
  }

  Future<void> _transitionSelected({String? status}) async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final target = status ?? _nextStatus[detail['status']];
    if (target == null) return;
    if (target == 'Geprüft/Geschlossen' &&
        (detail['resolution']?.toString().trim().isEmpty ?? true)) {
      _message('Bitte dokumentiere vor dem Schließen die Behebung.');
      return;
    }
    await _replaceSelected(await _request(
        '/api/defects/${detail['id']}/transition',
        method: 'POST',
        body: {'status': target}));
  }

  Future<void> _printSelected() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final data = await _request('/api/defects/${detail['id']}/print');
    if (data is Map) await _saveDownloadPayload(data);
  }

  Future<void> _addSelectedComment(String value) async {
    final detail = _selectedDetail;
    if (detail == null || value.trim().isEmpty) return;
    final result = await _request('/api/defects/${detail['id']}/comments',
        method: 'POST', body: {'text': value.trim()});
    if (result != null) await _refreshSelected();
  }

  Future<void> _addSelectedChecklist(String value) async {
    final detail = _selectedDetail;
    if (detail == null || value.trim().isEmpty) return;
    final result = await _request('/api/defects/${detail['id']}/checklist',
        method: 'POST', body: {'label': value.trim()});
    if (result != null) await _refreshSelected();
  }

  Future<void> _toggleSelectedChecklist(String itemId, bool done) async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final result = await _request(
        '/api/defects/${detail['id']}/checklist/$itemId',
        method: 'PATCH',
        body: {'done': done});
    if (result != null) await _refreshSelected();
  }

  Future<void> _addSelectedFollowUp() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final label = TextEditingController();
    final assignee = TextEditingController();
    final dueDate = TextEditingController();
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Folgeaufgabe hinzufügen'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: label,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Aufgabe *')),
            TextField(
                controller: assignee,
                decoration: const InputDecoration(labelText: 'Verantwortlich')),
            DateInputField(controller: dueDate, label: 'Frist'),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'label': label.text.trim(),
                    'assignee': assignee.text.trim(),
                    'dueDate': dateInputToIso(dueDate.text),
                  }),
              child: const Text('Hinzufügen')),
        ],
      ),
    );
    label.dispose();
    assignee.dispose();
    dueDate.dispose();
    if (payload == null || payload['label'].toString().isEmpty) return;
    final result = await _request(
        '/api/defects/${detail['id']}/follow-up-tasks',
        method: 'POST',
        body: payload);
    if (result != null) await _refreshSelected();
  }

  Future<void> _toggleSelectedFollowUp(String taskId, bool done) async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final result = await _request(
        '/api/defects/${detail['id']}/follow-up-tasks/$taskId',
        method: 'PATCH',
        body: {'done': done});
    if (result != null) await _refreshSelected();
  }

  Future<void> _addSelectedRelatedAction() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final label = TextEditingController();
    final reference = TextEditingController();
    var type = 'Reparatur';
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Vorgang verknüpfen'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Art'),
                items: const ['Reparatur', 'Beschaffung']
                    .map((value) =>
                        DropdownMenuItem(value: value, child: Text(value)))
                    .toList(),
                onChanged: (value) =>
                    setDialogState(() => type = value ?? type),
              ),
              TextField(
                  controller: label,
                  autofocus: true,
                  decoration:
                      const InputDecoration(labelText: 'Bezeichnung *')),
              TextField(
                  controller: reference,
                  decoration: const InputDecoration(
                      labelText: 'Vorgangs-/Referenz-ID')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context, {
                      'type': type,
                      'label': label.text.trim(),
                      'referenceId': reference.text.trim(),
                    }),
                child: const Text('Verknüpfen')),
          ],
        ),
      ),
    );
    label.dispose();
    reference.dispose();
    if (payload == null || payload['label'].toString().isEmpty) return;
    final result = await _request(
        '/api/defects/${detail['id']}/related-actions',
        method: 'POST',
        body: payload);
    if (result != null) await _refreshSelected();
  }

  Future<void> _addSelectedImage() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 8 * 1024 * 1024) {
      _message('Ein Bild darf höchstens 8 MB groß sein.');
      return;
    }
    final extension = file.name.split('.').last.toLowerCase();
    final uploaded = await _request('/api/defects/${detail['id']}/images',
        method: 'POST',
        body: {
          'fileName': file.name,
          'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
          'fileBase64': base64Encode(bytes),
        });
    if (uploaded != null) await _refreshSelected();
  }

  Future<void> _deleteSelectedImage(String imageId) async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final result = await _request(
        '/api/defects/${detail['id']}/images/$imageId',
        method: 'DELETE');
    if (result != null) await _refreshSelected();
  }

  Future<void> _archiveSelected() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    await _replaceSelected(
        await _request('/api/defects/${detail['id']}/archive', method: 'POST'));
  }

  Future<void> _disposeSelectedWithoutReplacement() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final quantity = TextEditingController(
        text: detail['affectedQuantity']?.toString() ?? '1');
    final reason = TextEditingController(
        text:
            'Aussonderung ohne Ersatz wegen Mangel ${detail['defectNumber']}.');
    final inventoryNumber = detail['inventoryNumber']?.toString() ?? '-';
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aussondern ohne Ersatz'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  'Inventarnummer: $inventoryNumber\n\nBei vollständiger Aussonderung wird die Inventarnummer freigegeben. Diese Aktion kann nicht rückgängig gemacht werden.'),
              const SizedBox(height: 12),
              TextField(
                  controller: quantity,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Auszusondernde Menge *',
                      helperText:
                          'Bei einer Teilmenge bleibt die Inventarnummer belegt.')),
              TextField(
                  controller: reason,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Begründung *')),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white),
            onPressed: () {
              final parsed = num.tryParse(quantity.text.replaceAll(',', '.'));
              if (parsed == null || parsed <= 0 || reason.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Bitte Menge und Begründung vollständig angeben.')));
                return;
              }
              Navigator.pop(context, {
                'disposalQuantity': parsed,
                'reason': reason.text.trim(),
              });
            },
            icon: const Icon(Icons.delete_forever),
            label: const Text('Endgültig aussondern'),
          ),
        ],
      ),
    );
    quantity.dispose();
    reason.dispose();
    if (payload == null) return;
    final result = await _request(
        '/api/defects/${detail['id']}/dispose-without-replacement',
        method: 'POST',
        body: payload);
    if (result is Map && result['defect'] is Map) {
      final updated = Map<String, dynamic>.from(result['defect'] as Map);
      final disposal = updated['disposal'] as Map?;
      _message(disposal?['inventoryNumberReleased'] == true
          ? 'Artikel ausgesondert; Inventarnummer ${disposal?['inventoryNumber'] ?? inventoryNumber} wurde freigegeben.'
          : 'Teilmenge ausgesondert; die Inventarnummer bleibt belegt.');
      await _replaceSelected(updated);
    }
  }

  Future<void> _disposeSelectedAndProcure() async {
    final detail = _selectedDetail;
    if (detail == null) return;
    final disposalQuantity = TextEditingController(
        text: detail['affectedQuantity']?.toString() ?? '1');
    final replacementQuantity = TextEditingController(
        text: detail['affectedQuantity']?.toString() ?? '1');
    final budget =
        TextEditingController(text: detail['estimatedCost']?.toString() ?? '');
    final reason = TextEditingController(
        text:
            'Ersatzbeschaffung nach Aussonderung wegen Mangel ${detail['defectNumber']}.');
    final department = TextEditingController(
        text: detail['responsibleDepartment']?.toString() ?? '');
    final costCenter = TextEditingController();
    final desiredDate = TextEditingController();
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aussondern und Ersatz beschaffen'),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'Der Artikel wird ausgesondert und gleichzeitig ein vorbefüllter Beschaffungsentwurf angelegt.'),
              TextField(
                  controller: disposalQuantity,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Auszusondernde Menge *')),
              TextField(
                  controller: replacementQuantity,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Zu beschaffende Ersatzmenge *')),
              TextField(
                  controller: budget,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Beantragtes Bruttobudget (€) *')),
              TextField(
                  controller: reason,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Begründung *')),
              TextField(
                  controller: department,
                  decoration: const InputDecoration(labelText: 'Fachbereich')),
              TextField(
                  controller: costCenter,
                  decoration: const InputDecoration(labelText: 'Kostenstelle')),
              DateInputField(
                  controller: desiredDate, label: 'Wunschlieferdatum'),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton.icon(
            onPressed: () {
              final disposal =
                  num.tryParse(disposalQuantity.text.replaceAll(',', '.'));
              final replacement =
                  num.tryParse(replacementQuantity.text.replaceAll(',', '.'));
              final gross = num.tryParse(budget.text.replaceAll(',', '.'));
              if (disposal == null ||
                  disposal <= 0 ||
                  replacement == null ||
                  replacement <= 0 ||
                  gross == null ||
                  gross <= 0 ||
                  reason.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Bitte Mengen, Bruttobudget und Begründung vollständig angeben.')));
                return;
              }
              Navigator.pop(context, {
                'disposalQuantity': disposal,
                'replacementQuantity': replacement,
                'requestedBudgetGross': gross,
                'reason': reason.text.trim(),
                'department': department.text.trim(),
                'costCenter': costCenter.text.trim(),
                'desiredDeliveryDate': dateInputToIso(desiredDate.text),
              });
            },
            icon: const Icon(Icons.delete_sweep),
            label: const Text('Aussondern & Entwurf anlegen'),
          ),
        ],
      ),
    );
    for (final controller in [
      disposalQuantity,
      replacementQuantity,
      budget,
      reason,
      department,
      costCenter,
      desiredDate,
    ]) {
      controller.dispose();
    }
    if (payload == null) return;
    final result = await _request(
        '/api/defects/${detail['id']}/dispose-and-procure',
        method: 'POST',
        body: payload);
    if (result is Map && result['defect'] is Map) {
      final request = result['procurementRequest'] as Map?;
      _message(
          'Artikel ausgesondert; Beschaffungsentwurf ${request?['number'] ?? ''} wurde angelegt.');
      await _replaceSelected(result['defect']);
    }
  }

  Future<void> _showDetail(Map<String, dynamic> summary) async {
    final loaded = await _request('/api/defects/${summary['id']}');
    if (loaded is! Map || !mounted) return;
    var detail = Map<String, dynamic>.from(loaded);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> replaceFrom(dynamic result) async {
            if (result is Map) {
              setDialogState(() => detail = Map<String, dynamic>.from(result));
              await _load();
            }
          }

          Future<void> edit() async {
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (_) => _DefectFormDialog(items: _items, defect: detail),
            );
            if (payload == null) return;
            await replaceFrom(await _request('/api/defects/${detail['id']}',
                method: 'PUT', body: payload));
          }

          Future<void> assign() async {
            final entityType = detail['entityType']?.toString() ?? '';
            final result = await _request(
                '/api/defects/assignees?entityType=${Uri.encodeQueryComponent(entityType)}');
            if (result is! List || !dialogContext.mounted) return;
            final assignees = result
                .map((entry) =>
                    Map<String, dynamic>.from(entry as Map<dynamic, dynamic>))
                .toList();
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (_) => _DefectAssignmentDialog(
                defect: detail,
                assignees: assignees,
              ),
            );
            if (payload != null) {
              await replaceFrom(await _request(
                  '/api/defects/${detail['id']}/assign',
                  method: 'POST',
                  body: payload));
            }
          }

          Future<void> transition() async {
            final target = _nextStatus[detail['status']];
            if (target == null) return;
            if (target == 'Geprüft/Geschlossen' &&
                (detail['resolution']?.toString().trim().isEmpty ?? true)) {
              _message(
                  'Bitte dokumentiere zuerst die Behebung über „Bearbeiten“.');
              return;
            }
            await replaceFrom(await _request(
                '/api/defects/${detail['id']}/transition',
                method: 'POST',
                body: {'status': target}));
          }

          Future<void> printReport() async {
            final data = await _request('/api/defects/${detail['id']}/print');
            if (data is Map) await _saveDownloadPayload(data);
          }

          Future<void> addComment() async {
            final controller = TextEditingController();
            final value = await showDialog<String>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Kommentar hinzufügen'),
                content: TextField(
                    controller: controller,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Kommentar')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('Speichern')),
                ],
              ),
            );
            controller.dispose();
            if (value == null || value.trim().isEmpty) return;
            await _request('/api/defects/${detail['id']}/comments',
                method: 'POST', body: {'text': value});
            final refreshed = await _request('/api/defects/${detail['id']}');
            await replaceFrom(refreshed);
          }

          Future<void> addChecklist() async {
            final controller = TextEditingController();
            final value = await showDialog<String>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Aufgabe hinzufügen'),
                content: TextField(
                    controller: controller,
                    decoration: const InputDecoration(labelText: 'Aufgabe')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('Hinzufügen')),
                ],
              ),
            );
            controller.dispose();
            if (value == null || value.trim().isEmpty) return;
            await _request('/api/defects/${detail['id']}/checklist',
                method: 'POST', body: {'label': value});
            await replaceFrom(await _request('/api/defects/${detail['id']}'));
          }

          Future<void> addRelatedAction() async {
            final label = TextEditingController();
            final reference = TextEditingController();
            var type = 'Reparatur';
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (context) => StatefulBuilder(
                builder: (context, setState) => AlertDialog(
                  title: const Text('Vorgang verknüpfen'),
                  content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButtonFormField<String>(
                        initialValue: type,
                        decoration: const InputDecoration(labelText: 'Art'),
                        items: const ['Reparatur', 'Beschaffung']
                            .map((value) => DropdownMenuItem(
                                value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) => setState(() => type = value!),
                      ),
                      TextField(
                          controller: label,
                          decoration: const InputDecoration(
                              labelText: 'Bezeichnung *')),
                      TextField(
                          controller: reference,
                          decoration: const InputDecoration(
                              labelText: 'Vorgangs-/Referenz-ID')),
                    ]),
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Abbrechen')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, {
                              'type': type,
                              'label': label.text.trim(),
                              'referenceId': reference.text.trim(),
                            }),
                        child: const Text('Verknüpfen')),
                  ],
                ),
              ),
            );
            label.dispose();
            reference.dispose();
            if (payload == null || payload['label'].toString().isEmpty) return;
            await _request('/api/defects/${detail['id']}/related-actions',
                method: 'POST', body: payload);
            await replaceFrom(await _request('/api/defects/${detail['id']}'));
          }

          Future<void> disposeAndProcure() async {
            final disposalQuantity = TextEditingController(
                text: detail['affectedQuantity']?.toString() ?? '1');
            final replacementQuantity = TextEditingController(
                text: detail['affectedQuantity']?.toString() ?? '1');
            final budget = TextEditingController(
                text: detail['estimatedCost']?.toString() ?? '');
            final reason = TextEditingController(
                text:
                    'Ersatzbeschaffung nach Aussonderung wegen Mangel ${detail['defectNumber']}.');
            final department = TextEditingController(
                text: detail['responsibleDepartment']?.toString() ?? '');
            final costCenter = TextEditingController();
            final desiredDate = TextEditingController();
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Aussondern und Ersatz beschaffen'),
                content: SizedBox(
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'Der Artikel wird ausgesondert und gleichzeitig ein vorbefüllter Beschaffungsentwurf angelegt.'),
                      TextField(
                          controller: disposalQuantity,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Auszusondernde Menge *')),
                      TextField(
                          controller: replacementQuantity,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Zu beschaffende Ersatzmenge *')),
                      TextField(
                          controller: budget,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Beantragtes Bruttobudget (€) *')),
                      TextField(
                          controller: reason,
                          maxLines: 3,
                          decoration:
                              const InputDecoration(labelText: 'Begründung *')),
                      TextField(
                          controller: department,
                          decoration:
                              const InputDecoration(labelText: 'Fachbereich')),
                      TextField(
                          controller: costCenter,
                          decoration:
                              const InputDecoration(labelText: 'Kostenstelle')),
                      DateInputField(
                          controller: desiredDate, label: 'Wunschlieferdatum'),
                    ]),
                  ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton.icon(
                    onPressed: () {
                      if ((num.tryParse(disposalQuantity.text
                                      .replaceAll(',', '.')) ??
                                  0) <=
                              0 ||
                          (num.tryParse(replacementQuantity.text
                                      .replaceAll(',', '.')) ??
                                  0) <=
                              0 ||
                          (num.tryParse(budget.text.replaceAll(',', '.')) ??
                                  0) <=
                              0 ||
                          reason.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Bitte Mengen, Bruttobudget und Begründung vollständig angeben.')));
                        return;
                      }
                      Navigator.pop(context, {
                        'disposalQuantity': num.parse(
                            disposalQuantity.text.replaceAll(',', '.')),
                        'replacementQuantity': num.parse(
                            replacementQuantity.text.replaceAll(',', '.')),
                        'requestedBudgetGross':
                            num.parse(budget.text.replaceAll(',', '.')),
                        'reason': reason.text.trim(),
                        'department': department.text.trim(),
                        'costCenter': costCenter.text.trim(),
                        'desiredDeliveryDate': dateInputToIso(desiredDate.text),
                      });
                    },
                    icon: const Icon(Icons.delete_sweep),
                    label: const Text('Aussondern & Entwurf anlegen'),
                  ),
                ],
              ),
            );
            for (final controller in [
              disposalQuantity,
              replacementQuantity,
              budget,
              reason,
              department,
              costCenter,
              desiredDate,
            ]) {
              controller.dispose();
            }
            if (payload == null) return;
            final result = await _request(
                '/api/defects/${detail['id']}/dispose-and-procure',
                method: 'POST',
                body: payload);
            if (result is Map && result['defect'] is Map) {
              final request = result['procurementRequest'] as Map?;
              _message(
                  'Artikel ausgesondert; Beschaffungsentwurf ${request?['number'] ?? ''} wurde angelegt.');
              await replaceFrom(result['defect']);
            }
          }

          Future<void> disposeWithoutReplacement() async {
            final disposalQuantity = TextEditingController(
                text: detail['affectedQuantity']?.toString() ?? '1');
            final reason = TextEditingController(
                text:
                    'Aussonderung ohne Ersatz wegen Mangel ${detail['defectNumber']}.');
            final inventoryNumber =
                detail['inventoryNumber']?.toString() ?? '-';
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Aussondern ohne Ersatz'),
                content: SizedBox(
                  width: 520,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                        'Inventarnummer: $inventoryNumber\n\nBei vollständiger Aussonderung wird die Inventarnummer freigegeben und kann automatisch oder manuell für einen neuen Artikel verwendet werden. Die Aussonderung kann nicht rückgängig gemacht werden.'),
                    const SizedBox(height: 12),
                    TextField(
                        controller: disposalQuantity,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: 'Auszusondernde Menge *',
                            helperText:
                                'Bei einer Teilmenge bleibt die Inventarnummer belegt.')),
                    TextField(
                        controller: reason,
                        maxLines: 3,
                        decoration:
                            const InputDecoration(labelText: 'Begründung *')),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton.icon(
                    onPressed: () {
                      final quantity = num.tryParse(
                          disposalQuantity.text.replaceAll(',', '.'));
                      if (quantity == null ||
                          quantity <= 0 ||
                          reason.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Bitte Menge und Begründung vollständig angeben.')));
                        return;
                      }
                      Navigator.pop(context, {
                        'disposalQuantity': quantity,
                        'reason': reason.text.trim(),
                      });
                    },
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white),
                    icon: const Icon(Icons.delete_forever),
                    label: const Text('Endgültig aussondern'),
                  ),
                ],
              ),
            );
            disposalQuantity.dispose();
            reason.dispose();
            if (payload == null) return;
            final result = await _request(
                '/api/defects/${detail['id']}/dispose-without-replacement',
                method: 'POST',
                body: payload);
            if (result is Map && result['defect'] is Map) {
              final updated =
                  Map<String, dynamic>.from(result['defect'] as Map);
              final disposal = updated['disposal'] as Map?;
              if (disposal?['inventoryNumberReleased'] == true) {
                _message(
                    'Artikel ausgesondert; Inventarnummer ${disposal?['inventoryNumber'] ?? inventoryNumber} wurde freigegeben.');
              } else {
                _message(
                    'Teilmenge ausgesondert; die Inventarnummer bleibt bis zur vollständigen Aussonderung belegt.');
              }
              await replaceFrom(updated);
            }
          }

          Future<void> addFollowUp() async {
            final label = TextEditingController();
            final assignee = TextEditingController();
            final dueDate = TextEditingController();
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Folgeaufgabe hinzufügen'),
                content: SizedBox(
                  width: 480,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: label,
                        decoration:
                            const InputDecoration(labelText: 'Aufgabe *')),
                    TextField(
                        controller: assignee,
                        decoration:
                            const InputDecoration(labelText: 'Verantwortlich')),
                    DateInputField(controller: dueDate, label: 'Frist'),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, {
                            'label': label.text.trim(),
                            'assignee': assignee.text.trim(),
                            'dueDate': dateInputToIso(dueDate.text),
                          }),
                      child: const Text('Hinzufügen')),
                ],
              ),
            );
            label.dispose();
            assignee.dispose();
            dueDate.dispose();
            if (payload == null || payload['label'].toString().isEmpty) return;
            await _request('/api/defects/${detail['id']}/follow-up-tasks',
                method: 'POST', body: payload);
            await replaceFrom(await _request('/api/defects/${detail['id']}'));
          }

          Future<void> addImage() async {
            final file = await FilePicker.pickFile(
              type: FileType.custom,
              allowedExtensions: const ['jpg', 'jpeg', 'png'],
            );
            if (file == null) return;
            final bytes = await file.readAsBytes();
            if (bytes.length > 8 * 1024 * 1024) {
              _message('Ein Bild darf höchstens 8 MB groß sein.');
              return;
            }
            final extension = file.name.split('.').last.toLowerCase();
            await _request('/api/defects/${detail['id']}/images',
                method: 'POST',
                body: {
                  'fileName': file.name,
                  'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
                  'fileBase64': base64Encode(bytes),
                });
            await replaceFrom(await _request('/api/defects/${detail['id']}'));
          }

          final checklist = (detail['checklist'] as List? ?? const [])
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList();
          final comments = (detail['comments'] as List? ?? const []).reversed;
          final relatedActions =
              (detail['relatedActions'] as List? ?? const []).reversed;
          final followUps = (detail['followUpTasks'] as List? ?? const [])
              .map((entry) => Map<String, dynamic>.from(entry as Map));
          final images = (detail['images'] as List? ?? const [])
              .map((entry) => Map<String, dynamic>.from(entry as Map));
          final documents = (detail['documents'] as List? ?? const [])
              .map((entry) => Map<String, dynamic>.from(entry as Map));
          final history = (detail['history'] as List? ?? const []).reversed;
          final archived = detail['archivedAt'] != null;
          final compactDialog = MediaQuery.sizeOf(context).width < 1050;
          return AlertDialog(
            insetPadding: compactDialog
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
            shape: compactDialog
                ? const RoundedRectangleBorder()
                : const RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(28))),
            title: Text('${detail['defectNumber']} · ${detail['title']}'),
            content: SizedBox(
              width: compactDialog ? double.maxFinite : 800,
              height: compactDialog
                  ? (MediaQuery.sizeOf(context).height - 150).clamp(300, 900)
                  : null,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      Chip(label: Text(detail['status']?.toString() ?? '')),
                      Chip(label: Text(detail['priority']?.toString() ?? '')),
                      Chip(
                          label: Text(
                              '${detail['entityName']} · ${detail['inventoryNumber'] ?? '-'}')),
                      Chip(
                          label:
                              Text('Menge ${detail['affectedQuantity'] ?? 1}')),
                    ]),
                    const SizedBox(height: 12),
                    Text(detail['description']?.toString() ?? ''),
                    const Divider(height: 28),
                    _facts(detail),
                    const SizedBox(height: 16),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      OutlinedButton.icon(
                          onPressed: printReport,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Mängelmeldung drucken')),
                      if (!archived) ...[
                        if (_can('defects.edit'))
                          OutlinedButton.icon(
                              onPressed: edit,
                              icon: const Icon(Icons.edit),
                              label: const Text('Bearbeiten')),
                        if (_can('defects.assign'))
                          OutlinedButton.icon(
                              onPressed: assign,
                              icon: const Icon(Icons.person_add),
                              label: const Text('Zuweisen')),
                        if (_can('defects.edit') &&
                            detail['disposal'] == null &&
                            ((detail['entityType'] == 'MaterialItem' &&
                                    _can('inventory.write')) ||
                                (detail['entityType'] == 'ClothingItem' &&
                                    _can('clothing.write'))))
                          OutlinedButton.icon(
                              onPressed: disposeWithoutReplacement,
                              icon: const Icon(Icons.delete_forever),
                              label: const Text('Aussondern ohne Ersatz')),
                        if (_can('defects.edit') &&
                            _can('procurement.request') &&
                            detail['disposal'] == null &&
                            ((detail['entityType'] == 'MaterialItem' &&
                                    _can('inventory.write')) ||
                                (detail['entityType'] == 'ClothingItem' &&
                                    _can('clothing.write'))))
                          FilledButton.icon(
                              onPressed: disposeAndProcure,
                              icon: const Icon(Icons.delete_sweep),
                              label:
                                  const Text('Aussondern & Ersatz beschaffen')),
                        if (_nextStatus.containsKey(detail['status']))
                          FilledButton.icon(
                              onPressed: transition,
                              icon: const Icon(Icons.arrow_forward),
                              label: Text(
                                  'Weiter: ${_nextStatus[detail['status']]}')),
                        if (detail['status'] == 'Geprüft/Geschlossen' &&
                            _can('defects.edit'))
                          OutlinedButton(
                              onPressed: () async => replaceFrom(await _request(
                                  '/api/defects/${detail['id']}/transition',
                                  method: 'POST',
                                  body: {'status': 'Neu'})),
                              child: const Text('Wieder öffnen')),
                      ],
                    ]),
                    const Divider(height: 28),
                    Row(children: [
                      Text('Checkliste',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (!archived && _can('defects.edit'))
                        IconButton(
                            onPressed: addChecklist,
                            tooltip: 'Aufgabe hinzufügen',
                            icon: const Icon(Icons.add_task)),
                    ]),
                    if (checklist.isEmpty) const Text('Keine Aufgaben.'),
                    ...checklist.map((item) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: item['done'] == true,
                          title: Text(item['label']?.toString() ?? ''),
                          onChanged: archived || !_can('defects.edit')
                              ? null
                              : (value) async {
                                  await _request(
                                      '/api/defects/${detail['id']}/checklist/${item['id']}',
                                      method: 'PATCH',
                                      body: {'done': value == true});
                                  await replaceFrom(await _request(
                                      '/api/defects/${detail['id']}'));
                                },
                        )),
                    Row(children: [
                      Text('Verknüpfte Vorgänge',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (!archived && _can('defects.edit'))
                        IconButton(
                            onPressed: addRelatedAction,
                            tooltip:
                                'Reparatur oder bestehende Beschaffung verknüpfen',
                            icon: const Icon(Icons.link)),
                    ]),
                    if (relatedActions.isEmpty)
                      const Text('Keine Vorgänge verknüpft.'),
                    ...relatedActions.map((entry) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.link),
                          title: Text('${entry['type']} · ${entry['label']}'),
                          subtitle: entry['referenceId'] == null
                              ? null
                              : Text('Referenz: ${entry['referenceId']}'),
                        )),
                    Row(children: [
                      Text('Folgeaufgaben',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (!archived && _can('defects.edit'))
                        IconButton(
                            onPressed: addFollowUp,
                            tooltip: 'Folgeaufgabe hinzufügen',
                            icon: const Icon(Icons.playlist_add)),
                    ]),
                    if (followUps.isEmpty) const Text('Keine Folgeaufgaben.'),
                    ...followUps.map((task) => CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: task['done'] == true,
                          title: Text(task['label']?.toString() ?? ''),
                          subtitle: Text([
                            task['assignee'],
                            task['dueDate'] == null
                                ? null
                                : 'Frist ${task['dueDate']}'
                          ]
                              .whereType<String>()
                              .where((v) => v.isNotEmpty)
                              .join(' · ')),
                          onChanged: archived || !_can('defects.edit')
                              ? null
                              : (value) async {
                                  await _request(
                                      '/api/defects/${detail['id']}/follow-up-tasks/${task['id']}',
                                      method: 'PATCH',
                                      body: {'done': value == true});
                                  await replaceFrom(await _request(
                                      '/api/defects/${detail['id']}'));
                                },
                        )),
                    if (documents.isNotEmpty) ...[
                      Text('Mängelbericht',
                          style: Theme.of(context).textTheme.titleMedium),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: documents
                            .map((document) => ActionChip(
                                  avatar:
                                      const Icon(Icons.description_outlined),
                                  label: Text(
                                      document['fileName']?.toString() ?? ''),
                                  onPressed: document['fileBase64'] == null
                                      ? null
                                      : () => _saveDownloadPayload({
                                            'fileName': document['fileName'],
                                            'mimeType': document['mimeType'],
                                            'fileBase64':
                                                document['fileBase64'],
                                          }),
                                ))
                            .toList(),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Row(children: [
                      Text('Bilder (${images.length}/10)',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (!archived && _can('defects.edit'))
                        IconButton(
                            onPressed: addImage,
                            tooltip: 'JPEG/PNG hinzufügen',
                            icon: const Icon(Icons.add_photo_alternate)),
                    ]),
                    if (images.isEmpty) const Text('Keine Bilder.'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: images.map((image) {
                        final bytes = image['fileBase64'] == null
                            ? Uint8List(0)
                            : base64Decode(image['fileBase64'].toString());
                        return SizedBox(
                          width: 150,
                          child: Column(children: [
                            if (bytes.isNotEmpty)
                              Image.memory(bytes,
                                  height: 100,
                                  width: 150,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.broken_image, size: 64)),
                            Text(image['fileName']?.toString() ?? '',
                                overflow: TextOverflow.ellipsis),
                          ]),
                        );
                      }).toList(),
                    ),
                    const Divider(height: 28),
                    Row(children: [
                      Text('Kommentare',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (!archived && _can('defects.edit'))
                        IconButton(
                            onPressed: addComment,
                            icon: const Icon(Icons.add_comment)),
                    ]),
                    if (comments.isEmpty) const Text('Keine Kommentare.'),
                    ...comments.map((entry) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry['text']?.toString() ?? ''),
                          subtitle: Text(
                              '${entry['author'] ?? '-'} · ${_formatDateTime(entry['createdAt'])}'),
                        )),
                    const Divider(height: 28),
                    Text('Änderungsverlauf',
                        style: Theme.of(context).textTheme.titleMedium),
                    ...history.map((entry) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry['details']?.toString() ??
                              entry['action']?.toString() ??
                              ''),
                          subtitle: Text(
                              '${entry['actor'] ?? '-'} · ${_formatDateTime(entry['at'])}'),
                        )),
                  ],
                ),
              ),
            ),
            actions: [
              if (!archived &&
                  detail['status'] == 'Geprüft/Geschlossen' &&
                  _can('defects.archive'))
                TextButton.icon(
                    onPressed: () async {
                      final result = await _request(
                          '/api/defects/${detail['id']}/archive',
                          method: 'POST');
                      await replaceFrom(result);
                    },
                    icon: const Icon(Icons.archive),
                    label: const Text('Archivieren')),
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Schließen')),
            ],
          );
        },
      ),
    );
  }

  static Widget _facts(Map<String, dynamic> defect) {
    final disposal = defect['disposal'] is Map
        ? Map<String, dynamic>.from(defect['disposal'] as Map)
        : null;
    final values = <String, dynamic>{
      'Schadensart': defect['damageType'],
      'Ursache': defect['cause'],
      'Gefährdung': defect['riskLevel'],
      'Einsatzbereitschaft': defect['operationalSafety'],
      'Getroffene Maßnahmen': defect['measuresTaken'],
      'Verantwortlich': defect['assignee'],
      'Fachbereich': defect['responsibleDepartment'],
      'Kontakt': defect['contactName'],
      'Kontakt E-Mail': defect['contactEmail'],
      'Kontakt Telefon': defect['contactPhone'],
      'Frist': defect['dueDate'],
      'Geschätzte Kosten': defect['estimatedCost'] == null
          ? null
          : '${defect['estimatedCost']} €',
      'Tatsächliche Kosten':
          defect['actualCost'] == null ? null : '${defect['actualCost']} €',
      'Behebung': defect['resolution'],
      'Prüfung': defect['linkedInspectionId'],
      'Wiederholung von': defect['recurrenceOfId'],
      'Duplikat von': defect['duplicateOfId'],
      'Aussonderung': disposal == null
          ? null
          : disposal['mode'] == 'without-replacement'
              ? 'Ohne Ersatz'
              : 'Mit Ersatzbeschaffung',
      'Aussonderungsgrund': disposal?['reason'],
      'Inventarnummer freigegeben': disposal == null
          ? null
          : disposal['inventoryNumberReleased'] == true
              ? 'Ja · ${disposal['inventoryNumber'] ?? '-'}'
              : 'Nein (Teilaussonderung)',
    }..removeWhere((_, value) => value == null || value.toString().isEmpty);
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: values.entries
          .map((entry) => SizedBox(
                width: 230,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.key,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(entry.value.toString()),
                    ]),
              ))
          .toList(),
    );
  }

  String _formatDateTime(Object? value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '-';
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Color _priorityColor(String value) => switch (value) {
        'Kritisch' => Colors.red,
        'Hoch' => Colors.deepOrange,
        'Niedrig' => Colors.blueGrey,
        _ => Colors.amber.shade800,
      };

  @override
  Widget build(BuildContext context) {
    final unread =
        _notifications.where((entry) => entry['readAt'] == null).length;
    final filteredDefects = _filtered;
    final pendingEmailCount =
        _emailImports.where((entry) => entry['status'] == 'pending').length;
    var openDefectCount = 0;
    var defectsInProgressCount = 0;
    for (final defect in _defects) {
      if (defect['status'] != 'Geprüft/Geschlossen' &&
          defect['archivedAt'] == null) {
        openDefectCount += 1;
      }
      if (defect['status'] == 'In Bearbeitung') {
        defectsInProgressCount += 1;
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mängelmanagement'),
        actions: [
          Badge(
            isLabelVisible: pendingEmailCount > 0,
            label: Text('$pendingEmailCount'),
            child: IconButton(
              tooltip: 'E-Mail-Prüfwarteschlange',
              onPressed: _showEmailQueue,
              icon: const Icon(Icons.forward_to_inbox_outlined),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export und Druck',
            icon: const Icon(Icons.download),
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'xlsx', child: Text('XLSX')),
              PopupMenuItem(value: 'ods', child: Text('ODS')),
              PopupMenuItem(value: 'csv', child: Text('CSV')),
              PopupMenuItem(value: 'pdf', child: Text('PDF')),
              PopupMenuItem(value: 'print', child: Text('Druckansicht')),
            ],
          ),
          Badge(
            isLabelVisible: unread > 0,
            label: Text('$unread'),
            child: IconButton(
                onPressed: _showNotifications,
                tooltip: 'Benachrichtigungen',
                icon: const Icon(Icons.notifications_outlined)),
          ),
          IconButton(
              onPressed: _load,
              tooltip: 'Aktualisieren',
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 1050;
                final controls = _buildWorkspaceControls(
                  openDefectCount: openDefectCount,
                  inProgressCount: defectsInProgressCount,
                  pendingEmailCount: pendingEmailCount,
                  compact: !wide,
                );
                if (!wide) {
                  return Column(children: [
                    controls,
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: filteredDefects.isEmpty
                            ? ListView(children: const [
                                SizedBox(height: 100),
                                Center(child: Text('Keine Mängel gefunden.')),
                              ])
                            : ListView.builder(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 4, 12, 24),
                                itemCount: filteredDefects.length,
                                itemBuilder: (_, index) => _defectListEntry(
                                  filteredDefects[index],
                                  selected: false,
                                  dense: false,
                                ),
                              ),
                      ),
                    ),
                  ]);
                }
                final listWidth =
                    (constraints.maxWidth * .34).clamp(390.0, 540.0);
                return Column(children: [
                  controls,
                  const Divider(height: 1),
                  Expanded(
                    child: Row(children: [
                      SizedBox(
                        width: listWidth,
                        child: Column(children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                            child: Row(children: [
                              Text('${filteredDefects.length} Mängel',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const Spacer(),
                              const Text('Auswahl öffnen'),
                            ]),
                          ),
                          Expanded(
                            child: filteredDefects.isEmpty
                                ? const Center(
                                    child: Text('Keine Mängel gefunden.'))
                                : ListView.builder(
                                    padding: const EdgeInsets.fromLTRB(
                                        10, 0, 10, 20),
                                    itemCount: filteredDefects.length,
                                    itemBuilder: (_, index) {
                                      final defect = filteredDefects[index];
                                      return _defectListEntry(
                                        defect,
                                        selected: defect['id']?.toString() ==
                                            _selectedDefectId,
                                        dense: true,
                                      );
                                    },
                                  ),
                          ),
                        ]),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(child: _buildSelectedWorkspace()),
                    ]),
                  ),
                ]);
              },
            ),
    );
  }

  Widget _buildWorkspaceControls({
    required int openDefectCount,
    required int inProgressCount,
    required int pendingEmailCount,
    required bool compact,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, compact ? 10 : 8, 12, 8),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: compact ? 260 : 300,
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText: 'Mängel durchsuchen',
                  isDense: true,
                ),
                onChanged: (value) => _searchDebouncer.run(() {
                  if (mounted) _changeFilter(() => _search = value);
                }),
              ),
            ),
            _filter('Status', ['Alle', ..._statuses], _status,
                (value) => _changeFilter(() => _status = value),
                width: compact ? 170 : 180),
            _filter('Priorität', ['Alle', ..._priorities], _priority,
                (value) => _changeFilter(() => _priority = value),
                width: compact ? 150 : 165),
            _filter(
              'Bereich',
              const ['Alle', 'MaterialItem', 'ClothingItem'],
              _entityType,
              (value) => _changeFilter(() => _entityType = value),
              width: compact ? 150 : 165,
              labels: const {
                'Alle': 'Alle',
                'MaterialItem': 'Inventar',
                'ClothingItem': 'Kleidung',
              },
            ),
            FilterChip(
              avatar: const Icon(Icons.person_outline, size: 18),
              label: const Text('Meine'),
              selected: _onlyMine,
              onSelected: (value) => _changeFilter(() => _onlyMine = value),
            ),
            FilterChip(
              avatar: const Icon(Icons.archive_outlined, size: 18),
              label: const Text('Archiv'),
              selected: _showArchived,
              onSelected: (value) async {
                _showArchived = value;
                await _load();
              },
            ),
            Chip(
              avatar: const Icon(Icons.warning_amber, size: 18),
              label: Text('$openDefectCount offen'),
            ),
            Chip(
              avatar: const Icon(Icons.build_outlined, size: 18),
              label: Text('$inProgressCount in Arbeit'),
            ),
            Badge(
              isLabelVisible: pendingEmailCount > 0,
              label: Text('$pendingEmailCount'),
              child: OutlinedButton.icon(
                onPressed: _showEmailInfo,
                icon: const Icon(Icons.alternate_email),
                label: const Text('E-Mail-Meldung'),
              ),
            ),
            if (_can('defects.report'))
              FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Neuer Mangel'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showEmailInfo() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mängel per E-Mail melden'),
        content: const SizedBox(
          width: 560,
          child: SelectableText(
              'Ausgefüllten Bericht als PDF, PNG oder JPEG zusammen mit optionalen Schadensbildern an maengel@materialkompass.org senden.'),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _downloadTemplate();
            },
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Vorlage herunterladen'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _showEmailQueue();
            },
            icon: const Icon(Icons.rule_folder_outlined),
            label: const Text('Prüfwarteschlange'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Schließen')),
        ],
      ),
    );
  }

  Widget _defectListEntry(Map<String, dynamic> defect,
      {required bool selected, required bool dense}) {
    final dueDate = defect['dueDate']?.toString();
    final assignee = defect['assignee']?.toString() ?? '';
    return Card(
      margin: EdgeInsets.symmetric(vertical: dense ? 3 : 5),
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Theme.of(context).colorScheme.surface,
      elevation: selected ? 1 : 0,
      child: ListTile(
        dense: dense,
        selected: selected,
        contentPadding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 16, vertical: dense ? 2 : 6),
        leading: Container(
          width: 5,
          height: dense ? 48 : 58,
          decoration: BoxDecoration(
            color: _priorityColor(defect['priority']?.toString() ?? 'Normal'),
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        title: Text(
          '${defect['defectNumber']} · ${defect['title']}',
          maxLines: dense ? 2 : 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text([
            '${defect['entityName']} · ${defect['inventoryNumber'] ?? '-'}',
            [
              defect['status'],
              defect['priority'],
              if (assignee.isNotEmpty) assignee,
              if (dueDate != null && dueDate.isNotEmpty) 'Frist $dueDate',
            ].whereType<Object>().join(' · '),
          ].join('\n')),
        ),
        isThreeLine: true,
        trailing: defect['archivedAt'] == null
            ? const Icon(Icons.chevron_right)
            : const Icon(Icons.archive_outlined),
        onTap: () => _selectDefect(defect),
      ),
    );
  }

  Widget _buildSelectedWorkspace() {
    if (_detailLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = _selectedDetail;
    if (detail == null) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.touch_app_outlined, size: 48),
          SizedBox(height: 12),
          Text('Wähle einen Mangel aus.'),
        ]),
      );
    }
    final canWriteEntity =
        (detail['entityType'] == 'MaterialItem' && _can('inventory.write')) ||
            (detail['entityType'] == 'ClothingItem' && _can('clothing.write'));
    final nextStatus = _nextStatus[detail['status']];
    final canTransition = nextStatus == null
        ? false
        : ['Behoben', 'Geprüft/Geschlossen'].contains(nextStatus)
            ? _can('defects.close')
            : _can('defects.edit');
    return _DefectDetailWorkspace(
      key: ValueKey(detail['id']),
      defect: detail,
      canEdit: _can('defects.edit'),
      canAssign: _can('defects.assign'),
      canTransition: canTransition,
      canArchive: _can('defects.archive'),
      canDispose: _can('defects.edit') && canWriteEntity,
      canProcure:
          _can('defects.edit') && _can('procurement.request') && canWriteEntity,
      onSave: _saveSelected,
      onAssign: () => _assignSelected(),
      onAssignToMe: () => _assignSelected(assignToMe: true),
      onTransition: () => _transitionSelected(),
      onReopen: () => _transitionSelected(status: 'Neu'),
      onPrint: _printSelected,
      onAddComment: _addSelectedComment,
      onAddChecklist: _addSelectedChecklist,
      onToggleChecklist: _toggleSelectedChecklist,
      onAddFollowUp: _addSelectedFollowUp,
      onToggleFollowUp: _toggleSelectedFollowUp,
      onAddRelatedAction: _addSelectedRelatedAction,
      onAddImage: _addSelectedImage,
      onDeleteImage: _deleteSelectedImage,
      onArchive: _archiveSelected,
      onDisposeWithoutReplacement: _disposeSelectedWithoutReplacement,
      onDisposeAndProcure: _disposeSelectedAndProcure,
      onDownload: _saveDownloadPayload,
      formatDateTime: _formatDateTime,
    );
  }

  Widget _filter(String label, List<String> values, String selected,
      ValueChanged<String> changed,
      {Map<String, String> labels = const {}, double width = 190}) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label-$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: values
            .map((value) => DropdownMenuItem(
                value: value,
                child: Text(labels[value] ?? value,
                    overflow: TextOverflow.ellipsis)))
            .toList(),
        onChanged: (value) {
          if (value != null) changed(value);
        },
      ),
    );
  }
}

class _DefectDetailWorkspace extends StatefulWidget {
  final Map<String, dynamic> defect;
  final bool canEdit;
  final bool canAssign;
  final bool canTransition;
  final bool canArchive;
  final bool canDispose;
  final bool canProcure;
  final Future<bool> Function(Map<String, dynamic>) onSave;
  final Future<void> Function() onAssign;
  final Future<void> Function() onAssignToMe;
  final Future<void> Function() onTransition;
  final Future<void> Function() onReopen;
  final Future<void> Function() onPrint;
  final Future<void> Function(String) onAddComment;
  final Future<void> Function(String) onAddChecklist;
  final Future<void> Function(String, bool) onToggleChecklist;
  final Future<void> Function() onAddFollowUp;
  final Future<void> Function(String, bool) onToggleFollowUp;
  final Future<void> Function() onAddRelatedAction;
  final Future<void> Function() onAddImage;
  final Future<void> Function(String) onDeleteImage;
  final Future<void> Function() onArchive;
  final Future<void> Function() onDisposeWithoutReplacement;
  final Future<void> Function() onDisposeAndProcure;
  final Future<void> Function(Map) onDownload;
  final String Function(Object?) formatDateTime;

  const _DefectDetailWorkspace({
    required this.defect,
    required this.canEdit,
    required this.canAssign,
    required this.canTransition,
    required this.canArchive,
    required this.canDispose,
    required this.canProcure,
    required this.onSave,
    required this.onAssign,
    required this.onAssignToMe,
    required this.onTransition,
    required this.onReopen,
    required this.onPrint,
    required this.onAddComment,
    required this.onAddChecklist,
    required this.onToggleChecklist,
    required this.onAddFollowUp,
    required this.onToggleFollowUp,
    required this.onAddRelatedAction,
    required this.onAddImage,
    required this.onDeleteImage,
    required this.onArchive,
    required this.onDisposeWithoutReplacement,
    required this.onDisposeAndProcure,
    required this.onDownload,
    required this.formatDateTime,
    super.key,
  });

  @override
  State<_DefectDetailWorkspace> createState() => _DefectDetailWorkspaceState();
}

class _DefectDetailWorkspaceState extends State<_DefectDetailWorkspace> {
  final comment = TextEditingController();
  final checklist = TextEditingController();
  bool editing = false;
  bool sendingComment = false;
  bool addingChecklist = false;

  bool get archived => widget.defect['archivedAt'] != null;

  @override
  void dispose() {
    comment.dispose();
    checklist.dispose();
    super.dispose();
  }

  Future<void> _submitComment() async {
    if (comment.text.trim().isEmpty || sendingComment) return;
    setState(() => sendingComment = true);
    await widget.onAddComment(comment.text);
    if (!mounted) return;
    comment.clear();
    setState(() => sendingComment = false);
  }

  Future<void> _submitChecklist() async {
    if (checklist.text.trim().isEmpty || addingChecklist) return;
    setState(() => addingChecklist = true);
    await widget.onAddChecklist(checklist.text);
    if (!mounted) return;
    checklist.clear();
    setState(() => addingChecklist = false);
  }

  @override
  Widget build(BuildContext context) {
    if (editing) {
      return _DefectInlineEditor(
        defect: widget.defect,
        onCancel: () => setState(() => editing = false),
        onSave: (payload) async {
          final saved = await widget.onSave(payload);
          if (saved && mounted) setState(() => editing = false);
          return saved;
        },
      );
    }

    final defect = widget.defect;
    final checklistItems = (defect['checklist'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final followUps = (defect['followUpTasks'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final related = (defect['relatedActions'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList()
        .reversed;
    final comments = (defect['comments'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList()
        .reversed;
    final images = (defect['images'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final documents = (defect['documents'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final history = (defect['history'] as List? ?? const [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList()
        .reversed;
    final nextStatus = _nextStatus[defect['status']];
    final disposalAvailable = defect['disposal'] == null;

    return Column(children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${defect['defectNumber']} · ${defect['title']}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 6),
                      Wrap(spacing: 7, runSpacing: 6, children: [
                        Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(defect['status']?.toString() ?? '-')),
                        Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.flag_outlined, size: 17),
                            label: Text(defect['priority']?.toString() ?? '-')),
                        Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.inventory_2_outlined,
                                size: 17),
                            label: Text(
                                '${defect['entityName']} · ${defect['inventoryNumber'] ?? '-'}')),
                        if (archived)
                          const Chip(
                              visualDensity: VisualDensity.compact,
                              avatar: Icon(Icons.archive_outlined, size: 17),
                              label: Text('Archiviert')),
                      ]),
                    ]),
              ),
              PopupMenuButton<String>(
                tooltip: 'Weitere Aktionen',
                onSelected: (value) {
                  switch (value) {
                    case 'print':
                      widget.onPrint();
                    case 'related':
                      widget.onAddRelatedAction();
                    case 'dispose':
                      widget.onDisposeWithoutReplacement();
                    case 'procure':
                      widget.onDisposeAndProcure();
                    case 'archive':
                      widget.onArchive();
                    case 'reopen':
                      widget.onReopen();
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'print',
                      child: ListTile(
                          leading: Icon(Icons.print_outlined),
                          title: Text('Mängelmeldung drucken'))),
                  if (!archived && widget.canEdit)
                    const PopupMenuItem(
                        value: 'related',
                        child: ListTile(
                            leading: Icon(Icons.link),
                            title: Text('Vorgang verknüpfen'))),
                  if (!archived && widget.canDispose && disposalAvailable)
                    const PopupMenuItem(
                        value: 'dispose',
                        child: ListTile(
                            leading: Icon(Icons.delete_forever),
                            title: Text('Aussondern ohne Ersatz'))),
                  if (!archived && widget.canProcure && disposalAvailable)
                    const PopupMenuItem(
                        value: 'procure',
                        child: ListTile(
                            leading: Icon(Icons.delete_sweep),
                            title: Text('Aussondern & Ersatz beschaffen'))),
                  if (!archived &&
                      defect['status'] == 'Geprüft/Geschlossen' &&
                      widget.canEdit)
                    const PopupMenuItem(
                        value: 'reopen', child: Text('Wieder öffnen')),
                  if (!archived &&
                      defect['status'] == 'Geprüft/Geschlossen' &&
                      widget.canArchive)
                    const PopupMenuItem(
                        value: 'archive', child: Text('Archivieren')),
                ],
              ),
            ]),
            if (!archived) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (nextStatus != null && widget.canTransition)
                  FilledButton.icon(
                    onPressed: widget.onTransition,
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Weiter: $nextStatus'),
                  ),
                if (widget.canAssign) ...[
                  OutlinedButton.icon(
                    onPressed: widget.onAssignToMe,
                    icon: const Icon(Icons.how_to_reg_outlined),
                    label: const Text('Mir zuweisen'),
                  ),
                  OutlinedButton.icon(
                    onPressed: widget.onAssign,
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Zuweisung & Frist'),
                  ),
                ],
                if (widget.canEdit)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => editing = true),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Bearbeiten'),
                  ),
              ]),
            ],
          ]),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
          child: LayoutBuilder(builder: (context, constraints) {
            final twoColumns = constraints.maxWidth >= 760;
            final overview = _WorkspaceSection(
              title: 'Überblick',
              icon: Icons.subject_outlined,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(defect['description']?.toString() ?? '-'),
                    const SizedBox(height: 16),
                    _DefectsPageState._facts(defect),
                  ]),
            );
            final work = Column(children: [
              _WorkspaceSection(
                title: 'Laufende Bearbeitung',
                icon: Icons.construction_outlined,
                trailing: !archived && widget.canEdit
                    ? IconButton(
                        tooltip: 'Folgeaufgabe hinzufügen',
                        onPressed: widget.onAddFollowUp,
                        icon: const Icon(Icons.playlist_add))
                    : null,
                child: Column(children: [
                  _CompactFact(
                      label: 'Verantwortlich',
                      value:
                          defect['assignee']?.toString() ?? 'Nicht zugewiesen'),
                  _CompactFact(
                      label: 'Fachbereich',
                      value:
                          defect['responsibleDepartment']?.toString() ?? '-'),
                  _CompactFact(
                      label: 'Frist',
                      value: defect['dueDate']?.toString() ?? '-'),
                  const Divider(),
                  if (followUps.isEmpty)
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Keine Folgeaufgaben.')),
                  ...followUps.map((task) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: task['done'] == true,
                        title: Text(task['label']?.toString() ?? ''),
                        subtitle: Text([
                          task['assignee'],
                          task['dueDate'] == null
                              ? null
                              : 'Frist ${task['dueDate']}'
                        ]
                            .whereType<String>()
                            .where((value) => value.isNotEmpty)
                            .join(' · ')),
                        onChanged: archived || !widget.canEdit
                            ? null
                            : (value) => widget.onToggleFollowUp(
                                task['id'].toString(), value == true),
                      )),
                ]),
              ),
              const SizedBox(height: 14),
              _WorkspaceSection(
                title: 'Checkliste',
                icon: Icons.checklist_outlined,
                child: Column(children: [
                  if (checklistItems.isEmpty)
                    const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Keine Aufgaben.')),
                  ...checklistItems.map((item) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: item['done'] == true,
                        title: Text(item['label']?.toString() ?? ''),
                        onChanged: archived || !widget.canEdit
                            ? null
                            : (value) => widget.onToggleChecklist(
                                item['id'].toString(), value == true),
                      )),
                  if (!archived && widget.canEdit)
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: checklist,
                          onSubmitted: (_) => _submitChecklist(),
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Neue Aufgabe',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Aufgabe hinzufügen',
                        onPressed: addingChecklist ? null : _submitChecklist,
                        icon: addingChecklist
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.add_task),
                      ),
                    ]),
                ]),
              ),
            ]);
            return Column(children: [
              if (twoColumns)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 6, child: overview),
                  const SizedBox(width: 14),
                  Expanded(flex: 4, child: work),
                ])
              else ...[
                overview,
                const SizedBox(height: 14),
                work,
              ],
              const SizedBox(height: 14),
              _WorkspaceSection(
                title: 'Kommentare',
                icon: Icons.forum_outlined,
                child: Column(children: [
                  if (!archived && widget.canEdit)
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(
                        child: TextField(
                          controller: comment,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                              labelText: 'Kommentar hinzufügen'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: sendingComment ? null : _submitComment,
                        icon: sendingComment
                            ? const SizedBox.square(
                                dimension: 17,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: const Text('Senden'),
                      ),
                    ]),
                  if (comments.isEmpty)
                    const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Keine Kommentare.'))),
                  ...comments.map((entry) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry['text']?.toString() ?? ''),
                        subtitle: Text(
                            '${entry['author'] ?? '-'} · ${widget.formatDateTime(entry['createdAt'])}'),
                      )),
                ]),
              ),
              const SizedBox(height: 14),
              _WorkspaceSection(
                title: 'Verknüpfte Vorgänge',
                icon: Icons.link,
                trailing: !archived && widget.canEdit
                    ? IconButton(
                        onPressed: widget.onAddRelatedAction,
                        tooltip: 'Vorgang verknüpfen',
                        icon: const Icon(Icons.add_link))
                    : null,
                child: related.isEmpty
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Keine Vorgänge verknüpft.'))
                    : Column(
                        children: related
                            .map((entry) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.link),
                                  title: Text(
                                      '${entry['type']} · ${entry['label']}'),
                                  subtitle: entry['referenceId'] == null
                                      ? null
                                      : Text(
                                          'Referenz: ${entry['referenceId']}'),
                                ))
                            .toList(),
                      ),
              ),
              const SizedBox(height: 14),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: Text(
                      'Bilder & Dokumente (${images.length + documents.length})'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (!archived && widget.canEdit)
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          onPressed:
                              images.length >= 10 ? null : widget.onAddImage,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Bild hinzufügen'),
                        ),
                      ),
                    if (images.isEmpty && documents.isEmpty)
                      const Text('Keine Bilder oder Dokumente.'),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: images.map((image) {
                        final bytes = image['fileBase64'] == null
                            ? Uint8List(0)
                            : base64Decode(image['fileBase64'].toString());
                        return SizedBox(
                          width: 170,
                          child: Card(
                            child: Column(children: [
                              if (bytes.isNotEmpty)
                                Image.memory(bytes,
                                    height: 110,
                                    width: 170,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox(
                                            height: 110,
                                            child: Icon(Icons.broken_image,
                                                size: 48))),
                              Row(children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                        image['fileName']?.toString() ?? '',
                                        overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                                if (!archived && widget.canEdit)
                                  IconButton(
                                    tooltip: 'Bild löschen',
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('Bild löschen?'),
                                          content: Text(
                                              '${image['fileName'] ?? 'Dieses Bild'} wird dauerhaft entfernt.'),
                                          actions: [
                                            TextButton(
                                                onPressed: () => Navigator.pop(
                                                    context, false),
                                                child: const Text('Abbrechen')),
                                            FilledButton(
                                                onPressed: () => Navigator.pop(
                                                    context, true),
                                                child: const Text('Löschen')),
                                          ],
                                        ),
                                      );
                                      if (confirmed == true) {
                                        widget.onDeleteImage(
                                            image['id'].toString());
                                      }
                                    },
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                              ]),
                            ]),
                          ),
                        );
                      }).toList(),
                    ),
                    if (documents.isNotEmpty) ...[
                      const Divider(),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: documents
                            .map((document) => ActionChip(
                                  avatar:
                                      const Icon(Icons.description_outlined),
                                  label: Text(
                                      document['fileName']?.toString() ?? ''),
                                  onPressed: document['fileBase64'] == null
                                      ? null
                                      : () => widget.onDownload({
                                            'fileName': document['fileName'],
                                            'mimeType': document['mimeType'],
                                            'fileBase64':
                                                document['fileBase64'],
                                          }),
                                ))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ExpansionTile(
                  leading: const Icon(Icons.history),
                  title: Text('Änderungsverlauf (${history.length})'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: history
                      .map((entry) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(entry['details']?.toString() ??
                                entry['action']?.toString() ??
                                ''),
                            subtitle: Text(
                                '${entry['actor'] ?? '-'} · ${widget.formatDateTime(entry['at'])}'),
                          ))
                      .toList(),
                ),
              ),
            ]);
          }),
        ),
      ),
    ]);
  }
}

class _WorkspaceSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  const _WorkspaceSection({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
              if (trailing != null) trailing!,
            ]),
            const Divider(),
            child,
          ]),
        ),
      );
}

class _CompactFact extends StatelessWidget {
  final String label;
  final String value;

  const _CompactFact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
              width: 120,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value)),
        ]),
      );
}

class _DefectInlineEditor extends StatefulWidget {
  final Map<String, dynamic> defect;
  final VoidCallback onCancel;
  final Future<bool> Function(Map<String, dynamic>) onSave;

  const _DefectInlineEditor({
    required this.defect,
    required this.onCancel,
    required this.onSave,
  });

  @override
  State<_DefectInlineEditor> createState() => _DefectInlineEditorState();
}

class _DefectInlineEditorState extends State<_DefectInlineEditor> {
  final formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> fields;
  late String priority;
  late String risk;
  late String operationalSafety;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    final value = widget.defect;
    fields = {
      for (final field in [
        'title',
        'description',
        'damageType',
        'cause',
        'measuresTaken',
        'responsibleDepartment',
        'contactName',
        'contactEmail',
        'contactPhone',
        'dueDate',
        'estimatedCost',
        'actualCost',
        'resolution',
        'recurrenceOfId',
        'duplicateOfId',
      ])
        field: TextEditingController(text: value[field]?.toString() ?? ''),
    };
    priority = value['priority']?.toString() ?? 'Normal';
    risk = value['riskLevel']?.toString() ?? 'Keine Angabe';
    operationalSafety =
        value['operationalSafety']?.toString() ?? 'Nicht einsatzfähig';
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _payload() => {
        for (final entry in fields.entries)
          entry.key: entry.key == 'dueDate'
              ? dateInputToIso(entry.value.text)
              : entry.value.text.trim(),
        'priority': priority,
        'riskLevel': risk,
        'operationalSafety': operationalSafety,
      };

  Future<void> _save() async {
    if (saving || formKey.currentState?.validate() != true) return;
    setState(() => saving = true);
    final saved = await widget.onSave(_payload());
    if (mounted && !saved) setState(() => saving = false);
  }

  TextFormField _field(String name, String label,
      {int maxLines = 1, TextInputType? keyboardType, bool required = false}) {
    return TextFormField(
      controller: fields[name],
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(labelText: label),
      validator: required
          ? (value) => value == null || value.trim().isEmpty
              ? '$label ist erforderlich.'
              : null
          : null,
    );
  }

  Widget _dropdown(String label, String value, List<String> values,
      ValueChanged<String> changed) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: values
          .map((entry) => DropdownMenuItem(value: entry, child: Text(entry)))
          .toList(),
      onChanged: (entry) {
        if (entry != null) changed(entry);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: Focus(
        autofocus: true,
        child: Form(
          key: formKey,
          child: Column(children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
                child: Row(children: [
                  IconButton(
                      tooltip: 'Bearbeitung abbrechen (Esc)',
                      onPressed: saving ? null : widget.onCancel,
                      icon: const Icon(Icons.close)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Mangel bearbeiten',
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text(
                              '${widget.defect['defectNumber']} · ${widget.defect['entityName']}'),
                        ]),
                  ),
                  TextButton(
                      onPressed: saving ? null : widget.onCancel,
                      child: const Text('Abbrechen')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: saving ? null : _save,
                    icon: saving
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                    label: const Text('Speichern  Strg+S'),
                  ),
                ]),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 780;
                final main = _WorkspaceSection(
                  title: 'Mangelbeschreibung',
                  icon: Icons.report_problem_outlined,
                  child: Column(children: [
                    _field('title', 'Titel *', required: true),
                    _field('description', 'Beschreibung *',
                        maxLines: 5, required: true),
                    Row(children: [
                      Expanded(
                          child: _dropdown('Priorität', priority, _priorities,
                              (value) => setState(() => priority = value))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _dropdown(
                              'Gefährdungsstufe',
                              risk,
                              const [
                                'Keine Angabe',
                                'Niedrig',
                                'Mittel',
                                'Hoch'
                              ],
                              (value) => setState(() => risk = value))),
                    ]),
                    _dropdown(
                        'Einsatzbereitschaft',
                        operationalSafety,
                        const [
                          'Einsatzfähig',
                          'Eingeschränkt',
                          'Nicht einsatzfähig'
                        ],
                        (value) => setState(() => operationalSafety = value)),
                    _field('damageType', 'Schadensart'),
                    _field('cause', 'Ursache', maxLines: 3),
                    _field('measuresTaken', 'Getroffene Maßnahmen',
                        maxLines: 4),
                    _field('resolution', 'Behebung/Arbeitsnachweis',
                        maxLines: 4),
                  ]),
                );
                final organization = Column(children: [
                  _WorkspaceSection(
                    title: 'Zuständigkeit & Kosten',
                    icon: Icons.assignment_ind_outlined,
                    child: Column(children: [
                      _field(
                          'responsibleDepartment', 'Zuständiger Fachbereich'),
                      DateInputField(
                          controller: fields['dueDate']!, label: 'Frist'),
                      _field('estimatedCost', 'Geschätzte Kosten (€)',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true)),
                      _field('actualCost', 'Tatsächliche Kosten (€)',
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true)),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  _WorkspaceSection(
                    title: 'Kontakt & Verknüpfungen',
                    icon: Icons.contact_mail_outlined,
                    child: Column(children: [
                      _field('contactName', 'Kontaktname'),
                      _field('contactEmail', 'Kontakt-E-Mail',
                          keyboardType: TextInputType.emailAddress),
                      _field('contactPhone', 'Kontakttelefon',
                          keyboardType: TextInputType.phone),
                      _field('recurrenceOfId', 'Wiederholung von (Mangel-ID)'),
                      _field('duplicateOfId', 'Duplikat von (Mangel-ID)'),
                    ]),
                  ),
                ]);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 6, child: main),
                            const SizedBox(width: 14),
                            Expanded(flex: 4, child: organization),
                          ],
                        )
                      : Column(children: [
                          main,
                          const SizedBox(height: 14),
                          organization,
                        ]),
                );
              }),
            ),
          ]),
        ),
      ),
    );
  }
}

class _DefectAssignmentDialog extends StatefulWidget {
  final Map<String, dynamic> defect;
  final List<Map<String, dynamic>> assignees;

  const _DefectAssignmentDialog({
    required this.defect,
    required this.assignees,
  });

  @override
  State<_DefectAssignmentDialog> createState() =>
      _DefectAssignmentDialogState();
}

class _DefectAssignmentDialogState extends State<_DefectAssignmentDialog> {
  late final TextEditingController externalAssignee;
  late final TextEditingController department;
  late final TextEditingController dueDate;
  late String assignmentType;
  String? assigneeUserId;

  bool get hasAssignment =>
      widget.defect['assignee']?.toString().trim().isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    final currentUserId = widget.defect['assigneeUserId']?.toString();
    final currentUserIsSelectable = currentUserId != null &&
        widget.assignees.any((entry) => entry['id'] == currentUserId);
    assignmentType = currentUserIsSelectable ||
            (!hasAssignment && widget.assignees.isNotEmpty)
        ? 'user'
        : 'external';
    assigneeUserId = currentUserIsSelectable
        ? currentUserId
        : widget.assignees.firstOrNull?['id']?.toString();
    externalAssignee = TextEditingController(
        text: assignmentType == 'external'
            ? widget.defect['assignee']?.toString() ?? ''
            : '');
    department = TextEditingController(
        text: widget.defect['responsibleDepartment']?.toString() ?? '');
    dueDate =
        TextEditingController(text: widget.defect['dueDate']?.toString() ?? '');
  }

  @override
  void dispose() {
    externalAssignee.dispose();
    department.dispose();
    dueDate.dispose();
    super.dispose();
  }

  String _userLabel(Map<String, dynamic> user) {
    final name = user['name']?.toString().trim() ?? '';
    final username = user['username']?.toString().trim() ?? '';
    if (name.isEmpty) return username;
    return username.isEmpty || username == name ? name : '$name ($username)';
  }

  void _submit() {
    if (assignmentType == 'user' && assigneeUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte einen Nutzer auswählen.')));
      return;
    }
    if (assignmentType == 'external' && externalAssignee.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Bitte eine verantwortliche Person angeben.')));
      return;
    }
    Navigator.pop(context, {
      if (assignmentType == 'user') 'assigneeUserId': assigneeUserId,
      if (assignmentType == 'external')
        'assignee': externalAssignee.text.trim(),
      'responsibleDepartment': department.text.trim(),
      'dueDate': dateInputToIso(dueDate.text),
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mangel zuweisen'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: assignmentType,
              decoration: const InputDecoration(labelText: 'Zuweisungsart'),
              items: [
                if (widget.assignees.isNotEmpty)
                  const DropdownMenuItem(
                      value: 'user', child: Text('Nutzerkonto')),
                const DropdownMenuItem(
                    value: 'external', child: Text('Externe Person')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => assignmentType = value);
              },
            ),
            const SizedBox(height: 12),
            if (assignmentType == 'user')
              DropdownButtonFormField<String>(
                initialValue: assigneeUserId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Verantwortlicher Nutzer *'),
                items: widget.assignees
                    .map((user) => DropdownMenuItem(
                        value: user['id']?.toString(),
                        child: Text(_userLabel(user),
                            overflow: TextOverflow.ellipsis)))
                    .toList(),
                onChanged: (value) => setState(() => assigneeUserId = value),
              )
            else
              TextField(
                controller: externalAssignee,
                decoration: const InputDecoration(
                    labelText: 'Externe verantwortliche Person *'),
              ),
            TextField(
                controller: department,
                decoration: const InputDecoration(labelText: 'Fachbereich')),
            DateInputField(controller: dueDate, label: 'Frist'),
          ]),
        ),
      ),
      actions: [
        if (hasAssignment)
          TextButton(
            onPressed: () => Navigator.pop(context, {'clearAssignment': true}),
            child: const Text('Zuweisung aufheben'),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(onPressed: _submit, child: const Text('Zuweisen')),
      ],
    );
  }
}

class _DefectFormDialog extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic>? defect;
  final String? initialEntityType;
  final String? initialEntityId;

  const _DefectFormDialog({
    required this.items,
    this.defect,
    this.initialEntityType,
    this.initialEntityId,
  });

  @override
  State<_DefectFormDialog> createState() => _DefectFormDialogState();
}

class _DefectFormDialogState extends State<_DefectFormDialog> {
  late final TextEditingController title;
  late final TextEditingController description;
  late final TextEditingController quantity;
  late final TextEditingController damageType;
  late final TextEditingController cause;
  late final TextEditingController measuresTaken;
  late final TextEditingController assignee;
  late final TextEditingController department;
  late final TextEditingController dueDate;
  late final TextEditingController estimatedCost;
  late final TextEditingController actualCost;
  late final TextEditingController resolution;
  late final TextEditingController recurrence;
  late final TextEditingController duplicate;
  late final TextEditingController contactName;
  late final TextEditingController contactEmail;
  late final TextEditingController contactPhone;
  final List<Map<String, dynamic>> pendingImages = [];
  String priority = 'Normal';
  String risk = 'Keine Angabe';
  String operationalSafety = 'Nicht einsatzfähig';
  String? entityType;
  String? entityId;

  bool get editing => widget.defect != null;

  @override
  void initState() {
    super.initState();
    final value = widget.defect ?? const <String, dynamic>{};
    title = TextEditingController(text: value['title']?.toString() ?? '');
    description =
        TextEditingController(text: value['description']?.toString() ?? '');
    quantity = TextEditingController(
        text: value['affectedQuantity']?.toString() ?? '1');
    damageType =
        TextEditingController(text: value['damageType']?.toString() ?? '');
    cause = TextEditingController(text: value['cause']?.toString() ?? '');
    measuresTaken =
        TextEditingController(text: value['measuresTaken']?.toString() ?? '');
    assignee = TextEditingController(text: value['assignee']?.toString() ?? '');
    department = TextEditingController(
        text: value['responsibleDepartment']?.toString() ?? '');
    dueDate = TextEditingController(text: value['dueDate']?.toString() ?? '');
    estimatedCost =
        TextEditingController(text: value['estimatedCost']?.toString() ?? '');
    actualCost =
        TextEditingController(text: value['actualCost']?.toString() ?? '');
    resolution =
        TextEditingController(text: value['resolution']?.toString() ?? '');
    recurrence =
        TextEditingController(text: value['recurrenceOfId']?.toString() ?? '');
    duplicate =
        TextEditingController(text: value['duplicateOfId']?.toString() ?? '');
    contactName =
        TextEditingController(text: value['contactName']?.toString() ?? '');
    contactEmail =
        TextEditingController(text: value['contactEmail']?.toString() ?? '');
    contactPhone =
        TextEditingController(text: value['contactPhone']?.toString() ?? '');
    priority = value['priority']?.toString() ?? 'Normal';
    risk = value['riskLevel']?.toString() ?? 'Keine Angabe';
    operationalSafety =
        value['operationalSafety']?.toString() ?? 'Nicht einsatzfähig';
    entityType = value['entityType']?.toString() ??
        widget.initialEntityType ??
        (widget.items.isEmpty
            ? null
            : widget.items.first['entityType']?.toString());
    entityId = value['entityId']?.toString() ?? widget.initialEntityId;
  }

  @override
  void dispose() {
    for (final controller in [
      title,
      description,
      quantity,
      damageType,
      cause,
      measuresTaken,
      assignee,
      department,
      dueDate,
      estimatedCost,
      actualCost,
      resolution,
      recurrence,
      duplicate,
      contactName,
      contactEmail,
      contactPhone,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _payload() => {
        if (!editing) 'entityType': entityType,
        if (!editing) 'entityId': entityId,
        if (!editing) 'affectedQuantity': num.tryParse(quantity.text),
        'title': title.text.trim(),
        'description': description.text.trim(),
        'priority': priority,
        'damageType': damageType.text.trim(),
        'cause': cause.text.trim(),
        'measuresTaken': measuresTaken.text.trim(),
        'riskLevel': risk,
        'operationalSafety': operationalSafety,
        'responsibleDepartment': department.text.trim(),
        'contactName': contactName.text.trim(),
        'contactEmail': contactEmail.text.trim(),
        'contactPhone': contactPhone.text.trim(),
        'dueDate': dateInputToIso(dueDate.text),
        'estimatedCost': estimatedCost.text.trim(),
        if (editing) 'actualCost': actualCost.text.trim(),
        if (editing) 'resolution': resolution.text.trim(),
        'recurrenceOfId': recurrence.text.trim(),
        'duplicateOfId': duplicate.text.trim(),
        if (!editing) '_pendingImages': pendingImages,
      };

  Future<void> _selectImages() async {
    final remaining = 10 - pendingImages.length;
    if (remaining <= 0) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
    );
    final selected = files.take(remaining);
    var rejected = 0;
    for (final file in selected) {
      final bytes = await file.readAsBytes();
      if (bytes.length > 8 * 1024 * 1024) {
        rejected += 1;
        continue;
      }
      final extension = file.name.split('.').last.toLowerCase();
      pendingImages.add({
        'fileName': file.name,
        'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
        'fileBase64': base64Encode(bytes),
      });
    }
    if (mounted) {
      setState(() {});
      if (rejected > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '$rejected Bild(er) wurden wegen fehlender Daten oder mehr als 8 MB übersprungen.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final types = widget.items
        .map((item) => item['entityType']?.toString())
        .whereType<String>()
        .toSet()
        .toList();
    final selectedItems =
        widget.items.where((item) => item['entityType'] == entityType).toList();
    if (!editing &&
        entityId != null &&
        !selectedItems.any((item) => item['id'] == entityId)) {
      entityId = null;
    }
    void submit() {
      if (title.text.trim().isEmpty ||
          description.text.trim().isEmpty ||
          (!editing && entityId == null)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Bitte alle Pflichtfelder ausfüllen.')));
        return;
      }
      Navigator.pop(context, _payload());
    }

    final targetSection = _WorkspaceSection(
      title: 'Betroffener Artikel',
      icon: Icons.inventory_2_outlined,
      child: Column(children: [
        DropdownButtonFormField<String>(
          initialValue: entityType,
          decoration: const InputDecoration(labelText: 'Bereich *'),
          items: types
              .map((value) => DropdownMenuItem(
                  value: value,
                  child:
                      Text(value == 'MaterialItem' ? 'Inventar' : 'Kleidung')))
              .toList(),
          onChanged: (value) => setState(() {
            entityType = value;
            entityId = null;
          }),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('$entityType-$entityId'),
          initialValue: entityId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Betroffener Artikel *'),
          items: selectedItems
              .map((item) => DropdownMenuItem(
                  value: item['id']?.toString(),
                  child: Text(
                      '${item['name']} · ${item['inventoryNumber'] ?? '-'}',
                      overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (value) => setState(() => entityId = value),
        ),
        TextField(
          controller: quantity,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Betroffene Menge *'),
        ),
      ]),
    );
    final descriptionSection = _WorkspaceSection(
      title: 'Mangelbeschreibung',
      icon: Icons.report_problem_outlined,
      child: Column(children: [
        TextField(
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Titel *')),
        TextField(
            controller: description,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Beschreibung *')),
        TextField(
            controller: damageType,
            decoration: const InputDecoration(labelText: 'Schadensart')),
        TextField(
            controller: cause,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Ursache')),
        TextField(
            controller: measuresTaken,
            maxLines: 4,
            decoration:
                const InputDecoration(labelText: 'Getroffene Maßnahmen')),
        if (editing)
          TextField(
              controller: resolution,
              maxLines: 4,
              decoration:
                  const InputDecoration(labelText: 'Behebung/Arbeitsnachweis')),
      ]),
    );
    final classificationSection = _WorkspaceSection(
      title: 'Einstufung & Zuständigkeit',
      icon: Icons.tune,
      child: Column(children: [
        DropdownButtonFormField<String>(
          initialValue: priority,
          decoration: const InputDecoration(labelText: 'Priorität'),
          items: _priorities
              .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)))
              .toList(),
          onChanged: (value) => setState(() => priority = value!),
        ),
        DropdownButtonFormField<String>(
          initialValue: risk,
          decoration: const InputDecoration(labelText: 'Gefährdungsstufe'),
          items: const ['Keine Angabe', 'Niedrig', 'Mittel', 'Hoch']
              .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)))
              .toList(),
          onChanged: (value) => setState(() => risk = value!),
        ),
        DropdownButtonFormField<String>(
          initialValue: operationalSafety,
          decoration: const InputDecoration(labelText: 'Einsatzbereitschaft'),
          items: const ['Einsatzfähig', 'Eingeschränkt', 'Nicht einsatzfähig']
              .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)))
              .toList(),
          onChanged: (value) => setState(() => operationalSafety = value!),
        ),
        TextField(
            controller: department,
            decoration:
                const InputDecoration(labelText: 'Zuständiger Fachbereich')),
        DateInputField(controller: dueDate, label: 'Frist'),
        TextField(
            controller: estimatedCost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration:
                const InputDecoration(labelText: 'Geschätzte Kosten (€)')),
        if (editing)
          TextField(
              controller: actualCost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Tatsächliche Kosten (€)')),
      ]),
    );
    final contactSection = _WorkspaceSection(
      title: 'Kontakt & Verknüpfungen',
      icon: Icons.contact_mail_outlined,
      child: Column(children: [
        TextField(
            controller: contactName,
            decoration: const InputDecoration(labelText: 'Kontaktname')),
        TextField(
            controller: contactEmail,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Kontakt-E-Mail')),
        TextField(
            controller: contactPhone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Kontakttelefon')),
        TextField(
            controller: recurrence,
            decoration: const InputDecoration(
                labelText: 'Wiederholung von (Mangel-ID)')),
        TextField(
            controller: duplicate,
            decoration:
                const InputDecoration(labelText: 'Duplikat von (Mangel-ID)')),
      ]),
    );
    final imageSection = _WorkspaceSection(
      title: 'Bilder zum Mangel',
      icon: Icons.photo_library_outlined,
      trailing: OutlinedButton.icon(
        onPressed: pendingImages.length >= 10 ? null : _selectImages,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('JPEG/PNG auswählen'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Maximal 10 Bilder, jeweils höchstens 8 MB.'),
        if (pendingImages.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: pendingImages
                .map((image) => InputChip(
                      label: Text(image['fileName'].toString()),
                      onDeleted: () =>
                          setState(() => pendingImages.remove(image)),
                    ))
                .toList(),
          ),
      ]),
    );

    final screen = MediaQuery.sizeOf(context);
    final fullscreen = screen.width < 720;
    final content = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): submit,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Column(children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
                child: Row(children: [
                  IconButton(
                      tooltip: 'Abbrechen (Esc)',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(editing ? 'Mangel bearbeiten' : 'Mangel melden',
                        style: Theme.of(context).textTheme.headlineSmall),
                  ),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                      onPressed: submit,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Speichern  Strg+S')),
                ]),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                final wide = constraints.maxWidth >= 820;
                final left = Column(children: [
                  if (!editing) ...[
                    targetSection,
                    const SizedBox(height: 14),
                  ],
                  descriptionSection,
                  if (!editing) ...[
                    const SizedBox(height: 14),
                    imageSection,
                  ],
                ]);
                final right = Column(children: [
                  classificationSection,
                  const SizedBox(height: 14),
                  contactSection,
                ]);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(18),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 6, child: left),
                            const SizedBox(width: 14),
                            Expanded(flex: 4, child: right),
                          ],
                        )
                      : Column(children: [
                          left,
                          const SizedBox(height: 14),
                          right,
                        ]),
                );
              }),
            ),
          ]),
        ),
      ),
    );
    if (fullscreen) return Dialog.fullscreen(child: content);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: screen.width.clamp(900, 1220).toDouble(),
        height: screen.height.clamp(620, 900).toDouble(),
        child: content,
      ),
    );
  }
}
