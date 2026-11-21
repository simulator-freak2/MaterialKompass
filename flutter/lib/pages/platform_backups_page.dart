import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/backup_status_card.dart';
import 'login_page.dart';

/// Server-side platform backups of the central administration: weekly check
/// status, manual check, creating a backup and restoring a stored backup.
class PlatformBackupsPage extends StatefulWidget {
  final String token;
  final http.Client? client;

  const PlatformBackupsPage({required this.token, this.client, super.key});

  @override
  State<PlatformBackupsPage> createState() => _PlatformBackupsPageState();
}

class _PlatformBackupsPageState extends State<PlatformBackupsPage> {
  late final http.Client _client = widget.client ?? http.Client();
  List<Map<String, dynamic>> _backups = const [];
  Map<String, dynamic> _status = const {};
  bool _loading = true;
  String? _busy;
  String? _error;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${widget.token}',
    'Content-Type': 'application/json',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.client == null) _client.close();
    super.dispose();
  }

  String _responseError(http.Response response, String fallback) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['error'] != null) return data['error'].toString();
    } on FormatException {
      // Keep the stable fallback for non-JSON proxy responses.
    }
    return fallback;
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _client.get(
        Uri.parse('$apiBaseUrl/api/platform/backups'),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw Exception(
          _responseError(response, 'Sicherungen konnten nicht geladen werden.'),
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _backups = (data['backups'] as List? ?? const [])
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
        _status = Map<String, dynamic>.from(data['status'] as Map? ?? const {});
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<Map<String, String>?> _credentials({
    required String title,
    required String description,
    required String actionLabel,
    String? confirmationText,
  }) => showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _CredentialsDialog(
      title: title,
      description: description,
      actionLabel: actionLabel,
      confirmationText: confirmationText,
    ),
  );

  Future<void> _createBackup() async {
    final credentials = await _credentials(
      title: 'Neue Plattformsicherung erstellen',
      description:
          'Der vollständige Plattformbestand wird verschlüsselt im '
          'Sicherungsverzeichnis des Servers abgelegt. Die Sicherung verlässt '
          'den Server dabei nicht.',
      actionLabel: 'Sicherung erstellen',
    );
    if (credentials == null || !mounted) return;
    setState(() => _busy = 'Sicherung wird erstellt …');
    try {
      final response = await _client.post(
        Uri.parse('$apiBaseUrl/api/platform/backups'),
        headers: _headers,
        body: jsonEncode(credentials),
      );
      if (response.statusCode != 201) {
        _message(
          _responseError(
            response,
            'Die Sicherung konnte nicht erstellt werden.',
          ),
        );
        return;
      }
      _message('Die Plattformsicherung wurde erstellt.');
      await _load();
    } catch (error) {
      _message('Sicherung fehlgeschlagen: $error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _runCheck() async {
    setState(() => _busy = 'Sicherungen werden geprüft …');
    try {
      final response = await _client.post(
        Uri.parse('$apiBaseUrl/api/platform/backups/checks'),
        headers: _headers,
        body: '{}',
      );
      if (response.statusCode != 201) {
        _message(
          _responseError(
            response,
            'Die Prüfung konnte nicht gestartet werden.',
          ),
        );
        return;
      }
      final check = jsonDecode(response.body)['check'] as Map? ?? const {};
      _message(
        'Prüfung abgeschlossen: ${backupStatusLabel(check['status']?.toString())}',
      );
      await _load();
    } catch (error) {
      _message('Prüfung fehlgeschlagen: $error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _acknowledge(String checkId) async {
    final response = await _client.post(
      Uri.parse(
        '$apiBaseUrl/api/platform/backups/checks/${Uri.encodeComponent(checkId)}/acknowledge',
      ),
      headers: _headers,
      body: '{}',
    );
    if (response.statusCode != 204) {
      _message(
        _responseError(response, 'Die Meldung konnte nicht bestätigt werden.'),
      );
      return;
    }
    await _load();
  }

  Future<void> _restore(Map<String, dynamic> backup) async {
    final id = backup['id'].toString();
    final credentials = await _credentials(
      title: 'Sicherung zurückspielen',
      description:
          'Der gesamte aktuelle Plattformbestand – alle Organisationen, Konten, '
          'Rollen, Passkeys und Fachdaten – wird durch den Stand vom '
          '${formatBackupTimestamp(backup['createdAt'])} ersetzt. Änderungen '
          'seit diesem Zeitpunkt gehen verloren. Vorher wird automatisch eine '
          'Sicherheitskopie des aktuellen Stands erstellt. Alle Nutzer müssen '
          'sich danach neu anmelden.',
      actionLabel: 'Zurückspielen',
      confirmationText: 'SICHERUNG $id ZURÜCKSPIELEN',
    );
    if (credentials == null || !mounted) return;
    setState(() => _busy = 'Sicherung wird zurückgespielt …');
    try {
      final response = await _client.post(
        Uri.parse(
          '$apiBaseUrl/api/platform/backups/${Uri.encodeComponent(id)}/restore',
        ),
        headers: _headers,
        body: jsonEncode(credentials),
      );
      if (response.statusCode != 200) {
        _message(
          _responseError(
            response,
            'Die Sicherung konnte nicht zurückgespielt werden.',
          ),
        );
        return;
      }
      if (!mounted) return;
      _message(
        'Die Sicherung wurde zurückgespielt. Bitte melde dich erneut an.',
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } catch (error) {
      _message('Wiederherstellung fehlgeschlagen: $error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  String _reasonLabel(String? reason) => switch (reason) {
    'manual' => 'Manuell',
    'scheduled' => 'Wochensicherung',
    'pre-restore' => 'Vor Wiederherstellung',
    _ => 'Unbekannt',
  };

  String _size(Object? value) {
    final bytes = int.tryParse(value?.toString() ?? '') ?? 0;
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plattformsicherungen'),
        actions: [
          IconButton(
            tooltip: 'Aktualisieren',
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Erneut versuchen'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_busy!),
                  const SizedBox(height: 12),
                ],
                BackupStatusCard(
                  status: _status,
                  showItems: true,
                  onAcknowledge: busy ? null : _acknowledge,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: busy || _status['configured'] != true
                          ? null
                          : _createBackup,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Neue Sicherung erstellen'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _runCheck,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Jetzt prüfen'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  'Gespeicherte Sicherungen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_backups.isEmpty)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text(
                        'Es ist noch keine Plattformsicherung vorhanden.',
                      ),
                    ),
                  )
                else
                  for (final backup in _backups)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.inventory_outlined),
                        title: Text(
                          '${formatBackupTimestamp(backup['createdAt'])} · '
                          '${_reasonLabel(backup['reason']?.toString())}',
                        ),
                        subtitle: Text(
                          [
                            backup['id'],
                            '${backup['recordCount'] ?? '?'} Datensätze',
                            _size(backup['sizeBytes']),
                            if (backup['applicationVersion'] != null &&
                                backup['applicationVersion'] != '')
                              'Version ${backup['applicationVersion']}',
                            if (backup['createdByName'] != null)
                              'von ${backup['createdByName']}',
                          ].join(' · '),
                        ),
                        isThreeLine: true,
                        trailing: TextButton.icon(
                          onPressed: busy ? null : () => _restore(backup),
                          icon: const Icon(Icons.restore),
                          label: const Text('Zurückspielen'),
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

/// Owns its controllers so they outlive the dialog's closing animation.
class _CredentialsDialog extends StatefulWidget {
  final String title;
  final String description;
  final String actionLabel;
  final String? confirmationText;

  const _CredentialsDialog({
    required this.title,
    required this.description,
    required this.actionLabel,
    this.confirmationText,
  });

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  final _password = TextEditingController();
  final _mfaCode = TextEditingController();
  final _confirmation = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _mfaCode.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confirmationText = widget.confirmationText;
    final ready =
        _password.text.isNotEmpty &&
        (confirmationText == null || _confirmation.text == confirmationText);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.description),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Aktuelles Admin-Passwort',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _mfaCode,
                decoration: const InputDecoration(
                  labelText: '2-FA-Code (falls aktiviert)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (confirmationText != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  'Zur Bestätigung exakt eingeben: $confirmationText',
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _confirmation,
                  decoration: const InputDecoration(
                    labelText: 'Bestätigung',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: ready
              ? () => Navigator.pop(context, {
                  'currentPassword': _password.text,
                  'mfaCode': _mfaCode.text.trim(),
                  if (confirmationText != null)
                    'confirmation': _confirmation.text,
                })
              : null,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}
