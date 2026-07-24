import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';

enum QrLoginMode { oneTime, reusable }

class QrLoginOptions {
  final bool oneTime;
  final int? validForDays;
  const QrLoginOptions.oneTime()
      : oneTime = true,
        validForDays = null;
  const QrLoginOptions.reusable(this.validForDays) : oneTime = false;
}

Future<QrLoginOptions?> chooseQrLoginOptions(BuildContext context) async {
  final mode = await showDialog<QrLoginMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Art des QR-Codes'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.looks_one_outlined),
                title: const Text('Einmal verwendbar'),
                subtitle: const Text(
                    '10 Minuten gültig und nach der ersten Anmeldung verbraucht.'),
                onTap: () => Navigator.pop(context, QrLoginMode.oneTime),
              ),
              ListTile(
                leading: const Icon(Icons.all_inclusive),
                title: const Text('Mehrfach verwendbar'),
                subtitle: const Text(
                    'Gültigkeitsdauer auswählen. Wie ein Passwort schützen.'),
                onTap: () => Navigator.pop(context, QrLoginMode.reusable),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
  if (mode == null) return null;
  if (mode == QrLoginMode.oneTime) return const QrLoginOptions.oneTime();
  if (!context.mounted) return null;
  final days = await showDialog<int?>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Gültigkeitsdauer'),
      children: [
        for (final days in const [7, 14, 30, 365])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, days),
            child: Text('$days Tage'),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, -1),
          child: const Text('Benutzerdefiniert'),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, 0),
          child: const Text('Bis Widerruf'),
        ),
      ],
    ),
  );
  if (days == null) return null;
  if (days == 0) return const QrLoginOptions.reusable(null);
  if (days > 0) return QrLoginOptions.reusable(days);
  if (!context.mounted) return null;
  final controller = TextEditingController();
  final customDays = await showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Benutzerdefinierte Gültigkeit'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Anzahl der Tage',
          helperText: '1 bis 3650 Tage',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () {
            final value = int.tryParse(controller.text.trim());
            if (value != null && value >= 1 && value <= 3650) {
              Navigator.pop(context, value);
            }
          },
          child: const Text('Übernehmen'),
        ),
      ],
    ),
  );
  controller.dispose();
  return customDays == null ? null : QrLoginOptions.reusable(customDays);
}

Future<void> showQrLoginCode(
  BuildContext context, {
  required String qrValue,
  required DateTime? expiresAt,
  required bool oneTime,
  String? accountLabel,
}) {
  final localExpiry = expiresAt?.toLocal();
  final time = localExpiry == null
      ? null
      : '${localExpiry.hour.toString().padLeft(2, '0')}:${localExpiry.minute.toString().padLeft(2, '0')}';
  final date = localExpiry == null
      ? null
      : '${localExpiry.day.toString().padLeft(2, '0')}.${localExpiry.month.toString().padLeft(2, '0')}.${localExpiry.year}';
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(accountLabel == null
          ? '${oneTime ? 'Einmaliger' : 'Mehrfach verwendbarer'} Anmelde-QR-Code'
          : 'QR-Code für $accountLabel'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              oneTime
                  ? 'Der Code enthält keine persönlichen Daten. Er ist einmalig und 10 Minuten gültig.'
                  : 'Der Code enthält keine persönlichen Daten. Er ist mehrfach verwendbar und muss wie ein Passwort geschützt werden.',
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
            Text(localExpiry == null
                ? 'Gültig bis zum Widerruf'
                : oneTime
                    ? 'Gültig bis $time Uhr'
                    : 'Gültig bis $date, $time Uhr'),
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

Future<String?> scanQrLoginCode(BuildContext context) => showDialog<String>(
      context: context,
      builder: (_) => const _QrLoginScannerDialog(),
    );

class _QrLoginScannerDialog extends StatefulWidget {
  const _QrLoginScannerDialog();

  @override
  State<_QrLoginScannerDialog> createState() => _QrLoginScannerDialogState();
}

class _QrLoginScannerDialogState extends State<_QrLoginScannerDialog> {
  final controller = TextEditingController();
  bool completed = false;

  void submit(String value) {
    final credential = value.trim();
    if (completed || !credential.startsWith('mkqr:v1:')) return;
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
