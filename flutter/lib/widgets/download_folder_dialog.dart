import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../services/download_service.dart';

Future<void> showDownloadFolderDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _DownloadFolderDialog(),
  );
}

class _DownloadFolderDialog extends StatefulWidget {
  const _DownloadFolderDialog();

  @override
  State<_DownloadFolderDialog> createState() => _DownloadFolderDialogState();
}

class _DownloadFolderDialogState extends State<_DownloadFolderDialog> {
  String? _directory;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final directory = await DownloadService.instance.configuredDirectory();
    if (!mounted) return;
    setState(() {
      _directory = directory;
      _loading = false;
    });
  }

  Future<void> _choose() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = await DownloadService.instance.chooseDirectory();
      if (!mounted) return;
      setState(() {
        if (selected != null) _directory = selected;
      });
    } on DownloadException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await DownloadService.instance.resetDirectory();
    if (!mounted) return;
    setState(() {
      _directory = null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Download-Ordner'),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Exporte, Dokumente, Anhänge und heruntergeladene Berichte werden '
            'lokal in diesem Ordner gespeichert. Programmupdates verwenden '
            'weiterhin ein geschütztes temporäres Verzeichnis.',
          ),
          if (defaultTargetPlatform == TargetPlatform.iOS) ...[
            const SizedBox(height: 10),
            const Text(
              'iOS verlangt beim Speichern zusätzlich eine Bestätigung im '
              'Systemdialog. Der ausgewählte Ordner wird dort als Ziel '
              'vorbelegt.',
            ),
          ],
          const SizedBox(height: 16),
          SelectableText(
            _directory ?? 'Systemstandard verwenden',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_loading) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _loading || _directory == null ? null : _reset,
        child: const Text('Systemstandard'),
      ),
      OutlinedButton.icon(
        onPressed: _loading ? null : _choose,
        icon: const Icon(Icons.folder_open_outlined),
        label: const Text('Ordner auswählen'),
      ),
      FilledButton(
        onPressed: _loading ? null : () => Navigator.pop(context),
        child: const Text('Schließen'),
      ),
    ],
  );
}
