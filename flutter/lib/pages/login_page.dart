import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
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
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Wenn das Konto existiert, wurde eine E-Mail versendet.')));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MaterialKompass Login')),
      body: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Container(
            width: 380,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Interne Materialverwaltung',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: emailController,
                  decoration: const InputDecoration(
                      labelText: 'Nutzername oder E-Mail'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Passwort'),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
