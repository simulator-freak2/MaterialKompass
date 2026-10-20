import 'dart:async';
import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/api_client.dart';
import '../services/passkey_service.dart';

Map<String, dynamic> _object(http.Response response) {
  if (response.body.isEmpty) return {};
  final decoded = jsonDecode(response.body);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

Future<Map<String, dynamic>?> verifyMfaChallenge(
  BuildContext context,
  Map<String, dynamic> challenge,
) async {
  final code = TextEditingController();
  final methods = (challenge['methods'] as List? ?? const [])
      .map((entry) => entry.toString())
      .toSet();
  final pushAvailable = methods.contains('push');
  final passkeys =
      methods.contains('passkey') && PasskeyService.platformSupported
      ? PasskeyService()
      : null;
  final codeAvailable =
      methods.contains('totp') || methods.contains('recovery_code');
  String? error;
  String? pushStatus;
  var submitting = false;
  var pushStarted = false;
  var dialogClosed = false;

  Future<void> startPush(
    StateSetter setDialogState,
    BuildContext dialogContext,
  ) async {
    try {
      final startedResponse = await http.post(
        Uri.parse('$apiBaseUrl/api/auth/mfa/push/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'challenge': challenge['challenge']}),
      );
      final started = _object(startedResponse);
      if (startedResponse.statusCode != 200) {
        throw started['error']?.toString() ??
            'Die Push-Benachrichtigung konnte nicht gesendet werden.';
      }
      if (!dialogContext.mounted || dialogClosed) return;
      setDialogState(() {
        pushStatus =
            'Push gesendet. Öffne die MaterialKompass-App auf deinem '
            'registrierten Gerät und bestätige oder lehne die Anmeldung ab.';
      });
      final approvalId = started['approvalId'];
      final expiresAt = DateTime.tryParse(
        started['expiresAt']?.toString() ?? '',
      );
      while (!dialogClosed && dialogContext.mounted) {
        if (expiresAt != null && !DateTime.now().isBefore(expiresAt)) {
          throw 'Die Push-Anfrage ist abgelaufen.';
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        if (dialogClosed || !dialogContext.mounted) return;
        final statusResponse = await http.post(
          Uri.parse('$apiBaseUrl/api/auth/mfa/push/status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'challenge': challenge['challenge'],
            'approvalId': approvalId,
          }),
        );
        final status = _object(statusResponse);
        if (statusResponse.statusCode == 202) continue;
        if (statusResponse.statusCode == 200 && status['token'] != null) {
          if (dialogContext.mounted) Navigator.pop(dialogContext, status);
          return;
        }
        throw status['error']?.toString() ??
            'Die Push-Anfrage konnte nicht bestätigt werden.';
      }
    } catch (pushError) {
      if (!dialogClosed && dialogContext.mounted) {
        setDialogState(() {
          error = pushError.toString();
          pushStatus = null;
          pushStarted = false;
        });
      }
    }
  }

  try {
    return await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            title: const Text('Zwei-Faktor-Authentifizierung'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    !pushAvailable && passkeys == null
                        ? 'Geben Sie den sechsstelligen Code Ihrer Authenticator-App '
                              'oder einen Wiederherstellungscode ein.'
                        : 'Wählen Sie eine verfügbare Methode, um die Anmeldung zu bestätigen.',
                  ),
                  if (pushAvailable) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: submitting || pushStarted
                            ? null
                            : () {
                                setDialogState(() {
                                  pushStarted = true;
                                  error = null;
                                  pushStatus =
                                      'Push-Benachrichtigung wird gesendet …';
                                });
                                unawaited(
                                  startPush(setDialogState, dialogContext),
                                );
                              },
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: Text(
                          pushStarted
                              ? 'Push-Benachrichtigung gesendet'
                              : 'Push-Benachrichtigung senden',
                        ),
                      ),
                    ),
                    if (pushStatus != null) ...[
                      const SizedBox(height: 8),
                      Text(pushStatus!),
                    ],
                  ],
                  if (passkeys != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: submitting
                            ? null
                            : () async {
                                setDialogState(() {
                                  submitting = true;
                                  error = null;
                                });
                                try {
                                  final data = await passkeys.approveMfa(
                                    challenge: challenge['challenge']
                                        .toString(),
                                  );
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext, data);
                                  }
                                } on ApiException catch (exception) {
                                  if (dialogContext.mounted) {
                                    setDialogState(() {
                                      error = exception.message;
                                      submitting = false;
                                    });
                                  }
                                }
                              },
                        icon: const Icon(Icons.key_outlined),
                        label: const Text('Mit Passkey bestätigen'),
                      ),
                    ),
                  ],
                  if ((pushAvailable || passkeys != null) && codeAvailable) ...[
                    const SizedBox(height: 12),
                    const Divider(),
                    const Text('Alternativ können Sie einen Code verwenden.'),
                  ],
                  if (codeAvailable) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: code,
                      autofocus: !pushAvailable,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      keyboardType: TextInputType.text,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.characters,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: '2-FA-Code',
                        errorText: error,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (error != null && !codeAvailable) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              if (codeAvailable)
                OutlinedButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          setDialogState(() {
                            submitting = true;
                            error = null;
                          });
                          try {
                            final response = await http.post(
                              Uri.parse('$apiBaseUrl/api/auth/mfa/verify'),
                              headers: {'Content-Type': 'application/json'},
                              body: jsonEncode({
                                'challenge': challenge['challenge'],
                                'code': code.text.trim(),
                              }),
                            );
                            final data = _object(response);
                            if (!dialogContext.mounted) return;
                            if (response.statusCode == 200) {
                              Navigator.pop(dialogContext, data);
                            } else {
                              setDialogState(() {
                                error =
                                    data['error']?.toString() ??
                                    'Der Code konnte nicht geprüft werden.';
                                submitting = false;
                              });
                            }
                          } catch (_) {
                            if (dialogContext.mounted) {
                              setDialogState(() {
                                error = 'Keine Verbindung zum Server.';
                                submitting = false;
                              });
                            }
                          }
                        },
                  child: submitting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Bestätigen'),
                ),
            ],
          );
        },
      ),
    );
  } finally {
    dialogClosed = true;
    passkeys?.close();
    code.dispose();
  }
}

Future<Map<String, dynamic>?> setupMfa(
  BuildContext context, {
  required String token,
  required String currentPassword,
}) async {
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  late http.Response setupResponse;
  try {
    setupResponse = await http.post(
      Uri.parse('$apiBaseUrl/api/users/me/mfa/setup'),
      headers: headers,
      body: jsonEncode({'currentPassword': currentPassword}),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Verbindung zum Server.')),
      );
    }
    return null;
  }
  final setup = _object(setupResponse);
  if (setupResponse.statusCode != 200) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            setup['error']?.toString() ??
                '2-FA konnte nicht vorbereitet werden.',
          ),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;

  final code = TextEditingController();
  String? error;
  var submitting = false;
  Map<String, dynamic>? confirmed;
  try {
    confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Authenticator-App einrichten'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Scannen Sie den QR-Code mit Ihrer Authenticator-App. '
                    'Alternativ können Sie den Schlüssel manuell eingeben.',
                  ),
                  const SizedBox(height: 16),
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(12),
                    child: bw.BarcodeWidget(
                      barcode: bw.Barcode.qrCode(),
                      data: setup['provisioningUri'].toString(),
                      width: 220,
                      height: 220,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    setup['secret'].toString(),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: setup['secret'].toString()),
                    ),
                    icon: const Icon(Icons.copy),
                    label: const Text('Schlüssel kopieren'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: code,
                    autofocus: true,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Aktueller sechsstelliger Code',
                      errorText: error,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      setDialogState(() {
                        submitting = true;
                        error = null;
                      });
                      try {
                        final response = await http.post(
                          Uri.parse('$apiBaseUrl/api/users/me/mfa/confirm'),
                          headers: headers,
                          body: jsonEncode({'code': code.text.trim()}),
                        );
                        final data = _object(response);
                        if (!dialogContext.mounted) return;
                        if (response.statusCode == 200) {
                          Navigator.pop(dialogContext, data);
                        } else {
                          setDialogState(() {
                            error =
                                data['error']?.toString() ??
                                'Der Code ist ungültig.';
                            submitting = false;
                          });
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            error = 'Keine Verbindung zum Server.';
                            submitting = false;
                          });
                        }
                      }
                    },
              child: const Text('Aktivieren'),
            ),
          ],
        ),
      ),
    );
  } finally {
    code.dispose();
  }
  if (confirmed == null || !context.mounted) return null;
  final recoveryCodes = (confirmed['recoveryCodes'] as List? ?? const [])
      .map((entry) => entry.toString())
      .toList();
  await showRecoveryCodes(context, recoveryCodes);
  return confirmed;
}

Future<void> showRecoveryCodes(
  BuildContext context,
  List<String> recoveryCodes,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Wiederherstellungscodes sichern'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Jeder Code ist nur einmal verwendbar. Bewahren Sie diese '
            'Codes getrennt von Ihrem Passwort sicher auf. Sie werden '
            'später nicht erneut angezeigt.',
          ),
          const SizedBox(height: 16),
          SelectableText(
            recoveryCodes.join('\n'),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton.icon(
        onPressed: () =>
            Clipboard.setData(ClipboardData(text: recoveryCodes.join('\n'))),
        icon: const Icon(Icons.copy),
        label: const Text('Codes kopieren'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Ich habe die Codes gesichert'),
      ),
    ],
  ),
);
