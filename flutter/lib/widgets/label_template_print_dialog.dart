import 'package:flutter/material.dart';

import '../services/authenticated_api_client.dart';
import '../services/document_output_service.dart';
import '../services/label_print_service.dart';

/// null chooses the existing standard label, false cancels, true completes.
Future<bool?> showTemplatePrintChoice(
  BuildContext context, {
  required String token,
  required List<LabelData> labels,
  required LabelType type,
}) async {
  final api = AuthenticatedApiClient(token);
  try {
    final response = await api.request('/api/label-templates');
    if (!context.mounted) return false;
    final templates = (response as List)
        .cast<Map>()
        .where(
          (t) =>
              t['type'] ==
                  (type == LabelType.inventory ? 'inventory' : 'clothing') &&
              labels.every(
                (l) =>
                    (t['categoryIds'] as List).contains(l.categoryId) ||
                    l.parentCategoryId.isNotEmpty &&
                        (t['categoryIds'] as List).contains(l.parentCategoryId),
              ),
        )
        .toList();
    if (templates.isEmpty) return null;
    final selection = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Etikettenvorlage wählen'),
        children: [
          ...templates.map(
            (t) => SimpleDialogOption(
              onPressed: () => Navigator.pop(c, t['id']),
              child: ListTile(
                leading: const Icon(Icons.label_outline),
                title: Text(t['name'].toString()),
                subtitle: Text(
                  '${t['manufacturer']} · Originaldatei${t['rendererAvailable'] == true ? '' : ' · Herstellerdienst fehlt'}',
                ),
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, 'standard'),
            child: const ListTile(
              leading: Icon(Icons.print_outlined),
              title: Text('Bisheriges Standardetikett (Zebra)'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
    if (selection == null || !context.mounted) return false;
    if (selection == 'standard') return null;
    final t = templates.firstWhere((t) => t['id'] == selection);
    if (!context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _TemplatePrintDialog(api: api, template: t, labels: labels),
        ) ??
        false;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Etikettenvorlagen konnten nicht geladen werden: $e'),
        ),
      );
    }
    return false;
  }
}

class _TemplatePrintDialog extends StatefulWidget {
  const _TemplatePrintDialog({
    required this.api,
    required this.template,
    required this.labels,
  });
  final AuthenticatedApiClient api;
  final Map template;
  final List<LabelData> labels;
  @override
  State<_TemplatePrintDialog> createState() => _TemplatePrintDialogState();
}

class _TemplatePrintDialogState extends State<_TemplatePrintDialog> {
  late final _copies = widget.labels
      .map((l) => TextEditingController(text: l.suggestedCopies.toString()))
      .toList();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _copies) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _output(bool print) async {
    final lines = <Map<String, dynamic>>[];
    var total = 0;
    for (var i = 0; i < widget.labels.length; i++) {
      final copies = int.tryParse(_copies[i].text);
      if (copies == null ||
          copies < 1 ||
          copies > 1000 ||
          (total += copies) > 1000) {
        setState(
          () => _error =
              'Bitte ganze Anzahlen angeben; maximal 1000 Etiketten je Auftrag.',
        );
        return;
      }
      lines.add({'itemId': widget.labels[i].itemId, 'copies': copies});
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final path = '/api/label-templates/${widget.template['id']}/render';
      final check =
          await widget.api.request(
                path,
                method: 'POST',
                body: {'lines': lines, 'checkOnly': true},
              )
              as Map;
      if (!mounted) return;
      final missing = check['missing'] as List;
      var allowMissing = false;
      if (missing.isNotEmpty) {
        allowMissing =
            await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Etikettendaten fehlen'),
                content: SizedBox(
                  width: 500,
                  child: SingleChildScrollView(
                    child: Text(
                      '${missing.take(30).map((m) => '${m['itemName']}: ${m['label']}').join('\n')}${missing.length > 30 ? '\n… und ${missing.length - 30} weitere' : ''}\n\nSie können die Daten ergänzen oder mit leeren Feldern fortfahren.',
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Abbrechen und ergänzen'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(
                      print ? 'Trotzdem drucken' : 'Trotzdem PDF erstellen',
                    ),
                  ),
                ],
              ),
            ) ??
            false;
        if (!allowMissing) return;
      }
      final result =
          await widget.api.request(
                path,
                method: 'POST',
                body: {'lines': lines, 'allowMissing': allowMissing},
              )
              as Map;
      if (print) {
        await DocumentOutputService.instance.printPdfPayload(
          result,
          fallbackFileName: 'etiketten.pdf',
        );
      } else {
        await DocumentOutputService.instance.savePayload(
          result,
          fallbackFileName: 'etiketten.pdf',
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.template['name'].toString()),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Layout und Etikettengröße werden aus der Herstellerdatei übernommen. Die Ausgabe kann vor dem Druck im System-Druckdialog geprüft werden.',
              ),
              const SizedBox(height: 12),
              if (widget.template['rendererAvailable'] != true)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Der Herstellerdienst ist noch nicht eingerichtet. Ein Originaldruck ist derzeit nicht möglich.',
                    ),
                  ),
                ),
              ...List.generate(
                widget.labels.length,
                (i) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(widget.labels[i].name),
                  subtitle: Text(widget.labels[i].inventoryNumber),
                  trailing: SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _copies[i],
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Anzahl'),
                    ),
                  ),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        OutlinedButton(
          onPressed: _busy || widget.template['rendererAvailable'] != true
              ? null
              : () => _output(false),
          child: const Text('PDF speichern'),
        ),
        FilledButton.icon(
          onPressed: _busy || widget.template['rendererAvailable'] != true
              ? null
              : () => _output(true),
          icon: const Icon(Icons.print),
          label: const Text('Drucken'),
        ),
      ],
    ),
  );
}
