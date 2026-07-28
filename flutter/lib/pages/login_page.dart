import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../services/api_client.dart';
import '../services/browser_download.dart';
import '../widgets/qr_login_dialog.dart';
import 'dashboard_page.dart';
import 'legal_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final api = ApiClient();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool loading = false;
  bool downloadsLoading = true;
  List<Map<String, dynamic>> downloads = const [
    {'platform': 'windows', 'label': 'Windows', 'available': false},
    {'platform': 'macos', 'label': 'macOS', 'available': false},
    {'platform': 'linux', 'label': 'Linux', 'available': false},
    {'platform': 'android', 'label': 'Android', 'available': false},
    {'platform': 'ios', 'label': 'iOS', 'available': false},
  ];

  @override
  void initState() {
    super.initState();
    if (kIsWeb) loadDownloads();
  }

  @override
  void dispose() {
    api.close();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> loadDownloads() async {
    try {
      final response = await api.get('/api/downloads');
      if (response.statusCode != 200) return;
      final data = response.data as List;
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

  Future<void> downloadApp(Map<String, dynamic> download) async {
    final platform = download['platform']?.toString() ?? '';
    if (platform.isEmpty || download['available'] != true) return;
    final downloadUri = Uri.parse('$apiBaseUrl/api/downloads/$platform');

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
  }

  Future<void> requestPasswordReset() async {
    final controller = TextEditingController(text: emailController.text);
    String? identifier;
    try {
      identifier = await showDialog<String>(
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
    } finally {
      controller.dispose();
    }
    if (identifier == null || identifier.trim().isEmpty) return;
    try {
      await api.post(
        '/api/auth/password-reset',
        body: {'identifier': identifier},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Wenn das Konto existiert, wurde eine E-Mail versendet.')));
      }
    } on ApiException catch (error) {
      _showError(error.message);
    }
  }

  Future<void> login() async {
    setState(() => loading = true);
    try {
      final response = await api.post(
        '/api/auth/login',
        body: {
          'identifier': emailController.text,
          'password': passwordController.text
        },
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        TextInput.finishAutofillContext(shouldSave: true);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => DashboardPage(token: response.object['token']),
          ),
        );
      } else {
        _showError(
          response.object['error']?.toString() ?? 'Login fehlgeschlagen',
        );
      }
    } on ApiException catch (error) {
      if (mounted) _showError(error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loginWithQrCode() async {
    final credential = await scanQrLoginCode(context);
    if (credential == null || !mounted) return;
    setState(() => loading = true);
    try {
      final response = await api.post(
        '/api/auth/qr-login',
        body: {'credential': credential},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) =>
                  DashboardPage(token: response.object['token'].toString())),
        );
      } else {
        _showError(response.object['error']?.toString() ??
            'QR-Anmeldung fehlgeschlagen.');
      }
    } on ApiException catch (error) {
      if (mounted) _showError(error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
                                ? CircularProgressIndicator(
                                    color:
                                        Theme.of(context).colorScheme.onPrimary,
                                  )
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
                          if (kIsWeb) ...[
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
                                  : 'Für Windows, macOS, Linux, Android und iOS',
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
                                return OutlinedButton.icon(
                                  onPressed: available
                                      ? () => downloadApp(download)
                                      : null,
                                  icon: Icon(_downloadIcon(platform)),
                                  label: Text(available
                                      ? '${download['label']} herunterladen'
                                      : '${download['label']} nicht verfügbar'),
                                );
                              }).toList(),
                            ),
                          ],
                          const Divider(height: 32),
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => const LegalPage(),
                                  ),
                                ),
                                child: const Text('Anbieterangaben'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const LegalPage(initialTab: 1),
                                  ),
                                ),
                                child: const Text('Datenschutz'),
                              ),
                            ],
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

IconData _downloadIcon(String platform) => switch (platform) {
      'windows' => Icons.desktop_windows_outlined,
      'android' => Icons.android_outlined,
      'ios' || 'macos' => Icons.apple,
      _ => Icons.computer_outlined,
    };
