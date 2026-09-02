import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';
import 'keyboard_dropdown_button_form_field.dart';

class QrLoginValidity {
  final String value;
  final int? customDays;
  final String title;

  const QrLoginValidity(this.value, {required this.title, this.customDays});

  Map<String, dynamic> toJson() => {
    'title': title,
    'validity': value,
    if (customDays != null) 'customDays': customDays,
  };
}

const qrLoginValidityOptions = <String, String>{
  '10m': '10 Minuten',
  '30m': '30 Minuten',
  '60m': '60 Minuten',
  '12h': '12 Stunden',
  '1d': '1 Tag',
  '7d': '7 Tage',
  '14d': '14 Tage',
  '30d': '30 Tage',
  '1y': '1 Jahr',
  '3y': '3 Jahre',
  'custom': 'Benutzerdefiniert (in Tagen)',
  'unlimited': 'Unbefristet',
};

String qrCredentialExpiryLabel(Object? value) {
  if (value == null) return 'Unbefristet gültig';
  final localExpiry = DateTime.tryParse(value.toString())?.toLocal();
  if (localExpiry == null) return 'Unbekannte Gültigkeit';
  return 'Gültig bis '
      '${localExpiry.day.toString().padLeft(2, '0')}.'
      '${localExpiry.month.toString().padLeft(2, '0')}.'
      '${localExpiry.year}, '
      '${localExpiry.hour.toString().padLeft(2, '0')}:'
      '${localExpiry.minute.toString().padLeft(2, '0')} Uhr';
}

Future<QrLoginValidity?> chooseQrLoginValidity(BuildContext context) async {
  var selected = '10m';
  String? errorText;
  String? titleErrorText;
  final title = TextEditingController();
  final customDays = TextEditingController();
  final result = await showDialog<QrLoginValidity>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Gültigkeit des Anmeldecodes'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Titel',
                  hintText: 'z. B. Tablet Gerätehaus',
                  errorText: titleErrorText,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Gültigkeitsdauer',
                  border: OutlineInputBorder(),
                ),
                items: qrLoginValidityOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() {
                      selected = value;
                      errorText = null;
                    });
                  }
                },
              ),
              if (selected == 'custom') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: customDays,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Anzahl Tage',
                    errorText: errorText,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                selected == 'unlimited'
                    ? 'Der Code kann bis zur manuellen Deaktivierung beliebig oft verwendet werden.'
                    : 'Der Code ist innerhalb der gewählten Laufzeit einmal verwendbar.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final trimmedTitle = title.text.trim();
              if (trimmedTitle.isEmpty) {
                setDialogState(() {
                  titleErrorText = 'Bitte einen Titel eingeben.';
                });
                return;
              }
              if (selected != 'custom') {
                Navigator.pop(
                  context,
                  QrLoginValidity(selected, title: trimmedTitle),
                );
                return;
              }
              final days = int.tryParse(customDays.text.trim());
              if (days == null || days < 1 || days > 36500) {
                setDialogState(() {
                  errorText = 'Bitte 1 bis 36500 Tage eingeben.';
                });
                return;
              }
              Navigator.pop(
                context,
                QrLoginValidity(
                  selected,
                  title: trimmedTitle,
                  customDays: days,
                ),
              );
            },
            child: const Text('Code erstellen'),
          ),
        ],
      ),
    ),
  );
  title.dispose();
  customDays.dispose();
  return result;
}

Future<void> showQrLoginCode(
  BuildContext context, {
  required String qrValue,
  DateTime? expiresAt,
  String? accountLabel,
  bool oneTime = true,
}) {
  final expiryText = qrCredentialExpiryLabel(expiresAt?.toIso8601String());
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(
        accountLabel == null
            ? 'Einmaliger Anmelde-QR-Code'
            : 'QR-Code für $accountLabel',
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              oneTime
                  ? 'Der Code enthält keine persönlichen Daten und ist nur einmal verwendbar.'
                  : 'Der Code enthält keine persönlichen Daten und kann bis zur Deaktivierung mehrfach verwendet werden.',
            ),
            const SizedBox(height: 16),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: bw.BarcodeWidget(
                barcode: bw.Barcode.qrCode(),
                data: qrValue,
                width: 240,
                height: 240,
              ),
            ),
            const SizedBox(height: 12),
            Text(expiryText),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: qrValue));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Anmeldecode wurde kopiert.')),
              );
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Code kopieren'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
}

Future<String?> scanQrLoginCode(
  BuildContext context, {
  List<String> allowedPrefixes = const ['mkqr:v1:'],
}) => showDialog<String>(
  context: context,
  builder: (_) => _QrLoginScannerDialog(allowedPrefixes: allowedPrefixes),
);

class _QrLoginScannerDialog extends StatefulWidget {
  final List<String> allowedPrefixes;
  const _QrLoginScannerDialog({required this.allowedPrefixes});

  @override
  State<_QrLoginScannerDialog> createState() => _QrLoginScannerDialogState();
}

class _QrLoginScannerDialogState extends State<_QrLoginScannerDialog> {
  final controller = TextEditingController();
  bool completed = false;

  void submit(String value) {
    final credential = value.trim();
    if (completed || !widget.allowedPrefixes.any(credential.startsWith)) return;
    completed = true;
    Navigator.pop(context, credential);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('QR-Code scannen'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCameraScanningSupported)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 300,
                child: MobileScanner(
                  onDetect: (capture) {
                    String? value;
                    for (final barcode in capture.barcodes) {
                      if (barcode.rawValue != null) {
                        value = barcode.rawValue;
                        break;
                      }
                    }
                    if (value != null) submit(value);
                  },
                ),
              ),
            )
          else
            const Text(
              'Auf diesem Gerät kann der Anmeldecode eingefügt werden.',
            ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            onSubmitted: submit,
            decoration: const InputDecoration(
              labelText: 'Anmeldecode',
              prefixIcon: Icon(Icons.key),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(
        onPressed: () => submit(controller.text),
        child: const Text('Anmelden'),
      ),
    ],
  );
}
