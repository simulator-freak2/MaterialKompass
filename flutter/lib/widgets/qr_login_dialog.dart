import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../camera_scan_support.dart';

Future<void> showQrLoginCode(
  BuildContext context, {
  required String qrValue,
  required DateTime expiresAt,
  String? accountLabel,
}) {
  final localExpiry = expiresAt.toLocal();
  final time =
      '${localExpiry.hour.toString().padLeft(2, '0')}:${localExpiry.minute.toString().padLeft(2, '0')}';
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(accountLabel == null
          ? 'Einmaliger Anmelde-QR-Code'
          : 'QR-Code für $accountLabel'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Der Code enthält keine persönlichen Daten. Er ist nur einmal und für 10 Minuten verwendbar.',
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
            Text('Gültig bis $time Uhr'),
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
