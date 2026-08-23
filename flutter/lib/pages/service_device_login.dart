part of 'service_device_pages.dart';

class ServiceDeviceLoginPage extends StatefulWidget {
  final String deviceCredential;
  final Map<String, dynamic>? initialDevice;
  const ServiceDeviceLoginPage(
      {required this.deviceCredential, this.initialDevice, super.key});

  @override
  State<ServiceDeviceLoginPage> createState() => _ServiceDeviceLoginPageState();
}

class _ServiceDeviceLoginPageState extends State<ServiceDeviceLoginPage> {
  final systemPassword = TextEditingController();
  final identifier = TextEditingController();
  final personalPassword = TextEditingController();
  final totp = TextEditingController();
  final nfc = TextEditingController();
  Map<String, dynamic>? device;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    device = widget.initialDevice;
    if (device == null) refresh();
  }

  @override
  void dispose() {
    systemPassword.dispose();
    identifier.dispose();
    personalPassword.dispose();
    totp.dispose();
    nfc.dispose();
    super.dispose();
  }

  void message(String value) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(value)));

  Future<void> refresh() async {
    try {
      final response = await http.post(
          Uri.parse('$apiBaseUrl/api/service-devices/status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'deviceCredential': widget.deviceCredential,
            ...await _clientInfo()
          }));
      if (response.statusCode == 200 && mounted) {
        setState(() => device =
            Map<String, dynamic>.from(_object(response)['device'] as Map));
      }
      if (response.statusCode != 200 && mounted) {
        message(_object(response)['error']?.toString() ??
            'Gerät konnte nicht geprüft werden.');
      }
    } catch (_) {
      if (mounted) message('Keine Verbindung zum Server.');
    }
  }

  Map<String, dynamic> factorBody(String mode) => {
        if (mode == 'totp') 'totp': totp.text.trim(),
        if (mode == 'nfc') 'nfcCredential': nfc.text.trim(),
      };

  Future<void> systemLogin({String? qrCredential}) async {
    setState(() => loading = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/service-devices/login/system'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceCredential': widget.deviceCredential,
          ...await _clientInfo(),
          if (qrCredential == null) 'password': systemPassword.text,
          if (qrCredential != null) 'qrCredential': qrCredential,
          ...factorBody(device?['systemMfa']?.toString() ?? 'off'),
        }),
      );
      if (!mounted) return;
      final data = _object(response);
      if (response.statusCode != 200) {
        return message(
            data['error']?.toString() ?? 'Systemlogin fehlgeschlagen.');
      }
      if (data['offlineLease'] is Map) {
        await OfflineStore.instance.saveQrLease(
          Map<String, dynamic>.from(data['offlineLease'] as Map),
          sessionToken: data['token'].toString(),
        );
      }
      if (!mounted) return;
      unawaited(OfflineSessionService.prepare(data['token'].toString()));
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ServiceDeviceHomePage(
                token: data['token'].toString(),
                device: device ?? {},
                deviceCredential: widget.deviceCredential,
              )));
    } catch (_) {
      final lease = qrCredential == null
          ? null
          : await OfflineStore.instance.authenticateQr(qrCredential);
      if (!mounted) return;
      if (lease == null || lease['sessionType'] != 'service_device_system') {
        return message('Keine Verbindung und keine gültige Offlinefreigabe.');
      }
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => ServiceDeviceHomePage(
                token: lease['sessionToken'].toString(),
                device: device ?? {},
                deviceCredential: widget.deviceCredential,
              )));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> personalLogin(
      {String? qrCredential, String? nfcCredential}) async {
    setState(() => loading = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/service-devices/login/personal'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceCredential': widget.deviceCredential,
          ...await _clientInfo(),
          if (qrCredential == null && nfcCredential == null) ...{
            'identifier': identifier.text,
            'password': personalPassword.text
          },
          if (qrCredential != null) 'qrCredential': qrCredential,
          if (nfcCredential != null) 'nfcLoginCredential': nfcCredential,
          ...factorBody(device?['personalMfa']?.toString() ?? 'off'),
        }),
      );
      if (!mounted) return;
      var data = _object(response);
      if (response.statusCode == 202 && data['mfaRequired'] == true) {
        final verified = await verifyMfaChallenge(context, data);
        if (verified == null || !mounted) return;
        data = verified;
      }
      if (response.statusCode != 200 && data['token'] == null) {
        return message(data['error']?.toString() ??
            'Persönliche Anmeldung fehlgeschlagen.');
      }
      if (data['offlineLease'] is Map) {
        await OfflineStore.instance.saveQrLease(
          Map<String, dynamic>.from(data['offlineLease'] as Map),
          sessionToken: data['token'].toString(),
        );
      }
      if (!mounted) return;
      unawaited(OfflineSessionService.prepare(data['token'].toString()));
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => DashboardPage(
                token: data['token'].toString(),
                logoutPageBuilder: (_) => ServiceDeviceLoginPage(
                  deviceCredential: widget.deviceCredential,
                  initialDevice: device,
                ),
              )));
    } catch (_) {
      final lease = qrCredential == null
          ? null
          : await OfflineStore.instance.authenticateQr(qrCredential);
      if (!mounted) return;
      if (lease == null || lease['sessionType'] != 'service_device_personal') {
        return message(
            'Keine Verbindung und keine gültige persönliche Offlinefreigabe.');
      }
      Navigator.of(context).pushReplacement(MaterialPageRoute(
          builder: (_) => DashboardPage(
                token: lease['sessionToken'].toString(),
                logoutPageBuilder: (_) => ServiceDeviceLoginPage(
                  deviceCredential: widget.deviceCredential,
                  initialDevice: device,
                ),
              )));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget factorField(String mode) {
    if (mode == 'totp') {
      return TextField(
          controller: totp,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'TOTP-Code', border: OutlineInputBorder()));
    }
    if (mode == 'nfc') {
      return TextField(
          controller: nfc,
          autofocus: true,
          onSubmitted: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: 'NFC-/Dienstausweis am USB-Leser',
              prefixIcon: Icon(Icons.badge),
              border: OutlineInputBorder()));
    }
    return const SizedBox.shrink();
  }

  Future<void> removeActivation() async {
    final admin = await showDialog<List<String>>(
        context: context, builder: (_) => const _AdminCredentialDialog());
    if (admin == null) return;
    final response = await http.post(
        Uri.parse('$apiBaseUrl/api/service-devices/deactivate-client'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceCredential': widget.deviceCredential,
          'identifier': admin[0],
          'password': admin[1]
        }));
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(_object(response)['error']?.toString() ??
          'Admin-Prüfung fehlgeschlagen.');
    }
    await ServiceDeviceStorage.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final systemMfa = device?['systemMfa']?.toString() ?? 'off';
    final personalMfa = device?['personalMfa']?.toString() ?? 'off';
    return DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text(device?['name']?.toString() ?? 'Dienstgerät'),
            bottom: const TabBar(tabs: [
              Tab(icon: Icon(Icons.devices), text: 'Systemzugang'),
              Tab(icon: Icon(Icons.person), text: 'Persönliches Konto')
            ]),
            actions: [
              IconButton(
                  onPressed: removeActivation,
                  tooltip: 'Geräteaktivierung entfernen',
                  icon: const Icon(Icons.phonelink_erase))
            ],
          ),
          body: device == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(children: [
                  _LoginCard(children: [
                    const Text(
                        'Eingeschränkter Zugang für Suche und Mängelmeldung.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: systemPassword,
                        obscureText: true,
                        onSubmitted: (_) => systemLogin(),
                        decoration: const InputDecoration(
                            labelText: 'Gerätepasswort',
                            border: OutlineInputBorder())),
                    if (systemMfa != 'off') ...[
                      const SizedBox(height: 12),
                      factorField(systemMfa)
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: loading ? null : () => systemLogin(),
                        icon: const Icon(Icons.login),
                        label: const Text('Systemzugang öffnen')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: loading
                            ? null
                            : () async {
                                final value = await scanQrLoginCode(context,
                                    allowedPrefixes: const ['mkdevice:v1:']);
                                if (value != null) {
                                  await systemLogin(qrCredential: value);
                                }
                              },
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('System-QR-Code scannen')),
                  ]),
                  _LoginCard(children: [
                    const Text(
                        'Der Zugriff richtet sich vollständig nach den Rechten des persönlichen Kontos.'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: identifier,
                        decoration: const InputDecoration(
                            labelText: 'Benutzername oder E-Mail',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(
                        controller: personalPassword,
                        obscureText: true,
                        onSubmitted: (_) => personalLogin(),
                        decoration: const InputDecoration(
                            labelText: 'Passwort',
                            border: OutlineInputBorder())),
                    if (personalMfa != 'off') ...[
                      const SizedBox(height: 12),
                      factorField(personalMfa)
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: loading ? null : () => personalLogin(),
                        icon: const Icon(Icons.login),
                        label: const Text('Persönlich anmelden')),
                    const SizedBox(height: 8),
                    Wrap(
                        spacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          OutlinedButton.icon(
                              onPressed: () async {
                                final value = await scanQrLoginCode(
                                  context,
                                  allowedPrefixes: const [
                                    'mkqr:v1:',
                                    'mkoffline:v1:',
                                  ],
                                );
                                if (value != null) {
                                  await personalLogin(qrCredential: value);
                                }
                              },
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('QR-Code')),
                          OutlinedButton.icon(
                              onPressed: () async {
                                final value = await showDialog<String>(
                                    context: context,
                                    builder: (_) => const _NfcReadDialog());
                                if (value != null) {
                                  await personalLogin(nfcCredential: value);
                                }
                              },
                              icon: const Icon(Icons.badge),
                              label: const Text('NFC/Dienstausweis')),
                        ]),
                  ]),
                ]),
        ));
  }
}

class _LoginCard extends StatelessWidget {
  final List<Widget> children;
  const _LoginCard({required this.children});
  @override
  Widget build(BuildContext context) => Center(
      child: SingleChildScrollView(
          child: Card(
              margin: const EdgeInsets.all(24),
              child: SizedBox(
                  width: 460,
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: children))))));
}

class _AdminCredentialDialog extends StatefulWidget {
  const _AdminCredentialDialog();
  @override
  State<_AdminCredentialDialog> createState() => _AdminCredentialDialogState();
}

class _AdminCredentialDialogState extends State<_AdminCredentialDialog> {
  final user = TextEditingController();
  final password = TextEditingController();
  @override
  void dispose() {
    user.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Admin-Bestätigung'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: user,
                decoration: const InputDecoration(labelText: 'Admin-Konto')),
            TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Passwort'))
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () =>
                    Navigator.pop(context, [user.text, password.text]),
                child: const Text('Aktivierung entfernen'))
          ]);
}

class _NfcReadDialog extends StatefulWidget {
  const _NfcReadDialog();
  @override
  State<_NfcReadDialog> createState() => _NfcReadDialogState();
}

class _NfcReadDialogState extends State<_NfcReadDialog> {
  final value = TextEditingController();
  @override
  void dispose() {
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('NFC-/Dienstausweis lesen'),
          content: TextField(
              controller: value,
              autofocus: true,
              obscureText: true,
              onSubmitted: (text) {
                if (text.trim().isNotEmpty) Navigator.pop(context, text.trim());
              },
              decoration: const InputDecoration(
                  labelText: 'USB-Kartenleser',
                  helperText:
                      'Karte auflegen; die Eingabe wird automatisch übernommen.')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context, value.text.trim()),
                child: const Text('Übernehmen'))
          ]);
}
