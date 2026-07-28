import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:file_saver/file_saver.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../widgets/qr_login_dialog.dart';
import '../services/file_save_mime_type.dart';
import 'legal_page.dart';

class ProfilePage extends StatefulWidget {
  final String token;
  final VoidCallback onAccountDeleted;
  const ProfilePage(
      {required this.token, required this.onAccountDeleted, super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final email = TextEditingController();
  final currentPassword = TextEditingController();
  final newPassword = TextEditingController();
  Map<String, dynamic>? user;
  List<Map<String, dynamic>> qrCredentials = [];
  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final response =
        await http.get(Uri.parse('$apiBaseUrl/api/auth/me'), headers: headers);
    if (response.statusCode == 200 && mounted) {
      user = jsonDecode(response.body)['user'];
      email.text = user!['email'];
      setState(() {});
      await loadQrCredentials();
    }
  }

  Future<void> loadQrCredentials() async {
    final response = await http.get(
      Uri.parse('$apiBaseUrl/api/auth/qr-credentials/me'),
      headers: headers,
    );
    if (response.statusCode == 200 && mounted) {
      qrCredentials = (jsonDecode(response.body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
      setState(() {});
    }
  }

  void message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> save() async {
    final body = <String, dynamic>{
      'email': email.text,
      'currentPassword': currentPassword.text
    };
    if (newPassword.text.isNotEmpty) body['password'] = newPassword.text;
    final response = await http.put(Uri.parse('$apiBaseUrl/api/users/me'),
        headers: headers, body: jsonEncode(body));
    final data = response.body.isEmpty ? {} : jsonDecode(response.body);
    if (response.statusCode == 200) {
      message(
          'Kontodaten gespeichert. Nach einer E-Mail-Änderung ist eine erneute Bestätigung erforderlich.');
      currentPassword.clear();
      newPassword.clear();
      await load();
    } else {
      message(data['error']?.toString() ?? 'Änderung fehlgeschlagen.');
    }
  }

  Future<void> deleteAccount() async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('Account endgültig löschen'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Diese Aktion kann nicht rückgängig gemacht werden.'),
                  TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: 'Passwort zur Bestätigung'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Abbrechen')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Endgültig löschen'))
                ]));
    if (confirmed != true) return;
    final response = await http.delete(Uri.parse('$apiBaseUrl/api/users/me'),
        headers: headers, body: jsonEncode({'password': password.text}));
    if (response.statusCode == 204) {
      widget.onAccountDeleted();
    } else {
      final data = jsonDecode(response.body);
      message(data['error']?.toString() ?? 'Löschung fehlgeschlagen.');
    }
  }

  Future<void> exportPersonalData() async {
    final response = await http.get(
      Uri.parse('$apiBaseUrl/api/users/me/export'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final data = response.body.isEmpty ? {} : jsonDecode(response.body);
      message(data['error']?.toString() ?? 'Datenkopie fehlgeschlagen.');
      return;
    }
    await FileSaver.instance.saveFile(
      name: 'materialkompass-datenkopie',
      bytes: response.bodyBytes,
      fileExtension: 'json',
      mimeType: MimeType.custom,
      customMimeType: fileMimeType('json'),
    );
    message('Ihre maschinenlesbare Datenkopie wurde gespeichert.');
  }

  Future<void> createQrLogin() async {
    final validity = await chooseQrLoginValidity(context);
    if (validity == null || !mounted) return;
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/auth/qr-credentials/me'),
      headers: headers,
      body: jsonEncode(validity.toJson()),
    );
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (!mounted) return;
    if (response.statusCode != 201) {
      message(
          data['error']?.toString() ?? 'QR-Code konnte nicht erstellt werden.');
      return;
    }
    await showQrLoginCode(
      context,
      qrValue: data['qrValue'].toString(),
      expiresAt: data['expiresAt'] == null
          ? null
          : DateTime.parse(data['expiresAt'].toString()),
      oneTime: data['oneTime'] != false,
    );
    await loadQrCredentials();
  }

  Future<void> deactivateQrLogin(Map<String, dynamic> credential) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anmeldecode deaktivieren?'),
        content: Text(
          '„${credential['title']}“ kann danach nicht mehr zur Anmeldung verwendet werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deaktivieren'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final response = await http.delete(
      Uri.parse('$apiBaseUrl/api/auth/qr-credentials/me/${credential['id']}'),
      headers: headers,
    );
    if (response.statusCode == 204) {
      message('Anmeldecode wurde deaktiviert.');
      await loadQrCredentials();
    } else {
      final data = response.body.isEmpty ? {} : jsonDecode(response.body);
      message(data['error']?.toString() ?? 'Deaktivierung fehlgeschlagen.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Mein Account')),
      body: user == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(24), children: [
              Text(user!['name'].toString(),
                  style: Theme.of(context).textTheme.headlineSmall),
              Text(
                  '@${user!['username']} · ${(user!['roles'] as List).join(', ')}'),
              const SizedBox(height: 24),
              TextField(
                  controller: email,
                  decoration: const InputDecoration(
                      labelText: 'E-Mail-Adresse',
                      border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: currentPassword,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Aktuelles Passwort *',
                      border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: newPassword,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Neues Passwort (optional)',
                      helperText:
                          'Mind. 12 Zeichen, Groß-/Kleinbuchstabe, Zahl und Sonderzeichen',
                      border: OutlineInputBorder())),
              const SizedBox(height: 16),
              Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                      onPressed: save,
                      icon: const Icon(Icons.save),
                      label: const Text('Änderungen speichern'))),
              const Divider(height: 48),
              Text('QR-Anmeldung',
                  style: Theme.of(context).textTheme.titleLarge),
              const Text(
                  'Erstellt benannte Einmalcodes für die Anmeldung auf weiteren Geräten. Mehrere Codes können gleichzeitig aktiv sein.'),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: createQrLogin,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Anmelde-QR-Code erstellen'),
                ),
              ),
              const SizedBox(height: 12),
              if (qrCredentials.isEmpty)
                const Text('Keine aktiven Anmeldecodes.')
              else
                ...qrCredentials.map(
                  (credential) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.qr_code_2),
                      title: Text(credential['title'].toString()),
                      subtitle: Text(
                        '${qrCredentialExpiryLabel(credential['expiresAt'])} · '
                        '${credential['oneTime'] == false ? 'Mehrfach verwendbar' : 'Einmal verwendbar'}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Anmeldecode deaktivieren',
                        onPressed: () => deactivateQrLogin(credential),
                        icon: const Icon(Icons.block),
                      ),
                    ),
                  ),
                ),
              const Divider(height: 48),
              Text('Datenschutzrechte',
                  style: Theme.of(context).textTheme.titleLarge),
              const Text(
                  'Laden Sie eine Kopie der Daten herunter, die Ihrem Konto unmittelbar zugeordnet werden konnten. Weitere Rechte können Sie gegenüber dem Verantwortlichen geltend machen.'),
              const SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: exportPersonalData,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Meine Daten herunterladen')),
                TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const LegalPage(initialTab: 1))),
                    icon: const Icon(Icons.privacy_tip_outlined),
                    label: const Text('Datenschutzinformationen')),
              ]),
              const Divider(height: 48),
              Text('Account löschen',
                  style: Theme.of(context).textTheme.titleLarge),
              const Text(
                  'Ihre Zugangsdaten werden sofort gelöscht. Gesetzlich erforderliche Auditdaten bleiben zweckgebunden erhalten.'),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                      onPressed: deleteAccount,
                      icon: const Icon(Icons.delete_forever),
                      label: const Text('Account endgültig löschen'))),
            ]));
}
