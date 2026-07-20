import 'dart:async';

import 'package:flutter/material.dart';

import '../services/client_update_service.dart';

class ClientUpdateGate extends StatefulWidget {
  const ClientUpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<ClientUpdateGate> createState() => _ClientUpdateGateState();
}

class _ClientUpdateGateState extends State<ClientUpdateGate> {
  final _service = ClientUpdateService();
  Timer? _timer;
  bool _dialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _check());
  }

  Future<void> _check() async {
    if (!mounted || _dialogVisible) return;
    try {
      final update = await _service.check();
      if (update == null || !mounted || _dialogVisible) return;
      _dialogVisible = true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !update.required,
        builder: (context) => PopScope(
          canPop: !update.required,
          child: AlertDialog(
            title: const Text('Update verfügbar'),
            content: Text([
              'MaterialKompass ${update.version} ist verfügbar.',
              if (update.notes?.trim().isNotEmpty == true) update.notes!.trim(),
              if (update.required)
                'Dieses Update ist erforderlich, um fortzufahren.',
            ].join('\n\n')),
            actions: [
              if (!update.required)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Später'),
                ),
              FilledButton.icon(
                onPressed: () async {
                  final opened = await _service.install(update);
                  if (!context.mounted) return;
                  if (opened && !update.required) Navigator.pop(context);
                  if (!opened) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Der Update-Download konnte nicht geöffnet werden.')),
                    );
                  }
                },
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Jetzt aktualisieren'),
              ),
            ],
          ),
        ),
      );
    } catch (_) {
      // A temporary backend/network failure must never block normal app use.
    } finally {
      _dialogVisible = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
