part of 'service_device_pages.dart';

class ServiceDeviceBootstrap extends StatefulWidget {
  const ServiceDeviceBootstrap({super.key});

  @override
  State<ServiceDeviceBootstrap> createState() => _ServiceDeviceBootstrapState();
}

class _ServiceDeviceBootstrapState extends State<ServiceDeviceBootstrap> {
  String? credential;
  Map<String, dynamic>? device;
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (kIsWeb) {
      if (mounted) setState(() => ready = true);
      return;
    }
    final stored = await ServiceDeviceStorage.readCredential();
    if (stored != null) {
      try {
        final response = await http.post(
          Uri.parse('$apiBaseUrl/api/service-devices/status'),
          headers: {'Content-Type': 'application/json'},
          body:
              jsonEncode({'deviceCredential': stored, ...await _clientInfo()}),
        );
        if (response.statusCode == 200) {
          credential = stored;
          device =
              Map<String, dynamic>.from(_object(response)['device'] as Map);
        } else {
          await ServiceDeviceStorage.clear();
        }
      } catch (_) {
        // Bei einem vorübergehenden Netzwerkfehler bleibt die Aktivierung
        // erhalten und kann über die Geräte-Anmeldeseite erneut geprüft werden.
        credential = stored;
      }
    }
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return const Stack(children: [
        AbsorbPointer(child: LoginPage()),
        Positioned.fill(
          child: ColoredBox(
            color: Color(0x55FFFFFF),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ]);
    }
    if (kIsWeb || credential == null) return const LoginPage();
    return ServiceDeviceLoginPage(
      deviceCredential: credential!,
      initialDevice: device,
    );
  }
}

class ServiceDeviceActivationPage extends StatefulWidget {
  const ServiceDeviceActivationPage({super.key});

  @override
  State<ServiceDeviceActivationPage> createState() =>
      _ServiceDeviceActivationPageState();
}

class _ServiceDeviceActivationPageState
    extends State<ServiceDeviceActivationPage> {
  final identifier = TextEditingController();
  final password = TextEditingController();
  List<Map<String, dynamic>> devices = [];
  String? selectedId;
  bool loading = false;

  @override
  void dispose() {
    identifier.dispose();
    password.dispose();
    super.dispose();
  }

  void message(String value) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(value)));

  Future<void> loadDevices() async {
    setState(() => loading = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/service-devices/activation/options'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(
            {'identifier': identifier.text, 'password': password.text}),
      );
      if (!mounted) return;
      if (response.statusCode != 200) {
        return message(_object(response)['error']?.toString() ??
            'Admin-Anmeldung fehlgeschlagen.');
      }
      devices = (jsonDecode(response.body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      selectedId = devices.isEmpty ? null : devices.first['id'].toString();
      setState(() {});
    } catch (_) {
      if (mounted) message('Der Server ist nicht erreichbar.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> activateDevice() async {
    if (selectedId == null) return;
    setState(() => loading = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/service-devices/activate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'identifier': identifier.text,
          'password': password.text,
          'deviceId': selectedId,
          ...await _clientInfo(),
        }),
      );
      if (!mounted) return;
      final data = _object(response);
      if (response.statusCode != 200) {
        return message(
            data['error']?.toString() ?? 'Aktivierung fehlgeschlagen.');
      }
      final credential = data['deviceCredential'].toString();
      await ServiceDeviceStorage.saveCredential(credential);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => ServiceDeviceLoginPage(
                  deviceCredential: credential,
                  initialDevice:
                      Map<String, dynamic>.from(data['device'] as Map),
                )),
        (_) => false,
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => kIsWeb
      ? Scaffold(
          appBar: AppBar(title: const Text('Dienstgerät aktivieren')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Dienstgeräte können nur in einer installierten App aktiviert werden.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        )
      : Scaffold(
          appBar: AppBar(title: const Text('Dienstgerät aktivieren')),
          body: Center(
              child: SingleChildScrollView(
                  child: Card(
            margin: const EdgeInsets.all(24),
            child: SizedBox(
                width: 520,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.devices_other, size: 56),
                    const SizedBox(height: 12),
                    const Text(
                        'Die Aktivierung muss einmalig durch einen Administrator erfolgen.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: identifier,
                        decoration: const InputDecoration(
                            labelText: 'Admin-Benutzername oder E-Mail',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Admin-Passwort',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: loading ? null : loadDevices,
                        icon: const Icon(Icons.login),
                        label: const Text('Geräte laden')),
                    if (devices.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      DropdownButtonFormField<String>(
                        initialValue: selectedId,
                        decoration: const InputDecoration(
                            labelText: 'Vorbereitetes Gerät',
                            border: OutlineInputBorder()),
                        items: devices
                            .map((entry) => DropdownMenuItem(
                                value: entry['id'].toString(),
                                child: Text(
                                    '${entry['name']} · ${entry['inventoryNumber']}')))
                            .toList(),
                        onChanged: (value) =>
                            setState(() => selectedId = value),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                          onPressed: loading ? null : activateDevice,
                          icon: const Icon(Icons.verified_user),
                          label: const Text('Dieses Gerät aktivieren')),
                    ],
                  ]),
                )),
          ))),
        );
}
