import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/stat_card.dart';
import 'categories_page.dart';
import 'login_page.dart';
import 'inventory_page.dart';
import 'locations_page.dart';
import 'procurement_page.dart';
import 'profile_page.dart';
import 'users_page.dart';
import 'wardrobe_page.dart';

class DashboardPage extends StatelessWidget {
  final String token;

  const DashboardPage({required this.token, super.key});

  Future<Map<String, dynamic>> loadDashboard() async {
    final responses = await Future.wait([
      http.get(Uri.parse('$apiBaseUrl/api/dashboard'),
          headers: {'Authorization': 'Bearer $token'}),
      http.get(Uri.parse('$apiBaseUrl/api/auth/me'),
          headers: {'Authorization': 'Bearer $token'}),
    ]);
    if (responses.any((response) => response.statusCode != 200)) {
      throw Exception('Failed to load dashboard');
    }
    final dashboard = jsonDecode(responses[0].body) as Map<String, dynamic>;
    dashboard['currentUser'] = jsonDecode(responses[1].body)['user'];
    return dashboard;
  }

  void _logout(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  String _formatActivityTime(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return 'Zeitpunkt unbekannt';
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(parsed.day)}.${twoDigits(parsed.month)}.${parsed.year}, '
        '${twoDigits(parsed.hour)}:${twoDigits(parsed.minute)} Uhr';
  }

  String _activityTitle(Map<String, dynamic> entry) {
    final entity = entry['entityLabel']?.toString() ?? 'Eintrag';
    final itemName = entry['itemName']?.toString();
    final action = entry['actionLabel']?.toString() ??
        entry['action']?.toString() ??
        'bearbeitet';
    return itemName == null || itemName.isEmpty
        ? '$entity: $action'
        : '$entity „$itemName“: $action';
  }

  String _activityDetails(Map<String, dynamic> entry) {
    final lines = <String>[
      '${entry['actor'] ?? 'unbekannt'} · '
          '${_formatActivityTime(entry['timestamp'])} · ${entry['area'] ?? ''}',
    ];
    final facts = <String>[];
    final category = entry['category']?.toString();
    final inventoryNumber = entry['inventoryNumber']?.toString();
    if (category != null && category.isNotEmpty) {
      facts.add('Kategorie: $category');
    }
    if (inventoryNumber != null && inventoryNumber.isNotEmpty) {
      facts.add('Inventarnummer: $inventoryNumber');
    }
    if (facts.isNotEmpty) lines.add(facts.join(' · '));
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Mein Account',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ProfilePage(
                  token: token, onAccountDeleted: () => _logout(context)),
            )),
          ),
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
          final currentUser = data['currentUser'] as Map? ?? {};
          final isAdmin =
              (currentUser['roles'] as List? ?? const []).contains('Admin');
          final canReadLocations =
              (currentUser['permissions'] as List? ?? const [])
                  .contains('locations.read');
          final dashboardButtonStyle = ElevatedButton.styleFrom(
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          );

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
                      title: 'Material ausgegeben',
                      value: summary['issuedMaterialCount']?.toString() ?? '0',
                    ),
                    StatCard(
                      title: 'Material defekt',
                      value:
                          summary['defectiveMaterialCount']?.toString() ?? '0',
                    ),
                    StatCard(
                      title: 'Prüfungen fällig',
                      value: summary['dueInspectionCount']?.toString() ?? '0',
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
                    StatCard(
                      title: 'Freigaben offen',
                      value:
                          summary['pendingProcurementApprovals']?.toString() ??
                              '0',
                    ),
                    StatCard(
                      title: 'Bestellungen überfällig',
                      value: summary['overdueProcurementOrders']?.toString() ??
                          '0',
                    ),
                    StatCard(
                      title: 'Wareneingänge offen',
                      value:
                          summary['openProcurementReceipts']?.toString() ?? '0',
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
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (isAdmin)
                          ElevatedButton.icon(
                            style: dashboardButtonStyle,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => UsersPage(token: token)),
                            ),
                            icon: const Icon(Icons.manage_accounts_outlined),
                            label: const Text('Nutzerverwaltung'),
                          ),
                        ElevatedButton.icon(
                          style: dashboardButtonStyle,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ProcurementPage(
                                token: token,
                                onLogout: () => _logout(context),
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.shopping_cart_outlined),
                          label: const Text('Beschaffung'),
                        ),
                        ElevatedButton.icon(
                          style: dashboardButtonStyle,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => InventoryPage(
                                token: token,
                                onLogout: () => _logout(context),
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: const Text('Inventar'),
                        ),
                        ElevatedButton.icon(
                          style: dashboardButtonStyle,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CategoriesPage(token: token),
                            ),
                          ),
                          icon: const Icon(Icons.category_outlined),
                          label: const Text('Kategorien'),
                        ),
                        if (canReadLocations)
                          ElevatedButton.icon(
                            style: dashboardButtonStyle,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => LocationsPage(token: token),
                              ),
                            ),
                            icon: const Icon(Icons.warehouse_outlined),
                            label: const Text('Lagerorte'),
                          ),
                        ElevatedButton.icon(
                          style: dashboardButtonStyle,
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
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: (data['recentActivity'] as List? ?? const []).isEmpty
                      ? const Center(
                          child: Text(
                            'Noch keine Aktivitäten in deinen freigeschalteten Bereichen.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: data['recentActivity']?.length ?? 0,
                          itemBuilder: (_, index) {
                            final entry = Map<String, dynamic>.from(
                              data['recentActivity'][index] as Map,
                            );
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  child: Icon(Icons.history),
                                ),
                                title: Text(_activityTitle(entry)),
                                subtitle: Text(_activityDetails(entry)),
                                isThreeLine: entry['category'] != null ||
                                    entry['inventoryNumber'] != null,
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
