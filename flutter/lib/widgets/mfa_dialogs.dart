import 'dart:async';
import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart' as bw;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/api_client.dart';
import '../services/passkey_service.dart';
import '../services/push_mfa_service.dart';

Map<String, dynamic> _object(http.Response response) {
  if (response.body.isEmpty) return {};
  final decoded = jsonDecode(response.body);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
}

Future<Map<String, dynamic>?> setupPushMfa(
  BuildContext context, {
  required String token,
  required String currentPassword,
  String code = '',
}) async {
  final service = PushMfaService();
  try {
    final pairing = await service.createPairing(
      token: token,
      currentPassword: currentPassword,
      code: code,
    );
    if (!context.mounted) return null;
    var dialogClosed = false;
    unawaited(() async {
      try {
        final result = await service.waitForPairing(pairing);
        if (!dialogClosed && context.mounted) {
          Navigator.of(context, rootNavigator: true).pop(result);
        }
      } on ApiException catch (error) {
        if (!dialogClosed && context.mounted) {
          Navigator.of(
            context,
            rootNavigator: true,
          ).pop(<String, dynamic>{'error': error.message});
        }
      }
    }());
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Authenticator koppeln'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Öffne die separat installierte MaterialKompass Authenticator-App '
                  'und scanne diesen einmaligen Kopplungscode.',
                ),
                const SizedBox(height: 16),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: bw.BarcodeWidget(
                    barcode: bw.Barcode.qrCode(),
                    data: pairing.qrValue,
                    width: 240,
                    height: 240,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Der Code ist fünf Minuten gültig und kann nur einmal verwendet werden.',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Warte auf das gekoppelte Gerät …'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
    dialogClosed = true;
    if (result?['error'] != null && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result!['error'].toString())));
      return null;
    }
    return result;
  } on ApiException catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
    return null;
  } finally {
    service.close();
  }
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
      final matchingCode = started['matchingCode']?.toString() ?? '';
      setDialogState(() {
        pushStatus =
            'Öffne MaterialKompass Authenticator und vergleiche den '
            'zweistelligen Bestätigungscode: $matchingCode';
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
  String activeToken = token;
  Map<String, String> headers() => {
    'Authorization': 'Bearer $activeToken',
    'Content-Type': 'application/json',
  };
  late http.Response setupResponse;
  try {
    setupResponse = await http.post(
      Uri.parse('$apiBaseUrl/api/users/me/mfa/setup'),
      headers: headers(),
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

  final pushService = PushMfaService();
  PushPairing? pairing;
  String? pairingError;
  try {
    pairing = await pushService.createPairing(
      token: token,
      currentPassword: currentPassword,
    );
  } on ApiException catch (exception) {
    pairingError = exception.message;
  }
  if (!context.mounted) {
    pushService.close();
    return null;
  }

  final code = TextEditingController();
  String? error;
  var submitting = false;
  var useMaterialKompassApp = pairing != null;
  var pairingReady = false;
  var dialogClosed = false;
  StateSetter? refreshDialog;
  final combinedQr = pairing == null
      ? null
      : materialKompassEnrollmentUri(
          pairing.qrValue,
          setup['provisioningUri'].toString(),
        );
  if (pairing != null) {
    unawaited(() async {
      try {
        final result = await pushService.waitForPairing(pairing!);
        activeToken = result['token']?.toString() ?? activeToken;
        pairingReady = true;
        if (!dialogClosed) refreshDialog?.call(() {});
      } on ApiException catch (exception) {
        pairingError = exception.message;
        if (!dialogClosed) refreshDialog?.call(() {});
      }
    }());
  }
  Map<String, dynamic>? confirmed;
  try {
    confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          refreshDialog = setDialogState;
          final qrValue = useMaterialKompassApp && combinedQr != null
              ? combinedQr
              : setup['provisioningUri'].toString();
          return AlertDialog(
            title: const Text('Authenticator-App einrichten'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pairing != null)
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.security_outlined),
                            label: Text('MaterialKompass-App'),
                          ),
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.password_outlined),
                            label: Text('Andere App'),
                          ),
                        ],
                        selected: {useMaterialKompassApp},
                        onSelectionChanged: (selection) => setDialogState(
                          () => useMaterialKompassApp = selection.first,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      useMaterialKompassApp && pairing != null
                          ? 'Scannen Sie den QR-Code mit der MaterialKompass '
                                'Authenticator-App. Code-Generierung und '
                                'Push-Bestätigung werden gemeinsam eingerichtet.'
                          : 'Scannen Sie den QR-Code mit Ihrer Authenticator-App. '
                                'Alternativ können Sie den Schlüssel manuell eingeben.',
                    ),
                    const SizedBox(height: 16),
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: bw.BarcodeWidget(
                        barcode: bw.Barcode.qrCode(),
                        data: qrValue,
                        width: 220,
                        height: 220,
                      ),
                    ),
                    if (useMaterialKompassApp && pairing != null) ...[
                      const SizedBox(height: 12),
                      if (pairingReady)
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline),
                            SizedBox(width: 8),
                            Text('Push-Bestätigung gekoppelt'),
                          ],
                        )
                      else if (pairingError == null)
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Warte auf die MaterialKompass-App …'),
                          ],
                        )
                      else
                        Text(
                          pairingError!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                    ],
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
                onPressed: submitting
                    ? null
                    : () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed:
                    submitting || (useMaterialKompassApp && !pairingReady)
                    ? null
                    : () async {
                        setDialogState(() {
                          submitting = true;
                          error = null;
                        });
                        try {
                          final response = await http.post(
                            Uri.parse('$apiBaseUrl/api/users/me/mfa/confirm'),
                            headers: headers(),
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
          );
        },
      ),
    );
  } finally {
    dialogClosed = true;
    pushService.close();
    code.dispose();
  }
  if (confirmed == null || !context.mounted) return null;
  final recoveryCodes = (confirmed['recoveryCodes'] as List? ?? const [])
      .map((entry) => entry.toString())
      .toList();
  await showRecoveryCodes(context, recoveryCodes);
  return confirmed;
}

Future<bool> setupAdditionalMfaCodeDevice(
  BuildContext context, {
  required String token,
  required String currentPassword,
  required String code,
}) async {
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  late http.Response response;
  try {
    response = await http.post(
      Uri.parse('$apiBaseUrl/api/users/me/mfa/code-device'),
      headers: headers,
      body: jsonEncode({'currentPassword': currentPassword, 'code': code}),
    );
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keine Verbindung zum Server.')),
      );
    }
    return false;
  }
  final setup = _object(response);
  if (response.statusCode != 200) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            setup['error']?.toString() ??
                'Das weitere Code-Gerät konnte nicht vorbereitet werden.',
          ),
        ),
      );
    }
    return false;
  }

  final pushService = PushMfaService();
  PushPairing? pairing;
  String? pairingError;
  try {
    pairing = await pushService.createPairing(
      token: token,
      currentPassword: currentPassword,
      code: code,
    );
  } on ApiException catch (exception) {
    pairingError = exception.message;
  }
  if (!context.mounted) {
    pushService.close();
    return false;
  }

  var useMaterialKompassApp = pairing != null;
  var pairingReady = false;
  var dialogClosed = false;
  StateSetter? refreshDialog;
  final combinedQr = pairing == null
      ? null
      : materialKompassEnrollmentUri(
          pairing.qrValue,
          setup['provisioningUri'].toString(),
        );
  if (pairing != null) {
    unawaited(() async {
      try {
        await pushService.waitForPairing(pairing!);
        pairingReady = true;
        if (!dialogClosed) refreshDialog?.call(() {});
      } on ApiException catch (exception) {
        pairingError = exception.message;
        if (!dialogClosed) refreshDialog?.call(() {});
      }
    }());
  }

  bool? completed;
  try {
    completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          refreshDialog = setDialogState;
          final qrValue = useMaterialKompassApp && combinedQr != null
              ? combinedQr
              : setup['provisioningUri'].toString();
          return AlertDialog(
            title: const Text('Weiteres Code-Gerät hinzufügen'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pairing != null)
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: true,
                            icon: Icon(Icons.security_outlined),
                            label: Text('MaterialKompass-App'),
                          ),
                          ButtonSegment(
                            value: false,
                            icon: Icon(Icons.password_outlined),
                            label: Text('Andere App'),
                          ),
                        ],
                        selected: {useMaterialKompassApp},
                        onSelectionChanged: (selection) => setDialogState(
                          () => useMaterialKompassApp = selection.first,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      useMaterialKompassApp && pairing != null
                          ? 'Scannen Sie den QR-Code auf dem zusätzlichen Gerät. '
                                'Die MaterialKompass-App übernimmt Codes und '
                                'Push-Bestätigung gemeinsam.'
                          : 'Scannen Sie den QR-Code auf dem zusätzlichen Gerät. '
                                'Die bereits eingerichteten Geräte bleiben gültig.',
                    ),
                    const SizedBox(height: 16),
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: bw.BarcodeWidget(
                        barcode: bw.Barcode.qrCode(),
                        data: qrValue,
                        width: 220,
                        height: 220,
                      ),
                    ),
                    if (useMaterialKompassApp && pairing != null) ...[
                      const SizedBox(height: 12),
                      if (pairingReady)
                        const Text('Codes und Push-Bestätigung übernommen.')
                      else if (pairingError == null)
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Warte auf das zusätzliche Gerät …'),
                          ],
                        )
                      else
                        Text(
                          pairingError!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                    ],
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
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: useMaterialKompassApp && !pairingReady
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Fertig'),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    dialogClosed = true;
    pushService.close();
  }
  return completed == true;
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
