import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const MaterialKompassApp());
}

class MaterialKompassApp extends StatelessWidget {
  const MaterialKompassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MaterialKompass',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController(text: 'admin@materialkompass.local');
  final passwordController = TextEditingController(text: 'Admin123!');
  bool loading = false;

  Future<void> login() async {
    setState(() => loading = true);
    final response = await http.post(
      Uri.parse('http://localhost:3000/api/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': emailController.text, 'password': passwordController.text}),
    );

    setState(() => loading = false);
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => DashboardPage(token: data['token'])));
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Login fehlgeschlagen')));
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
                const Text('Interne Materialverwaltung', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                TextField(controller: emailController, decoration: const InputDecoration(labelText: 'E-Mail')),
                const SizedBox(height: 12),
                TextField(controller: passwordController, obscureText: true, decoration: const InputDecoration(labelText: 'Passwort')),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: loading ? null : login, child: loading ? const CircularProgressIndicator() : const Text('Anmelden')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardPage extends StatelessWidget {
  final String token;
  const DashboardPage({required this.token, super.key});

  Future<Map<String, dynamic>> loadDashboard() async {
    final response = await http.get(Uri.parse('http://localhost:3000/api/dashboard'), headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode != 200) throw Exception('Failed to load dashboard');
    return jsonDecode(response.body);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: loadDashboard(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(snapshot.error.toString()));
          }
          final data = snapshot.data ?? {};
          final summary = data['summary'] ?? {};
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Willkommen bei MaterialKompass', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              Wrap(spacing: 16, runSpacing: 16, children: [
                _StatCard(title: 'Material', value: summary['materialCount']?.toString() ?? '0'),
                _StatCard(title: 'Kleidung', value: summary['clothingCount']?.toString() ?? '0'),
                _StatCard(title: 'Mängel', value: summary['defectCount']?.toString() ?? '0'),
                _StatCard(title: 'Beschaffungen', value: summary['procurementCount']?.toString() ?? '0'),
              ]),
              const SizedBox(height: 24),
              const Text('Letzte Aktivitäten', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(child: ListView.builder(itemCount: data['recentActivity']?.length ?? 0, itemBuilder: (_, index) {
                final entry = data['recentActivity'][index];
                return Card(child: ListTile(title: Text(entry['action']), subtitle: Text(entry['details']?.toString() ?? '')));
              })),
            ]),
          );
        },
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  const _StatCard({required this.title, required this.value, super.key});

  @override
  Widget build(BuildContext context) {
    return Card(child: SizedBox(width: 160, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 16)), const SizedBox(height: 8), Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold))]))));
  }
}
