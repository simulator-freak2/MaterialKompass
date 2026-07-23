import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/stat_card.dart';
import 'categories_page.dart';
import 'defects_page.dart';
import 'login_page.dart';
import 'inventory_page.dart';
import 'locations_page.dart';
import 'procurement_page.dart';
import 'profile_page.dart';
import 'users_page.dart';
import 'wardrobe_page.dart';

typedef DashboardLoader = Future<Map<String, dynamic>> Function();

class DashboardPage extends StatefulWidget {
  final String token;
  final DashboardLoader? dashboardLoader;

  const DashboardPage({
    required this.token,
    this.dashboardLoader,
    super.key,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<Map<String, dynamic>> _dashboardFuture;

  @override
  void initState() {
    super.initState();
    _dashboardFuture = _loadDashboard();
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token ||
        oldWidget.dashboardLoader != widget.dashboardLoader) {
      _dashboardFuture = _loadDashboard();
    }
  }

  Future<Map<String, dynamic>> _loadDashboard() {
    return widget.dashboardLoader?.call() ?? loadDashboard();
  }

  Future<Map<String, dynamic>> loadDashboard() async {
    final responses = await Future.wait([
      http.get(Uri.parse('$apiBaseUrl/api/dashboard'),
          headers: {'Authorization': 'Bearer ${widget.token}'}),
      http.get(Uri.parse('$apiBaseUrl/api/auth/me'),
          headers: {'Authorization': 'Bearer ${widget.token}'}),
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

  Future<void> _refresh() async {
    final future = _loadDashboard();
    setState(() => _dashboardFuture = future);
    await future;
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
                  token: widget.token,
                  onAccountDeleted: () => _logout(context)),
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
        future: _dashboardFuture,
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
          final canReadDefects =
              (currentUser['permissions'] as List? ?? const [])
                  .contains('defects.read');
          final dashboardButtonStyle = ElevatedButton.styleFrom(
            minimumSize: const Size(0, 56),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          );

          return LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 700;
              final pagePadding = isMobile ? 16.0 : 24.0;
              final activities = data['recentActivity'] as List? ?? const [];
              final actions =
                  <({IconData icon, String label, VoidCallback onTap})>[
                if (isAdmin)
                  (
                    icon: Icons.manage_accounts_outlined,
                    label: 'Nutzerverwaltung',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => UsersPage(token: widget.token),
                        )),
                  ),
                (
                  icon: Icons.shopping_cart_outlined,
                  label: 'Beschaffung',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ProcurementPage(
                          token: widget.token,
                          onLogout: () => _logout(context),
                        ),
                      )),
                ),
                (
                  icon: Icons.inventory_2_outlined,
                  label: 'Inventar',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => InventoryPage(
                          token: widget.token,
                          onLogout: () => _logout(context),
                        ),
                      )),
                ),
                if (canReadDefects)
                  (
                    icon: Icons.report_problem_outlined,
                    label: 'Mängel',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => DefectsPage(token: widget.token),
                        )),
                  ),
                (
                  icon: Icons.category_outlined,
                  label: 'Kategorien',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CategoriesPage(token: widget.token),
                      )),
                ),
                if (canReadLocations)
                  (
                    icon: Icons.warehouse_outlined,
                    label: 'Lagerorte',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => LocationsPage(token: widget.token),
                        )),
                  ),
                (
                  icon: Icons.checkroom,
                  label: 'Kleiderkammer',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => WardrobePage(
                          token: widget.token,
                          onLogout: () => _logout(context),
                        ),
                      )),
                ),
              ];
              final statCards = [
                ('Material', summary['materialCount']),
                ('Material ausgegeben', summary['issuedMaterialCount']),
                ('Material defekt', summary['defectiveMaterialCount']),
                ('Prüfungen fällig', summary['dueInspectionCount']),
                ('Kleidung', summary['clothingCount']),
                ('Mängel offen', summary['openDefectCount']),
                ('Mängel in Bearbeitung', summary['defectsInProgressCount']),
                ('Beschaffungen', summary['procurementCount']),
                ('Freigaben offen', summary['pendingProcurementApprovals']),
                (
                  'Bestellungen überfällig',
                  summary['overdueProcurementOrders']
                ),
                ('Wareneingänge offen', summary['openProcurementReceipts']),
              ];

              Widget actionButton(
                ({IconData icon, String label, VoidCallback onTap}) action,
              ) {
                if (!isMobile) {
                  return ElevatedButton.icon(
                    style: dashboardButtonStyle,
                    onPressed: action.onTap,
                    icon: Icon(action.icon),
                    label: Text(action.label),
                  );
                }
                return ElevatedButton(
                  style: dashboardButtonStyle.copyWith(
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    ),
                  ),
                  onPressed: action.onTap,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(action.icon),
                      const SizedBox(height: 6),
                      Text(
                        action.label,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        pagePadding,
                        pagePadding,
                        pagePadding,
                        12,
                      ),
                      sliver: SliverList.list(
                        children: [
                          Text(
                            'Willkommen bei MaterialKompass',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 16),
                          if (isMobile)
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                childAspectRatio: 1.18,
                              ),
                              itemCount: statCards.length,
                              itemBuilder: (_, index) => StatCard(
                                title: statCards[index].$1,
                                value: statCards[index].$2?.toString() ?? '0',
                                width: double.infinity,
                                compact: true,
                              ),
                            )
                          else
                            Wrap(
                              spacing: 16,
                              runSpacing: 16,
                              children: [
                                for (final stat in statCards)
                                  StatCard(
                                    title: stat.$1,
                                    value: stat.$2?.toString() ?? '0',
                                  ),
                              ],
                            ),
                          SizedBox(height: isMobile ? 24 : 28),
                          if (isMobile) ...[
                            const Text(
                              'Bereiche',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 10),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                                mainAxisExtent: 88,
                              ),
                              itemCount: actions.length,
                              itemBuilder: (_, index) =>
                                  actionButton(actions[index]),
                            ),
                            const SizedBox(height: 28),
                            const Text(
                              'Letzte Aktivitäten',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ] else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 16),
                                  child: Text(
                                    'Letzte Aktivitäten',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      alignment: WrapAlignment.end,
                                      children:
                                          actions.map(actionButton).toList(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    if (activities.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'Noch keine Aktivitäten in deinen freigeschalteten Bereichen.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          pagePadding,
                          0,
                          pagePadding,
                          pagePadding + MediaQuery.paddingOf(context).bottom,
                        ),
                        sliver: SliverList.builder(
                          itemCount: activities.length,
                          itemBuilder: (_, index) {
                            final entry = Map<String, dynamic>.from(
                              activities[index] as Map,
                            );
                            return Card(
                              child: ListTile(
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 12 : 16,
                                  vertical: isMobile ? 4 : 8,
                                ),
                                leading: CircleAvatar(
                                  radius: isMobile ? 18 : 20,
                                  child: const Icon(Icons.history),
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
          );
        },
      ),
    );
  }
}
