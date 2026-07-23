import 'dart:async';

import 'package:flutter/material.dart';

import '../services/client_update_service.dart';

class ClientUpdateGate extends StatefulWidget {
  const ClientUpdateGate({required this.child, super.key});

  final Widget child;

  @override
  State<ClientUpdateGate> createState() => _ClientUpdateGateState();
}

class _ClientUpdateGateState extends State<ClientUpdateGate>
    with WidgetsBindingObserver {
  final _service = ClientUpdateService();
  Timer? _timer;
  bool _dialogVisible = false;
  bool _installing = false;

  Future<void> _install(ClientUpdate update) async {
    _installing = true;
    final progress = ValueNotifier<double>(0);
    BuildContext? progressContext;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        progressContext = context;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Update wird installiert'),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: value == 0 ? null : value),
                  const SizedBox(height: 12),
                  Text('${(value * 100).round()} % heruntergeladen'),
                  const SizedBox(height: 8),
                  const Text(
                    'Anschließend öffnet MaterialKompass automatisch den sicheren System-Installer.',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    await WidgetsBinding.instance.endOfFrame;

    try {
      final opened = await _service.install(
        update,
        onProgress: (value) =>
            progress.value = value.clamp(0.0, 1.0).toDouble(),
      );
      if (progressContext?.mounted == true) {
        Navigator.of(progressContext!).pop();
      }
      await dialog;
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Der System-Installer konnte nicht gestartet werden.')),
        );
      }
    } catch (error) {
      if (progressContext?.mounted == true) {
        Navigator.of(progressContext!).pop();
      }
      await dialog;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update fehlgeschlagen: $error')),
        );
      }
    } finally {
      _installing = false;
      progress.dispose();
      if (update.required) {
        Future<void>.delayed(const Duration(seconds: 2), _check);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future<void>.delayed(const Duration(seconds: 1), _check);
    }
  }

  Future<void> _check() async {
    if (!mounted || _dialogVisible || _installing) return;
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
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  await _install(update);
                },
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Herunterladen und installieren'),
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
    WidgetsBinding.instance.removeObserver(this);
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
