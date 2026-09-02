import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../services/app_http_client.dart';
import '../services/offline_http.dart' as offline_transport;
import '../services/offline_session_service.dart';
import '../services/offline_store.dart';
import '../widgets/stat_card.dart';
import 'categories_page.dart' deferred as categories_page;
import 'defects_page.dart' deferred as defects_page;
import 'login_page.dart';
import 'inventory_page.dart' deferred as inventory_page;
import 'knowledge_base_page.dart' deferred as knowledge_base_page;
import 'locations_page.dart' deferred as locations_page;
import 'procurement_page.dart' deferred as procurement_page;
import 'profile_page.dart' deferred as profile_page;
import 'stocktakes_page.dart' deferred as stocktakes_page;
import 'users_page.dart' deferred as users_page;
import 'wardrobe_page.dart' deferred as wardrobe_page;

typedef DashboardLoader = Future<Map<String, dynamic>> Function();
typedef AppExit = Future<void> Function();

class DashboardPage extends StatefulWidget {
  final String token;
  final DashboardLoader? dashboardLoader;
  final AppExit? appExit;
  final WidgetBuilder? logoutPageBuilder;

  const DashboardPage({
    required this.token,
    this.dashboardLoader,
    this.appExit,
    this.logoutPageBuilder,
    super.key,
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with WidgetsBindingObserver {
  late Future<Map<String, dynamic>> _dashboardFuture;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(OfflineStore.instance.restoreStatus());
    _dashboardFuture = _loadDashboard();
    _syncTimer = Timer.periodic(const Duration(minutes: 1), (_) => _sync());
  }

  Future<void> _sync() => offline_transport.flush(
    headers: {'Authorization': 'Bearer ${widget.token}'},
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_sync());
      unawaited(OfflineSessionService.prepare(widget.token));
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token ||
        oldWidget.dashboardLoader != widget.dashboardLoader) {
      _dashboardFuture = _loadDashboard();
      unawaited(OfflineSessionService.prepare(widget.token));
    }
  }

  Future<Map<String, dynamic>> _loadDashboard() {
    return widget.dashboardLoader?.call() ?? loadDashboard();
  }

  Future<Map<String, dynamic>> loadDashboard() async {
    final responses = await Future.wait([
      AppHttpClient.get(
        Uri.parse('$apiBaseUrl/api/dashboard'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ),
      AppHttpClient.get(
        Uri.parse('$apiBaseUrl/api/auth/me'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ),
    ]);
    if (responses.any((response) => response.statusCode != 200)) {
      throw Exception('Failed to load dashboard');
    }
    final dashboard = jsonDecode(responses[0].body) as Map<String, dynamic>;
    dashboard['currentUser'] = jsonDecode(responses[1].body)['user'];
    return dashboard;
  }

  Future<void> _logout(BuildContext context) async {
    final store = OfflineStore.instance;
    final subject = store.subjectFromHeaders({
      'Authorization': 'Bearer ${widget.token}',
    });
    final pending = (await store.commands())
        .where((entry) => entry.subject == subject)
        .length;
    if (pending > 0 && context.mounted) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Änderungen noch nicht synchronisiert'),
          content: Text(
            '$pending Offline-Änderungen sind noch nicht auf dem Server. '
            'Zum Schutz vor Datenverlust bleibt die Anmeldung bestehen.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Angemeldet bleiben'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Änderungen verwerfen und abmelden'),
            ),
          ],
        ),
      );
      if (discard != true) return;
      await store.discardCommands(subject);
    }
    if (!context.mounted) return;
    if (widget.logoutPageBuilder != null) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: widget.logoutPageBuilder!),
        (route) => false,
      );
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  Future<void> _exitApplication(BuildContext context) async {
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('MaterialKompass beenden?'),
        content: const Text(
          'Die Software wird geschlossen. Nicht gespeicherte Eingaben gehen verloren.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Beenden'),
          ),
        ],
      ),
    );
    if (shouldExit != true) return;

    await (widget.appExit?.call() ?? SystemNavigator.pop());
  }

  Future<void> _refresh() async {
    final future = _loadDashboard();
    setState(() => _dashboardFuture = future);
    await future;
  }

  Future<void> _loadAndOpen(
    Future<void> Function() loadLibrary,
    Widget Function() pageBuilder,
  ) async {
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      await loadLibrary();
      if (rootNavigator.mounted) rootNavigator.pop();
      if (!mounted) return;
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => pageBuilder()));
    } catch (_) {
      if (rootNavigator.mounted) rootNavigator.pop();
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Der Bereich konnte nicht geladen werden. Bitte die Verbindung prüfen.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showOfflineStatus() async {
    final store = OfflineStore.instance;
    final headers = {'Authorization': 'Bearer ${widget.token}'};
    final subject = store.subjectFromHeaders(headers);
    final commands = (await store.commands())
        .where((entry) => entry.subject == subject)
        .toList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Offline-Synchronisation'),
          content: SizedBox(
            width: 620,
            child: commands.isEmpty
                ? const Text('Alle Änderungen wurden synchronisiert.')
                : ListView(
                    shrinkWrap: true,
                    children: commands
                        .map(
                          (entry) => ListTile(
                            leading: Icon(
                              entry.failure == null
                                  ? Icons.schedule
                                  : Icons.sync_problem,
                            ),
                            title: Text(
                              '${entry.method} ${Uri.parse(entry.uri).path}',
                            ),
                            subtitle: Text(
                              entry.failure ??
                                  'Wartet seit ${_formatActivityTime(entry.createdAt.toIso8601String())} auf eine Verbindung.',
                            ),
                            trailing: entry.failure == null
                                ? null
                                : IconButton(
                                    tooltip: 'Abgelehnte Änderung verwerfen',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () async {
                                      await store.discardCommand(
                                        subject,
                                        entry.id,
                                      );
                                      commands.removeWhere(
                                        (command) => command.id == entry.id,
                                      );
                                      setDialogState(() {});
                                    },
                                  ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Schließen'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await offline_transport.flush(headers: headers);
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.sync),
              label: const Text('Jetzt synchronisieren'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showOfflineSettings() async {
    final store = OfflineStore.instance;
    final settings = await store.settings();
    final response = await AppHttpClient.get(
      Uri.parse('$apiBaseUrl/api/locations'),
      headers: {'Authorization': 'Bearer ${widget.token}'},
    );
    final locations = response.statusCode == 200
        ? (jsonDecode(response.body) as List)
              .cast<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList()
        : <Map<String, dynamic>>[];
    var mobileData = settings['mobileData'] != false;
    var largeFileMb =
        ((settings['largeFileBytes'] as num? ?? 10485760) / (1024 * 1024))
            .round()
            .clamp(1, 1024);
    final selected = (settings['locationIds'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toSet();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Offline-Einstellungen'),
          content: SizedBox(
            width: 620,
            child: ListView(
              shrinkWrap: true,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Synchronisation über Mobilfunk'),
                  subtitle: const Text(
                    'WLAN und LAN bleiben unabhängig davon erlaubt.',
                  ),
                  value: mobileData,
                  onChanged: (value) =>
                      setDialogState(() => mobileData = value),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Grenze für große Dateien'),
                  subtitle: Text('$largeFileMb MB · danach nur WLAN/LAN'),
                ),
                Slider(
                  min: 1,
                  max: 100,
                  divisions: 99,
                  value: largeFileMb.clamp(1, 100).toDouble(),
                  label: '$largeFileMb MB',
                  onChanged: (value) =>
                      setDialogState(() => largeFileMb = value.round()),
                ),
                const Divider(),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Offline-Standorte'),
                  subtitle: Text(
                    'Ohne Auswahl werden alle berechtigten Standorte geladen.',
                  ),
                ),
                ...locations.map((entry) {
                  final id = entry['id'].toString();
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(entry['name']?.toString() ?? id),
                    value: selected.contains(id),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    }),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern und aktualisieren'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;
    await store.saveSettings({
      'mobileData': mobileData,
      'largeFileBytes': largeFileMb * 1024 * 1024,
      'locationIds': selected.toList(),
    });
    await OfflineSessionService.prepare(
      widget.token,
      locationIds: selected.toList(),
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
    final action =
        entry['actionLabel']?.toString() ??
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
          ValueListenableBuilder<OfflineStatus>(
            valueListenable: OfflineStore.instance.status,
            builder: (context, status, _) => IconButton(
              onPressed: _showOfflineStatus,
              tooltip: status.offline
                  ? 'Offline · ${status.pending} ausstehend'
                  : status.syncing
                  ? 'Synchronisierung läuft'
                  : 'Online · ${status.pending} ausstehend',
              icon: Badge(
                isLabelVisible: status.pending > 0,
                label: Text('${status.pending}'),
                child: Icon(
                  status.offline
                      ? Icons.cloud_off
                      : status.syncing
                      ? Icons.sync
                      : Icons.cloud_done,
                ),
              ),
            ),
          ),
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.offline_bolt_outlined),
              tooltip: 'Offline-Einstellungen',
              onPressed: _showOfflineSettings,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Aktualisieren',
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Mein Account',
            onPressed: () => _loadAndOpen(
              profile_page.loadLibrary,
              () => profile_page.ProfilePage(
                token: widget.token,
                onAccountDeleted: () => _logout(context),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Abmelden',
            onPressed: () => _logout(context),
          ),
          if (!kIsWeb)
            IconButton(
              icon: const Icon(Icons.power_settings_new),
              tooltip: 'Software beenden',
              onPressed: () => _exitApplication(context),
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
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Das Dashboard konnte nicht geladen werden.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Erneut versuchen'),
                    ),
                  ],
                ),
              ),
            );
          }

          final data = snapshot.data ?? {};
          final summary = Map<String, dynamic>.from(
            data['summary'] as Map? ?? const {},
          );
          final currentUser = Map<String, dynamic>.from(
            data['currentUser'] as Map? ?? const {},
          );
          final permissions = (currentUser['permissions'] as List? ?? const [])
              .map((permission) => permission.toString())
              .toSet();
          final roles = (currentUser['roles'] as List? ?? const [])
              .map((role) => role.toString())
              .toList();
          bool can(String permission) => permissions.contains(permission);
          bool hasMetric(String key) => summary.containsKey(key);
          int metricValue(String key) =>
              int.tryParse(summary[key]?.toString() ?? '') ?? 0;

          return LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 700;
              final pagePadding = isMobile ? 16.0 : 28.0;
              const activityPermissions = {
                'Lagerorte': 'locations.read',
                'Kategorien': 'categories.read',
                'Inventar': 'inventory.read',
                'Kleiderkammer': 'clothing.read',
                'Mängel': 'defects.read',
                'Beschaffung': 'procurement.read',
                'Berichte': 'reports.read',
                'Inventuren': 'stocktakes.read',
              };
              final activities = (data['recentActivity'] as List? ?? const [])
                  .where((entry) {
                    if (entry is! Map) return false;
                    final requiredPermission =
                        activityPermissions[entry['area']?.toString()];
                    return requiredPermission != null &&
                        can(requiredPermission);
                  })
                  .toList();
              final actions = <_DashboardAction>[
                _DashboardAction(
                  icon: Icons.menu_book_outlined,
                  label: 'Handbuch',
                  description: 'Anleitungen und Antworten durchsuchen',
                  onTap: () => _loadAndOpen(
                    knowledge_base_page.loadLibrary,
                    () => knowledge_base_page.KnowledgeBasePage(),
                  ),
                ),
                if (can('inventory.read'))
                  _DashboardAction(
                    icon: Icons.inventory_2_outlined,
                    label: 'Inventar',
                    description: 'Bestände und Material verwalten',
                    onTap: () => _loadAndOpen(
                      inventory_page.loadLibrary,
                      () => inventory_page.InventoryPage(
                        token: widget.token,
                        onLogout: () => _logout(context),
                      ),
                    ),
                  ),
                if (can('clothing.read'))
                  _DashboardAction(
                    icon: Icons.checkroom,
                    label: 'Kleiderkammer',
                    description: 'Kleidung und Ausgaben einsehen',
                    onTap: () => _loadAndOpen(
                      wardrobe_page.loadLibrary,
                      () => wardrobe_page.WardrobePage(
                        token: widget.token,
                        onLogout: () => _logout(context),
                      ),
                    ),
                  ),
                if (can('stocktakes.read'))
                  _DashboardAction(
                    icon: Icons.fact_check_outlined,
                    label: 'Inventuren',
                    description:
                        'Bestände digital oder mit Zähllisten aufnehmen',
                    onTap: () => _loadAndOpen(
                      stocktakes_page.loadLibrary,
                      () => stocktakes_page.StocktakesPage(
                        token: widget.token,
                        onLogout: () => _logout(context),
                      ),
                    ),
                  ),
                if (can('defects.read'))
                  _DashboardAction(
                    icon: Icons.report_problem_outlined,
                    label: 'Mängel',
                    description: 'Mängel und E-Mail-Meldungen bearbeiten',
                    onTap: () => _loadAndOpen(
                      defects_page.loadLibrary,
                      () => defects_page.DefectsPage(token: widget.token),
                    ),
                  ),
                if (can('procurement.read'))
                  _DashboardAction(
                    icon: Icons.shopping_cart_outlined,
                    label: 'Beschaffung',
                    description: 'Anträge, Freigaben und Bestellungen',
                    onTap: () => _loadAndOpen(
                      procurement_page.loadLibrary,
                      () => procurement_page.ProcurementPage(
                        token: widget.token,
                        onLogout: () => _logout(context),
                      ),
                    ),
                  ),
                if (can('categories.read'))
                  _DashboardAction(
                    icon: Icons.category_outlined,
                    label: 'Kategorien',
                    description: 'Materialstruktur einsehen',
                    onTap: () => _loadAndOpen(
                      categories_page.loadLibrary,
                      () => categories_page.CategoriesPage(token: widget.token),
                    ),
                  ),
                if (can('locations.read'))
                  _DashboardAction(
                    icon: Icons.warehouse_outlined,
                    label: 'Lagerorte',
                    description: 'Lager und Lagerplätze öffnen',
                    onTap: () => _loadAndOpen(
                      locations_page.loadLibrary,
                      () => locations_page.LocationsPage(token: widget.token),
                    ),
                  ),
                if (can('users.read') && can('roles.read'))
                  _DashboardAction(
                    icon: Icons.manage_accounts_outlined,
                    label: 'Nutzerverwaltung',
                    description: 'Konten, Rollen und Fachbereiche',
                    onTap: () => _loadAndOpen(
                      users_page.loadLibrary,
                      () => users_page.UsersPage(token: widget.token),
                    ),
                  ),
              ];

              final overview = <_DashboardMetric>[
                if (can('inventory.read') && hasMetric('materialCount'))
                  _DashboardMetric(
                    label: 'Material',
                    value: metricValue('materialCount'),
                    icon: Icons.inventory_2_outlined,
                  ),
                if (can('inventory.read') && hasMetric('issuedMaterialCount'))
                  _DashboardMetric(
                    label: 'Material ausgegeben',
                    value: metricValue('issuedMaterialCount'),
                    icon: Icons.output_outlined,
                  ),
                if (can('clothing.read') && hasMetric('clothingCount'))
                  _DashboardMetric(
                    label: 'Kleidung',
                    value: metricValue('clothingCount'),
                    icon: Icons.checkroom_outlined,
                  ),
                if (can('procurement.read') && hasMetric('procurementCount'))
                  _DashboardMetric(
                    label: 'Beschaffungen',
                    value: metricValue('procurementCount'),
                    icon: Icons.shopping_cart_outlined,
                  ),
              ];
              final tasks = <_DashboardMetric>[
                if (can('inventory.read') &&
                    hasMetric('defectiveMaterialCount'))
                  _DashboardMetric(
                    label: 'Material defekt',
                    value: metricValue('defectiveMaterialCount'),
                    icon: Icons.build_circle_outlined,
                    attention: metricValue('defectiveMaterialCount') > 0,
                  ),
                if (can('inventory.read') && hasMetric('dueInspectionCount'))
                  _DashboardMetric(
                    label: 'Prüfungen fällig',
                    value: metricValue('dueInspectionCount'),
                    icon: Icons.event_busy_outlined,
                    attention: metricValue('dueInspectionCount') > 0,
                  ),
                if (can('defects.read') && hasMetric('openDefectCount'))
                  _DashboardMetric(
                    label: 'Mängel offen',
                    value: metricValue('openDefectCount'),
                    icon: Icons.report_problem_outlined,
                    attention: metricValue('openDefectCount') > 0,
                  ),
                if (can('defects.read') && hasMetric('defectsInProgressCount'))
                  _DashboardMetric(
                    label: 'Mängel in Bearbeitung',
                    value: metricValue('defectsInProgressCount'),
                    icon: Icons.pending_actions_outlined,
                  ),
                if (can('defects.read') && hasMetric('unreadNotificationCount'))
                  _DashboardMetric(
                    label: 'Neue Hinweise',
                    value: metricValue('unreadNotificationCount'),
                    icon: Icons.notifications_active_outlined,
                    attention: metricValue('unreadNotificationCount') > 0,
                  ),
                if (can('defects.read') && hasMetric('pendingDefectEmailCount'))
                  _DashboardMetric(
                    label: 'E-Mail-Prüfungen',
                    value: metricValue('pendingDefectEmailCount'),
                    icon: Icons.mark_email_unread_outlined,
                    attention: metricValue('pendingDefectEmailCount') > 0,
                  ),
                if (can('procurement.approve') &&
                    hasMetric('pendingProcurementApprovals'))
                  _DashboardMetric(
                    label: 'Freigaben offen',
                    value: metricValue('pendingProcurementApprovals'),
                    icon: Icons.approval_outlined,
                    attention: metricValue('pendingProcurementApprovals') > 0,
                  ),
                if (can('procurement.order') &&
                    hasMetric('overdueProcurementOrders'))
                  _DashboardMetric(
                    label: 'Bestellungen überfällig',
                    value: metricValue('overdueProcurementOrders'),
                    icon: Icons.delivery_dining_outlined,
                    attention: metricValue('overdueProcurementOrders') > 0,
                  ),
                if (can('procurement.receive') &&
                    hasMetric('openProcurementReceipts'))
                  _DashboardMetric(
                    label: 'Wareneingänge offen',
                    value: metricValue('openProcurementReceipts'),
                    icon: Icons.move_to_inbox_outlined,
                    attention: metricValue('openProcurementReceipts') > 0,
                  ),
              ];

              Widget metricGrid(List<_DashboardMetric> metrics) {
                final columns = isMobile ? 2 : 4;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: isMobile ? 1.35 : 1.55,
                  ),
                  itemCount: metrics.length,
                  itemBuilder: (_, index) {
                    final metric = metrics[index];
                    return StatCard(
                      title: metric.label,
                      value: metric.value.toString(),
                      width: double.infinity,
                      compact: isMobile,
                      icon: metric.icon,
                      attention: metric.attention,
                    );
                  },
                );
              }

              return RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1200),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              pagePadding,
                              pagePadding,
                              pagePadding,
                              pagePadding +
                                  MediaQuery.paddingOf(context).bottom,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _WelcomeCard(
                                  name: currentUser['name']?.toString(),
                                  roles: roles,
                                ),
                                if (actions.isNotEmpty) ...[
                                  const SizedBox(height: 28),
                                  const _SectionHeading(
                                    title: 'Schnellzugriff',
                                    subtitle:
                                        'Direkt zu Ihren freigeschalteten Bereichen',
                                  ),
                                  const SizedBox(height: 12),
                                  GridView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    gridDelegate:
                                        SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: isMobile ? 2 : 3,
                                          crossAxisSpacing: 12,
                                          mainAxisSpacing: 12,
                                          mainAxisExtent: isMobile ? 132 : 112,
                                        ),
                                    itemCount: actions.length,
                                    itemBuilder: (_, index) => _QuickActionCard(
                                      action: actions[index],
                                      compact: isMobile,
                                    ),
                                  ),
                                ],
                                if (overview.isNotEmpty) ...[
                                  const SizedBox(height: 28),
                                  const _SectionHeading(
                                    title: 'Übersicht',
                                    subtitle:
                                        'Die wichtigsten Zahlen aus Ihren Bereichen',
                                  ),
                                  const SizedBox(height: 12),
                                  metricGrid(overview),
                                ],
                                if (tasks.isNotEmpty) ...[
                                  const SizedBox(height: 28),
                                  const _SectionHeading(
                                    title: 'Aufgaben & Hinweise',
                                    subtitle:
                                        'Was aktuell Ihre Aufmerksamkeit braucht',
                                  ),
                                  const SizedBox(height: 12),
                                  metricGrid(tasks),
                                ],
                                const SizedBox(height: 28),
                                const _SectionHeading(
                                  title: 'Letzte Aktivitäten',
                                  subtitle:
                                      'Nur Ereignisse aus Ihren freigeschalteten Bereichen',
                                ),
                                const SizedBox(height: 8),
                                if (activities.isEmpty)
                                  const _EmptyActivityCard()
                                else
                                  for (final rawEntry in activities)
                                    _ActivityCard(
                                      title: _activityTitle(
                                        Map<String, dynamic>.from(
                                          rawEntry as Map,
                                        ),
                                      ),
                                      details: _activityDetails(
                                        Map<String, dynamic>.from(rawEntry),
                                      ),
                                    ),
                              ],
                            ),
                          ),
                        ),
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

class _DashboardAction {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _DashboardAction({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
  });
}

class _DashboardMetric {
  final String label;
  final int value;
  final IconData icon;
  final bool attention;

  const _DashboardMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.attention = false,
  });
}

class _WelcomeCard extends StatelessWidget {
  final String? name;
  final List<String> roles;

  const _WelcomeCard({required this.name, required this.roles});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = (name == null || name!.trim().isEmpty)
        ? 'Willkommen'
        : 'Hallo, ${name!.trim().split(' ').first}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
            child: const Icon(Icons.space_dashboard_outlined),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  roles.isEmpty
                      ? 'Ihre persönliche Übersicht'
                      : 'Ihre Übersicht als ${roles.join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeading({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  final _DashboardAction action;
  final bool compact;

  const _QuickActionCard({required this.action, required this.compact});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: action.onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? 12 : 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(action.icon, color: colors.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        action.description,
                        maxLines: compact ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!compact)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Icon(Icons.chevron_right),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final String title;
  final String details;

  const _ActivityCard({required this.title, required this.details});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const CircleAvatar(child: Icon(Icons.history)),
        title: Text(title),
        subtitle: Text(details),
      ),
    );
  }
}

class _EmptyActivityCard extends StatelessWidget {
  const _EmptyActivityCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Icon(
              Icons.inbox_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Noch keine Aktivitäten in Ihren freigeschalteten Bereichen.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
