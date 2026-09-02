import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/app_http_client.dart';
import '../services/authenticated_api_client.dart';
import '../services/debouncer.dart';
import '../services/file_save_mime_type.dart';
import '../services/label_print_service.dart';
import '../widgets/address_input.dart';
import '../widgets/date_input_field.dart';
import '../widgets/keyboard_dropdown_button_form_field.dart';
import '../widgets/label_print_dialogs.dart';

double offerTotalValue(Map offer) {
  final calculated = num.tryParse(
    offer['calculatedGrossTotal']?.toString() ?? '',
  );
  if (calculated != null) return calculated.toDouble();
  return ((num.tryParse(offer['grossTotal']?.toString() ?? '') ?? 0) +
          (num.tryParse(offer['shippingGross']?.toString() ?? '') ?? 0))
      .toDouble();
}

class ProcurementPage extends StatefulWidget {
  final String token;
  final VoidCallback? onLogout;

  const ProcurementPage({required this.token, this.onLogout, super.key});

  @override
  State<ProcurementPage> createState() => _ProcurementPageState();
}

class _ProcurementPageState extends State<ProcurementPage> {
  final _search = TextEditingController();
  final _searchDebouncer = Debouncer();
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _stocks = [];
  List<Map<String, dynamic>> _departments = [];
  List<Map<String, dynamic>> _emailInbox = [];
  String _offerEmailAddress = 'angebote@materialkompass.org';
  Set<String> _permissions = {};
  Set<String> _roles = {};
  Set<String> _departmentIds = {};
  bool _loading = true;
  String? _status;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${widget.token}',
    'Content-Type': 'application/json',
  };
  AuthenticatedApiClient get _api => AuthenticatedApiClient(widget.token);

  bool _can(String permission) => _permissions.contains(permission);
  bool get _canPrintLabels =>
      LabelPrintService.instance.supported && userMayPrintLabels(_roles);

  List<Map<String, dynamic>> get _availableDepartments => _departments
      .where(
        (entry) =>
            entry['active'] != false &&
            (!_roles.contains('Fachbereichsleiter') ||
                _departmentIds.contains(entry['id']?.toString())),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    _search.addListener(_refreshView);
    _load();
  }

  @override
  void dispose() {
    _search.removeListener(_refreshView);
    _searchDebouncer.dispose();
    _search.dispose();
    super.dispose();
  }

  void _refreshView() {
    _searchDebouncer.run(() {
      if (mounted) setState(() {});
    });
  }

  List<Map<String, dynamic>> _asList(http.Response response) =>
      (jsonDecode(response.body) as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final responses = await Future.wait([
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/procurement'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/suppliers'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/categories'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/locations'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/stock-structures'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/auth/me'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/procurement-email-inbox'),
          headers: _headers,
        ),
        AppHttpClient.get(
          Uri.parse('$apiBaseUrl/api/departments'),
          headers: _headers,
        ),
      ]);
      if (responses.any((response) => response.statusCode == 401)) {
        widget.onLogout?.call();
        return;
      }
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Beschaffungsdaten konnten nicht geladen werden.');
      }
      final user = jsonDecode(responses[5].body)['user'] as Map;
      final inbox = jsonDecode(responses[6].body) as Map;
      if (!mounted) return;
      setState(() {
        _requests = _asList(responses[0]);
        _suppliers = _asList(responses[1]);
        _categories = _asList(responses[2]);
        _locations = _asList(responses[3]);
        _stocks = _asList(responses[4]);
        _departments = _asList(responses[7]);
        _emailInbox = ((inbox['entries'] as List?) ?? const [])
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        _offerEmailAddress = inbox['address']?.toString() ?? _offerEmailAddress;
        _permissions = ((user['permissions'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        _roles = ((user['roles'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        _departmentIds = ((user['departmentIds'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message(error.toString(), error: true);
    }
  }

  Future<dynamic> _request(
    String path, {
    String method = 'GET',
    Object? body,
  }) async {
    try {
      return await _api.request(path, method: method, body: body);
    } on AuthenticatedApiException catch (error) {
      if (error.statusCode == 401) widget.onLogout?.call();
      _message(error.message, error: true);
      return null;
    }
  }

  void _message(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text.replaceFirst('Exception: ', '')),
        backgroundColor: error ? Colors.red.shade700 : null,
      ),
    );
  }

  String _supplierName(dynamic id) =>
      _suppliers
          .where((entry) => entry['id'] == id)
          .map((entry) => entry['name'].toString())
          .firstOrNull ??
      '–';

  String _categoryName(dynamic id) =>
      _categories
          .where((entry) => entry['id'] == id)
          .map((entry) => entry['name'].toString())
          .firstOrNull ??
      '–';

  String _date(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? '–'
        : '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}';
  }

  String _money(dynamic value) =>
      '${(num.tryParse(value?.toString() ?? '') ?? 0).toStringAsFixed(2).replaceAll('.', ',')} €';

  List<Map<String, dynamic>> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return _requests.where((entry) {
      final text = [
        entry['number'],
        entry['title'],
        entry['department'],
        entry['costCenter'],
        entry['requestedBy'],
      ].join(' ').toLowerCase();
      return (_status == null || entry['status'] == _status) &&
          (query.isEmpty || text.contains(query));
    }).toList();
  }

  Future<void> _createRequest() async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProcurementRequestDialog(
        categories: _categories,
        departments: _availableDepartments,
        suppliers: _suppliers
            .where((entry) => entry['active'] != false)
            .toList(),
      ),
    );
    if (payload == null) return;
    final created = await _request(
      '/api/procurement',
      method: 'POST',
      body: payload,
    );
    if (created != null) {
      _message('Beschaffungsentwurf wurde angelegt.');
      await _load();
    }
  }

  Future<void> _editRequest(Map<String, dynamic> request) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProcurementRequestDialog(
        categories: _categories,
        departments: _availableDepartments,
        suppliers: _suppliers
            .where((entry) => entry['active'] != false)
            .toList(),
        request: request,
      ),
    );
    if (payload == null) return;
    final saved = await _request(
      '/api/procurement/${request['id']}',
      method: 'PUT',
      body: payload,
    );
    if (saved != null) {
      _message('Beschaffungsentwurf wurde aktualisiert.');
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await _load();
    }
  }

  Future<void> _deleteDraft(Map<String, dynamic> request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entwurf löschen?'),
        content: Text('${request['number']} wird dauerhaft gelöscht.'),
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
    final result = await _request(
      '/api/procurement/${request['id']}',
      method: 'DELETE',
    );
    if (result != null) {
      _message('Entwurf wurde gelöscht.');
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await _load();
    }
  }

  Future<void> _simpleAction(
    Map<String, dynamic> request,
    String action, {
    Object? body,
    String? success,
  }) async {
    final result = await _request(
      '/api/procurement/${request['id']}/$action',
      method: 'POST',
      body: body ?? {},
    );
    if (result != null) {
      if (success != null) _message(success);
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await _load();
    }
  }

  Future<void> _approve(Map<String, dynamic> request, bool approve) async {
    final notes = TextEditingController();
    final resolution = TextEditingController();
    final approvedBudget = TextEditingController(
      text: request['requestedBudgetGross']?.toString() ?? '',
    );
    final isChair = _roles.contains('Vorsitz') || _roles.contains('Admin');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Freigabe erteilen' : 'Antrag ablehnen'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (approve && isChair)
                TextField(
                  controller: approvedBudget,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Freigegebenes Budget *',
                    suffixText: '€',
                  ),
                ),
              if ((request['requestedBudgetGross'] as num? ?? 0) >= 100 &&
                  isChair)
                TextField(
                  controller: resolution,
                  decoration: const InputDecoration(
                    labelText: 'Referenz Vorstandsbeschluss',
                  ),
                ),
              TextField(
                controller: notes,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: approve ? 'Freigabenotiz' : 'Begründung *',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(approve ? 'Freigeben' : 'Ablehnen'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        (!approve && notes.text.trim().isEmpty) ||
        (approve &&
            isChair &&
            (double.tryParse(approvedBudget.text.replaceAll(',', '.')) ?? 0) <=
                0)) {
      return;
    }
    await _simpleAction(
      request,
      'approval',
      body: {
        'decision': approve ? 'approve' : 'reject',
        'role': _roles.contains('Schatzmeister') ? 'Schatzmeister' : 'Vorsitz',
        'notes': notes.text.trim(),
        'boardResolution': resolution.text.trim(),
        'approvedBudgetGross': double.tryParse(
          approvedBudget.text.replaceAll(',', '.'),
        ),
      },
      success: approve ? 'Freigabe wurde erteilt.' : 'Antrag wurde abgelehnt.',
    );
  }

  Future<void> _addOffer(Map<String, dynamic> request) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => OfferDialog(
        request: request,
        suppliers: _suppliers
            .where((entry) => entry['active'] != false)
            .toList(),
      ),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/offers',
      method: 'POST',
      body: payload,
    );
    if (result != null) {
      _message('Angebot wurde hinzugefügt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _editOffer(
    Map<String, dynamic> request,
    Map<String, dynamic> offer,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => OfferDialog(
        request: request,
        offer: offer,
        suppliers: _suppliers
            .where((entry) => entry['active'] != false)
            .toList(),
      ),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/offers/${offer['id']}',
      method: 'PUT',
      body: {
        ...payload,
        'expectedUpdatedAt': offer['updatedAt'] ?? offer['createdAt'],
      },
    );
    if (result != null) {
      _message(
        'Angebot wurde aktualisiert; eine bestehende Auswahl wurde aufgehoben.',
      );
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _selectOffer(
    Map<String, dynamic> request,
    Map<String, dynamic> offer,
  ) async {
    final justification = TextEditingController();
    final offers = (request['offers'] as List? ?? const []).cast<Map>();
    final cheapest = offers
        .map(offerTotalValue)
        .reduce((a, b) => a < b ? a : b);
    final total = offerTotalValue(offer);
    if (total > cheapest) {
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Teureres Angebot auswählen'),
          content: TextField(
            controller: justification,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Begründung *'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, justification.text.trim()),
              child: const Text('Auswählen'),
            ),
          ],
        ),
      );
      if (value == null || value.isEmpty) return;
    }
    final result = await _request(
      '/api/procurement/${request['id']}/select-offer',
      method: 'POST',
      body: {
        'offerId': offer['id'],
        'justification': justification.text.trim(),
      },
    );
    if (result != null) {
      _message('Angebot wurde ausgewählt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _createOrder(Map<String, dynamic> request) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => OrderDialog(
        request: request,
        suppliers: _suppliers
            .where((entry) => entry['active'] != false)
            .toList(),
      ),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/orders',
      method: 'POST',
      body: payload,
    );
    if (result != null) {
      _message('Bestellung ${result['number']} wurde angelegt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _receive(
    Map<String, dynamic> request,
    Map<String, dynamic> order,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ReceiptDialog(request: request, order: order),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/orders/${order['id']}/receipts',
      method: 'POST',
      body: payload,
    );
    if (result != null) {
      _message('Wareneingang ${result['number']} wurde gebucht.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _transfer(
    Map<String, dynamic> request,
    Map<String, dynamic> receipt,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => TransferDialog(
        request: request,
        receipt: receipt,
        locations: _locations,
        stocks: _stocks,
        categories: _categories,
      ),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/receipts/${receipt['id']}/transfer',
      method: 'POST',
      body: payload,
    );
    if (result != null) {
      _message(
        '${(result['created'] as List).length} Inventareinträge wurden erzeugt.',
      );
      if (mounted) Navigator.pop(context);
      await _load();
      if (_canPrintLabels && mounted) {
        final created = (result['created'] as List)
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
        final materials = created
            .where((entry) => entry['entity'] == 'material')
            .toList();
        final clothing = created
            .where((entry) => entry['entity'] == 'clothing')
            .toList();
        if (materials.isNotEmpty) {
          await showLabelPrintDialog(
            context,
            labels: materials
                .map((item) => LabelData.fromItem(item, LabelType.inventory))
                .toList(),
            type: LabelType.inventory,
          );
        }
        if (clothing.isNotEmpty && mounted) {
          await showLabelPrintDialog(
            context,
            labels: clothing
                .map((item) => LabelData.fromItem(item, LabelType.clothing))
                .toList(),
            type: LabelType.clothing,
          );
        }
      }
    }
  }

  Future<void> _upload(Map<String, dynamic> request) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'docx',
        'xlsx',
        'ods',
      ],
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) {
      _message('Die Datei darf maximal 5 MB groß sein.', error: true);
      return;
    }
    if (!mounted) return;
    final type = await showDialog<String>(
      context: context,
      builder: (context) {
        var selected = 'Angebot';
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Dokumenttyp'),
            content: DropdownButtonFormField<String>(
              initialValue: selected,
              items:
                  [
                        'Angebot',
                        'Genehmigung',
                        'Bestellung',
                        'Auftragsbestätigung',
                        'Lieferschein',
                        'Rechnung',
                      ]
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
              onChanged: (value) => setDialogState(() => selected = value!),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: const Text('Hochladen'),
              ),
            ],
          ),
        );
      },
    );
    if (type == null) return;
    final result = await _request(
      '/api/procurement/${request['id']}/documents',
      method: 'POST',
      body: {
        'fileName': file.name,
        'fileBase64': base64Encode(bytes),
        'documentType': type,
      },
    );
    if (result != null) {
      _message('Dokument wurde hinzugefügt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _export(String format) async {
    final data = await _request('/api/procurement/export/$format');
    if (data == null) return;
    final fileName = data['fileName'].toString();
    await FileSaver.instance.saveFile(
      name: fileName.substring(0, fileName.length - format.length - 1),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: format,
      mimeType: MimeType.custom,
      customMimeType: fileMimeType(format),
    );
    _message('$fileName wurde erstellt.');
  }

  Future<void> _downloadDocument(
    Map<String, dynamic> request,
    Map<String, dynamic> document,
  ) async {
    final data = await _request(
      '/api/procurement/${request['id']}/documents/${document['id']}',
    );
    if (data == null) return;
    final fileName = data['fileName'].toString();
    final extension = fileName.contains('.') ? fileName.split('.').last : 'bin';
    final baseName = fileName.endsWith('.$extension')
        ? fileName.substring(0, fileName.length - extension.length - 1)
        : fileName;
    await FileSaver.instance.saveFile(
      name: baseName,
      bytes: base64Decode(data['fileBase64']),
      fileExtension: extension,
      mimeType: MimeType.custom,
      customMimeType: fileMimeType(extension),
    );
    _message('$fileName wurde gespeichert.');
  }

  Future<void> _printDetail(Map<String, dynamic> request, String type) async {
    final data = await _request(
      '/api/procurement/${request['id']}/print/$type',
    );
    if (data == null) return;
    final fileName = data['fileName'].toString();
    await FileSaver.instance.saveFile(
      name: fileName.substring(0, fileName.length - 4),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: 'pdf',
      mimeType: MimeType.custom,
      customMimeType: fileMimeType('pdf'),
    );
    _message('$fileName wurde erstellt.');
  }

  Future<void> _downloadEmailAttachment(
    Map<String, dynamic> email,
    Map<String, dynamic> attachment,
  ) async {
    final data = await _request(
      '/api/procurement-email-inbox/${email['id']}/attachments/${attachment['id']}',
    );
    if (data == null) return;
    final fileName = data['fileName'].toString();
    final extension = fileName.contains('.') ? fileName.split('.').last : 'bin';
    final baseName = fileName.endsWith('.$extension')
        ? fileName.substring(0, fileName.length - extension.length - 1)
        : fileName;
    await FileSaver.instance.saveFile(
      name: baseName,
      bytes: base64Decode(data['fileBase64']),
      fileExtension: extension,
      mimeType: MimeType.custom,
      customMimeType: fileMimeType(extension),
    );
  }

  Future<void> _processEmailOffer(Map<String, dynamic> email) async {
    final eligibleRequests = _requests
        .where(
          (request) =>
              request['status'] == 'Beantragt' ||
              request['status'] == 'Genehmigt',
        )
        .toList();
    final activeSuppliers = _suppliers
        .where((entry) => entry['active'] != false)
        .toList();
    if (eligibleRequests.isEmpty || activeSuppliers.isEmpty) {
      _message(
        'Es wird ein offener Vorgang und ein aktiver Lieferant benötigt.',
        error: true,
      );
      return;
    }
    var requestId = email['requestId']?.toString();
    if (!eligibleRequests.any((entry) => entry['id'] == requestId)) {
      requestId = eligibleRequests.first['id'].toString();
    }
    final selectedRequestId = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Beschaffungsvorgang auswählen'),
          content: SizedBox(
            width: 560,
            child: DropdownButtonFormField<String>(
              initialValue: requestId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Beschaffungsvorgang *',
                border: OutlineInputBorder(),
              ),
              items: eligibleRequests
                  .map(
                    (entry) => DropdownMenuItem(
                      value: entry['id'].toString(),
                      child: Text('${entry['number']} · ${entry['title']}'),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setDialogState(() => requestId = value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, requestId),
              child: const Text('Weiter'),
            ),
          ],
        ),
      ),
    );
    if (selectedRequestId == null) return;
    if (!mounted) return;
    final selectedRequest = eligibleRequests.firstWhere(
      (entry) => entry['id'].toString() == selectedRequestId,
    );
    var supplierId = email['supplierId']?.toString();
    if (!activeSuppliers.any((entry) => entry['id'] == supplierId)) {
      supplierId = activeSuppliers.first['id'].toString();
    }
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => OfferDialog(
        request: selectedRequest,
        suppliers: activeSuppliers,
        initialSupplierId: supplierId,
        initialNotes: email['messageText']?.toString() ?? '',
        title: 'Angebot aus E-Mail übernehmen',
        saveLabel: 'Übernehmen',
      ),
    );
    if (payload == null) return;
    final result = await _request(
      '/api/procurement-email-inbox/${email['id']}/process',
      method: 'POST',
      body: {...payload, 'requestId': selectedRequestId},
    );
    if (result != null) {
      _message('Angebot und Anhänge wurden übernommen.');
      await _load();
    }
  }

  Future<void> _discardEmailOffer(Map<String, dynamic> email) async {
    final reason = await _textPrompt('E-Mail verwerfen', 'Begründung');
    if (reason == null) return;
    final result = await _request(
      '/api/procurement-email-inbox/${email['id']}/discard',
      method: 'POST',
      body: {'reason': reason},
    );
    if (result != null) await _load();
  }

  Future<void> _supplierDialog([Map<String, dynamic>? supplier]) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => SupplierDialog(supplier: supplier, token: widget.token),
    );
    if (payload == null) return;
    final result = await _request(
      supplier == null ? '/api/suppliers' : '/api/suppliers/${supplier['id']}',
      method: supplier == null ? 'POST' : 'PUT',
      body: payload,
    );
    if (result != null) {
      _message('Lieferant wurde gespeichert.');
      await _load();
    }
  }

  Future<void> _showDetails(Map<String, dynamic> initial) async {
    final fresh = await _request('/api/procurement/${initial['id']}');
    if (fresh == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: ProcurementDetail(
          request: Map<String, dynamic>.from(fresh),
          supplierName: _supplierName,
          categoryName: _categoryName,
          money: _money,
          date: _date,
          canApprove: _can('procurement.approve'),
          canOrder: _can('procurement.order'),
          canReceive: _can('procurement.receive'),
          canWrite: _can('procurement.request'),
          onSubmit: () => _simpleAction(
            fresh,
            'submit',
            success: 'Antrag wurde eingereicht.',
          ),
          onEdit: () => _editRequest(fresh),
          onDelete: () => _deleteDraft(fresh),
          onApprove: (approve) => _approve(fresh, approve),
          onAddOffer: () => _addOffer(fresh),
          onEditOffer: (offer) => _editOffer(fresh, offer),
          onSelectOffer: (offer) => _selectOffer(fresh, offer),
          onCreateOrder: () => _createOrder(fresh),
          onReceive: (order) => _receive(fresh, order),
          onTransfer: (receipt) => _transfer(fresh, receipt),
          onUpload: () => _upload(fresh),
          onDownloadDocument: (document) => _downloadDocument(fresh, document),
          onPrint: (type) => _printDetail(fresh, type),
          onCancel: () async {
            final reason = await _textPrompt(
              'Vorgang stornieren',
              'Begründung *',
            );
            if (reason != null && reason.isNotEmpty) {
              await _simpleAction(
                fresh,
                'cancel',
                body: {'reason': reason},
                success: 'Vorgang wurde storniert.',
              );
            }
          },
        ),
      ),
    );
  }

  Future<String?> _textPrompt(String title, String label) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Bestätigen'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Beschaffung'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: Icon(Icons.list_alt), text: 'Vorgänge'),
              Tab(icon: Icon(Icons.approval_outlined), text: 'Freigaben'),
              Tab(icon: Icon(Icons.inbox_outlined), text: 'Postbox'),
              Tab(
                icon: Icon(Icons.local_shipping_outlined),
                text: 'Lieferanten',
              ),
            ],
          ),
          actions: [
            if (_canPrintLabels)
              IconButton(
                onPressed: () => showPrinterSettingsDialog(context),
                tooltip: 'Etikettendrucker einrichten',
                icon: const Icon(Icons.settings_outlined),
              ),
            if (_canPrintLabels)
              IconButton(
                onPressed: () => showPrintQueueDialog(context),
                tooltip: 'Zwischengespeicherte Druckaufträge',
                icon: const Icon(Icons.queue),
              ),
            IconButton(
              onPressed: _load,
              tooltip: 'Aktualisieren',
              icon: const Icon(Icons.refresh),
            ),
            if (widget.onLogout != null)
              IconButton(
                onPressed: widget.onLogout,
                tooltip: 'Abmelden',
                icon: const Icon(Icons.logout),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _overview(),
                  _approvals(),
                  _emailInboxView(),
                  _supplierView(),
                ],
              ),
        floatingActionButton: _can('procurement.request')
            ? FloatingActionButton.extended(
                onPressed: _createRequest,
                icon: const Icon(Icons.add),
                label: const Text('Vorgang anlegen'),
              )
            : null,
      ),
    );
  }

  Widget _toolbar({bool approvalsOnly = false}) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
    child: Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 310,
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Nummer, Titel, Fachbereich oder Antragsteller',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (!approvalsOnly)
          SizedBox(
            width: 210,
            child: DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
              ),
              items:
                  [
                        'Alle',
                        'Entwurf',
                        'Beantragt',
                        'Genehmigt',
                        'Abgelehnt',
                        'Bestellt',
                        'Teilweise geliefert',
                        'Geliefert',
                        'Abgeschlossen',
                        'Storniert',
                      ]
                      .map(
                        (value) => DropdownMenuItem(
                          value: value == 'Alle' ? null : value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
              onChanged: (value) => setState(() => _status = value),
            ),
          ),
        if (!approvalsOnly && _can('procurement.request'))
          FilledButton.icon(
            onPressed: _createRequest,
            icon: const Icon(Icons.add),
            label: const Text('Vorgang anlegen'),
          ),
        if (_can('procurement.export'))
          PopupMenuButton<String>(
            tooltip: 'Exportieren',
            onSelected: _export,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'xlsx', child: Text('Excel (.xlsx)')),
              PopupMenuItem(value: 'ods', child: Text('OpenDocument (.ods)')),
              PopupMenuItem(value: 'pdf', child: Text('Druckansicht (.pdf)')),
            ],
            child: OutlinedButton.icon(
              onPressed: null,
              icon: Icon(Icons.download),
              label: Text('Exportieren'),
            ),
          ),
      ],
    ),
  );

  Widget _overview() => Column(
    children: [
      _toolbar(),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20),
        child: Card(
          child: ListTile(
            leading: Icon(Icons.forward_to_inbox_outlined),
            title: Text('Lieferscheine und Angebote per E-Mail einreichen'),
            subtitle: Text(
              'Lieferscheine und Angebote können über '
              'angebote@materialkompass.org eingereicht werden. Wenn eine '
              'eindeutige Zuordnung möglich ist, werden sie dem passenden '
              'Vorgang zugeordnet.',
            ),
          ),
        ),
      ),
      Expanded(child: _requestList(_filtered)),
    ],
  );

  Widget _approvals() {
    final pending = _filtered
        .where((entry) => entry['status'] == 'Beantragt')
        .toList();
    return Column(
      children: [
        _toolbar(approvalsOnly: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${pending.length} Antrag/Anträge warten auf eine Entscheidung',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _requestList(pending, approvalButtons: true)),
      ],
    );
  }

  Widget _emailInboxView() {
    final open = _emailInbox
        .where(
          (entry) =>
              entry['status'] != 'verarbeitet' &&
              entry['status'] != 'verworfen',
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.forward_to_inbox_outlined),
              title: const Text('Angebote per E-Mail empfangen'),
              subtitle: Text(
                'Lieferanten senden Angebote an $_offerEmailAddress. Die Vorgangsnummer im Betreff ermöglicht die automatische Zuordnung.',
              ),
              trailing: Chip(label: Text('${open.length} offen')),
            ),
          ),
        ),
        Expanded(
          child: _emailInbox.isEmpty
              ? const Center(
                  child: Text('Noch keine Angebots-E-Mails eingegangen.'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  itemCount: _emailInbox.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final email = _emailInbox[index];
                    final attachments =
                        ((email['attachments'] as List?) ?? const [])
                            .map(
                              (entry) =>
                                  Map<String, dynamic>.from(entry as Map),
                            )
                            .toList();
                    final request = _requests
                        .where((entry) => entry['id'] == email['requestId'])
                        .firstOrNull;
                    final completed =
                        email['status'] == 'verarbeitet' ||
                        email['status'] == 'verworfen';
                    return Card(
                      child: ExpansionTile(
                        leading: Icon(
                          completed
                              ? Icons.mark_email_read_outlined
                              : Icons.mark_email_unread_outlined,
                        ),
                        title: Text(
                          email['subject']?.toString() ?? 'Ohne Betreff',
                        ),
                        subtitle: Text(
                          [
                            email['senderName']?.toString().isNotEmpty == true
                                ? '${email['senderName']} <${email['sender']}>'
                                : email['sender'],
                            request == null
                                ? 'nicht zugeordnet'
                                : '${request['number']} · ${request['title']}',
                            email['status'],
                          ].join(' · '),
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          20,
                          0,
                          20,
                          16,
                        ),
                        children: [
                          if (email['problem']?.toString().isNotEmpty == true)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                email['problem'].toString(),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          if (email['messageText']?.toString().isNotEmpty ==
                              true)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  email['messageText'].toString(),
                                  maxLines: 8,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: attachments
                                .map(
                                  (attachment) => ActionChip(
                                    avatar: const Icon(
                                      Icons.attach_file_outlined,
                                      size: 18,
                                    ),
                                    label: Text(
                                      attachment['fileName'].toString(),
                                    ),
                                    onPressed: () => _downloadEmailAttachment(
                                      email,
                                      attachment,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          if (!completed && _can('procurement.request')) ...[
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: () => _discardEmailOffer(email),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Verwerfen'),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.icon(
                                  onPressed: attachments.isEmpty
                                      ? null
                                      : () => _processEmailOffer(email),
                                  icon: const Icon(
                                    Icons.move_to_inbox_outlined,
                                  ),
                                  label: const Text('Angebot übernehmen'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _requestList(
    List<Map<String, dynamic>> entries, {
    bool approvalButtons = false,
  }) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_add,
              size: 54,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text('Keine passenden Beschaffungsvorgänge.'),
            if (_can('procurement.request') && !approvalButtons) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _createRequest,
                icon: const Icon(Icons.add),
                label: const Text('Ersten Vorgang anlegen'),
              ),
            ],
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) {
        final entry = entries[index];
        return Card(
          child: ListTile(
            onTap: () => _showDetails(entry),
            leading: CircleAvatar(
              backgroundColor: _statusColor(
                entry['status'],
              ).withValues(alpha: .15),
              child: Icon(
                Icons.shopping_cart_outlined,
                color: _statusColor(entry['status']),
              ),
            ),
            title: Text(
              '${entry['number']} · ${entry['title']}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${entry['requestedBy']} · ${entry['department']?.toString().isNotEmpty == true ? entry['department'] : 'ohne Fachbereich'} · Wunsch ${_date(entry['desiredDeliveryDate'])}',
            ),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  _money(entry['requestedBudgetGross']),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Chip(
                  label: Text(entry['status']),
                  side: BorderSide(color: _statusColor(entry['status'])),
                ),
                if (approvalButtons && _can('procurement.approve'))
                  IconButton(
                    onPressed: () => _approve(entry, true),
                    tooltip: 'Freigeben',
                    icon: const Icon(
                      Icons.check_circle_outline,
                      color: Colors.green,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Color _statusColor(dynamic status) => switch (status) {
    'Genehmigt' || 'Abgeschlossen' => Colors.green.shade700,
    'Abgelehnt' || 'Storniert' => Colors.red.shade700,
    'Beantragt' || 'Teilweise geliefert' => Colors.orange.shade800,
    'Geliefert' => Colors.teal.shade700,
    _ => Colors.blueGrey.shade700,
  };

  String _supplierAddress(Map<String, dynamic> supplier) {
    final structured = [
      [
        supplier['street'],
        supplier['houseNumber'],
      ].where((value) => value?.toString().trim().isNotEmpty == true).join(' '),
      [
        supplier['postalCode'],
        supplier['city'],
      ].where((value) => value?.toString().trim().isNotEmpty == true).join(' '),
      supplier['country']?.toString().trim() ?? '',
    ].where((value) => value.isNotEmpty).join(', ');
    return structured.isNotEmpty
        ? structured
        : supplier['address']?.toString().trim() ?? '';
  }

  Widget _supplierView() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Lieferantenverwaltung',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (_can('suppliers.write'))
              FilledButton.icon(
                onPressed: () => _supplierDialog(),
                icon: const Icon(Icons.add_business),
                label: const Text('Lieferant anlegen'),
              ),
          ],
        ),
      ),
      Expanded(
        child: _suppliers.isEmpty
            ? const Center(child: Text('Keine Lieferanten vorhanden.'))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                itemCount: _suppliers.length,
                itemBuilder: (_, index) {
                  final supplier = _suppliers[index];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        supplier['active'] == false
                            ? Icons.block
                            : Icons.local_shipping_outlined,
                      ),
                      title: Text(supplier['name']),
                      subtitle: Text(
                        [
                              _supplierAddress(supplier),
                              supplier['customerNumber'],
                              supplier['email'],
                              supplier['phone'],
                              supplier['paymentTerms'],
                            ]
                            .where(
                              (value) => value?.toString().isNotEmpty == true,
                            )
                            .join(' · '),
                      ),
                      trailing: _can('suppliers.write')
                          ? IconButton(
                              onPressed: () => _supplierDialog(supplier),
                              icon: const Icon(Icons.edit_outlined),
                            )
                          : null,
                    ),
                  );
                },
              ),
      ),
    ],
  );
}

class ProcurementRequestDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> departments;
  final List<Map<String, dynamic>> suppliers;
  final Map<String, dynamic>? request;
  const ProcurementRequestDialog({
    required this.categories,
    required this.departments,
    required this.suppliers,
    this.request,
    super.key,
  });
  @override
  State<ProcurementRequestDialog> createState() =>
      _ProcurementRequestDialogState();
}

class _ProcurementRequestDialogState extends State<ProcurementRequestDialog> {
  final title = TextEditingController(),
      reason = TextEditingController(),
      costCenter = TextEditingController(),
      requestedBudget = TextEditingController(),
      desiredDate = TextEditingController(),
      notes = TextEditingController();
  final items = <_RequestItemControllers>[];
  String priority = 'Normal';
  String? departmentId;
  String? supplier;

  Map<String, dynamic>? _category(String? id) => widget.categories
      .where((entry) => entry['id']?.toString() == id)
      .firstOrNull;

  bool _isWardrobeItem(_RequestItemControllers item) =>
      _category(item.categoryId)?['useInWardrobe'] == true;

  List<String> _sizesForItem(_RequestItemControllers item) {
    final selected = _category(item.subcategoryId ?? item.categoryId);
    final own = (selected?['sizes'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
    if (own.isNotEmpty) return own;
    return (_category(item.categoryId)?['sizes'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final request = widget.request;
    if (request == null) {
      items.add(_RequestItemControllers());
      return;
    }
    title.text = request['title']?.toString() ?? '';
    reason.text = request['reason']?.toString() ?? '';
    departmentId = request['departmentId']?.toString();
    if (!widget.departments.any(
      (entry) => entry['id']?.toString() == departmentId,
    )) {
      final departmentName = request['department']?.toString();
      departmentId = widget.departments
          .where((entry) => entry['name']?.toString() == departmentName)
          .map((entry) => entry['id']?.toString())
          .firstOrNull;
    }
    costCenter.text = request['costCenter']?.toString() ?? '';
    requestedBudget.text = request['requestedBudgetGross']?.toString() ?? '';
    desiredDate.text = formatDateForInput(request['desiredDeliveryDate']);
    notes.text = request['notes']?.toString() ?? '';
    priority = request['priority']?.toString() ?? 'Normal';
    supplier = request['preferredSupplierId']?.toString();
    items.addAll(
      (request['items'] as List? ?? const []).map(
        (raw) => _RequestItemControllers.from(Map<String, dynamic>.from(raw)),
      ),
    );
    if (items.isEmpty) items.add(_RequestItemControllers());
  }

  @override
  void dispose() {
    for (final c in [
      title,
      reason,
      costCenter,
      requestedBudget,
      desiredDate,
      notes,
    ]) {
      c.dispose();
    }
    for (final item in items) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.request == null
          ? 'Beschaffungsantrag anlegen'
          : 'Beschaffungsentwurf bearbeiten',
    ),
    content: SizedBox(
      width: 880,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                field(title, 'Titel *', 420),
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                    initialValue: departmentId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Fachbereich'),
                    hint: const Text('Bitte auswählen'),
                    items: widget.departments
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry['id'].toString(),
                            child: Text(
                              entry['name'].toString(),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: widget.departments.isEmpty
                        ? null
                        : (value) => setState(() => departmentId = value),
                  ),
                ),
                field(costCenter, 'Kostenstelle', 180),
                field(requestedBudget, 'Beantragtes Budget *', 210),
                field(reason, 'Begründung *', 640, lines: 2),
                dateField(desiredDate, 'Wunschlieferdatum', 230),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    initialValue: priority,
                    decoration: const InputDecoration(labelText: 'Priorität'),
                    items: ['Niedrig', 'Normal', 'Hoch', 'Dringend']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) => setState(() => priority = v!),
                  ),
                ),
                SizedBox(
                  width: 280,
                  child: DropdownButtonFormField<String>(
                    initialValue: supplier,
                    decoration: const InputDecoration(
                      labelText: 'Bevorzugter Lieferant',
                    ),
                    items: widget.suppliers
                        .map(
                          (v) => DropdownMenuItem(
                            value: v['id'].toString(),
                            child: Text(v['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => supplier = v),
                  ),
                ),
                field(notes, 'Notizen', 640, lines: 2),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  'Positionen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => items.add(_RequestItemControllers())),
                  icon: const Icon(Icons.add),
                  label: const Text('Position'),
                ),
              ],
            ),
            ...items.asMap().entries.map(
              (entry) => _itemRow(entry.key, entry.value),
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
        onPressed: _save,
        child: Text(
          widget.request == null ? 'Entwurf speichern' : 'Änderungen speichern',
        ),
      ),
    ],
  );
  Widget _itemRow(int index, _RequestItemControllers item) {
    final mains = widget.categories
        .where((entry) => entry['parentId'] == null)
        .toList();
    final subs = widget.categories
        .where((entry) => entry['parentId'] == item.categoryId)
        .toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            field(item.name, 'Bezeichnung *', 250),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: item.categoryId,
                decoration: const InputDecoration(
                  labelText: 'Hauptkategorie *',
                ),
                items: mains
                    .map(
                      (v) => DropdownMenuItem(
                        value: v['id'].toString(),
                        child: Text(v['name']),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  item.categoryId = v;
                  item.subcategoryId = null;
                  item.size.clear();
                }),
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<String>(
                initialValue: item.subcategoryId,
                decoration: const InputDecoration(labelText: 'Unterkategorie'),
                items: subs
                    .map(
                      (v) => DropdownMenuItem(
                        value: v['id'].toString(),
                        child: Text(v['name']),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  item.subcategoryId = v;
                  item.size.clear();
                }),
              ),
            ),
            if (_isWardrobeItem(item))
              if (_sizesForItem(item).isNotEmpty)
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey(
                      'request-size-${item.categoryId}-${item.subcategoryId}-${item.size.text}',
                    ),
                    initialValue: _sizesForItem(item).contains(item.size.text)
                        ? item.size.text
                        : null,
                    decoration: const InputDecoration(labelText: 'Größe *'),
                    items: _sizesForItem(item)
                        .map(
                          (size) =>
                              DropdownMenuItem(value: size, child: Text(size)),
                        )
                        .toList(),
                    onChanged: (value) => item.size.text = value ?? '',
                  ),
                )
              else
                field(item.size, 'Größe', 130),
            field(item.quantity, 'Menge *', 100),
            field(item.unit, 'Einheit', 110),
            SizedBox(
              width: 105,
              child: DropdownButtonFormField<int>(
                initialValue: item.taxRate,
                decoration: const InputDecoration(labelText: 'MwSt.'),
                items: [0, 7, 19]
                    .map((v) => DropdownMenuItem(value: v, child: Text('$v %')))
                    .toList(),
                onChanged: (v) => setState(() => item.taxRate = v!),
              ),
            ),
            if (items.length > 1)
              IconButton(
                onPressed: () => setState(() {
                  item.dispose();
                  items.removeAt(index);
                }),
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (title.text.trim().isEmpty ||
        reason.text.trim().isEmpty ||
        (double.tryParse(requestedBudget.text.replaceAll(',', '.')) ?? 0) <=
            0 ||
        items.any(
          (i) =>
              i.name.text.trim().isEmpty ||
              i.categoryId == null ||
              (_isWardrobeItem(i) &&
                  _sizesForItem(i).isNotEmpty &&
                  !_sizesForItem(i).contains(i.size.text)) ||
              (double.tryParse(i.quantity.text.replaceAll(',', '.')) ?? 0) <= 0,
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte alle Pflichtfelder ausfüllen.')),
      );
      return;
    }
    Navigator.pop(context, {
      'title': title.text.trim(),
      'reason': reason.text.trim(),
      'departmentId': departmentId,
      'costCenter': costCenter.text.trim(),
      'requestedBudgetGross': double.tryParse(
        requestedBudget.text.replaceAll(',', '.'),
      ),
      'desiredDeliveryDate': dateInputToIso(desiredDate.text),
      'priority': priority,
      'notes': notes.text.trim(),
      'preferredSupplierId': supplier,
      'items': items
          .map(
            (i) => {
              'name': i.name.text.trim(),
              'categoryId': i.categoryId,
              'subcategoryId': i.subcategoryId,
              'size': i.size.text.trim(),
              'quantity': double.tryParse(i.quantity.text.replaceAll(',', '.')),
              'unit': i.unit.text.trim(),
              'taxRate': i.taxRate,
            },
          )
          .toList(),
    });
  }
}

class _RequestItemControllers {
  final name = TextEditingController(),
      quantity = TextEditingController(text: '1'),
      unit = TextEditingController(text: 'Stück'),
      size = TextEditingController();
  String? categoryId, subcategoryId;
  int taxRate = 19;

  _RequestItemControllers();

  _RequestItemControllers.from(Map<String, dynamic> item) {
    name.text = item['name']?.toString() ?? '';
    quantity.text = item['quantity']?.toString() ?? '1';
    unit.text = item['unit']?.toString() ?? 'Stück';
    size.text = item['size']?.toString() ?? '';
    categoryId = item['categoryId']?.toString();
    subcategoryId = item['subcategoryId']?.toString();
    taxRate = int.tryParse(item['taxRate']?.toString() ?? '') ?? 19;
  }

  void dispose() {
    name.dispose();
    quantity.dispose();
    unit.dispose();
    size.dispose();
  }
}

Widget field(
  TextEditingController controller,
  String label,
  double width, {
  int lines = 1,
}) => SizedBox(
  width: width,
  child: TextField(
    controller: controller,
    maxLines: lines,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  ),
);

Widget dateField(
  TextEditingController controller,
  String label,
  double width, {
  bool required = false,
}) => DateInputField(
  controller: controller,
  label: label,
  width: width,
  required: required,
);

class OfferDialog extends StatefulWidget {
  final Map<String, dynamic> request;
  final List<Map<String, dynamic>> suppliers;
  final Map<String, dynamic>? offer;
  final String? initialSupplierId, initialNotes;
  final String title, saveLabel;
  const OfferDialog({
    required this.request,
    required this.suppliers,
    this.offer,
    this.initialSupplierId,
    this.initialNotes,
    this.title = 'Angebot erfassen',
    this.saveLabel = 'Speichern',
    super.key,
  });
  @override
  State<OfferDialog> createState() => _OfferDialogState();
}

class _OfferDialogState extends State<OfferDialog> {
  String? supplier;
  final number = TextEditingController(),
      date = TextEditingController(),
      valid = TextEditingController(),
      days = TextEditingController(),
      documentTotal = TextEditingController(),
      notes = TextEditingController();
  late final List<_OfferLine> lines;
  late final List<_OfferComponentLine> components;
  String? error;

  @override
  void initState() {
    super.initState();
    final offer = widget.offer;
    supplier = offer?['supplierId']?.toString() ?? widget.initialSupplierId;
    number.text = offer?['offerNumber']?.toString() ?? '';
    date.text = _inputDate(offer?['offerDate']);
    valid.text = _inputDate(offer?['validUntil']);
    days.text = offer?['deliveryDays']?.toString() ?? '';
    notes.text = offer?['notes']?.toString() ?? widget.initialNotes ?? '';
    final savedItems = (offer?['items'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    lines = (widget.request['items'] as List? ?? const []).whereType<Map>().map(
      (raw) {
        final item = Map<String, dynamic>.from(raw);
        final saved = savedItems
            .where((entry) => entry['requestItemId'] == item['id'])
            .firstOrNull;
        final legacySingleTotal =
            saved == null &&
                offer != null &&
                (widget.request['items'] as List).length == 1
            ? offer['grossTotal']?.toString() ?? ''
            : '';
        return _OfferLine(
          item,
          offered: saved?['offered'] != false,
          total: saved?['grossTotal']?.toString() ?? legacySingleTotal,
        );
      },
    ).toList();
    final savedComponents = (offer?['components'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
    Map<String, dynamic>? component(String kind) =>
        savedComponents.where((entry) => entry['kind'] == kind).firstOrNull;
    final shipping = component('shipping');
    final discount = component('discount');
    components = [
      _OfferComponentLine.fixed(
        'shipping',
        'Versandkosten',
        shipping?['grossAmount']?.toString() ??
            offer?['shippingGross']?.toString() ??
            '0',
        'add',
      ),
      _OfferComponentLine.fixed(
        'discount',
        'Rabatt',
        discount?['grossAmount']?.toString() ??
            offer?['discountGross']?.toString() ??
            '0',
        'subtract',
      ),
      ...savedComponents
          .where((entry) => entry['kind'] == 'custom')
          .map(
            (entry) => _OfferComponentLine.custom(
              entry['label']?.toString() ?? '',
              entry['grossAmount']?.toString() ?? '0',
              entry['operation'] == 'subtract' ? 'subtract' : 'add',
            ),
          ),
    ];
    documentTotal.text =
        offer?['documentGrossTotal']?.toString() ??
        (offer == null ? '' : offerTotalValue(offer).toStringAsFixed(2));
    for (final controller in _amountControllers) {
      controller.addListener(_recalculate);
    }
  }

  String _inputDate(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null ? '' : formatDateForInput(parsed);
  }

  Iterable<TextEditingController> get _amountControllers => [
    documentTotal,
    ...lines.map((line) => line.total),
    ...components.map((line) => line.amount),
  ];

  int? _cents(String value, {bool signed = false}) {
    final raw = value.trim().replaceAll(' ', '');
    if (raw.isEmpty) return null;
    final normalized = raw.contains(',')
        ? raw.replaceAll('.', '').replaceAll(',', '.')
        : raw;
    if (!RegExp(r'^[+-]?\d+(?:\.\d{1,2})?$').hasMatch(normalized)) {
      return null;
    }
    final parsed = double.tryParse(normalized);
    if (parsed == null || !parsed.isFinite) return null;
    final cents = (parsed * 100).round();
    if (!signed && cents < 0) return null;
    return cents;
  }

  int get _calculatedCents {
    var result = 0;
    for (final line in lines) {
      if (line.offered) result += _cents(line.total.text) ?? 0;
    }
    for (final component in components) {
      final amount =
          _cents(component.amount.text, signed: component.kind == 'discount') ??
          0;
      result += component.operation == 'subtract' ? -amount : amount;
    }
    return result;
  }

  int? get _documentCents => _cents(documentTotal.text);
  bool get _matches =>
      _documentCents != null &&
      _documentCents == _calculatedCents &&
      _calculatedCents > 0;
  String _formatCents(int cents) =>
      '${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')} €';

  void _recalculate() {
    if (mounted) setState(() => error = null);
  }

  void _addComponent() {
    final component = _OfferComponentLine.custom('', '0', 'add');
    component.amount.addListener(_recalculate);
    setState(() => components.add(component));
  }

  void _removeComponent(_OfferComponentLine component) {
    component.amount.removeListener(_recalculate);
    component.dispose();
    setState(() => components.remove(component));
  }

  void _save() {
    if (supplier == null) {
      setState(() => error = 'Bitte einen Lieferanten auswählen.');
      return;
    }
    if (!lines.any((line) => line.offered)) {
      setState(() => error = 'Mindestens eine Position muss angeboten werden.');
      return;
    }
    if (lines.any(
      (line) => line.offered && (_cents(line.total.text) ?? 0) <= 0,
    )) {
      setState(
        () => error =
            'Für jede angebotene Position ist eine positive Bruttosumme erforderlich.',
      );
      return;
    }
    final shipping = components.firstWhere((line) => line.kind == 'shipping');
    if (_cents(shipping.amount.text) == null) {
      setState(() => error = 'Versandkosten dürfen nicht negativ sein.');
      return;
    }
    final discount = components.firstWhere((line) => line.kind == 'discount');
    if (_cents(discount.amount.text, signed: true) == null) {
      setState(() => error = 'Der Rabatt ist ungültig.');
      return;
    }
    if (components
        .where((line) => line.kind == 'custom')
        .any(
          (line) =>
              line.label.text.trim().isEmpty ||
              _cents(line.amount.text) == null,
        )) {
      setState(
        () => error =
            'Zusätzliche Bestandteile benötigen eine Bezeichnung und einen nicht negativen Betrag.',
      );
      return;
    }
    if (!_matches) {
      setState(
        () => error =
            'Die Kontrollsumme muss centgenau mit der berechneten Angebotssumme übereinstimmen.',
      );
      return;
    }
    Navigator.pop(context, {
      'supplierId': supplier,
      'offerNumber': number.text.trim(),
      'offerDate': dateInputToIso(date.text),
      'validUntil': dateInputToIso(valid.text),
      'deliveryDays': days.text.trim().isEmpty ? null : int.tryParse(days.text),
      'documentGrossTotal': _documentCents! / 100,
      'items': lines
          .map(
            (line) => {
              'requestItemId': line.item['id'],
              'offered': line.offered,
              'grossTotal': line.offered ? _cents(line.total.text)! / 100 : 0,
            },
          )
          .toList(),
      'components': components
          .map(
            (line) => {
              'kind': line.kind,
              'label': line.label.text.trim(),
              'operation': line.operation,
              'grossAmount':
                  _cents(line.amount.text, signed: line.kind == 'discount')! /
                  100,
            },
          )
          .toList(),
      'notes': notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final difference = (_documentCents ?? 0) - _calculatedCents;
    final legacyNeedsBreakdown =
        widget.offer != null &&
        (widget.offer!['items'] as List? ?? const []).isEmpty &&
        lines.length > 1;
    return AlertDialog(
      title: Text(widget.offer == null ? widget.title : 'Angebot bearbeiten'),
      content: SizedBox(
        width: 880,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (legacyNeedsBreakdown)
                const Card(
                  color: Color(0xFFFFF3CD),
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Dieses ältere Angebot enthält noch keine Positionsaufteilung. Bitte tragen Sie die Summen einmalig nach.',
                    ),
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 290,
                    child: DropdownButtonFormField<String>(
                      initialValue: supplier,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Lieferant *',
                        border: OutlineInputBorder(),
                      ),
                      items: widget.suppliers
                          .map(
                            (v) => DropdownMenuItem(
                              value: v['id'].toString(),
                              child: Text(v['name'].toString()),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => supplier = v),
                    ),
                  ),
                  field(number, 'Angebotsnummer', 200),
                  dateField(date, 'Angebotsdatum', 200),
                  dateField(valid, 'Gültig bis', 200),
                  field(days, 'Lieferzeit (Tage)', 160),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'Angebotspositionen',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              ...lines.map(
                (line) => Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Checkbox(
                          value: line.offered,
                          onChanged: (value) => setState(() {
                            line.offered = value ?? false;
                            error = null;
                          }),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(line.item['name']?.toString() ?? ''),
                              Text(
                                '${line.item['quantity']} ${line.item['unit']} · ${line.offered ? 'angeboten' : 'nicht angeboten'}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 210,
                          child: TextField(
                            controller: line.total,
                            enabled: line.offered,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Positionssumme brutto *',
                              suffixText: '€',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Zusätzliche Angebotsbestandteile',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: components.length < 50 ? _addComponent : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Bestandteil hinzufügen'),
                  ),
                ],
              ),
              ...components.map(
                (component) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: component.label,
                          enabled: component.kind == 'custom',
                          maxLength: 100,
                          decoration: const InputDecoration(
                            labelText: 'Bezeichnung',
                            border: OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (component.kind == 'custom')
                        SizedBox(
                          width: 150,
                          child: DropdownButtonFormField<String>(
                            initialValue: component.operation,
                            decoration: const InputDecoration(
                              labelText: 'Berechnung',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'add',
                                child: Text('Hinzurechnen'),
                              ),
                              DropdownMenuItem(
                                value: 'subtract',
                                child: Text('Abziehen'),
                              ),
                            ],
                            onChanged: (value) => setState(() {
                              component.operation = value ?? 'add';
                              error = null;
                            }),
                          ),
                        )
                      else
                        SizedBox(
                          width: 150,
                          child: Text(
                            component.operation == 'subtract'
                                ? 'wird abgezogen'
                                : 'wird addiert',
                          ),
                        ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 180,
                        child: TextField(
                          controller: component.amount,
                          keyboardType: TextInputType.numberWithOptions(
                            decimal: true,
                            signed: component.kind == 'discount',
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Betrag brutto',
                            suffixText: '€',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      if (component.kind == 'custom')
                        IconButton(
                          tooltip: 'Bestandteil entfernen',
                          onPressed: () => _removeComponent(component),
                          icon: const Icon(Icons.delete_outline),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                color: _matches ? Colors.green.shade50 : Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Berechnete Angebotssumme',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            _formatCents(_calculatedCents),
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: documentTotal,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText:
                              'Gesamtsumme laut Angebotsdokument brutto *',
                          suffixText: '€',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            _matches ? Icons.check_circle : Icons.error_outline,
                            color: _matches
                                ? Colors.green.shade700
                                : Colors.red.shade700,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _matches
                                  ? 'Eingabe und Angebot stimmen centgenau überein.'
                                  : 'Abweichung: ${_formatCents(difference)}',
                              style: TextStyle(
                                color: _matches
                                    ? Colors.green.shade800
                                    : Colors.red.shade800,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              field(notes, 'Notiz', 840, lines: 3),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
        FilledButton(
          onPressed: _matches ? _save : null,
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final controller in _amountControllers) {
      controller.removeListener(_recalculate);
    }
    for (final controller in [
      number,
      date,
      valid,
      days,
      documentTotal,
      notes,
    ]) {
      controller.dispose();
    }
    for (final line in lines) {
      line.dispose();
    }
    for (final component in components) {
      component.dispose();
    }
    super.dispose();
  }
}

class _OfferLine {
  final Map<String, dynamic> item;
  bool offered;
  final TextEditingController total;
  _OfferLine(this.item, {required this.offered, required String total})
    : total = TextEditingController(text: total);
  void dispose() => total.dispose();
}

class _OfferComponentLine {
  final String kind;
  final TextEditingController label, amount;
  String operation;
  _OfferComponentLine._(this.kind, String label, String amount, this.operation)
    : label = TextEditingController(text: label),
      amount = TextEditingController(text: amount);
  factory _OfferComponentLine.fixed(
    String kind,
    String label,
    String amount,
    String operation,
  ) => _OfferComponentLine._(kind, label, amount, operation);
  factory _OfferComponentLine.custom(
    String label,
    String amount,
    String operation,
  ) => _OfferComponentLine._('custom', label, amount, operation);
  void dispose() {
    label.dispose();
    amount.dispose();
  }
}

class OrderDialog extends StatefulWidget {
  final Map<String, dynamic> request;
  final List<Map<String, dynamic>> suppliers;
  const OrderDialog({
    required this.request,
    required this.suppliers,
    super.key,
  });
  @override
  State<OrderDialog> createState() => _OrderDialogState();
}

class _OrderDialogState extends State<OrderDialog> {
  String? supplier;
  final shipping = TextEditingController(text: '0'),
      expected = TextEditingController(),
      notes = TextEditingController();
  late final List<_OrderLine> lines;
  @override
  void initState() {
    super.initState();
    final offers = (widget.request['offers'] as List? ?? const []).cast<Map>();
    final selectedOffer = offers
        .where((offer) => offer['id'] == widget.request['selectedOfferId'])
        .firstOrNull;
    final defaultOffer =
        selectedOffer ?? (offers.length == 1 ? offers.first : null);
    supplier =
        widget.request['preferredSupplierId'] ??
        defaultOffer?['supplierId']?.toString();
    shipping.text = defaultOffer?['shippingGross']?.toString() ?? '0';
    final offerItems = (defaultOffer?['items'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final singlePositionTotal =
        (widget.request['items'] as List).length == 1 && defaultOffer != null
        ? defaultOffer['grossTotal']?.toString() ?? ''
        : '';
    lines = (widget.request['items'] as List).map((raw) {
      final item = Map<String, dynamic>.from(raw);
      final offerItem = offerItems
          .where((entry) => entry['requestItemId'] == item['id'])
          .firstOrNull;
      return _OrderLine(
        item,
        quantity: offerItem?['offered'] == false
            ? '0'
            : item['quantity'].toString(),
        price: offerItem?['offered'] == false
            ? ''
            : offerItem?['grossTotal']?.toString() ?? singlePositionTotal,
      );
    }).toList();
  }

  @override
  void dispose() {
    shipping.dispose();
    expected.dispose();
    notes.dispose();
    for (final line in lines) {
      line.quantity.dispose();
      line.price.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Bestellung anlegen'),
    content: SizedBox(
      width: 760,
      child: SingleChildScrollView(
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: 270,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: supplier,
                    decoration: const InputDecoration(
                      labelText: 'Lieferant *',
                      border: OutlineInputBorder(),
                    ),
                    items: widget.suppliers
                        .map(
                          (v) => DropdownMenuItem(
                            value: v['id'].toString(),
                            child: Text(v['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => supplier = v),
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Freigegebenes Budget',
                    ),
                    child: Text(
                      '${widget.request['approvedBudgetGross'] ?? '–'} €',
                    ),
                  ),
                ),
                field(shipping, 'Versand brutto', 160),
                dateField(expected, 'Erwartete Lieferung', 230),
                field(notes, 'Bestellnotiz', 500, lines: 2),
              ],
            ),
            const SizedBox(height: 16),
            ...lines.map(
              (line) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(child: Text(line.item['name'])),
                      field(line.quantity, 'Bestellmenge', 130),
                      const SizedBox(width: 10),
                      field(line.price, 'Positionssumme brutto', 180),
                    ],
                  ),
                ),
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
      FilledButton(
        onPressed: () {
          if (supplier == null) return;
          Navigator.pop(context, {
            'supplierId': supplier,
            'shippingGross': double.tryParse(
              shipping.text.replaceAll(',', '.'),
            ),
            'expectedDeliveryDate': dateInputToIso(expected.text),
            'notes': notes.text,
            'items': lines
                .where(
                  (line) =>
                      (double.tryParse(
                            line.quantity.text.replaceAll(',', '.'),
                          ) ??
                          0) >
                      0,
                )
                .map(
                  (line) => {
                    'requestItemId': line.item['id'],
                    'quantity': double.tryParse(
                      line.quantity.text.replaceAll(',', '.'),
                    ),
                    'grossTotal': double.tryParse(
                      line.price.text.replaceAll(',', '.'),
                    ),
                  },
                )
                .toList(),
          });
        },
        child: const Text('Bestellung speichern'),
      ),
    ],
  );
}

class _OrderLine {
  final Map<String, dynamic> item;
  final TextEditingController quantity, price;
  _OrderLine(this.item, {required String quantity, required String price})
    : quantity = TextEditingController(text: quantity),
      price = TextEditingController(text: price);
}

class ReceiptDialog extends StatefulWidget {
  final Map<String, dynamic> request, order;
  const ReceiptDialog({required this.request, required this.order, super.key});
  @override
  State<ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<ReceiptDialog> {
  final note = TextEditingController(),
      date = TextEditingController(),
      complaint = TextEditingController();
  bool contested = false;
  late final List<_ReceiptLine> lines;
  @override
  void initState() {
    super.initState();
    date.text = formatDateForInput(DateTime.now());
    lines = (widget.order['items'] as List).map((raw) {
      final item = Map<String, dynamic>.from(raw);
      return _ReceiptLine(
        item,
        ((item['quantity'] as num) - (item['deliveredQuantity'] as num? ?? 0))
            .toString(),
      );
    }).toList();
  }

  String name(dynamic id) => (widget.request['items'] as List)
      .cast<Map>()
      .firstWhere((item) => item['id'] == id)['name'];
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Wareneingang buchen'),
    content: SizedBox(
      width: 680,
      child: SingleChildScrollView(
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                field(note, 'Lieferscheinnummer', 250),
                dateField(date, 'Eingangsdatum', 220, required: true),
                SizedBox(
                  width: 200,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Beanstandet'),
                    value: contested,
                    onChanged: (v) => setState(() => contested = v),
                  ),
                ),
                if (contested)
                  field(
                    complaint,
                    'Beschreibung der Beanstandung *',
                    620,
                    lines: 2,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            ...lines.map(
              (line) => ListTile(
                title: Text(name(line.item['requestItemId'])),
                subtitle: Text(
                  'Bestellt ${line.item['quantity']}, bereits geliefert ${line.item['deliveredQuantity']}',
                ),
                trailing: field(line.quantity, 'Geliefert', 130),
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
      FilledButton(
        onPressed: () {
          if (contested && complaint.text.trim().isEmpty) return;
          Navigator.pop(context, {
            'deliveryNoteNumber': note.text,
            'receivedAt': dateInputToIso(date.text),
            'contested': contested,
            'complaint': complaint.text,
            'items': lines
                .where(
                  (line) =>
                      (double.tryParse(
                            line.quantity.text.replaceAll(',', '.'),
                          ) ??
                          0) >
                      0,
                )
                .map(
                  (line) => {
                    'requestItemId': line.item['requestItemId'],
                    'quantity': double.tryParse(
                      line.quantity.text.replaceAll(',', '.'),
                    ),
                  },
                )
                .toList(),
          });
        },
        child: const Text('Wareneingang buchen'),
      ),
    ],
  );
}

class _ReceiptLine {
  final Map<String, dynamic> item;
  final TextEditingController quantity;
  _ReceiptLine(this.item, String quantity)
    : quantity = TextEditingController(text: quantity);
}

class TransferDialog extends StatefulWidget {
  final Map<String, dynamic> request, receipt;
  final List<Map<String, dynamic>> locations, stocks, categories;
  const TransferDialog({
    required this.request,
    required this.receipt,
    required this.locations,
    required this.stocks,
    required this.categories,
    super.key,
  });
  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  String? location, stock;
  String itemType = 'individual';
  bool resolved = false;
  final manufacturer = TextEditingController(),
      manufacturingYear = TextEditingController(),
      model = TextEditingController(),
      interval = TextEditingController();
  final Map<String, String> selectedSizes = {};

  @override
  void initState() {
    super.initState();
    for (final raw in widget.receipt['items'] as List? ?? const []) {
      final receiptItem = Map<String, dynamic>.from(raw as Map);
      final source = requestItem(receiptItem['requestItemId']);
      final size = source?['size']?.toString() ?? '';
      if (source != null && size.isNotEmpty) {
        selectedSizes[source['id'].toString()] = size;
      }
    }
  }

  Map<String, dynamic>? requestItem(Object? id) =>
      (widget.request['items'] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .where((entry) => entry['id'] == id)
          .firstOrNull;

  List<String> sizesFor(Map<String, dynamic> item) {
    final categoryId =
        item['subcategoryId']?.toString() ?? item['categoryId']?.toString();
    final category = widget.categories
        .where((entry) => entry['id']?.toString() == categoryId)
        .firstOrNull;
    final own = (category?['sizes'] as List? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
    if (own.isNotEmpty) return own;
    final parentId = category?['parentId']?.toString();
    return (widget.categories
                    .where((entry) => entry['id']?.toString() == parentId)
                    .firstOrNull?['sizes']
                as List? ??
            const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  bool isWardrobeItem(Map<String, dynamic> item) {
    final main = widget.categories
        .where((entry) => entry['id'] == item['categoryId'])
        .firstOrNull;
    return main?['useInWardrobe'] == true;
  }

  @override
  void dispose() {
    manufacturer.dispose();
    manufacturingYear.dispose();
    model.dispose();
    interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availableStocks = widget.stocks
        .where((entry) => entry['locationId'] == location)
        .toList();
    return AlertDialog(
      title: const Text('Manuell prüfen und ins Inventar übernehmen'),
      content: SizedBox(
        width: 620,
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                initialValue: location,
                decoration: const InputDecoration(
                  labelText: 'Standort *',
                  border: OutlineInputBorder(),
                ),
                items: widget.locations
                    .map(
                      (v) => DropdownMenuItem(
                        value: v['id'].toString(),
                        child: Text(v['name']),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() {
                  location = v;
                  stock = null;
                }),
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String>(
                initialValue: stock,
                decoration: const InputDecoration(
                  labelText: 'Lagerplatz',
                  border: OutlineInputBorder(),
                ),
                items: availableStocks
                    .map(
                      (v) => DropdownMenuItem(
                        value: v['id'].toString(),
                        child: Text(
                          v['path']?.toString() ??
                              '${v['name']} · ${v['section']}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => stock = v),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                initialValue: itemType,
                decoration: const InputDecoration(
                  labelText: 'Artikelart',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'individual',
                    child: Text('Einzelartikel'),
                  ),
                  DropdownMenuItem(value: 'bulk', child: Text('Mengenartikel')),
                ],
                onChanged: (v) => setState(() => itemType = v!),
              ),
            ),
            field(manufacturer, 'Hersteller', 180),
            field(manufacturingYear, 'Baujahr', 180),
            field(model, 'Modell', 180),
            field(interval, 'Prüfintervall Monate', 180),
            ...(widget.receipt['items'] as List? ?? const []).map((raw) {
              final receiptItem = Map<String, dynamic>.from(raw as Map);
              final source = requestItem(receiptItem['requestItemId']);
              if (source == null || !isWardrobeItem(source)) {
                return const SizedBox.shrink();
              }
              final sizes = sizesFor(source);
              final itemId = source['id'].toString();
              if (sizes.isEmpty) {
                return SizedBox(
                  width: 220,
                  child: TextFormField(
                    decoration: InputDecoration(
                      labelText: 'Größe · ${source['name']}',
                    ),
                    onChanged: (value) => selectedSizes[itemId] = value,
                  ),
                );
              }
              return SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  initialValue: selectedSizes[itemId],
                  decoration: InputDecoration(
                    labelText: 'Größe · ${source['name']} *',
                    border: const OutlineInputBorder(),
                  ),
                  items: sizes
                      .map(
                        (size) =>
                            DropdownMenuItem(value: size, child: Text(size)),
                      )
                      .toList(),
                  onChanged: (value) =>
                      setState(() => selectedSizes[itemId] = value ?? ''),
                ),
              );
            }),
            if (widget.receipt['status'] == 'Beanstandet')
              SizedBox(
                width: 500,
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: resolved,
                  onChanged: (v) => setState(() => resolved = v!),
                  title: const Text('Beanstandung wurde geklärt'),
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
          onPressed: () {
            if (location == null) return;
            Navigator.pop(context, {
              'complaintResolved': resolved,
              'items': (widget.receipt['items'] as List).map((raw) {
                final receiptItem = Map<String, dynamic>.from(raw);
                return {
                  'requestItemId': receiptItem['requestItemId'],
                  'locationId': location,
                  'stockStructureId': stock,
                  'itemType': itemType,
                  'manufacturer': manufacturer.text,
                  'manufacturingYear': manufacturingYear.text,
                  'model': model.text,
                  'inspectionIntervalMonths': int.tryParse(interval.text),
                  'size': selectedSizes[receiptItem['requestItemId']] ?? '',
                };
              }).toList(),
            });
          },
          child: const Text('Inventar erzeugen'),
        ),
      ],
    );
  }
}

class SupplierDialog extends StatefulWidget {
  final Map<String, dynamic>? supplier;
  final String token;
  const SupplierDialog({this.supplier, required this.token, super.key});
  @override
  State<SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<SupplierDialog> {
  late final Map<String, TextEditingController> c;
  bool active = true;
  String? _validationMessage, _legacyAddress;

  @override
  void initState() {
    super.initState();
    c = {
      for (final key in [
        'name',
        'contact',
        'street',
        'houseNumber',
        'postalCode',
        'city',
        'country',
        'customerNumber',
        'email',
        'phone',
        'website',
        'paymentTerms',
      ])
        key: TextEditingController(
          text: widget.supplier?[key]?.toString() ?? '',
        ),
    };
    if (c['country']!.text.trim().isEmpty) c['country']!.text = 'Deutschland';
    final hasStructuredAddress = [
      'street',
      'houseNumber',
      'postalCode',
      'city',
    ].any((key) => c[key]!.text.trim().isNotEmpty);
    final oldAddress = widget.supplier?['address']?.toString().trim() ?? '';
    if (!hasStructuredAddress && oldAddress.isNotEmpty) {
      _legacyAddress = oldAddress;
    }
    active = widget.supplier?['active'] != false;
  }

  @override
  void dispose() {
    for (final controller in c.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final missing = [
      'name',
      'street',
      'houseNumber',
      'postalCode',
      'city',
      'country',
    ].any((key) => c[key]!.text.trim().isEmpty);
    if (missing) {
      setState(
        () => _validationMessage =
            'Bitte Name, Straße, Hausnummer, Postleitzahl, Ort und Land ausfüllen.',
      );
      return;
    }
    if (euCountryCodeFor(c['country']!.text) == 'de' &&
        !RegExp(r'^\d{5}$').hasMatch(c['postalCode']!.text.trim())) {
      setState(
        () => _validationMessage =
            'Eine deutsche Postleitzahl muss aus genau fünf Ziffern bestehen.',
      );
      return;
    }
    Navigator.pop(context, {
      for (final entry in c.entries) entry.key: entry.value.text.trim(),
      'active': active,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.supplier == null ? 'Lieferant anlegen' : 'Lieferant bearbeiten',
    ),
    content: SizedBox(
      width: 650,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                field(c['name']!, 'Name *', 300),
                field(c['contact']!, 'Ansprechpartner', 280),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 18, bottom: 12),
              child: Divider(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Adresse',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_legacyAddress != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Bisherige Anschrift: $_legacyAddress\nBitte in die strukturierten Felder übernehmen.',
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AddressInput(
                token: widget.token,
                streetController: c['street']!,
                houseNumberController: c['houseNumber']!,
                postalCodeController: c['postalCode']!,
                cityController: c['city']!,
                countryController: c['country']!,
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                field(c['customerNumber']!, 'Kundennummer', 200),
                field(c['email']!, 'E-Mail', 280),
                field(c['phone']!, 'Telefon', 220),
                field(c['website']!, 'Website', 280),
                field(c['paymentTerms']!, 'Zahlungsbedingungen', 280),
                SizedBox(
                  width: 200,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktiv'),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
                ),
              ],
            ),
            if (_validationMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _validationMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
}

class ProcurementDetail extends StatelessWidget {
  final Map<String, dynamic> request;
  final String Function(dynamic) supplierName, categoryName, money, date;
  final bool canApprove, canOrder, canReceive, canWrite;
  final VoidCallback onSubmit,
      onEdit,
      onDelete,
      onAddOffer,
      onCreateOrder,
      onUpload,
      onCancel;
  final ValueChanged<bool> onApprove;
  final ValueChanged<Map<String, dynamic>> onSelectOffer,
      onEditOffer,
      onReceive,
      onTransfer;
  final ValueChanged<Map<String, dynamic>> onDownloadDocument;
  final ValueChanged<String> onPrint;
  const ProcurementDetail({
    required this.request,
    required this.supplierName,
    required this.categoryName,
    required this.money,
    required this.date,
    required this.canApprove,
    required this.canOrder,
    required this.canReceive,
    required this.canWrite,
    required this.onSubmit,
    required this.onEdit,
    required this.onDelete,
    required this.onApprove,
    required this.onAddOffer,
    required this.onSelectOffer,
    required this.onEditOffer,
    required this.onCreateOrder,
    required this.onReceive,
    required this.onTransfer,
    required this.onUpload,
    required this.onDownloadDocument,
    required this.onPrint,
    required this.onCancel,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final offers = (request['offers'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final orders = (request['orders'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final docs = (request['documents'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final history = (request['history'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    Widget offerTile(Map<String, dynamic> offer) {
      final offerItems = (offer['items'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final components = (offer['components'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final offeredCount = offerItems
          .where((entry) => entry['offered'] != false)
          .length;
      return ExpansionTile(
        leading: IconButton(
          tooltip: request['selectedOfferId'] == offer['id']
              ? 'Ausgewähltes Angebot'
              : 'Angebot auswählen',
          onPressed: canOrder ? () => onSelectOffer(offer) : null,
          icon: Icon(
            request['selectedOfferId'] == offer['id']
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
        ),
        title: Text(
          '${supplierName(offer['supplierId'])} · ${offer['offerNumber']?.toString().isNotEmpty == true ? offer['offerNumber'] : 'ohne Angebotsnummer'}',
        ),
        subtitle: Text(
          offerItems.isEmpty
              ? 'Älteres Angebot ohne Positionsaufteilung · Lieferzeit ${offer['deliveryDays'] ?? '–'} Tage'
              : '$offeredCount von ${offerItems.length} Positionen angeboten · Lieferzeit ${offer['deliveryDays'] ?? '–'} Tage',
        ),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              money(offerTotalValue(offer)),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            if (canWrite &&
                ['Beantragt', 'Genehmigt'].contains(request['status']))
              IconButton(
                tooltip: 'Angebot bearbeiten',
                onPressed: () => onEditOffer(offer),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        children: [
          if (offerItems.isEmpty)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(
                'Beim Bearbeiten muss die Positionsaufteilung nachgetragen werden.',
              ),
            )
          else
            ...offerItems.map((entry) {
              final requestItem = (request['items'] as List)
                  .whereType<Map>()
                  .where((item) => item['id'] == entry['requestItemId'])
                  .firstOrNull;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 24),
                leading: Icon(
                  entry['offered'] == false
                      ? Icons.remove_circle_outline
                      : Icons.check_circle_outline,
                ),
                title: Text(
                  requestItem?['name']?.toString() ?? 'Unbekannte Position',
                ),
                trailing: Text(
                  entry['offered'] == false
                      ? 'nicht angeboten'
                      : money(entry['grossTotal']),
                ),
              );
            }),
          ...components.map(
            (entry) => ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 72, right: 24),
              leading: Icon(
                entry['operation'] == 'subtract' ? Icons.remove : Icons.add,
              ),
              title: Text(entry['label']?.toString() ?? ''),
              trailing: Text(
                '${entry['operation'] == 'subtract' ? '− ' : '+ '}${money(entry['grossAmount'])}',
              ),
            ),
          ),
          ListTile(
            contentPadding: const EdgeInsets.only(left: 72, right: 24),
            title: const Text('Kontrollsumme laut Angebot'),
            subtitle: Text('gültig bis ${date(offer['validUntil'])}'),
            trailing: Text(
              money(offer['documentGrossTotal'] ?? offerTotalValue(offer)),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${request['number']} · ${request['title']}'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'PDF erstellen',
            onSelected: onPrint,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'orders',
                child: Text('Bestellungen als PDF'),
              ),
              PopupMenuItem(
                value: 'offers',
                child: Text('Angebotsvergleich als PDF'),
              ),
              PopupMenuItem(
                value: 'receipts',
                child: Text('Wareneingänge als PDF'),
              ),
            ],
            icon: const Icon(Icons.picture_as_pdf_outlined),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(request['status'])),
                    Chip(
                      avatar: const Icon(Icons.euro, size: 18),
                      label: Text(
                        'Beantragt ${money(request['requestedBudgetGross'])}',
                      ),
                    ),
                    if (request['approvedBudgetGross'] != null)
                      Chip(
                        avatar: const Icon(Icons.verified, size: 18),
                        label: Text(
                          'Freigegeben ${money(request['approvedBudgetGross'])}',
                        ),
                      ),
                    Chip(
                      avatar: const Icon(Icons.person_outline, size: 18),
                      label: Text(request['requestedBy']),
                    ),
                    Chip(
                      avatar: const Icon(Icons.business_outlined, size: 18),
                      label: Text(
                        request['department']?.toString().isNotEmpty == true
                            ? request['department']
                            : 'Ohne Fachbereich',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  request['reason'],
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (request['notes']?.toString().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Notiz: ${request['notes']}'),
                  ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (request['status'] == 'Entwurf' && canWrite)
                      FilledButton.icon(
                        onPressed: onSubmit,
                        icon: const Icon(Icons.send),
                        label: const Text('Beantragen'),
                      ),
                    if (request['status'] == 'Entwurf' && canWrite)
                      OutlinedButton.icon(
                        onPressed: onEdit,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Bearbeiten'),
                      ),
                    if (request['status'] == 'Entwurf' && canWrite)
                      TextButton.icon(
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Entwurf löschen'),
                      ),
                    if (request['status'] == 'Beantragt' && canApprove) ...[
                      FilledButton.icon(
                        onPressed: () => onApprove(true),
                        icon: const Icon(Icons.check),
                        label: const Text('Freigeben'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => onApprove(false),
                        icon: const Icon(Icons.close),
                        label: const Text('Ablehnen'),
                      ),
                    ],
                    if ([
                          'Beantragt',
                          'Genehmigt',
                        ].contains(request['status']) &&
                        canWrite)
                      OutlinedButton.icon(
                        onPressed: onAddOffer,
                        icon: const Icon(Icons.request_quote_outlined),
                        label: const Text('Angebot erfassen'),
                      ),
                    if (['Genehmigt', 'Bestellt'].contains(request['status']) &&
                        canOrder)
                      FilledButton.icon(
                        onPressed: onCreateOrder,
                        icon: const Icon(Icons.shopping_cart_checkout),
                        label: const Text('Bestellung anlegen'),
                      ),
                    if (canWrite)
                      OutlinedButton.icon(
                        onPressed: onUpload,
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Dokument'),
                      ),
                    if (![
                      'Abgeschlossen',
                      'Storniert',
                    ].contains(request['status']))
                      TextButton.icon(
                        onPressed: onCancel,
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Stornieren'),
                      ),
                  ],
                ),
                section(
                  context,
                  'Positionen',
                  (request['items'] as List).map((raw) {
                    final item = raw as Map;
                    return ListTile(
                      title: Text(item['name']),
                      subtitle: Text(
                        '${categoryName(item['categoryId'])}${item['subcategoryId'] == null ? '' : ' / ${categoryName(item['subcategoryId'])}'} · MwSt. ${item['taxRate']} %',
                      ),
                      trailing: Text('${item['quantity']} ${item['unit']}'),
                    );
                  }).toList(),
                ),
                section(
                  context,
                  'Freigaben',
                  (request['approvals'] as List? ?? const []).isEmpty
                      ? [
                          const ListTile(
                            title: Text('Noch keine Freigabe erteilt.'),
                          ),
                        ]
                      : (request['approvals'] as List).map((raw) {
                          final a = raw as Map;
                          return ListTile(
                            leading: Icon(
                              a['decision'] == 'Genehmigt'
                                  ? Icons.check_circle
                                  : Icons.cancel,
                              color: a['decision'] == 'Genehmigt'
                                  ? Colors.green
                                  : Colors.red,
                            ),
                            title: Text('${a['role']} · ${a['name']}'),
                            subtitle: Text(
                              '${date(a['createdAt'])}${a['boardResolution']?.toString().isNotEmpty == true ? ' · ${a['boardResolution']}' : ''}${a['approvedBudgetGross'] != null ? ' · Freigegeben ${money(a['approvedBudgetGross'])}' : ''}\n${a['notes'] ?? ''}',
                            ),
                          );
                        }).toList(),
                ),
                section(
                  context,
                  'Angebotsvergleich',
                  offers.isEmpty
                      ? [
                          const ListTile(
                            title: Text('Noch keine Angebote erfasst.'),
                          ),
                        ]
                      : offers.map(offerTile).toList(),
                ),
                section(
                  context,
                  'Bestellungen und Wareneingänge',
                  orders.isEmpty
                      ? [
                          const ListTile(
                            title: Text('Noch keine Bestellung angelegt.'),
                          ),
                        ]
                      : orders
                            .expand(
                              (order) => [
                                ListTile(
                                  leading: const Icon(
                                    Icons.shopping_cart_outlined,
                                  ),
                                  title: Text(
                                    '${order['number']} · ${supplierName(order['supplierId'])}',
                                  ),
                                  subtitle: Text(
                                    'Bestellt ${date(order['orderDate'])} · erwartet ${date(order['expectedDeliveryDate'])} · freigegeben ${money(request['approvedBudgetGross'])}',
                                  ),
                                  trailing: Wrap(
                                    children: [
                                      Text(money(order['grossTotal'])),
                                      if (canReceive &&
                                          (order['items'] as List).any(
                                            (raw) =>
                                                (raw['deliveredQuantity']
                                                        as num? ??
                                                    0) <
                                                (raw['quantity'] as num),
                                          ))
                                        IconButton(
                                          onPressed: () => onReceive(order),
                                          tooltip: 'Wareneingang',
                                          icon: const Icon(
                                            Icons.inventory_outlined,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                ...(order['receipts'] as List? ?? const [])
                                    .cast<Map<String, dynamic>>()
                                    .map(
                                      (receipt) => Padding(
                                        padding: const EdgeInsets.only(
                                          left: 36,
                                        ),
                                        child: ListTile(
                                          leading: Icon(
                                            receipt['status'] == 'Beanstandet'
                                                ? Icons.report_problem_outlined
                                                : Icons.move_to_inbox_outlined,
                                            color:
                                                receipt['status'] ==
                                                    'Beanstandet'
                                                ? Colors.orange
                                                : null,
                                          ),
                                          title: Text(
                                            '${receipt['number']} · Lieferschein ${receipt['deliveryNoteNumber']?.toString().isNotEmpty == true ? receipt['deliveryNoteNumber'] : '–'}',
                                          ),
                                          subtitle: Text(
                                            '${receipt['status']} · ${date(receipt['receivedAt'])}${receipt['complaint']?.toString().isNotEmpty == true ? '\n${receipt['complaint']}' : ''}',
                                          ),
                                          trailing:
                                              !receipt['inventoryTransferred'] &&
                                                  canReceive
                                              ? FilledButton.tonal(
                                                  onPressed: () =>
                                                      onTransfer(receipt),
                                                  child: const Text(
                                                    'Prüfen & übernehmen',
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.check_circle,
                                                  color: Colors.green,
                                                ),
                                        ),
                                      ),
                                    ),
                              ],
                            )
                            .toList(),
                ),
                section(
                  context,
                  'Dokumente',
                  docs.isEmpty
                      ? [
                          const ListTile(
                            title: Text('Noch keine Dokumente hinterlegt.'),
                          ),
                        ]
                      : docs
                            .map(
                              (doc) => ListTile(
                                onTap: () => onDownloadDocument(doc),
                                leading: const Icon(Icons.description_outlined),
                                title: Text(doc['fileName']),
                                subtitle: Text(
                                  '${doc['documentType']} · ${date(doc['createdAt'])}',
                                ),
                                trailing: const Icon(Icons.download),
                              ),
                            )
                            .toList(),
                ),
                section(
                  context,
                  'Verlauf',
                  history.reversed
                      .map(
                        (h) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.history, size: 20),
                          title: Text(h['action']),
                          subtitle: Text(
                            '${h['actor']} · ${date(h['createdAt'])}',
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget section(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const Divider(),
                ...children,
              ],
            ),
          ),
        ),
      );
}
