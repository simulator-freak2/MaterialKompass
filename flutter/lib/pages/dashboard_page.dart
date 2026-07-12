import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/stat_card.dart';
import 'login_page.dart';
import 'wardrobe_page.dart';

class DashboardPage extends StatelessWidget {
  final String token;

  const DashboardPage({required this.token, super.key});

  Future<Map<String, dynamic>> loadDashboard() async {
    final response = await http.get(
      Uri.parse('$apiBaseUrl/api/dashboard'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load dashboard');
    }
    return jsonDecode(response.body);
  }

  void _logout(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Abmelden',
            onPressed: () => _logout(context),
          ),
        ],
      ),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Willkommen bei MaterialKompass',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    StatCard(
                      title: 'Material',
                      value: summary['materialCount']?.toString() ?? '0',
                    ),
                    StatCard(
                      title: 'Kleidung',
                      value: summary['clothingCount']?.toString() ?? '0',
                    ),
                    StatCard(
                      title: 'Mängel',
                      value: summary['defectCount']?.toString() ?? '0',
                    ),
                    StatCard(
                      title: 'Beschaffungen',
                      value: summary['procurementCount']?.toString() ?? '0',
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Letzte Aktivitäten',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => WardrobePage(
                            token: token,
                            onLogout: () => _logout(context),
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.checkroom),
                      label: const Text('Kleiderkammer'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: data['recentActivity']?.length ?? 0,
                    itemBuilder: (_, index) {
                      final entry = data['recentActivity'][index];
                      return Card(
                        child: ListTile(
                          title: Text(entry['action']),
                          subtitle: Text(entry['details']?.toString() ?? ''),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
