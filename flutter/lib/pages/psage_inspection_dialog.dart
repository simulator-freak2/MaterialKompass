import 'dart:convert';

import 'package:flutter/material.dart' hide DropdownButtonFormField;

import '../constants.dart';
import '../services/app_http_client.dart';
import '../services/document_output_service.dart';
import '../services/download_service.dart';
import '../widgets/date_input_field.dart';

/// PSAgE-Westentypen; die Schlüssel entsprechen dem Backend
/// (`backend/src/psage-checklists.js`).
const psageVestTypeLabels = <String, String>{
  'buoyancy-aid': 'Schwimm-, Auftriebshilfe oder Prallschutzweste',
  'lifejacket': 'Rettungsweste (aufblasbar)',
};

const psageReleaseTypeLabels = <String, String>{
  'automatic': 'Automatische Auslösung',
  'manual': 'Manuelle Auslösung',
};

const psageBuoyancyValues = <int>[50, 70, 100, 150, 275];

const psageInspectionKindLabels = <String, String>{
  'expert': 'Sachkundigenprüfung',
  'visual': 'Sichtprüfung durch Nutzer',
};

Map<String, String> _authHeaders(String token, {bool json = false}) => {
  'Authorization': 'Bearer $token',
  if (json) 'Content-Type': 'application/json',
};

String _errorMessage(String body, String fallback) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['error'] != null) {
      return decoded['error'].toString();
    }
  } catch (_) {}
  return fallback;
}

String _formatDate(Object? value) {
  final formatted = formatDateForInput(value);
  return formatted.isEmpty ? '-' : formatted;
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// Lädt Organisationseinstellungen, Rechte und Checklisten.
Future<Map<String, dynamic>?> fetchPsageSettings(String token) async {
  try {
    final response = await AppHttpClient.get(
      Uri.parse('$apiBaseUrl/api/psage/settings'),
      headers: _authHeaders(token),
    );
    if (response.statusCode != 200) return null;
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  } catch (_) {
    return null;
  }
}

/// Organisationsweite Einstellungen (nur Administratoren).
Future<Map<String, dynamic>?> showPsageSettingsDialog({
  required BuildContext context,
  required String token,
  required Map<String, dynamic> settings,
}) async {
  var visualCheckEnabled = settings['visualCheckEnabled'] == true;
  var pdfEnabled = settings['pdfEnabled'] == true;
  var pdfArchiveRequired = settings['pdfArchiveRequired'] == true;
  var saving = false;
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('PSAgE-Prüfungen · Einstellungen'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Sichtprüfung durch Nutzer'),
                subtitle: const Text(
                  'Nutzer mit Zugriff auf die Kleiderkammer können eine Sichtprüfung bzw. einen Buddy-Check dokumentieren. Eine nicht bestandene Sichtprüfung sperrt die Weste bis zur nächsten Sachkundigenprüfung.',
                ),
                value: visualCheckEnabled,
                onChanged: (value) =>
                    setDialogState(() => visualCheckEnabled = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('PDF-Prüfnachweis'),
                subtitle: const Text(
                  'Zu jeder PSAgE-Prüfung kann ein Prüfprotokoll als PDF heruntergeladen oder gedruckt werden.',
                ),
                value: pdfEnabled,
                onChanged: (value) => setDialogState(() {
                  pdfEnabled = value;
                  if (!value) pdfArchiveRequired = false;
                }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('PDF-Nachweis verpflichtend ablegen'),
                subtitle: const Text(
                  'Nach jeder Sachkundigenprüfung wird das Prüfprotokoll automatisch erzeugt und unveränderlich gespeichert.',
                ),
                value: pdfArchiveRequired,
                onChanged: pdfEnabled
                    ? (value) =>
                          setDialogState(() => pdfArchiveRequired = value)
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setDialogState(() => saving = true);
                    try {
                      final response = await AppHttpClient.put(
                        Uri.parse('$apiBaseUrl/api/psage/settings'),
                        headers: _authHeaders(token, json: true),
                        body: jsonEncode({
                          'visualCheckEnabled': visualCheckEnabled,
                          'pdfEnabled': pdfEnabled,
                          'pdfArchiveRequired': pdfArchiveRequired,
                        }),
                      );
                      if (!dialogContext.mounted) return;
                      if (response.statusCode == 200) {
                        Navigator.pop(
                          dialogContext,
                          Map<String, dynamic>.from(
                            jsonDecode(response.body) as Map,
                          ),
                        );
                        return;
                      }
                      _showMessage(
                        dialogContext,
                        _errorMessage(
                          response.body,
                          'Einstellungen konnten nicht gespeichert werden.',
                        ),
                      );
                    } catch (error) {
                      if (dialogContext.mounted) {
                        _showMessage(
                          dialogContext,
                          'Verbindung zum Server fehlgeschlagen: $error',
                        );
                      }
                    }
                    if (dialogContext.mounted) {
                      setDialogState(() => saving = false);
                    }
                  },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}

/// Ampelhinweis zur Einsatzfreigabe einer Weste.
class PsageSafetyBanner extends StatelessWidget {
  const PsageSafetyBanner({required this.safety, super.key});

  final Map<String, dynamic> safety;

  @override
  Widget build(BuildContext context) {
    final blocked = safety['blocked'] == true;
    final reasons = (safety['reasons'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final warnings = (safety['warnings'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final color = blocked
        ? const Color(0xFFFDECEA)
        : warnings.isNotEmpty
        ? const Color(0xFFFFF3CD)
        : const Color(0xFFE6F4EA);
    return Card(
      color: color,
      child: ListTile(
        leading: Icon(
          blocked ? Icons.block : Icons.verified_user,
          color: blocked ? Colors.red.shade800 : Colors.green.shade800,
        ),
        title: Text(
          blocked ? 'Nicht einsatzbereit – Ausgabe gesperrt' : 'Einsatzbereit',
          style: const TextStyle(color: Colors.black87),
        ),
        subtitle: reasons.isEmpty && warnings.isEmpty
            ? null
            : Text(
                [...reasons, ...warnings].join('\n'),
                style: const TextStyle(color: Colors.black87),
              ),
      ),
    );
  }
}

/// Erstellt das PDF-Prüfprotokoll und speichert oder druckt es.
Future<void> openPsageProtocol({
  required BuildContext context,
  required String token,
  required String clothingId,
  required String inspectionId,
  required bool print,
}) async {
  try {
    final response = await AppHttpClient.get(
      Uri.parse(
        '$apiBaseUrl/api/clothing/${Uri.encodeComponent(clothingId)}/psage-inspections/${Uri.encodeComponent(inspectionId)}/pdf',
      ),
      headers: _authHeaders(token),
    );
    if (!context.mounted) return;
    if (response.statusCode != 200) {
      _showMessage(
        context,
        _errorMessage(
          response.body,
          'Das Prüfprotokoll konnte nicht erstellt werden.',
        ),
      );
      return;
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (print) {
      await DocumentOutputService.instance.printPdfPayload(
        data,
        fallbackFileName: 'psage-pruefprotokoll.pdf',
      );
    } else {
      await DocumentOutputService.instance.savePayload(
        data,
        fallbackFileName: 'psage-pruefprotokoll.pdf',
        fallbackMimeType: 'application/pdf',
      );
      if (context.mounted) _showMessage(context, 'Prüfprotokoll gespeichert.');
    }
  } on DownloadException catch (error) {
    if (context.mounted) _showMessage(context, error.message);
  } catch (error) {
    if (context.mounted) {
      _showMessage(context, 'Verbindung zum Server fehlgeschlagen: $error');
    }
  }
}

/// Übersicht der PSAgE-Prüfungen einer Weste mit Freigabestatus,
/// Prüfhistorie, PDF-Nachweisen und Einstieg in die Checklisten.
/// Liefert `true`, wenn eine neue Prüfung gespeichert wurde.
Future<bool> showPsageOverviewDialog({
  required BuildContext context,
  required String token,
  required Map<String, dynamic> item,
  required Map<String, dynamic> settings,
}) async {
  final vestType = item['psageSafety'] is Map
      ? (item['psageSafety'] as Map)['vestType']?.toString()
      : null;
  if (vestType == null || !psageVestTypeLabels.containsKey(vestType)) {
    return false;
  }
  final inspections = (item['inspections'] as List? ?? const [])
      .map((entry) => Map<String, dynamic>.from(entry as Map))
      .where((entry) => entry['psageChecklist'] == true)
      .toList();
  final canInspect = settings['canInspect'] == true;
  final visualEnabled = settings['visualCheckEnabled'] == true;
  final pdfEnabled = settings['pdfEnabled'] == true;
  final action = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('PSAgE-Prüfungen · ${item['name'] ?? 'Weste'}'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${psageVestTypeLabels[vestType]} · ${item['inventoryNumber'] ?? ''}',
              ),
              const SizedBox(height: 8),
              PsageSafetyBanner(
                safety: Map<String, dynamic>.from(item['psageSafety'] as Map),
              ),
              const SizedBox(height: 12),
              Text(
                'Prüfhistorie',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (inspections.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Noch keine PSAgE-Prüfung dokumentiert.'),
                ),
              ...inspections.map((inspection) {
                final ready = inspection['ready'] == true;
                final archived = inspection['protocolDocumentId'] != null;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    ready ? Icons.check_circle : Icons.cancel,
                    color: ready ? Colors.green.shade700 : Colors.red.shade700,
                  ),
                  title: Text(
                    '${_formatDate(inspection['inspectionDate'])} · ${psageInspectionKindLabels[inspection['kind']] ?? 'Prüfung'} · ${ready ? 'einsatzbereit' : 'nicht einsatzbereit'}',
                  ),
                  subtitle: Text(
                    [
                      inspection['inspector']?.toString() ?? '-',
                      if (inspection['nextInspectionDate'] != null)
                        'nächste Prüfung ${_formatDate(inspection['nextInspectionDate'])}',
                      if (archived) 'PDF abgelegt',
                      ...((inspection['autoFindings'] as List? ?? const []).map(
                        (value) => value.toString(),
                      )),
                    ].join(' · '),
                  ),
                  trailing: pdfEnabled || archived
                      ? Wrap(
                          children: [
                            IconButton(
                              tooltip: 'PDF speichern',
                              icon: const Icon(Icons.download),
                              onPressed: () => openPsageProtocol(
                                context: dialogContext,
                                token: token,
                                clothingId: item['id'].toString(),
                                inspectionId: inspection['id'].toString(),
                                print: false,
                              ),
                            ),
                            IconButton(
                              tooltip: 'PDF drucken',
                              icon: const Icon(Icons.print),
                              onPressed: () => openPsageProtocol(
                                context: dialogContext,
                                token: token,
                                clothingId: item['id'].toString(),
                                inspectionId: inspection['id'].toString(),
                                print: true,
                              ),
                            ),
                          ],
                        )
                      : null,
                );
              }),
              if (!canInspect && !visualEnabled)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Sachkundigenprüfungen dürfen nur Personen mit der Rolle „Sachkundiger PSAgE“ erfassen.',
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Schließen'),
        ),
        if (visualEnabled)
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'visual'),
            icon: const Icon(Icons.visibility),
            label: const Text('Sichtprüfung'),
          ),
        if (canInspect)
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'expert'),
            icon: const Icon(Icons.fact_check),
            label: const Text('Sachkundigenprüfung'),
          ),
      ],
    ),
  );
  if (action == null || !context.mounted) return false;
  final saved = await showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PsageChecklistDialog(
      token: token,
      item: item,
      vestType: vestType,
      kind: action,
      settings: settings,
    ),
  );
  if (saved == null || !context.mounted) return false;
  _showMessage(
    context,
    saved['ready'] == true
        ? 'Prüfung gespeichert: einsatzbereit.'
        : 'Prüfung gespeichert: nicht einsatzbereit – Mangel wurde angelegt.',
  );
  if (pdfEnabled && action == 'expert') {
    final print = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Prüfprotokoll'),
        content: Text(
          saved['protocolDocumentId'] != null
              ? 'Das PDF-Prüfprotokoll wurde abgelegt. Jetzt speichern oder drucken?'
              : 'Soll das PDF-Prüfprotokoll jetzt gespeichert oder gedruckt werden?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Später'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Speichern'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Drucken'),
          ),
        ],
      ),
    );
    if (print != null && context.mounted) {
      await openPsageProtocol(
        context: context,
        token: token,
        clothingId: item['id'].toString(),
        inspectionId: saved['id'].toString(),
        print: print,
      );
    }
  }
  return true;
}

/// Checkliste nach Westenkunde LV Hessen (Stand 2023-1) mit Bewertung
/// N/A, OK oder KO je Position. Das Ergebnis berechnet das Backend verbindlich.
class PsageChecklistDialog extends StatefulWidget {
  const PsageChecklistDialog({
    required this.token,
    required this.item,
    required this.vestType,
    required this.kind,
    required this.settings,
    super.key,
  });

  final String token;
  final Map<String, dynamic> item;
  final String vestType;
  final String kind;
  final Map<String, dynamic> settings;

  @override
  State<PsageChecklistDialog> createState() => _PsageChecklistDialogState();
}

class _PsageChecklistDialogState extends State<PsageChecklistDialog> {
  final _date = TextEditingController(text: formatDateForInput(DateTime.now()));
  final _serviceTag = TextEditingController();
  final _defects = TextEditingController();
  final _followUp = TextEditingController();
  final _remarks = TextEditingController();
  final _gasType = TextEditingController(text: 'CO2');
  final _grossMass = TextEditingController();
  final _grossTolerance = TextEditingController();
  final _gasMass = TextEditingController();
  final _gasTolerance = TextEditingController();
  final _actualMass = TextEditingController();
  final Map<String, String> _ratings = {};
  final Map<String, TextEditingController> _itemRemarks = {};
  late final List<Map<String, dynamic>> _sections;
  bool _saving = false;

  bool get _isLifejacketExpert =>
      widget.kind == 'expert' && widget.vestType == 'lifejacket';

  @override
  void initState() {
    super.initState();
    final checklists = widget.settings['checklists'];
    final definition = checklists is Map && checklists[widget.kind] is Map
        ? (checklists[widget.kind] as Map)[widget.vestType]
        : null;
    final swiftwater = widget.item['psageSwiftwaterRescue'] == true;
    final manual = widget.item['psageReleaseType'] == 'manual';
    final rawSections =
        (definition is Map ? definition['sections'] as List? : null) ??
        const [];
    _sections = rawSections.map((section) {
      final map = Map<String, dynamic>.from(section as Map);
      map['items'] = (map['items'] as List? ?? const [])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .where((entry) {
            final requires = entry['requires']?.toString();
            if (requires == 'swiftwater') return swiftwater;
            if (requires == 'automatic') return !manual;
            return true;
          })
          .toList();
      return map;
    }).toList();
    for (final section in _sections) {
      for (final entry in section['items'] as List<Map<String, dynamic>>) {
        _itemRemarks[entry['id'].toString()] = TextEditingController();
      }
    }
    for (final controller in [
      _grossMass,
      _grossTolerance,
      _gasMass,
      _gasTolerance,
      _actualMass,
    ]) {
      controller.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _date,
      _serviceTag,
      _defects,
      _followUp,
      _remarks,
      _gasType,
      _grossMass,
      _grossTolerance,
      _gasMass,
      _gasTolerance,
      _actualMass,
      ..._itemRemarks.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Iterable<Map<String, dynamic>> get _items => _sections.expand(
    (section) => section['items'] as List<Map<String, dynamic>>,
  );

  double? _number(TextEditingController controller) =>
      double.tryParse(controller.text.trim().replaceAll(',', '.'));

  String _formatNumber(double value) => value
      .toStringAsFixed(value.truncateToDouble() == value ? 0 : 2)
      .replaceAll('.', ',');

  bool? get _massWithinTolerance {
    final gross = _number(_grossMass);
    final gas = _number(_gasMass);
    final actual = _number(_actualMass);
    if (gross == null || gas == null || actual == null) return null;
    final tolerance =
        (_number(_grossTolerance) ?? 0) + (_number(_gasTolerance) ?? 0);
    return (actual - (gross + gas)).abs() <= tolerance + 1e-9;
  }

  bool get _hasKo => _ratings.values.contains('ko');

  int get _openCount =>
      _items.where((entry) => !_ratings.containsKey(entry['id'])).length;

  void _setAllOpen(String rating) {
    setState(() {
      for (final entry in _items) {
        _ratings.putIfAbsent(entry['id'].toString(), () => rating);
      }
    });
  }

  Future<void> _save() async {
    final inspectionDate = dateInputToIso(_date.text);
    if (inspectionDate == null) {
      _showMessage(context, 'Bitte ein gültiges Prüfdatum angeben.');
      return;
    }
    if (_openCount > 0) {
      _showMessage(
        context,
        'Bitte alle $_openCount offenen Positionen bewerten.',
      );
      return;
    }
    final serviceTag = _serviceTag.text.trim().isEmpty
        ? null
        : dateInputToIso(_serviceTag.text);
    if (_serviceTag.text.trim().isNotEmpty && serviceTag == null) {
      _showMessage(context, 'Das Datum der Prüfplakette ist ungültig.');
      return;
    }
    setState(() => _saving = true);
    try {
      final response = await AppHttpClient.post(
        Uri.parse(
          '$apiBaseUrl/api/clothing/${Uri.encodeComponent(widget.item['id'].toString())}/psage-inspections',
        ),
        headers: _authHeaders(widget.token, json: true),
        body: jsonEncode({
          'kind': widget.kind,
          'inspectionDate': inspectionDate,
          'ratings': {
            for (final entry in _items)
              entry['id'].toString(): {
                'rating': _ratings[entry['id'].toString()],
                'remark': _itemRemarks[entry['id'].toString()]!.text.trim(),
              },
          },
          if (_isLifejacketExpert)
            'measurements': {
              'gasType': _gasType.text.trim(),
              'grossMass': _grossMass.text.trim(),
              'grossTolerance': _grossTolerance.text.trim(),
              'gasMass': _gasMass.text.trim(),
              'gasTolerance': _gasTolerance.text.trim(),
              'actualMass': _actualMass.text.trim(),
            },
          'serviceTagDueDate': ?serviceTag,
          'defectsText': _defects.text.trim(),
          'followUp': _followUp.text.trim(),
          'remarks': _remarks.text.trim(),
        }),
      );
      if (!mounted) return;
      if (response.statusCode == 201) {
        Navigator.pop(
          context,
          Map<String, dynamic>.from(jsonDecode(response.body) as Map),
        );
        return;
      }
      _showMessage(
        context,
        _errorMessage(
          response.body,
          'Prüfung konnte nicht gespeichert werden.',
        ),
      );
    } catch (error) {
      if (mounted) {
        _showMessage(context, 'Verbindung zum Server fehlgeschlagen: $error');
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _ratingRow(Map<String, dynamic> entry) {
    final id = entry['id'].toString();
    final rating = _ratings[id];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: rating == 'ko' ? const Color(0xFFFDECEA) : null,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    entry['position']?.toString() ?? '',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(child: Text(entry['label']?.toString() ?? '')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'na', label: Text('N/A')),
                    ButtonSegment(value: 'ok', label: Text('OK')),
                    ButtonSegment(value: 'ko', label: Text('KO')),
                  ],
                  selected: rating == null ? <String>{} : {rating},
                  onSelectionChanged: (selection) => setState(() {
                    if (selection.isEmpty) {
                      _ratings.remove(id);
                    } else {
                      _ratings[id] = selection.first;
                    }
                  }),
                ),
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _itemRemarks[id],
                    maxLength: 500,
                    decoration: const InputDecoration(
                      labelText: 'Bemerkung',
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, suffixText: 'g'),
      ),
    );
  }

  Widget _measurements() {
    final gross = _number(_grossMass);
    final gas = _number(_gasMass);
    final within = _massWithinTolerance;
    final expected = gross != null && gas != null
        ? '${_formatNumber(gross + gas)} ± ${_formatNumber((_number(_grossTolerance) ?? 0) + (_number(_gasTolerance) ?? 0))} g'
        : '–';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Druckgasflasche wiegen (Herstellerangaben beachten)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: _gasType,
                    decoration: const InputDecoration(labelText: 'Gas'),
                  ),
                ),
                _numberField(_grossMass, 'Mindest-Bruttomasse'),
                _numberField(_grossTolerance, '± Toleranz'),
                _numberField(_gasMass, 'Masse Gasinhalt'),
                _numberField(_gasTolerance, '± Toleranz'),
                _numberField(_actualMass, 'Ist (Waage)'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Soll gesamt: $expected${within == null
                  ? ''
                  : within
                  ? ' · innerhalb der Toleranz'
                  : ' · außerhalb der Toleranz (nicht einsatzbereit)'}',
              style: TextStyle(
                color: within == false ? Colors.red.shade800 : null,
                fontWeight: within == false ? FontWeight.bold : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.kind == 'visual'
        ? 'Sichtprüfung durch den Nutzer'
        : 'Prüfung durch einen Sachkundigen';
    final notReady = _hasKo || _massWithinTolerance == false;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  Text(
                    '${psageVestTypeLabels[widget.vestType]} · ${widget.item['name'] ?? ''} · ${widget.item['inventoryNumber'] ?? ''}',
                  ),
                  Text(
                    'Checkliste ${widget.settings['checklists']?['version'] ?? ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 220,
                        child: DateInputField(
                          controller: _date,
                          label: 'Prüfdatum',
                          required: true,
                          lastDate: DateTime.now(),
                        ),
                      ),
                      if (widget.vestType == 'lifejacket' &&
                          widget.kind == 'expert')
                        SizedBox(
                          width: 260,
                          child: DateInputField(
                            controller: _serviceTag,
                            label: 'Prüfplakette gültig bis',
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: _openCount == 0
                            ? null
                            : () => _setAllOpen('ok'),
                        icon: const Icon(Icons.done_all),
                        label: Text('Offene Positionen auf OK ($_openCount)'),
                      ),
                    ],
                  ),
                  for (final section in _sections) ...[
                    const SizedBox(height: 16),
                    Text(
                      section['title']?.toString() ?? '',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    for (final entry
                        in section['items'] as List<Map<String, dynamic>>)
                      _ratingRow(entry),
                    if (section['measurements'] == true && _isLifejacketExpert)
                      _measurements(),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    color: notReady
                        ? const Color(0xFFFDECEA)
                        : const Color(0xFFE6F4EA),
                    child: ListTile(
                      leading: Icon(
                        notReady ? Icons.cancel : Icons.check_circle,
                        color: notReady
                            ? Colors.red.shade800
                            : Colors.green.shade800,
                      ),
                      title: Text(
                        notReady
                            ? 'Die vorliegende PSAgE ist nicht einsatzbereit.'
                            : 'Die vorliegende PSAgE ist gemäß der durchgeführten Prüfung einsatzbereit.',
                        style: const TextStyle(color: Colors.black87),
                      ),
                      subtitle: const Text(
                        'Das verbindliche Ergebnis ermittelt der Server aus KO-Positionen, Patronenmasse, Prüfplakette und Alter der Weste.',
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  ),
                  TextField(
                    controller: _defects,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Festgestellte Mängel',
                      helperText:
                          'Pflicht, wenn die Weste nicht einsatzbereit ist',
                    ),
                  ),
                  TextField(
                    controller: _followUp,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Anweisungen zum weiteren Vorgehen',
                    ),
                  ),
                  TextField(
                    controller: _remarks,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Sonstige Bemerkungen',
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Abbrechen'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Prüfung speichern'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
