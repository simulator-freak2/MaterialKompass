import 'package:flutter/material.dart';

import '../services/api_client.dart';
import 'login_page.dart';

class AuthLinkPage extends StatefulWidget {
  final String action;
  final String token;
  const AuthLinkPage({required this.action, required this.token, super.key});
  @override
  State<AuthLinkPage> createState() => _AuthLinkPageState();
}

class _AuthLinkPageState extends State<AuthLinkPage> {
  final api = ApiClient();
  final password = TextEditingController();
  String? message;
  bool loading = false;
  Map<String, dynamic>? invitation;
  bool invitationCompleted = false;
  @override
  void initState() {
    super.initState();
    if (widget.action == 'verify-email') verify();
    if (widget.action == 'membership-invitation') loadInvitation();
  }

  Future<void> loadInvitation() async {
    setState(() => loading = true);
    try {
      final response = await api.get(
        '/api/auth/membership-invitation',
        queryParameters: {'token': widget.token},
      );
      if (mounted) {
        setState(() {
          if (response.statusCode == 200) {
            invitation = response.object;
          } else {
            invitation = null;
            message =
                response.object['error']?.toString() ??
                'Die Einladung konnte nicht geladen werden.';
          }
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> answerInvitation(bool accept) async {
    setState(() => loading = true);
    try {
      final response = await api.post(
        '/api/auth/membership-invitation/confirm',
        body: {'token': widget.token, 'accept': accept},
      );
      if (mounted) {
        setState(() {
          invitationCompleted =
              response.statusCode >= 200 && response.statusCode < 300;
          message =
              (response.object[invitationCompleted ? 'message' : 'error'] ??
                      'Die Einladung konnte nicht verarbeitet werden.')
                  .toString();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> verify() async {
    setState(() => loading = true);
    try {
      final response = await api.get(
        '/api/auth/verify-email',
        queryParameters: {'token': widget.token},
      );
      if (mounted) {
        setState(() {
          message =
              response.object['message']?.toString() ??
              response.object['error']?.toString();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> reset() async {
    setState(() => loading = true);
    try {
      final response = await api.post(
        '/api/auth/password-reset/confirm',
        body: {'token': widget.token, 'password': password.text},
      );
      if (mounted) {
        setState(() {
          message =
              response.object['message']?.toString() ??
              response.object['error']?.toString();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => message = error.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    api.close();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('MaterialKompass')),
    body: SingleChildScrollView(
      child: Center(
        child: Card(
          child: SizedBox(
            width: 430,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.action == 'verify-email'
                        ? 'E-Mail bestätigen'
                        : widget.action == 'membership-invitation'
                        ? 'Organisationszuordnung prüfen'
                        : 'Passwort zurücksetzen',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  if (invitation != null && !invitationCompleted) ...[
                    Text('Einladung von ${invitation!['organization']}'),
                    for (final scope
                        in (invitation!['scopes'] as List? ?? const [])
                            .cast<Map>())
                      ListTile(
                        title: Text(scope['unit'].toString()),
                        subtitle: Text((scope['roles'] as List).join(', ')),
                      ),
                    const Text(
                      'Mit deiner Zustimmung werden diese Bereichsrechte deinem bestehenden Konto hinzugefügt.',
                    ),
                  ],
                  if (widget.action == 'password-reset')
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Neues Passwort',
                        helperText:
                            'Mind. 12 Zeichen, Groß-/Kleinbuchstabe, Zahl und Sonderzeichen',
                      ),
                    ),
                  if (message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(message!, textAlign: TextAlign.center),
                    ),
                  if (loading)
                    const CircularProgressIndicator()
                  else if (invitation != null && !invitationCompleted) ...[
                    FilledButton(
                      onPressed: () => answerInvitation(true),
                      child: const Text('Zustimmen und Rechte aktivieren'),
                    ),
                    TextButton(
                      onPressed: () => answerInvitation(false),
                      child: const Text('Ablehnen'),
                    ),
                  ] else if (widget.action == 'password-reset')
                    FilledButton(
                      onPressed: reset,
                      child: const Text('Passwort speichern'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const LoginPage()),
                    ),
                    child: const Text('Zur Anmeldung'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
