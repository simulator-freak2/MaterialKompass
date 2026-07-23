import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/browser_download.dart';
import '../widgets/qr_login_dialog.dart';
import 'dashboard_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool loading = false;
  bool downloadsLoading = true;
  String? activeDownload;
  List<Map<String, dynamic>> downloads = const [
    {'platform': 'windows', 'label': 'Windows', 'available': false},
    {'platform': 'linux', 'label': 'Linux', 'available': false},
    {'platform': 'android', 'label': 'Android', 'available': false},
  ];

  @override
  void initState() {
    super.initState();
    loadDownloads();
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> loadDownloads() async {
    try {
      final response = await http.get(Uri.parse('$apiBaseUrl/api/downloads'));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as List;
      if (!mounted) return;
      setState(() {
        downloads = data
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList();
      });
    } catch (_) {
      // Die Anmeldung bleibt auch bei einem nicht erreichbaren Downloadserver nutzbar.
    } finally {
      if (mounted) setState(() => downloadsLoading = false);
    }
  }

  Future<void> downloadDesktopApp(Map<String, dynamic> download) async {
    final platform = download['platform']?.toString() ?? '';
    if (platform.isEmpty || download['available'] != true) return;
    final downloadUri = Uri.parse('$apiBaseUrl/api/downloads/$platform');

    if (kIsWeb) {
      try {
        final launched = await startBrowserDownload(downloadUri);
        if (!launched) {
          throw Exception('Der Download konnte nicht gestartet werden.');
        }
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
      return;
    }

    setState(() => activeDownload = platform);
    try {
      final response = await http.get(downloadUri);
      if (response.statusCode != 200) {
        throw Exception('Der Download ist derzeit nicht verfügbar.');
      }
      final fileName = download['fileName']?.toString() ??
          switch (platform) {
            'windows' => 'MaterialKompass-Windows.exe',
            'android' => 'MaterialKompass-Android.apk',
            _ => 'MaterialKompass-Linux.deb',
          };
      final extension = fileName.toLowerCase().endsWith('.tar.gz')
          ? 'tar.gz'
          : fileName.split('.').last;
      final baseName =
          fileName.substring(0, fileName.length - extension.length - 1);
      await FileSaver.instance.saveFile(
        name: baseName,
        bytes: response.bodyBytes,
        fileExtension: extension,
        mimeType: MimeType.custom,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$fileName wurde heruntergeladen.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => activeDownload = null);
    }
  }

  Future<void> requestPasswordReset() async {
    final controller = TextEditingController(text: emailController.text);
    final identifier = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Passwort zurücksetzen'),
              content: TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                      labelText: 'Nutzername oder E-Mail')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, controller.text),
                    child: const Text('Reset-Link anfordern'))
              ],
            ));
    if (identifier == null || identifier.trim().isEmpty) return;
    await http.post(Uri.parse('$apiBaseUrl/api/auth/password-reset'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier}));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Wenn das Konto existiert, wurde eine E-Mail versendet.')));
    }
  }

  Future<void> login() async {
    setState(() => loading = true);
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(
        {
          'identifier': emailController.text,
          'password': passwordController.text
        },
      ),
    );

    setState(() => loading = false);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (!mounted) return;
      TextInput.finishAutofillContext(shouldSave: true);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => DashboardPage(token: data['token'])),
      );
    } else {
      if (!mounted) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data['error']?.toString() ?? 'Login fehlgeschlagen'),
      ));
    }
  }

  Future<void> loginWithQrCode() async {
    final credential = await scanQrLoginCode(context);
    if (credential == null || !mounted) return;
    setState(() => loading = true);
    try {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/auth/qr-login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'credential': credential}),
      );
      final data = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (!mounted) return;
      if (response.statusCode == 200) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => DashboardPage(token: data['token'].toString())),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              data['error']?.toString() ?? 'QR-Anmeldung fehlgeschlagen.'),
        ));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MaterialKompass Login')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Container(
                    width: 380,
                    padding: const EdgeInsets.all(24),
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Interne Materialverwaltung',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: emailController,
                            autofillHints: const [AutofillHints.username],
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                                labelText: 'Nutzername oder E-Mail'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: passwordController,
                            obscureText: true,
                            autofillHints: const [AutofillHints.password],
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) {
                              if (!loading) login();
                            },
                            decoration:
                                const InputDecoration(labelText: 'Passwort'),
                          ),
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: loading ? null : login,
                            child: loading
                                ? const CircularProgressIndicator()
                                : const Text('Anmelden'),
                          ),
                          TextButton(
                              onPressed: loading ? null : requestPasswordReset,
                              child: const Text('Passwort vergessen?')),
                          OutlinedButton.icon(
                            onPressed: loading ? null : loginWithQrCode,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('Mit QR-Code anmelden'),
                          ),
                          const Divider(height: 32),
                          const Text(
                            'App herunterladen',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            downloadsLoading
                                ? 'Verfügbarkeit wird geprüft …'
                                : 'Für Windows, Linux und Android',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 12,
                            runSpacing: 8,
                            children: downloads.map((download) {
                              final platform =
                                  download['platform']?.toString() ?? '';
                              final available = download['available'] == true;
                              final downloading = activeDownload == platform;
                              return OutlinedButton.icon(
                                onPressed: available && activeDownload == null
                                    ? () => downloadDesktopApp(download)
                                    : null,
                                icon: downloading
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2),
                                      )
                                    : Icon(platform == 'windows'
                                        ? Icons.desktop_windows_outlined
                                        : Icons.computer_outlined),
                                label: Text(available
                                    ? '${download['label']} herunterladen'
                                    : '${download['label']} nicht verfügbar'),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
