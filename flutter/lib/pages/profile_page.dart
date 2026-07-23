import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';
import '../widgets/qr_login_dialog.dart';

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
    if (response.statusCode == 204)
      widget.onAccountDeleted();
    else {
      final data = jsonDecode(response.body);
      message(data['error']?.toString() ?? 'Löschung fehlgeschlagen.');
    }
  }

  Future<void> createQrLogin() async {
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/auth/qr-credentials/me'),
      headers: headers,
      body: '{}',
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
      expiresAt: DateTime.parse(data['expiresAt'].toString()),
    );
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
                  'Erstellt einen anonymen Einmalcode für die Anmeldung auf einem weiteren Gerät. Ein neuer Code widerruft den vorherigen.'),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: createQrLogin,
                  icon: const Icon(Icons.qr_code_2),
                  label: const Text('Anmelde-QR-Code erstellen'),
                ),
              ),
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
