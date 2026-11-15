import 'package:flutter/material.dart';

import '../services/web_startup_bridge.dart';
import 'dashboard_page.dart' deferred as dashboard;

/// Laedt die Fachbereiche im Web erst nach einer erfolgreichen Anmeldung.
class DeferredDashboardPage extends StatefulWidget {
  const DeferredDashboardPage({
    required this.token,
    this.logoutPageBuilder,
    super.key,
  });

  final String token;
  final WidgetBuilder? logoutPageBuilder;

  static Future<void>? _preloaded;

  /// Beginnt das Laden des Arbeitsbereichs, waehrend die Sitzung noch geprueft
  /// wird. Ein Fehlschlag wird beim Anzeigen erneut versucht.
  static Future<void> preload() =>
      _preloaded ??= dashboard.loadLibrary()
        ..catchError((Object _) => _preloaded = null);

  @override
  State<DeferredDashboardPage> createState() => _DeferredDashboardPageState();
}

class _DeferredDashboardPageState extends State<DeferredDashboardPage> {
  late Future<void> _loaded = DeferredDashboardPage.preload();

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _loaded,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done) {
        // Erst jetzt ist der Arbeitsbereich sichtbar; die HTML-Loginseite
        // bleibt bis dahin mit Ladehinweis stehen.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => notifyWebAppReady(),
        );
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Der Arbeitsbereich konnte nicht geladen werden.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => setState(() {
                    _loaded = dashboard.loadLibrary();
                  }),
                  child: const Text('Erneut versuchen'),
                ),
              ],
            ),
          ),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return dashboard.DashboardPage(
        token: widget.token,
        logoutPageBuilder: widget.logoutPageBuilder,
      );
    },
  );
}
