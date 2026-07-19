import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/date_input_field.dart';

class ProcurementPage extends StatefulWidget {
  final String token;
  final VoidCallback? onLogout;

  const ProcurementPage({required this.token, this.onLogout, super.key});

  @override
  State<ProcurementPage> createState() => _ProcurementPageState();
}

class _ProcurementPageState extends State<ProcurementPage> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _suppliers = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _locations = [];
  List<Map<String, dynamic>> _stocks = [];
  Set<String> _permissions = {};
  Set<String> _roles = {};
  bool _loading = true;
  String? _status;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  bool _can(String permission) => _permissions.contains(permission);

  @override
  void initState() {
    super.initState();
    _search.addListener(_refreshView);
    _load();
  }

  @override
  void dispose() {
    _search.removeListener(_refreshView);
    _search.dispose();
    super.dispose();
  }

  void _refreshView() {
    if (mounted) setState(() {});
  }

  List<Map<String, dynamic>> _asList(http.Response response) =>
      (jsonDecode(response.body) as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList();

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final responses = await Future.wait([
        http.get(Uri.parse('$apiBaseUrl/api/procurement'), headers: _headers),
        http.get(Uri.parse('$apiBaseUrl/api/suppliers'), headers: _headers),
        http.get(Uri.parse('$apiBaseUrl/api/categories'), headers: _headers),
        http.get(Uri.parse('$apiBaseUrl/api/locations'), headers: _headers),
        http.get(Uri.parse('$apiBaseUrl/api/stock-structures'),
            headers: _headers),
        http.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: _headers),
      ]);
      if (responses.any((response) => response.statusCode == 401)) {
        widget.onLogout?.call();
        return;
      }
      if (responses.any((response) => response.statusCode != 200)) {
        throw Exception('Beschaffungsdaten konnten nicht geladen werden.');
      }
      final user = jsonDecode(responses[5].body)['user'] as Map;
      if (!mounted) return;
      setState(() {
        _requests = _asList(responses[0]);
        _suppliers = _asList(responses[1]);
        _categories = _asList(responses[2]);
        _locations = _asList(responses[3]);
        _stocks = _asList(responses[4]);
        _permissions = ((user['permissions'] as List?) ?? const [])
            .map((value) => value.toString())
            .toSet();
        _roles = ((user['roles'] as List?) ?? const [])
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

  Future<dynamic> _request(String path,
      {String method = 'GET', Object? body}) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    late http.Response response;
    if (method == 'POST') {
      response = await http.post(uri,
          headers: _headers, body: body == null ? null : jsonEncode(body));
    } else if (method == 'PUT') {
      response = await http.put(uri,
          headers: _headers, body: body == null ? null : jsonEncode(body));
    } else if (method == 'DELETE') {
      response = await http.delete(uri, headers: _headers);
    } else {
      response = await http.get(uri, headers: _headers);
    }
    final data = response.body.isEmpty ? {} : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      _message(
          data is Map
              ? data['error']?.toString() ?? 'Aktion fehlgeschlagen.'
              : 'Aktion fehlgeschlagen.',
          error: true);
      return null;
    }
    return data;
  }

  void _message(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text.replaceFirst('Exception: ', '')),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
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
        entry['requestedBy']
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
        suppliers:
            _suppliers.where((entry) => entry['active'] != false).toList(),
      ),
    );
    if (payload == null) return;
    final created =
        await _request('/api/procurement', method: 'POST', body: payload);
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
        suppliers:
            _suppliers.where((entry) => entry['active'] != false).toList(),
        request: request,
      ),
    );
    if (payload == null) return;
    final saved = await _request('/api/procurement/${request['id']}',
        method: 'PUT', body: payload);
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
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed != true) return;
    final result =
        await _request('/api/procurement/${request['id']}', method: 'DELETE');
    if (result != null) {
      _message('Entwurf wurde gelöscht.');
      if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      await _load();
    }
  }

  Future<void> _simpleAction(Map<String, dynamic> request, String action,
      {Object? body, String? success}) async {
    final result = await _request('/api/procurement/${request['id']}/$action',
        method: 'POST', body: body ?? {});
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
        text: request['requestedBudgetGross']?.toString() ?? '');
    final isChair = _roles.contains('Vorsitz') || _roles.contains('Admin');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Freigabe erteilen' : 'Antrag ablehnen'),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (approve && isChair)
              TextField(
                controller: approvedBudget,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Freigegebenes Budget *', suffixText: '€'),
              ),
            if ((request['requestedBudgetGross'] as num? ?? 0) >= 100 &&
                isChair)
              TextField(
                controller: resolution,
                decoration: const InputDecoration(
                    labelText: 'Referenz Vorstandsbeschluss'),
              ),
            TextField(
              controller: notes,
              maxLines: 3,
              decoration: InputDecoration(
                  labelText: approve ? 'Freigabenotiz' : 'Begründung *'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(approve ? 'Freigeben' : 'Ablehnen')),
        ],
      ),
    );
    if (confirmed != true ||
        (!approve && notes.text.trim().isEmpty) ||
        (approve &&
            isChair &&
            (double.tryParse(approvedBudget.text.replaceAll(',', '.')) ?? 0) <=
                0)) return;
    await _simpleAction(request, 'approval',
        body: {
          'decision': approve ? 'approve' : 'reject',
          'role':
              _roles.contains('Schatzmeister') ? 'Schatzmeister' : 'Vorsitz',
          'notes': notes.text.trim(),
          'boardResolution': resolution.text.trim(),
          'approvedBudgetGross':
              double.tryParse(approvedBudget.text.replaceAll(',', '.')),
        },
        success:
            approve ? 'Freigabe wurde erteilt.' : 'Antrag wurde abgelehnt.');
  }

  Future<void> _addOffer(Map<String, dynamic> request) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => OfferDialog(
          suppliers:
              _suppliers.where((entry) => entry['active'] != false).toList()),
    );
    if (payload == null) return;
    final result = await _request('/api/procurement/${request['id']}/offers',
        method: 'POST', body: payload);
    if (result != null) {
      _message('Angebot wurde hinzugefügt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _selectOffer(
      Map<String, dynamic> request, Map<String, dynamic> offer) async {
    final justification = TextEditingController();
    final offers = (request['offers'] as List? ?? const []).cast<Map>();
    final cheapest = offers
        .map((entry) =>
            (entry['grossTotal'] as num? ?? 0) +
            (entry['shippingGross'] as num? ?? 0))
        .reduce((a, b) => a < b ? a : b);
    final total = (offer['grossTotal'] as num? ?? 0) +
        (offer['shippingGross'] as num? ?? 0);
    if (total > cheapest) {
      final value = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Teureres Angebot auswählen'),
                content: TextField(
                    controller: justification,
                    maxLines: 3,
                    decoration:
                        const InputDecoration(labelText: 'Begründung *')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, justification.text.trim()),
                      child: const Text('Auswählen'))
                ],
              ));
      if (value == null || value.isEmpty) return;
    }
    final result = await _request(
        '/api/procurement/${request['id']}/select-offer',
        method: 'POST',
        body: {
          'offerId': offer['id'],
          'justification': justification.text.trim()
        });
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
          suppliers:
              _suppliers.where((entry) => entry['active'] != false).toList()),
    );
    if (payload == null) return;
    final result = await _request('/api/procurement/${request['id']}/orders',
        method: 'POST', body: payload);
    if (result != null) {
      _message('Bestellung ${result['number']} wurde angelegt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _receive(
      Map<String, dynamic> request, Map<String, dynamic> order) async {
    final payload = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => ReceiptDialog(request: request, order: order));
    if (payload == null) return;
    final result = await _request(
        '/api/procurement/${request['id']}/orders/${order['id']}/receipts',
        method: 'POST',
        body: payload);
    if (result != null) {
      _message('Wareneingang ${result['number']} wurde gebucht.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _transfer(
      Map<String, dynamic> request, Map<String, dynamic> receipt) async {
    final payload = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => TransferDialog(
            request: request,
            receipt: receipt,
            locations: _locations,
            stocks: _stocks,
            categories: _categories));
    if (payload == null) return;
    final result = await _request(
        '/api/procurement/${request['id']}/receipts/${receipt['id']}/transfer',
        method: 'POST',
        body: payload);
    if (result != null) {
      _message(
          '${(result['created'] as List).length} Inventareinträge wurden erzeugt.');
      if (mounted) Navigator.pop(context);
      await _load();
    }
  }

  Future<void> _upload(Map<String, dynamic> request) async {
    final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'pdf',
          'png',
          'jpg',
          'jpeg',
          'docx',
          'xlsx',
          'ods'
        ],
        withData: true);
    final file = picked?.files.single;
    if (file?.bytes == null || file!.bytes!.length > 5 * 1024 * 1024) {
      if (file != null)
        _message('Die Datei darf maximal 5 MB groß sein.', error: true);
      return;
    }
    final type = await showDialog<String>(
        context: context,
        builder: (context) {
          var selected = 'Angebot';
          return StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                    title: const Text('Dokumenttyp'),
                    content: DropdownButtonFormField<String>(
                        initialValue: selected,
                        items: [
                          'Angebot',
                          'Genehmigung',
                          'Bestellung',
                          'Auftragsbestätigung',
                          'Lieferschein',
                          'Rechnung'
                        ]
                            .map((value) => DropdownMenuItem(
                                value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) =>
                            setDialogState(() => selected = value!)),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Abbrechen')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, selected),
                          child: const Text('Hochladen'))
                    ],
                  ));
        });
    if (type == null) return;
    final result = await _request('/api/procurement/${request['id']}/documents',
        method: 'POST',
        body: {
          'fileName': file.name,
          'fileBase64': base64Encode(file.bytes!),
          'documentType': type
        });
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
    );
    _message('$fileName wurde erstellt.');
  }

  Future<void> _downloadDocument(
      Map<String, dynamic> request, Map<String, dynamic> document) async {
    final data = await _request(
        '/api/procurement/${request['id']}/documents/${document['id']}');
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
    );
    _message('$fileName wurde gespeichert.');
  }

  Future<void> _printDetail(Map<String, dynamic> request, String type) async {
    final data =
        await _request('/api/procurement/${request['id']}/print/$type');
    if (data == null) return;
    final fileName = data['fileName'].toString();
    await FileSaver.instance.saveFile(
      name: fileName.substring(0, fileName.length - 4),
      bytes: base64Decode(data['fileBase64']),
      fileExtension: 'pdf',
      mimeType: MimeType.custom,
    );
    _message('$fileName wurde erstellt.');
  }

  Future<void> _supplierDialog([Map<String, dynamic>? supplier]) async {
    final payload = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => SupplierDialog(supplier: supplier));
    if (payload == null) return;
    final result = await _request(
        supplier == null
            ? '/api/suppliers'
            : '/api/suppliers/${supplier['id']}',
        method: supplier == null ? 'POST' : 'PUT',
        body: payload);
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
              onSubmit: () => _simpleAction(fresh, 'submit',
                  success: 'Antrag wurde eingereicht.'),
              onEdit: () => _editRequest(fresh),
              onDelete: () => _deleteDraft(fresh),
              onApprove: (approve) => _approve(fresh, approve),
              onAddOffer: () => _addOffer(fresh),
              onSelectOffer: (offer) => _selectOffer(fresh, offer),
              onCreateOrder: () => _createOrder(fresh),
              onReceive: (order) => _receive(fresh, order),
              onTransfer: (receipt) => _transfer(fresh, receipt),
              onUpload: () => _upload(fresh),
              onDownloadDocument: (document) =>
                  _downloadDocument(fresh, document),
              onPrint: (type) => _printDetail(fresh, type),
              onCancel: () async {
                final reason =
                    await _textPrompt('Vorgang stornieren', 'Begründung *');
                if (reason != null && reason.isNotEmpty)
                  await _simpleAction(fresh, 'cancel',
                      body: {'reason': reason},
                      success: 'Vorgang wurde storniert.');
              },
            )));
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
                    decoration: InputDecoration(labelText: label)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('Bestätigen'))
                ]));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Beschaffung'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.list_alt), text: 'Vorgänge'),
            Tab(icon: Icon(Icons.approval_outlined), text: 'Freigaben'),
            Tab(icon: Icon(Icons.local_shipping_outlined), text: 'Lieferanten')
          ]),
          actions: [
            IconButton(
                onPressed: _load,
                tooltip: 'Aktualisieren',
                icon: const Icon(Icons.refresh)),
            if (widget.onLogout != null)
              IconButton(
                  onPressed: widget.onLogout,
                  tooltip: 'Abmelden',
                  icon: const Icon(Icons.logout))
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [_overview(), _approvals(), _supplierView()]),
        floatingActionButton: _can('procurement.request')
            ? FloatingActionButton.extended(
                onPressed: _createRequest,
                icon: const Icon(Icons.add),
                label: const Text('Vorgang anlegen'))
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
                          labelText:
                              'Nummer, Titel, Fachbereich oder Antragsteller',
                          border: OutlineInputBorder()))),
              if (!approvalsOnly)
                SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<String>(
                        initialValue: _status,
                        decoration: const InputDecoration(
                            labelText: 'Status', border: OutlineInputBorder()),
                        items: [
                          'Alle',
                          'Entwurf',
                          'Beantragt',
                          'Genehmigt',
                          'Abgelehnt',
                          'Bestellt',
                          'Teilweise geliefert',
                          'Geliefert',
                          'Abgeschlossen',
                          'Storniert'
                        ]
                            .map((value) => DropdownMenuItem(
                                value: value == 'Alle' ? null : value,
                                child: Text(value)))
                            .toList(),
                        onChanged: (value) => setState(() => _status = value))),
              if (!approvalsOnly && _can('procurement.request'))
                FilledButton.icon(
                    onPressed: _createRequest,
                    icon: const Icon(Icons.add),
                    label: const Text('Vorgang anlegen')),
              if (_can('procurement.export'))
                PopupMenuButton<String>(
                    tooltip: 'Exportieren',
                    onSelected: _export,
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'xlsx', child: Text('Excel (.xlsx)')),
                          PopupMenuItem(
                              value: 'ods', child: Text('OpenDocument (.ods)')),
                          PopupMenuItem(
                              value: 'pdf', child: Text('Druckansicht (.pdf)'))
                        ],
                    child: OutlinedButton.icon(
                        onPressed: null,
                        icon: Icon(Icons.download),
                        label: Text('Exportieren'))),
            ]),
      );

  Widget _overview() =>
      Column(children: [_toolbar(), Expanded(child: _requestList(_filtered))]);

  Widget _approvals() {
    final pending =
        _filtered.where((entry) => entry['status'] == 'Beantragt').toList();
    return Column(children: [
      _toolbar(approvalsOnly: true),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  '${pending.length} Antrag/Anträge warten auf eine Entscheidung',
                  style: Theme.of(context).textTheme.titleMedium))),
      const SizedBox(height: 8),
      Expanded(child: _requestList(pending, approvalButtons: true))
    ]);
  }

  Widget _requestList(List<Map<String, dynamic>> entries,
      {bool approvalButtons = false}) {
    if (entries.isEmpty)
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.playlist_add,
            size: 54, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        const Text('Keine passenden Beschaffungsvorgänge.'),
        if (_can('procurement.request') && !approvalButtons) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: _createRequest,
              icon: const Icon(Icons.add),
              label: const Text('Ersten Vorgang anlegen'))
        ]
      ]));
    return ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          final entry = entries[index];
          return Card(
              child: ListTile(
            onTap: () => _showDetails(entry),
            leading: CircleAvatar(
                backgroundColor:
                    _statusColor(entry['status']).withValues(alpha: .15),
                child: Icon(Icons.shopping_cart_outlined,
                    color: _statusColor(entry['status']))),
            title: Text('${entry['number']} · ${entry['title']}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
                '${entry['requestedBy']} · ${entry['department']?.toString().isNotEmpty == true ? entry['department'] : 'ohne Fachbereich'} · Wunsch ${_date(entry['desiredDeliveryDate'])}'),
            trailing: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Text(_money(entry['requestedBudgetGross']),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Chip(
                      label: Text(entry['status']),
                      side: BorderSide(color: _statusColor(entry['status']))),
                  if (approvalButtons && _can('procurement.approve'))
                    IconButton(
                        onPressed: () => _approve(entry, true),
                        tooltip: 'Freigeben',
                        icon: const Icon(Icons.check_circle_outline,
                            color: Colors.green))
                ]),
          ));
        });
  }

  Color _statusColor(dynamic status) => switch (status) {
        'Genehmigt' || 'Abgeschlossen' => Colors.green.shade700,
        'Abgelehnt' || 'Storniert' => Colors.red.shade700,
        'Beantragt' || 'Teilweise geliefert' => Colors.orange.shade800,
        'Geliefert' => Colors.teal.shade700,
        _ => Colors.blueGrey.shade700,
      };

  Widget _supplierView() => Column(children: [
        Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Expanded(
                  child: Text('Lieferantenverwaltung',
                      style: Theme.of(context).textTheme.titleLarge)),
              if (_can('suppliers.write'))
                FilledButton.icon(
                    onPressed: () => _supplierDialog(),
                    icon: const Icon(Icons.add_business),
                    label: const Text('Lieferant anlegen'))
            ])),
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
                              leading: Icon(supplier['active'] == false
                                  ? Icons.block
                                  : Icons.local_shipping_outlined),
                              title: Text(supplier['name']),
                              subtitle: Text([
                                supplier['customerNumber'],
                                supplier['email'],
                                supplier['phone'],
                                supplier['paymentTerms']
                              ]
                                  .where((value) =>
                                      value?.toString().isNotEmpty == true)
                                  .join(' · ')),
                              trailing: _can('suppliers.write')
                                  ? IconButton(
                                      onPressed: () =>
                                          _supplierDialog(supplier),
                                      icon: const Icon(Icons.edit_outlined))
                                  : null));
                    }))
      ]);
}

class ProcurementRequestDialog extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> suppliers;
  final Map<String, dynamic>? request;
  const ProcurementRequestDialog(
      {required this.categories,
      required this.suppliers,
      this.request,
      super.key});
  @override
  State<ProcurementRequestDialog> createState() =>
      _ProcurementRequestDialogState();
}

class _ProcurementRequestDialogState extends State<ProcurementRequestDialog> {
  final title = TextEditingController(),
      reason = TextEditingController(),
      department = TextEditingController(),
      costCenter = TextEditingController(),
      requestedBudget = TextEditingController(),
      desiredDate = TextEditingController(),
      notes = TextEditingController();
  final items = <_RequestItemControllers>[];
  String priority = 'Normal';
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
    department.text = request['department']?.toString() ?? '';
    costCenter.text = request['costCenter']?.toString() ?? '';
    requestedBudget.text = request['requestedBudgetGross']?.toString() ?? '';
    desiredDate.text = formatDateForInput(request['desiredDeliveryDate']);
    notes.text = request['notes']?.toString() ?? '';
    priority = request['priority']?.toString() ?? 'Normal';
    supplier = request['preferredSupplierId']?.toString();
    items.addAll((request['items'] as List? ?? const []).map(
        (raw) => _RequestItemControllers.from(Map<String, dynamic>.from(raw))));
    if (items.isEmpty) items.add(_RequestItemControllers());
  }

  @override
  void dispose() {
    for (final c in [
      title,
      reason,
      department,
      costCenter,
      requestedBudget,
      desiredDate,
      notes
    ]) c.dispose();
    for (final item in items) item.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.request == null
            ? 'Beschaffungsantrag anlegen'
            : 'Beschaffungsentwurf bearbeiten'),
        content: SizedBox(
            width: 880,
            child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    field(title, 'Titel *', 420),
                    field(department, 'Abteilung/Fachbereich', 210),
                    field(costCenter, 'Kostenstelle', 180),
                    field(requestedBudget, 'Beantragtes Budget *', 210),
                    field(reason, 'Begründung *', 640, lines: 2),
                    dateField(desiredDate, 'Wunschlieferdatum', 230),
                    SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                            initialValue: priority,
                            decoration:
                                const InputDecoration(labelText: 'Priorität'),
                            items: ['Niedrig', 'Normal', 'Hoch', 'Dringend']
                                .map((v) =>
                                    DropdownMenuItem(value: v, child: Text(v)))
                                .toList(),
                            onChanged: (v) => setState(() => priority = v!))),
                    SizedBox(
                        width: 280,
                        child: DropdownButtonFormField<String>(
                            initialValue: supplier,
                            decoration: const InputDecoration(
                                labelText: 'Bevorzugter Lieferant'),
                            items: widget.suppliers
                                .map((v) => DropdownMenuItem(
                                    value: v['id'].toString(),
                                    child: Text(v['name'])))
                                .toList(),
                            onChanged: (v) => setState(() => supplier = v))),
                    field(notes, 'Notizen', 640, lines: 2)
                  ]),
                  const SizedBox(height: 18),
                  Row(children: [
                    Text('Positionen',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    TextButton.icon(
                        onPressed: () => setState(
                            () => items.add(_RequestItemControllers())),
                        icon: const Icon(Icons.add),
                        label: const Text('Position'))
                  ]),
                  ...items
                      .asMap()
                      .entries
                      .map((entry) => _itemRow(entry.key, entry.value)),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: _save,
              child: Text(widget.request == null
                  ? 'Entwurf speichern'
                  : 'Änderungen speichern'))
        ],
      );
  Widget _itemRow(int index, _RequestItemControllers item) {
    final mains =
        widget.categories.where((entry) => entry['parentId'] == null).toList();
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
                              labelText: 'Hauptkategorie *'),
                          items: mains
                              .map((v) => DropdownMenuItem(
                                  value: v['id'].toString(),
                                  child: Text(v['name'])))
                              .toList(),
                          onChanged: (v) => setState(() {
                                item.categoryId = v;
                                item.subcategoryId = null;
                                item.size.clear();
                              }))),
                  SizedBox(
                      width: 190,
                      child: DropdownButtonFormField<String>(
                          initialValue: item.subcategoryId,
                          decoration: const InputDecoration(
                              labelText: 'Unterkategorie'),
                          items: subs
                              .map((v) => DropdownMenuItem(
                                  value: v['id'].toString(),
                                  child: Text(v['name'])))
                              .toList(),
                          onChanged: (v) => setState(() {
                                item.subcategoryId = v;
                                item.size.clear();
                              }))),
                  if (_isWardrobeItem(item))
                    if (_sizesForItem(item).isNotEmpty)
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(
                              'request-size-${item.categoryId}-${item.subcategoryId}-${item.size.text}'),
                          initialValue:
                              _sizesForItem(item).contains(item.size.text)
                                  ? item.size.text
                                  : null,
                          decoration:
                              const InputDecoration(labelText: 'Größe *'),
                          items: _sizesForItem(item)
                              .map((size) => DropdownMenuItem(
                                  value: size, child: Text(size)))
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
                              .map((v) => DropdownMenuItem(
                                  value: v, child: Text('$v %')))
                              .toList(),
                          onChanged: (v) => setState(() => item.taxRate = v!))),
                  if (items.length > 1)
                    IconButton(
                        onPressed: () => setState(() {
                              item.dispose();
                              items.removeAt(index);
                            }),
                        icon: const Icon(Icons.delete_outline))
                ])));
  }

  void _save() {
    if (title.text.trim().isEmpty ||
        reason.text.trim().isEmpty ||
        (double.tryParse(requestedBudget.text.replaceAll(',', '.')) ?? 0) <=
            0 ||
        items.any((i) =>
            i.name.text.trim().isEmpty ||
            i.categoryId == null ||
            (_isWardrobeItem(i) &&
                _sizesForItem(i).isNotEmpty &&
                !_sizesForItem(i).contains(i.size.text)) ||
            (double.tryParse(i.quantity.text.replaceAll(',', '.')) ?? 0) <=
                0)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte alle Pflichtfelder ausfüllen.')));
      return;
    }
    Navigator.pop(context, {
      'title': title.text.trim(),
      'reason': reason.text.trim(),
      'department': department.text.trim(),
      'costCenter': costCenter.text.trim(),
      'requestedBudgetGross':
          double.tryParse(requestedBudget.text.replaceAll(',', '.')),
      'desiredDeliveryDate': dateInputToIso(desiredDate.text),
      'priority': priority,
      'notes': notes.text.trim(),
      'preferredSupplierId': supplier,
      'items': items
          .map((i) => {
                'name': i.name.text.trim(),
                'categoryId': i.categoryId,
                'subcategoryId': i.subcategoryId,
                'size': i.size.text.trim(),
                'quantity':
                    double.tryParse(i.quantity.text.replaceAll(',', '.')),
                'unit': i.unit.text.trim(),
                'taxRate': i.taxRate
              })
          .toList()
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

Widget field(TextEditingController controller, String label, double width,
        {int lines = 1}) =>
    SizedBox(
        width: width,
        child: TextField(
            controller: controller,
            maxLines: lines,
            decoration: InputDecoration(
                labelText: label, border: const OutlineInputBorder())));

Widget dateField(TextEditingController controller, String label, double width,
        {bool required = false}) =>
    DateInputField(
        controller: controller, label: label, width: width, required: required);

class OfferDialog extends StatefulWidget {
  final List<Map<String, dynamic>> suppliers;
  const OfferDialog({required this.suppliers, super.key});
  @override
  State<OfferDialog> createState() => _OfferDialogState();
}

class _OfferDialogState extends State<OfferDialog> {
  String? supplier;
  final number = TextEditingController(),
      date = TextEditingController(),
      valid = TextEditingController(),
      days = TextEditingController(),
      total = TextEditingController(),
      shipping = TextEditingController(text: '0'),
      notes = TextEditingController();
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Angebot erfassen'),
          content: SizedBox(
              width: 620,
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                SizedBox(
                    width: 290,
                    child: DropdownButtonFormField<String>(
                        initialValue: supplier,
                        decoration: const InputDecoration(
                            labelText: 'Lieferant *',
                            border: OutlineInputBorder()),
                        items: widget.suppliers
                            .map((v) => DropdownMenuItem(
                                value: v['id'].toString(),
                                child: Text(v['name'])))
                            .toList(),
                        onChanged: (v) => setState(() => supplier = v))),
                field(number, 'Angebotsnummer', 200),
                dateField(date, 'Angebotsdatum', 200),
                dateField(valid, 'Gültig bis', 200),
                field(days, 'Lieferzeit (Tage)', 160),
                field(total, 'Angebot brutto *', 180),
                field(shipping, 'Versand brutto', 180),
                field(notes, 'Notiz', 600, lines: 2)
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () {
                  if (supplier == null ||
                      (double.tryParse(total.text.replaceAll(',', '.')) ?? 0) <=
                          0) return;
                  Navigator.pop(context, {
                    'supplierId': supplier,
                    'offerNumber': number.text,
                    'offerDate': dateInputToIso(date.text),
                    'validUntil': dateInputToIso(valid.text),
                    'deliveryDays': int.tryParse(days.text),
                    'grossTotal':
                        double.tryParse(total.text.replaceAll(',', '.')),
                    'shippingGross':
                        double.tryParse(shipping.text.replaceAll(',', '.')),
                    'notes': notes.text
                  });
                },
                child: const Text('Speichern'))
          ]);
}

class OrderDialog extends StatefulWidget {
  final Map<String, dynamic> request;
  final List<Map<String, dynamic>> suppliers;
  const OrderDialog(
      {required this.request, required this.suppliers, super.key});
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
    supplier = widget.request['preferredSupplierId'] ??
        defaultOffer?['supplierId']?.toString();
    final singlePositionTotal =
        (widget.request['items'] as List).length == 1 && defaultOffer != null
            ? defaultOffer['grossTotal']?.toString() ?? ''
            : '';
    lines = (widget.request['items'] as List).map((raw) {
      final item = Map<String, dynamic>.from(raw);
      return _OrderLine(item,
          quantity: item['quantity'].toString(), price: singlePositionTotal);
    }).toList();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Bestellung anlegen'),
          content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                  child: Column(children: [
                Wrap(spacing: 12, runSpacing: 12, children: [
                  SizedBox(
                      width: 270,
                      child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: supplier,
                          decoration: const InputDecoration(
                              labelText: 'Lieferant *',
                              border: OutlineInputBorder()),
                          items: widget.suppliers
                              .map((v) => DropdownMenuItem(
                                  value: v['id'].toString(),
                                  child: Text(v['name'])))
                              .toList(),
                          onChanged: (v) => setState(() => supplier = v))),
                  SizedBox(
                      width: 240,
                      child: InputDecorator(
                          decoration: const InputDecoration(
                              labelText: 'Freigegebenes Budget'),
                          child: Text(
                              '${widget.request['approvedBudgetGross'] ?? '–'} €'))),
                  field(shipping, 'Versand brutto', 160),
                  dateField(expected, 'Erwartete Lieferung', 230),
                  field(notes, 'Bestellnotiz', 500, lines: 2)
                ]),
                const SizedBox(height: 16),
                ...lines.map((line) => Card(
                    child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(children: [
                          Expanded(child: Text(line.item['name'])),
                          field(line.quantity, 'Bestellmenge', 130),
                          const SizedBox(width: 10),
                          field(line.price, 'Positionssumme brutto', 180)
                        ]))))
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () {
                  if (supplier == null) return;
                  Navigator.pop(context, {
                    'supplierId': supplier,
                    'shippingGross':
                        double.tryParse(shipping.text.replaceAll(',', '.')),
                    'expectedDeliveryDate': dateInputToIso(expected.text),
                    'notes': notes.text,
                    'items': lines
                        .where((line) =>
                            (double.tryParse(
                                    line.quantity.text.replaceAll(',', '.')) ??
                                0) >
                            0)
                        .map((line) => {
                              'requestItemId': line.item['id'],
                              'quantity': double.tryParse(
                                  line.quantity.text.replaceAll(',', '.')),
                              'grossTotal': double.tryParse(
                                  line.price.text.replaceAll(',', '.'))
                            })
                        .toList()
                  });
                },
                child: const Text('Bestellung speichern'))
          ]);
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
              .toString());
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
                  child: Column(children: [
                Wrap(spacing: 12, runSpacing: 12, children: [
                  field(note, 'Lieferscheinnummer', 250),
                  dateField(date, 'Eingangsdatum', 220, required: true),
                  SizedBox(
                      width: 200,
                      child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Beanstandet'),
                          value: contested,
                          onChanged: (v) => setState(() => contested = v))),
                  if (contested)
                    field(complaint, 'Beschreibung der Beanstandung *', 620,
                        lines: 2)
                ]),
                const SizedBox(height: 12),
                ...lines.map((line) => ListTile(
                    title: Text(name(line.item['requestItemId'])),
                    subtitle: Text(
                        'Bestellt ${line.item['quantity']}, bereits geliefert ${line.item['deliveredQuantity']}'),
                    trailing: field(line.quantity, 'Geliefert', 130)))
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () {
                  if (contested && complaint.text.trim().isEmpty) return;
                  Navigator.pop(context, {
                    'deliveryNoteNumber': note.text,
                    'receivedAt': dateInputToIso(date.text),
                    'contested': contested,
                    'complaint': complaint.text,
                    'items': lines
                        .where((line) =>
                            (double.tryParse(
                                    line.quantity.text.replaceAll(',', '.')) ??
                                0) >
                            0)
                        .map((line) => {
                              'requestItemId': line.item['requestItemId'],
                              'quantity': double.tryParse(
                                  line.quantity.text.replaceAll(',', '.'))
                            })
                        .toList()
                  });
                },
                child: const Text('Wareneingang buchen'))
          ]);
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
  const TransferDialog(
      {required this.request,
      required this.receipt,
      required this.locations,
      required this.stocks,
      required this.categories,
      super.key});
  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  String? location, stock;
  String itemType = 'individual';
  bool resolved = false;
  final manufacturer = TextEditingController(),
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
                .firstOrNull?['sizes'] as List? ??
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
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                      initialValue: location,
                      decoration: const InputDecoration(
                          labelText: 'Standort *',
                          border: OutlineInputBorder()),
                      items: widget.locations
                          .map((v) => DropdownMenuItem(
                              value: v['id'].toString(),
                              child: Text(v['name'])))
                          .toList(),
                      onChanged: (v) => setState(() {
                            location = v;
                            stock = null;
                          }))),
              SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                      initialValue: stock,
                      decoration: const InputDecoration(
                          labelText: 'Lagerplatz',
                          border: OutlineInputBorder()),
                      items: availableStocks
                          .map((v) => DropdownMenuItem(
                              value: v['id'].toString(),
                              child: Text('${v['name']} · ${v['section']}')))
                          .toList(),
                      onChanged: (v) => setState(() => stock = v))),
              SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                      initialValue: itemType,
                      decoration: const InputDecoration(
                          labelText: 'Artikelart',
                          border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(
                            value: 'individual', child: Text('Einzelartikel')),
                        DropdownMenuItem(
                            value: 'bulk', child: Text('Mengenartikel'))
                      ],
                      onChanged: (v) => setState(() => itemType = v!))),
              field(manufacturer, 'Hersteller', 180),
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
                          labelText: 'Größe · ${source['name']}'),
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
                        .map((size) =>
                            DropdownMenuItem(value: size, child: Text(size)))
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
                        title: const Text('Beanstandung wurde geklärt')))
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
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
                      'model': model.text,
                      'inspectionIntervalMonths': int.tryParse(interval.text),
                      'size': selectedSizes[receiptItem['requestItemId']] ?? ''
                    };
                  }).toList()
                });
              },
              child: const Text('Inventar erzeugen'))
        ]);
  }
}

class SupplierDialog extends StatefulWidget {
  final Map<String, dynamic>? supplier;
  const SupplierDialog({this.supplier, super.key});
  @override
  State<SupplierDialog> createState() => _SupplierDialogState();
}

class _SupplierDialogState extends State<SupplierDialog> {
  late final Map<String, TextEditingController> c;
  bool active = true;
  @override
  void initState() {
    super.initState();
    c = {
      for (final key in [
        'name',
        'contact',
        'address',
        'customerNumber',
        'email',
        'phone',
        'website',
        'paymentTerms'
      ])
        key:
            TextEditingController(text: widget.supplier?[key]?.toString() ?? '')
    };
    active = widget.supplier?['active'] != false;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.supplier == null
              ? 'Lieferant anlegen'
              : 'Lieferant bearbeiten'),
          content: SizedBox(
              width: 650,
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                field(c['name']!, 'Name *', 300),
                field(c['contact']!, 'Ansprechpartner', 280),
                field(c['address']!, 'Anschrift', 600, lines: 2),
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
                        onChanged: (v) => setState(() => active = v)))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () {
                  if (c['name']!.text.trim().isEmpty) return;
                  Navigator.pop(context, {
                    for (final entry in c.entries)
                      entry.key: entry.value.text.trim(),
                    'active': active
                  });
                },
                child: const Text('Speichern'))
          ]);
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
  final ValueChanged<Map<String, dynamic>> onSelectOffer, onReceive, onTransfer;
  final ValueChanged<Map<String, dynamic>> onDownloadDocument;
  final ValueChanged<String> onPrint;
  const ProcurementDetail(
      {required this.request,
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
      required this.onCreateOrder,
      required this.onReceive,
      required this.onTransfer,
      required this.onUpload,
      required this.onDownloadDocument,
      required this.onPrint,
      required this.onCancel,
      super.key});
  @override
  Widget build(BuildContext context) {
    final offers =
        (request['offers'] as List? ?? const []).cast<Map<String, dynamic>>();
    final orders =
        (request['orders'] as List? ?? const []).cast<Map<String, dynamic>>();
    final docs = (request['documents'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final history =
        (request['history'] as List? ?? const []).cast<Map<String, dynamic>>();
    return Scaffold(
        appBar: AppBar(
            title: Text('${request['number']} · ${request['title']}'),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'PDF erstellen',
                onSelected: onPrint,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'orders', child: Text('Bestellungen als PDF')),
                  PopupMenuItem(
                      value: 'offers',
                      child: Text('Angebotsvergleich als PDF')),
                  PopupMenuItem(
                      value: 'receipts', child: Text('Wareneingänge als PDF')),
                ],
                icon: const Icon(Icons.picture_as_pdf_outlined),
              ),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close))
            ]),
        body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            Chip(label: Text(request['status'])),
                            Chip(
                                avatar: const Icon(Icons.euro, size: 18),
                                label: Text(
                                    'Beantragt ${money(request['requestedBudgetGross'])}')),
                            if (request['approvedBudgetGross'] != null)
                              Chip(
                                  avatar: const Icon(Icons.verified, size: 18),
                                  label: Text(
                                      'Freigegeben ${money(request['approvedBudgetGross'])}')),
                            Chip(
                                avatar:
                                    const Icon(Icons.person_outline, size: 18),
                                label: Text(request['requestedBy'])),
                            Chip(
                                avatar: const Icon(Icons.business_outlined,
                                    size: 18),
                                label: Text(request['department']
                                            ?.toString()
                                            .isNotEmpty ==
                                        true
                                    ? request['department']
                                    : 'Ohne Fachbereich'))
                          ]),
                          const SizedBox(height: 16),
                          Text(request['reason'],
                              style: Theme.of(context).textTheme.bodyLarge),
                          if (request['notes']?.toString().isNotEmpty == true)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text('Notiz: ${request['notes']}')),
                          const SizedBox(height: 18),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            if (request['status'] == 'Entwurf' && canWrite)
                              FilledButton.icon(
                                  onPressed: onSubmit,
                                  icon: const Icon(Icons.send),
                                  label: const Text('Beantragen')),
                            if (request['status'] == 'Entwurf' && canWrite)
                              OutlinedButton.icon(
                                  onPressed: onEdit,
                                  icon: const Icon(Icons.edit_outlined),
                                  label: const Text('Bearbeiten')),
                            if (request['status'] == 'Entwurf' && canWrite)
                              TextButton.icon(
                                  onPressed: onDelete,
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Entwurf löschen')),
                            if (request['status'] == 'Beantragt' &&
                                canApprove) ...[
                              FilledButton.icon(
                                  onPressed: () => onApprove(true),
                                  icon: const Icon(Icons.check),
                                  label: const Text('Freigeben')),
                              OutlinedButton.icon(
                                  onPressed: () => onApprove(false),
                                  icon: const Icon(Icons.close),
                                  label: const Text('Ablehnen'))
                            ],
                            if (['Beantragt', 'Genehmigt']
                                    .contains(request['status']) &&
                                canWrite)
                              OutlinedButton.icon(
                                  onPressed: onAddOffer,
                                  icon:
                                      const Icon(Icons.request_quote_outlined),
                                  label: const Text('Angebot erfassen')),
                            if (['Genehmigt', 'Bestellt']
                                    .contains(request['status']) &&
                                canOrder)
                              FilledButton.icon(
                                  onPressed: onCreateOrder,
                                  icon:
                                      const Icon(Icons.shopping_cart_checkout),
                                  label: const Text('Bestellung anlegen')),
                            if (canWrite)
                              OutlinedButton.icon(
                                  onPressed: onUpload,
                                  icon: const Icon(Icons.attach_file),
                                  label: const Text('Dokument')),
                            if (!['Abgeschlossen', 'Storniert']
                                .contains(request['status']))
                              TextButton.icon(
                                  onPressed: onCancel,
                                  icon: const Icon(Icons.cancel_outlined),
                                  label: const Text('Stornieren'))
                          ]),
                          section(
                              context,
                              'Positionen',
                              (request['items'] as List).map((raw) {
                                final item = raw as Map;
                                return ListTile(
                                    title: Text(item['name']),
                                    subtitle: Text(
                                        '${categoryName(item['categoryId'])}${item['subcategoryId'] == null ? '' : ' / ${categoryName(item['subcategoryId'])}'} · MwSt. ${item['taxRate']} %'),
                                    trailing: Text(
                                        '${item['quantity']} ${item['unit']}'));
                              }).toList()),
                          section(
                              context,
                              'Freigaben',
                              (request['approvals'] as List? ?? const [])
                                      .isEmpty
                                  ? [
                                      const ListTile(
                                          title: Text(
                                              'Noch keine Freigabe erteilt.'))
                                    ]
                                  : (request['approvals'] as List).map((raw) {
                                      final a = raw as Map;
                                      return ListTile(
                                          leading: Icon(
                                              a['decision'] == 'Genehmigt'
                                                  ? Icons.check_circle
                                                  : Icons.cancel,
                                              color:
                                                  a['decision'] == 'Genehmigt'
                                                      ? Colors.green
                                                      : Colors.red),
                                          title: Text(
                                              '${a['role']} · ${a['name']}'),
                                          subtitle: Text(
                                              '${date(a['createdAt'])}${a['boardResolution']?.toString().isNotEmpty == true ? ' · ${a['boardResolution']}' : ''}${a['approvedBudgetGross'] != null ? ' · Freigegeben ${money(a['approvedBudgetGross'])}' : ''}\n${a['notes'] ?? ''}'));
                                    }).toList()),
                          section(
                              context,
                              'Angebotsvergleich',
                              offers.isEmpty
                                  ? [
                                      const ListTile(
                                          title: Text(
                                              'Noch keine Angebote erfasst.'))
                                    ]
                                  : offers
                                      .map((offer) => ListTile(
                                          leading: IconButton(
                                              tooltip: request['selectedOfferId'] ==
                                                      offer['id']
                                                  ? 'Ausgewähltes Angebot'
                                                  : 'Angebot auswählen',
                                              onPressed: canOrder
                                                  ? () => onSelectOffer(offer)
                                                  : null,
                                              icon: Icon(request['selectedOfferId'] ==
                                                      offer['id']
                                                  ? Icons.radio_button_checked
                                                  : Icons
                                                      .radio_button_unchecked)),
                                          title: Text(
                                              '${supplierName(offer['supplierId'])} · ${offer['offerNumber']?.toString().isNotEmpty == true ? offer['offerNumber'] : 'ohne Angebotsnummer'}'),
                                          subtitle: Text(
                                              'Lieferzeit ${offer['deliveryDays'] ?? '–'} Tage · gültig bis ${date(offer['validUntil'])}'),
                                          trailing: Text(
                                              money((offer['grossTotal'] as num? ?? 0) + (offer['shippingGross'] as num? ?? 0)),
                                              style: const TextStyle(fontWeight: FontWeight.bold))))
                                      .toList()),
                          section(
                              context,
                              'Bestellungen und Wareneingänge',
                              orders.isEmpty
                                  ? [
                                      const ListTile(
                                          title: Text(
                                              'Noch keine Bestellung angelegt.'))
                                    ]
                                  : orders
                                      .expand((order) => [
                                            ListTile(
                                                leading: const Icon(Icons
                                                    .shopping_cart_outlined),
                                                title: Text(
                                                    '${order['number']} · ${supplierName(order['supplierId'])}'),
                                                subtitle: Text(
                                                    'Bestellt ${date(order['orderDate'])} · erwartet ${date(order['expectedDeliveryDate'])} · freigegeben ${money(request['approvedBudgetGross'])}'),
                                                trailing: Wrap(children: [
                                                  Text(money(
                                                      order['grossTotal'])),
                                                  if (canReceive &&
                                                      (order['items'] as List)
                                                          .any((raw) =>
                                                              (raw['deliveredQuantity']
                                                                      as num? ??
                                                                  0) <
                                                              (raw['quantity']
                                                                  as num)))
                                                    IconButton(
                                                        onPressed: () =>
                                                            onReceive(order),
                                                        tooltip: 'Wareneingang',
                                                        icon: const Icon(Icons
                                                            .inventory_outlined))
                                                ])),
                                            ...(order['receipts'] as List? ??
                                                    const [])
                                                .cast<Map<String, dynamic>>()
                                                .map((receipt) => Padding(
                                                    padding: const EdgeInsets.only(
                                                        left: 36),
                                                    child: ListTile(
                                                        leading: Icon(
                                                            receipt['status'] ==
                                                                    'Beanstandet'
                                                                ? Icons
                                                                    .report_problem_outlined
                                                                : Icons
                                                                    .move_to_inbox_outlined,
                                                            color: receipt['status'] ==
                                                                    'Beanstandet'
                                                                ? Colors.orange
                                                                : null),
                                                        title: Text('${receipt['number']} · Lieferschein ${receipt['deliveryNoteNumber']?.toString().isNotEmpty == true ? receipt['deliveryNoteNumber'] : '–'}'),
                                                        subtitle: Text('${receipt['status']} · ${date(receipt['receivedAt'])}${receipt['complaint']?.toString().isNotEmpty == true ? '\n${receipt['complaint']}' : ''}'),
                                                        trailing: !receipt['inventoryTransferred'] && canReceive ? FilledButton.tonal(onPressed: () => onTransfer(receipt), child: const Text('Prüfen & übernehmen')) : const Icon(Icons.check_circle, color: Colors.green))))
                                          ])
                                      .toList()),
                          section(
                              context,
                              'Dokumente',
                              docs.isEmpty
                                  ? [
                                      const ListTile(
                                          title: Text(
                                              'Noch keine Dokumente hinterlegt.'))
                                    ]
                                  : docs
                                      .map((doc) => ListTile(
                                          onTap: () => onDownloadDocument(doc),
                                          leading: const Icon(
                                              Icons.description_outlined),
                                          title: Text(doc['fileName']),
                                          subtitle: Text(
                                              '${doc['documentType']} · ${date(doc['createdAt'])}'),
                                          trailing: const Icon(Icons.download)))
                                      .toList()),
                          section(
                              context,
                              'Verlauf',
                              history.reversed
                                  .map((h) => ListTile(
                                      dense: true,
                                      leading:
                                          const Icon(Icons.history, size: 20),
                                      title: Text(h['action']),
                                      subtitle: Text(
                                          '${h['actor']} · ${date(h['createdAt'])}')))
                                  .toList()),
                        ])))));
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
                            child: Text(title,
                                style: Theme.of(context).textTheme.titleLarge)),
                        const Divider(),
                        ...children
                      ]))));
}
