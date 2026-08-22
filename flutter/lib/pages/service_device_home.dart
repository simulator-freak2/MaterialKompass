part of 'service_device_pages.dart';

class ServiceDeviceHomePage extends StatefulWidget {
  final String token;
  final Map<String, dynamic> device;
  final String deviceCredential;
  const ServiceDeviceHomePage(
      {required this.token,
      required this.device,
      required this.deviceCredential,
      super.key});
  @override
  State<ServiceDeviceHomePage> createState() => _ServiceDeviceHomePageState();
}

class _ServiceDeviceHomePageState extends State<ServiceDeviceHomePage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> results = [];
  bool loading = false;
  Timer? warningTimer;
  Timer? logoutTimer;

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };

  @override
  void initState() {
    super.initState();
    scheduleSessionExpiry();
  }

  @override
  void dispose() {
    warningTimer?.cancel();
    logoutTimer?.cancel();
    search.dispose();
    clearTemporaryDeviceFiles();
    super.dispose();
  }

  void scheduleSessionExpiry() {
    warningTimer?.cancel();
    logoutTimer?.cancel();
    warningTimer =
        Timer(const Duration(minutes: 4, seconds: 30), warnBeforeExpiry);
  }

  Future<void> warnBeforeExpiry() async {
    if (!mounted) return;
    logoutTimer = Timer(const Duration(seconds: 30), logout);
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: const Text('Sitzung läuft ab'),
                content: const Text(
                    'Die Sitzung wird aus Sicherheitsgründen in 30 Sekunden beendet.'),
                actions: [
                  FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Jetzt abmelden'))
                ]));
    await logout();
  }

  Future<void> logout() async {
    warningTimer?.cancel();
    logoutTimer?.cancel();
    await clearTemporaryDeviceFiles();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => ServiceDeviceLoginPage(
                deviceCredential: widget.deviceCredential,
                initialDevice: widget.device)),
        (_) => false);
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> performSearch() async {
    final query = search.text.trim();
    if (query.isEmpty) return;
    setState(() => loading = true);
    try {
      final response = await http.get(
          Uri.parse(
              '$apiBaseUrl/api/device/search?q=${Uri.encodeQueryComponent(query)}'),
          headers: headers);
      if (!mounted) return;
      if (response.statusCode != 200) {
        return message(
            _object(response)['error']?.toString() ?? 'Suche fehlgeschlagen.');
      }
      results = (jsonDecode(response.body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      setState(() {});
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> openDocument(Map<String, dynamic> document) async {
    final response = await http.get(
        Uri.parse('$apiBaseUrl/api/device/documents/${document['id']}'),
        headers: headers);
    if (response.statusCode != 200) {
      return message(_object(response)['error']?.toString() ??
          'Dokument konnte nicht geöffnet werden.');
    }
    final data = _object(response);
    final opened = await openTemporaryDeviceFile(
        data['fileName']?.toString() ?? 'dokument',
        base64Decode(data['fileBase64'].toString()));
    if (!opened && mounted) {
      message('Das Dokument konnte auf diesem Gerät nicht geöffnet werden.');
    }
  }

  Future<void> findDefectTarget() async {
    final controller = TextEditingController();
    final number = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('Artikel für Mangel finden'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    onSubmitted: (value) => Navigator.pop(context, value),
                    decoration: const InputDecoration(
                        labelText: 'Inventarnummer, Barcode oder QR-Code',
                        prefixIcon: Icon(Icons.qr_code_scanner))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('Suchen'))
                ]));
    controller.dispose();
    if (number == null || number.trim().isEmpty) return;
    final response = await http.get(
        Uri.parse(
            '$apiBaseUrl/api/device/defect-target?inventoryNumber=${Uri.encodeQueryComponent(number.trim())}'),
        headers: headers);
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
          _object(response)['error']?.toString() ?? 'Artikel nicht gefunden.');
    }
    await createDefect(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  Future<void> createDefect(Map<String, dynamic> item) async {
    final payload = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _DeviceDefectDialog(
            item: item,
            defaultLocation: widget.device['locationName']?.toString() ?? ''));
    if (payload == null) return;
    final response = await http.post(
        Uri.parse('$apiBaseUrl/api/device/defects'),
        headers: headers,
        body: jsonEncode(payload));
    if (!mounted) return;
    final data = _object(response);
    if (response.statusCode != 201) {
      return message(
          data['error']?.toString() ?? 'Mängelmeldung fehlgeschlagen.');
    }
    if (response.headers['x-materialkompass-offline-queued'] == 'true') {
      message(
          'Mängelmeldung wurde offline gespeichert und wird später synchronisiert.');
      return;
    }
    final report = Map<String, dynamic>.from(data['report'] as Map);
    final accessQr =
        'mkdefect:v1:${report['defectNumber']}:${data['accessCode']}';
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: const Text('Mängelmeldung gespeichert'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 48),
                  const SizedBox(height: 12),
                  SelectableText(
                      'Mängelnummer: ${report['defectNumber']}\nZugriffscode: ${data['accessCode']}',
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: bw.BarcodeWidget(
                      barcode: bw.Barcode.qrCode(),
                      data: accessQr,
                      width: 190,
                      height: 190,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                      'Bewahren Sie Mängelnummer und Zugriffscode gemeinsam auf.')
                ]),
                actions: [
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(
                        text:
                            '${report['defectNumber']} · ${data['accessCode']}',
                      ));
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Code kopieren'),
                  ),
                  FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Fertig'))
                ]));
    search.clear();
    results = [];
    if (mounted) setState(() {});
  }

  Future<void> accessDefect() async {
    final credentials = await showDialog<Map<String, String>>(
        context: context, builder: (_) => const _DefectAccessDialog());
    if (credentials == null) return;
    final response = await http.post(
        Uri.parse('$apiBaseUrl/api/device/defects/access'),
        headers: headers,
        body: jsonEncode(credentials));
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
          _object(response)['error']?.toString() ?? 'Meldung nicht gefunden.');
    }
    final report = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final update = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _DeviceDefectDialog(
                item: {
                  'type': report['entityType'],
                  'id': report['entityId'],
                  'name': report['entityName'],
                  'inventoryNumber': report['inventoryNumber']
                },
                defaultLocation: report['deviceLocation']?.toString() ?? '',
                report: report));
    if (update == null || report['editable'] != true) return;
    final saved = await http.put(
        Uri.parse('$apiBaseUrl/api/device/defects/access'),
        headers: headers,
        body: jsonEncode({...credentials, ...update}));
    if (mounted) {
      message(saved.statusCode == 200
          ? 'Mängelmeldung wurde aktualisiert.'
          : (_object(saved)['error']?.toString() ??
              'Änderung fehlgeschlagen.'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(
                'Systemzugang · ${widget.device['name'] ?? 'Dienstgerät'}'),
            actions: [
              IconButton(
                  onPressed: logout,
                  tooltip: 'Abmelden',
                  icon: const Icon(Icons.logout))
            ]),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                SizedBox(
                    width: 520,
                    child: TextField(
                        controller: search,
                        onSubmitted: (_) => performSearch(),
                        decoration: InputDecoration(
                            labelText:
                                'Material, Kleidung, Lagerort oder Kategorie suchen',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: IconButton(
                                onPressed: performSearch,
                                icon: const Icon(Icons.arrow_forward)),
                            border: const OutlineInputBorder()))),
                FilledButton.icon(
                    onPressed: findDefectTarget,
                    icon: const Icon(Icons.report_problem),
                    label: const Text('Mangel melden')),
                OutlinedButton.icon(
                    onPressed: accessDefect,
                    icon: const Icon(Icons.key),
                    label: const Text('Meldung mit Code öffnen')),
              ])),
          if (loading) const LinearProgressIndicator(),
          Expanded(
              child: results.isEmpty
                  ? const Center(
                      child: Text(
                          'Suchbegriff eingeben oder einen Artikel scannen.'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: results.length,
                      itemBuilder: (_, index) {
                        final item = results[index];
                        final isItem = item['type'] == 'MaterialItem' ||
                            item['type'] == 'ClothingItem';
                        return Card(
                            child: ExpansionTile(
                                leading: Icon(isItem
                                    ? Icons.inventory_2
                                    : item['type'] == 'Location'
                                        ? Icons.warehouse
                                        : Icons.category),
                                title: Text(item['name']?.toString() ?? ''),
                                subtitle: Text(isItem
                                    ? '${item['inventoryNumber']} · ${item['status']}\n${item['location'] ?? ''} ${item['storagePosition'] ?? ''}'
                                    : item['code']?.toString() ?? ''),
                                children: isItem
                                    ? [
                                        Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Wrap(
                                                spacing: 16,
                                                runSpacing: 8,
                                                children: [
                                                  Text(
                                                      'Bestand: ${item['quantity']}'),
                                                  Text(
                                                      'Verfügbar: ${item['availableQuantity']}'),
                                                  Text(
                                                      'Prüfdatum: ${item['nextInspectionDate'] ?? '-'}'),
                                                  FilledButton.icon(
                                                      onPressed: () =>
                                                          createDefect(item),
                                                      icon: const Icon(
                                                          Icons.report_problem),
                                                      label: const Text(
                                                          'Mangel melden')),
                                                  ...((item['documents']
                                                              as List? ??
                                                          const [])
                                                      .map((document) => ActionChip(
                                                          avatar: const Icon(
                                                              Icons
                                                                  .description),
                                                          label: Text(document['title']
                                                                  ?.toString() ??
                                                              document['fileName']
                                                                  .toString()),
                                                          onPressed: () => openDocument(
                                                              Map<String, dynamic>.from(
                                                                  document as Map)))))
                                                ]))
                                      ]
                                    : const []));
                      })),
        ]),
      );
}

class _DefectAccessDialog extends StatefulWidget {
  const _DefectAccessDialog();
  @override
  State<_DefectAccessDialog> createState() => _DefectAccessDialogState();
}

class _DefectAccessDialogState extends State<_DefectAccessDialog> {
  final number = TextEditingController();
  final code = TextEditingController();
  @override
  void dispose() {
    number.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> scan() async {
    final value = await scanQrLoginCode(
      context,
      allowedPrefixes: const ['mkdefect:v1:'],
    );
    if (value == null) return;
    final parts = value.substring('mkdefect:v1:'.length).split(':');
    if (parts.length != 2) return;
    setState(() {
      number.text = parts[0];
      code.text = parts[1];
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Mängelmeldung öffnen'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: number,
                decoration: const InputDecoration(labelText: 'Mängelnummer')),
            TextField(
                controller: code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Zugriffscode'))
          ]),
          actions: [
            OutlinedButton.icon(
                onPressed: scan,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('QR-Code scannen')),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context, {
                      'defectNumber': number.text.trim(),
                      'code': code.text.trim()
                    }),
                child: const Text('Öffnen'))
          ]);
}

class _DeviceDefectDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  final String defaultLocation;
  final Map<String, dynamic>? report;
  const _DeviceDefectDialog(
      {required this.item, required this.defaultLocation, this.report});
  @override
  State<_DeviceDefectDialog> createState() => _DeviceDefectDialogState();
}

class _DeviceDefectDialogState extends State<_DeviceDefectDialog> {
  late final title =
      TextEditingController(text: widget.report?['title']?.toString());
  late final description =
      TextEditingController(text: widget.report?['description']?.toString());
  late final risk =
      TextEditingController(text: widget.report?['riskLevel']?.toString());
  late final measures =
      TextEditingController(text: widget.report?['measuresTaken']?.toString());
  late final location = TextEditingController(
      text: widget.report?['deviceLocation']?.toString() ??
          widget.defaultLocation);
  late final contactName =
      TextEditingController(text: widget.report?['contactName']?.toString());
  late final contactEmail =
      TextEditingController(text: widget.report?['contactEmail']?.toString());
  late final contactPhone =
      TextEditingController(text: widget.report?['contactPhone']?.toString());
  final images = <Map<String, dynamic>>[];
  bool get editable => widget.report?['editable'] != false;
  @override
  void dispose() {
    for (final c in [
      title,
      description,
      risk,
      measures,
      location,
      contactName,
      contactEmail,
      contactPhone
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> addImages() async {
    final picked = await FilePicker.pickFiles(type: FileType.image);
    for (final file in picked) {
      final bytes = await file.readAsBytes();
      images.add({
        'fileName': file.name,
        'mimeType': file.name.split('.').last.toLowerCase() == 'png'
            ? 'image/png'
            : 'image/jpeg',
        'fileBase64': base64Encode(bytes)
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(
              '${widget.item['name']} · ${widget.item['inventoryNumber']}'),
          content: SizedBox(
              width: 620,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (!editable)
                  const ListTile(
                      leading: Icon(Icons.lock),
                      title: Text('Die Meldung ist schreibgeschützt.')),
                TextField(
                    controller: title,
                    enabled: editable,
                    decoration: const InputDecoration(labelText: 'Titel *')),
                TextField(
                    controller: description,
                    enabled: editable,
                    minLines: 3,
                    maxLines: 6,
                    decoration:
                        const InputDecoration(labelText: 'Beschreibung *')),
                TextField(
                    controller: risk,
                    enabled: editable,
                    decoration:
                        const InputDecoration(labelText: 'Gefährdung *')),
                TextField(
                    controller: measures,
                    enabled: editable,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                        labelText: 'Getroffene Sofortmaßnahmen *')),
                TextField(
                    controller: location,
                    enabled: editable,
                    decoration: const InputDecoration(labelText: 'Standort *')),
                const Divider(),
                TextField(
                    controller: contactName,
                    enabled: editable,
                    decoration: const InputDecoration(
                        labelText: 'Name der meldenden Person *')),
                TextField(
                    controller: contactEmail,
                    enabled: editable,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'E-Mail')),
                TextField(
                    controller: contactPhone,
                    enabled: editable,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Telefon')),
                if (editable)
                  ListTile(
                      leading: const Icon(Icons.add_a_photo),
                      title: Text('${images.length} neue Bilder ausgewählt'),
                      trailing: TextButton(
                          onPressed: addImages,
                          child: const Text('Bilder wählen'))),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(editable ? 'Abbrechen' : 'Schließen')),
            if (editable)
              FilledButton(
                  onPressed: () {
                    if ([
                          title,
                          description,
                          risk,
                          measures,
                          location,
                          contactName
                        ].any((c) => c.text.trim().isEmpty) ||
                        (contactEmail.text.trim().isEmpty &&
                            contactPhone.text.trim().isEmpty)) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Bitte alle Pflichtfelder und E-Mail oder Telefon ausfüllen.')));
                      return;
                    }
                    Navigator.pop(context, {
                      'entityType': widget.item['type'],
                      'entityId': widget.item['id'],
                      'title': title.text.trim(),
                      'description': description.text.trim(),
                      'riskLevel': risk.text.trim(),
                      'measuresTaken': measures.text.trim(),
                      'location': location.text.trim(),
                      'contactName': contactName.text.trim(),
                      'contactEmail': contactEmail.text.trim(),
                      'contactPhone': contactPhone.text.trim(),
                      if (images.isNotEmpty) 'images': images
                    });
                  },
                  child: const Text('Speichern'))
          ]);
}
