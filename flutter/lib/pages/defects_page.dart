import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
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

class DefectsPage extends StatefulWidget {
  final String token;
  final String? initialEntityType;
  final String? initialEntityId;

  const DefectsPage({
    required this.token,
    this.initialEntityType,
    this.initialEntityId,
    super.key,
  });

  @override
  State<DefectsPage> createState() => _DefectsPageState();
}

class _DefectsPageState extends State<DefectsPage> {
  bool _loading = true;
  bool _showArchived = false;
  String _search = '';
  String _status = 'Alle';
  String _priority = 'Alle';
  String _entityType = 'Alle';
  List<Map<String, dynamic>> _defects = [];
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _notifications = [];
  List<Map<String, dynamic>> _emailImports = [];
  Set<String> _permissions = {};
  Set<String> _roles = {};
  bool _initialCreateOpened = false;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  bool _can(String permission) =>
      _roles.contains('Admin') || _permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _request(String path,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    late http.Response response;
    try {
      switch (method) {
        case 'POST':
          response = await http.post(uri,
              headers: _headers, body: jsonEncode(body ?? {}));
          break;
        case 'PUT':
          response = await http.put(uri,
              headers: _headers, body: jsonEncode(body ?? {}));
          break;
        case 'PATCH':
          response = await http.patch(uri,
              headers: _headers, body: jsonEncode(body ?? {}));
          break;
        case 'DELETE':
          response = await http.delete(uri, headers: _headers);
          break;
        default:
          response = await http.get(uri, headers: _headers);
      }
    } catch (error) {
      if (mounted) _message('Verbindung fehlgeschlagen: $error');
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Die Anfrage ist fehlgeschlagen.';
      try {
        message = jsonDecode(response.body)['error']?.toString() ?? message;
      } catch (_) {}
      if (mounted) _message(message);
      return null;
    }
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body);
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
      _loading = false;
    });
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
            (_entityType == 'Alle' || defect['entityType'] == _entityType);
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
    name.dispose();
    email.dispose();
    phone.dispose();
    reason.dispose();
    if (completed == true) await _load();
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
            final assignee = TextEditingController(
                text: detail['assignee']?.toString() ?? '');
            final department = TextEditingController(
                text: detail['responsibleDepartment']?.toString() ?? '');
            final dueDate = TextEditingController(
                text: detail['dueDate']?.toString() ?? '');
            final payload = await showDialog<Map<String, dynamic>>(
              context: dialogContext,
              builder: (context) => AlertDialog(
                title: const Text('Mangel zuweisen'),
                content: SizedBox(
                  width: 480,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: assignee,
                        decoration: const InputDecoration(
                            labelText: 'Verantwortliche Person *')),
                    TextField(
                        controller: department,
                        decoration:
                            const InputDecoration(labelText: 'Fachbereich')),
                    DateInputField(controller: dueDate, label: 'Frist'),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, {
                            'assignee': assignee.text.trim(),
                            'responsibleDepartment': department.text.trim(),
                            'dueDate': dateInputToIso(dueDate.text),
                          }),
                      child: const Text('Zuweisen')),
                ],
              ),
            );
            assignee.dispose();
            department.dispose();
            dueDate.dispose();
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
                        items: const [
                          'Reparatur',
                          'Beschaffung',
                          'Aussonderung'
                        ]
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
            final result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: const ['jpg', 'jpeg', 'png'],
              withData: true,
            );
            final file = result?.files.single;
            if (file == null || file.bytes == null) return;
            if (file.size > 8 * 1024 * 1024) {
              _message('Ein Bild darf höchstens 8 MB groß sein.');
              return;
            }
            final extension = file.extension?.toLowerCase();
            await _request('/api/defects/${detail['id']}/images',
                method: 'POST',
                body: {
                  'fileName': file.name,
                  'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
                  'fileBase64': base64Encode(file.bytes!),
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
          return AlertDialog(
            title: Text('${detail['defectNumber']} · ${detail['title']}'),
            content: SizedBox(
              width: 800,
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
                    if (!archived)
                      Wrap(spacing: 8, runSpacing: 8, children: [
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
                            tooltip: 'Reparatur, Beschaffung oder Aussonderung',
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
    final values = <String, dynamic>{
      'Schadensart': defect['damageType'],
      'Ursache': defect['cause'],
      'Gefährdung': defect['riskLevel'],
      'Einsatzbereitschaft': defect['operationalSafety'],
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mängelmanagement'),
        actions: [
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
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: _can('defects.report')
          ? FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.report_problem_outlined),
              label: const Text('Mangel melden'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(Icons.forward_to_inbox_outlined, size: 34),
                          const SizedBox(
                            width: 470,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Mängel auch per E-Mail melden',
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold)),
                                SizedBox(height: 4),
                                SelectableText(
                                    'Ausgefüllten Bericht als PDF, PNG oder JPEG zusammen mit optionalen Schadensbildern an maengel@materialkompass.org senden.'),
                              ],
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _downloadTemplate,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('Vorlage herunterladen'),
                          ),
                          Badge(
                            isLabelVisible: _emailImports
                                .any((entry) => entry['status'] == 'pending'),
                            label: Text(
                                '${_emailImports.where((entry) => entry['status'] == 'pending').length}'),
                            child: FilledButton.icon(
                              onPressed: _showEmailQueue,
                              icon: const Icon(Icons.rule_folder_outlined),
                              label: const Text('Prüfwarteschlange'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    SizedBox(
                      width: 280,
                      child: TextField(
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: 'Suchen'),
                        onChanged: (value) => setState(() => _search = value),
                      ),
                    ),
                    _filter('Status', ['Alle', ..._statuses], _status,
                        (value) => setState(() => _status = value)),
                    _filter('Priorität', ['Alle', ..._priorities], _priority,
                        (value) => setState(() => _priority = value)),
                    _filter(
                        'Bereich',
                        const ['Alle', 'MaterialItem', 'ClothingItem'],
                        _entityType,
                        (value) => setState(() => _entityType = value),
                        labels: const {
                          'Alle': 'Alle',
                          'MaterialItem': 'Inventar',
                          'ClothingItem': 'Kleidung',
                        }),
                    FilterChip(
                      label: const Text('Archiv anzeigen'),
                      selected: _showArchived,
                      onSelected: (value) async {
                        _showArchived = value;
                        await _load();
                      },
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Wrap(spacing: 12, children: [
                    Chip(
                        avatar: const Icon(Icons.warning_amber, size: 18),
                        label: Text(
                            '${_defects.where((d) => d['status'] != 'Geprüft/Geschlossen' && d['archivedAt'] == null).length} offen')),
                    Chip(
                        avatar: const Icon(Icons.build, size: 18),
                        label: Text(
                            '${_defects.where((d) => d['status'] == 'In Bearbeitung').length} in Bearbeitung')),
                  ]),
                  if (_filtered.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: Text('Keine Mängel gefunden.')),
                    ),
                  ..._filtered.map((defect) => Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: _priorityColor(
                                defect['priority']?.toString() ?? 'Normal'),
                            foregroundColor: Colors.white,
                            child: const Icon(Icons.report_problem),
                          ),
                          title: Text(
                              '${defect['defectNumber']} · ${defect['title']}'),
                          subtitle: Text(
                              '${defect['entityName']} · ${defect['inventoryNumber'] ?? '-'}\n'
                              '${defect['status']} · ${defect['priority']}'
                              '${defect['assignee']?.toString().isNotEmpty == true ? ' · ${defect['assignee']}' : ''}'),
                          isThreeLine: true,
                          trailing: defect['archivedAt'] == null
                              ? const Icon(Icons.chevron_right)
                              : const Icon(Icons.archive),
                          onTap: () => _showDetail(defect),
                        ),
                      )),
                  const SizedBox(height: 80),
                ],
              ),
            ),
    );
  }

  Widget _filter(String label, List<String> values, String selected,
      ValueChanged<String> changed,
      {Map<String, String> labels = const {}}) {
    return SizedBox(
      width: 190,
      child: DropdownButtonFormField<String>(
        initialValue: selected,
        decoration: InputDecoration(labelText: label),
        items: values
            .map((value) => DropdownMenuItem(
                value: value, child: Text(labels[value] ?? value)))
            .toList(),
        onChanged: (value) {
          if (value != null) changed(value);
        },
      ),
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
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final selected = result.files.take(remaining);
    var rejected = 0;
    for (final file in selected) {
      if (file.bytes == null || file.size > 8 * 1024 * 1024) {
        rejected += 1;
        continue;
      }
      final extension = file.extension?.toLowerCase();
      pendingImages.add({
        'fileName': file.name,
        'mimeType': extension == 'png' ? 'image/png' : 'image/jpeg',
        'fileBase64': base64Encode(file.bytes!),
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
    return AlertDialog(
      title: Text(editing ? 'Mangel bearbeiten' : 'Mangel melden'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(children: [
            if (!editing) ...[
              DropdownButtonFormField<String>(
                initialValue: entityType,
                decoration: const InputDecoration(labelText: 'Bereich *'),
                items: types
                    .map((value) => DropdownMenuItem(
                        value: value,
                        child: Text(
                            value == 'MaterialItem' ? 'Inventar' : 'Kleidung')))
                    .toList(),
                onChanged: (value) => setState(() {
                  entityType = value;
                  entityId = null;
                }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: entityId,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Betroffener Artikel *'),
                items: selectedItems
                    .map((item) => DropdownMenuItem(
                        value: item['id']?.toString(),
                        child: Text(
                            '${item['name']} · ${item['inventoryNumber'] ?? '-'}')))
                    .toList(),
                onChanged: (value) => setState(() => entityId = value),
              ),
              TextField(
                controller: quantity,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Betroffene Menge *'),
              ),
            ],
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Titel *')),
            TextField(
                controller: description,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Beschreibung *')),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Einstufung',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: priority,
                  decoration: const InputDecoration(labelText: 'Priorität'),
                  items: _priorities
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => setState(() => priority = value!),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  initialValue: risk,
                  decoration:
                      const InputDecoration(labelText: 'Gefährdungsstufe'),
                  items: const ['Keine Angabe', 'Niedrig', 'Mittel', 'Hoch']
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => setState(() => risk = value!),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  initialValue: operationalSafety,
                  decoration:
                      const InputDecoration(labelText: 'Einsatzbereitschaft'),
                  items: const [
                    'Einsatzfähig',
                    'Eingeschränkt',
                    'Nicht einsatzfähig'
                  ]
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => operationalSafety = value!),
                ),
              ),
            ]),
            if (!editing) ...[
              const SizedBox(height: 14),
              Row(children: [
                const Expanded(
                    child: Text('Bilder zum Mangel',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                OutlinedButton.icon(
                  onPressed: pendingImages.length >= 10 ? null : _selectImages,
                  icon: const Icon(Icons.add_photo_alternate),
                  label: const Text('JPEG/PNG auswählen'),
                ),
              ]),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Maximal 10 Bilder, jeweils höchstens 8 MB.'),
              ),
              if (pendingImages.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    children: pendingImages
                        .map((image) => InputChip(
                              label: Text(image['fileName'].toString()),
                              onDeleted: () =>
                                  setState(() => pendingImages.remove(image)),
                            ))
                        .toList(),
                  ),
                ),
            ],
            TextField(
                controller: damageType,
                decoration: const InputDecoration(labelText: 'Schadensart')),
            TextField(
                controller: cause,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Ursache')),
            TextField(
                controller: department,
                decoration: const InputDecoration(
                    labelText: 'Zuständiger Fachbereich')),
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Kontaktdaten',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
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
            DateInputField(controller: dueDate, label: 'Frist'),
            TextField(
                controller: estimatedCost,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Geschätzte Kosten (€)')),
            if (editing) ...[
              TextField(
                  controller: actualCost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Tatsächliche Kosten (€)')),
              TextField(
                  controller: resolution,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Behebung/Arbeitsnachweis')),
            ],
            TextField(
                controller: recurrence,
                decoration: const InputDecoration(
                    labelText: 'Wiederholung von (Mangel-ID)')),
            TextField(
                controller: duplicate,
                decoration: const InputDecoration(
                    labelText: 'Duplikat von (Mangel-ID)')),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen')),
        FilledButton(
          onPressed: () {
            if (title.text.trim().isEmpty ||
                description.text.trim().isEmpty ||
                (!editing && entityId == null)) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Bitte alle Pflichtfelder ausfüllen.')));
              return;
            }
            Navigator.pop(context, _payload());
          },
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}
