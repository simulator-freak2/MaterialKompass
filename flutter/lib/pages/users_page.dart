import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../widgets/qr_login_dialog.dart';

class UsersPage extends StatefulWidget {
  final String token;
  const UsersPage({required this.token, super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final searchController = TextEditingController();
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> roles = [];
  List<Map<String, dynamic>> departments = [];
  List<Map<String, dynamic>> scannerEmailAddresses = [];
  List<Map<String, dynamic>> mailTemplates = [];
  List<String> scannerEmailDestinations = [];
  String scannerEmailDomain = 'materialkompass.org';
  bool isAdmin = false;
  bool loading = true;

  Map<String, String> get headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      };

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final query = Uri.encodeQueryComponent(searchController.text.trim());
    final responses = await Future.wait([
      http.get(Uri.parse('$apiBaseUrl/api/users?search=$query'),
          headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/roles'), headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/departments'), headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/scanner-email-addresses'),
          headers: headers),
      http.get(Uri.parse('$apiBaseUrl/api/mail/templates'), headers: headers),
    ]);
    if (!mounted) return;
    if (responses.take(3).any((response) => response.statusCode != 200)) {
      _message('Nutzerverwaltung konnte nicht geladen werden.');
    } else {
      users = (jsonDecode(responses[0].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      roles = (jsonDecode(responses[1].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      departments = (jsonDecode(responses[2].body) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      isAdmin = responses[3].statusCode == 200;
      if (isAdmin) {
        final scannerData =
            Map<String, dynamic>.from(jsonDecode(responses[3].body) as Map);
        scannerEmailDomain =
            scannerData['domain']?.toString() ?? scannerEmailDomain;
        scannerEmailDestinations =
            ((scannerData['destinations'] as List?) ?? const [])
                .map((entry) => entry.toString())
                .toList();
        scannerEmailAddresses =
            ((scannerData['addresses'] as List?) ?? const [])
                .cast<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList();
        if (responses[4].statusCode == 200) {
          mailTemplates = (jsonDecode(responses[4].body) as List)
              .cast<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList();
        }
      }
    }
    setState(() => loading = false);
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _send(String method, String path,
      [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$apiBaseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    late http.Response response;
    if (method == 'POST') {
      response = await http.post(uri, headers: headers, body: encoded);
    }
    if (method == 'PUT') {
      response = await http.put(uri, headers: headers, body: encoded);
    }
    if (method == 'DELETE') {
      response = await http.delete(uri, headers: headers, body: encoded);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    final data = response.body.isEmpty ? {} : jsonDecode(response.body);
    _message(data['error']?.toString() ?? 'Aktion fehlgeschlagen.');
    return false;
  }

  Future<void> editUser([Map<String, dynamic>? user]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => UserDialog(
          user: user,
          roles: roles.map((role) => role['name'].toString()).toList(),
          departments: departments,
          mailTemplates: mailTemplates),
    );
    if (result == null) return;
    final ok = await _send(user == null ? 'POST' : 'PUT',
        user == null ? '/api/users' : '/api/users/${user['id']}', result);
    if (ok) {
      _message(user == null
          ? 'Nutzer wurde angelegt; E-Mails zur Bestätigung und Passwortvergabe wurden versendet.'
          : 'Nutzer wurde aktualisiert.');
      await load();
    }
  }

  Future<void> sendPasswordReset(Map<String, dynamic> user) async {
    final message = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => AccountMessageDialog(
        title: 'Passwort-Reset senden',
        description:
            'Die Standardmail enthält weiterhin den sicheren Reset-Link. Optional können Sie eine individuelle Nachricht ergänzen.',
        templates: mailTemplates
            .where((entry) =>
                entry['purpose'] == 'general' ||
                entry['purpose'] == 'password-reset')
            .toList(),
      ),
    );
    if (message == null) return;
    if (await _send('POST', '/api/users/${user['id']}/password-reset', {
      if (message.isNotEmpty) 'mailMessage': message,
    })) {
      _message('Reset-E-Mail wurde angefordert.');
    }
  }

  Future<void> editMailTemplate([Map<String, dynamic>? template]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => MailTemplateDialog(template: template),
    );
    if (result == null) return;
    final ok = await _send(
      template == null ? 'POST' : 'PUT',
      template == null
          ? '/api/mail/templates'
          : '/api/mail/templates/${template['id']}',
      result,
    );
    if (ok) {
      _message(template == null
          ? 'Mailvorlage wurde angelegt.'
          : 'Mailvorlage wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteMailTemplate(Map<String, dynamic> template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Mailvorlage löschen?'),
        content: Text('„${template['name']}“ wird dauerhaft gelöscht.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send('DELETE', '/api/mail/templates/${template['id']}')) {
      _message('Mailvorlage wurde gelöscht.');
      await load();
    }
  }

  Future<void> composeIndividualMail() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => IndividualMailDialog(
        templates: mailTemplates,
        users: users,
      ),
    );
    if (result == null) return;
    if (await _send('POST', '/api/mail/send', result)) {
      _message('E-Mail wurde an den Mailserver übergeben.');
    }
  }

  Future<void> deleteUser(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Account endgültig löschen?'),
              content: Text(
                  '${user['name']} wird unwiderruflich aus der Nutzerverwaltung gelöscht.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Abbrechen')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Löschen'))
              ],
            ));
    if (confirmed == true &&
        await _send('DELETE', '/api/users/${user['id']}')) {
      await load();
    }
  }

  Future<void> confirmEmailManually(Map<String, dynamic> user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('E-Mail-Adresse manuell bestätigen?'),
        content: Text(
          'Die Adresse ${user['email']} wird ohne Prüfung eines Bestätigungslinks als bestätigt markiert. Offene Bestätigungslinks werden ungültig.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Manuell bestätigen'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (await _send(
      'POST',
      '/api/users/${user['id']}/verification/confirm',
    )) {
      _message('E-Mail-Adresse wurde manuell bestätigt.');
      await load();
    }
  }

  Future<bool> createQrLogin(Map<String, dynamic> user) async {
    final validity = await chooseQrLoginValidity(context);
    if (validity == null || !mounted) return false;
    final response = await http.post(
      Uri.parse('$apiBaseUrl/api/users/${user['id']}/qr-credential'),
      headers: headers,
      body: jsonEncode(validity.toJson()),
    );
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (!mounted) return false;
    if (response.statusCode != 201) {
      _message(
          data['error']?.toString() ?? 'QR-Code konnte nicht erstellt werden.');
      return false;
    }
    await showQrLoginCode(
      context,
      qrValue: data['qrValue'].toString(),
      expiresAt: data['expiresAt'] == null
          ? null
          : DateTime.parse(data['expiresAt'].toString()),
      accountLabel: user['name']?.toString() ?? user['username'].toString(),
      oneTime: data['oneTime'] != false,
    );
    return true;
  }

  Future<List<Map<String, dynamic>>> loadUserQrLogins(
      Map<String, dynamic> user) async {
    final response = await http.get(
      Uri.parse('$apiBaseUrl/api/users/${user['id']}/qr-credentials'),
      headers: headers,
    );
    if (response.statusCode != 200) {
      final data = response.body.isEmpty ? {} : jsonDecode(response.body);
      _message(data['error']?.toString() ??
          'Anmeldecodes konnten nicht geladen werden.');
      return [];
    }
    return (jsonDecode(response.body) as List)
        .cast<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList();
  }

  Future<void> manageQrLogins(Map<String, dynamic> user) async {
    final credentials = await loadUserQrLogins(user);
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Anmeldecodes für ${user['name'] ?? user['username']}'),
          content: SizedBox(
            width: 520,
            child: credentials.isEmpty
                ? const Text('Keine aktiven Anmeldecodes.')
                : ListView(
                    shrinkWrap: true,
                    children: credentials
                        .map(
                          (credential) => ListTile(
                            leading: const Icon(Icons.qr_code_2),
                            title: Text(credential['title'].toString()),
                            subtitle: Text(
                              '${qrCredentialExpiryLabel(credential['expiresAt'])} · '
                              '${credential['oneTime'] == false ? 'Mehrfach verwendbar' : 'Einmal verwendbar'}',
                            ),
                            trailing: IconButton(
                              tooltip: 'Anmeldecode deaktivieren',
                              icon: const Icon(Icons.block),
                              onPressed: () async {
                                final response = await http.delete(
                                  Uri.parse(
                                    '$apiBaseUrl/api/users/${user['id']}/qr-credentials/${credential['id']}',
                                  ),
                                  headers: headers,
                                );
                                if (!mounted || !dialogContext.mounted) return;
                                if (response.statusCode == 204) {
                                  setDialogState(
                                    () => credentials.removeWhere(
                                      (entry) =>
                                          entry['id'] == credential['id'],
                                    ),
                                  );
                                  _message('Anmeldecode wurde deaktiviert.');
                                } else {
                                  final data = response.body.isEmpty
                                      ? {}
                                      : jsonDecode(response.body);
                                  _message(data['error']?.toString() ??
                                      'Deaktivierung fehlgeschlagen.');
                                }
                              },
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Schließen'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, 'create'),
              icon: const Icon(Icons.add),
              label: const Text('Neuen Code erstellen'),
            ),
          ],
        ),
      ),
    );
    if (action == 'create' && await createQrLogin(user) && mounted) {
      await manageQrLogins(user);
    }
  }

  List<String> get allPermissions {
    final allPermissions = roles
        .expand((role) => (role['permissions'] as List? ?? const []))
        .map((e) => e.toString())
        .toSet()
        .toList()
      ..sort();
    return allPermissions;
  }

  Future<void> editRole([Map<String, dynamic>? role]) async {
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => RoleDialog(
              permissions: allPermissions,
              role: role,
            ));
    if (result == null) return;
    final ok = await _send(
      role == null ? 'POST' : 'PUT',
      role == null ? '/api/roles' : '/api/roles/${role['id']}',
      result,
    );
    if (ok) {
      _message(
          role == null ? 'Rolle wurde angelegt.' : 'Rolle wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteRole(Map<String, dynamic> role) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rolle löschen?'),
        content: Text(
            'Die Rolle „${role['name']}“ wird dauerhaft gelöscht. Zugewiesene oder geschützte Rollen können nicht gelöscht werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send('DELETE', '/api/roles/${role['id']}')) {
      _message('Rolle wurde gelöscht.');
      await load();
    }
  }

  Future<void> editDepartment([Map<String, dynamic>? department]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => DepartmentDialog(department: department),
    );
    if (result == null) return;
    final ok = await _send(
      department == null ? 'POST' : 'PUT',
      department == null
          ? '/api/departments'
          : '/api/departments/${department['id']}',
      result,
    );
    if (ok) {
      _message(department == null
          ? 'Fachbereich wurde angelegt.'
          : 'Fachbereich wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteDepartment(Map<String, dynamic> department) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Fachbereich löschen?'),
        content: Text(
            '„${department['name']}“ wird dauerhaft gelöscht. Zugewiesene Fachbereiche können nur deaktiviert werden.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send('DELETE', '/api/departments/${department['id']}')) {
      _message('Fachbereich wurde gelöscht.');
      await load();
    }
  }

  Future<void> editScannerEmail([Map<String, dynamic>? address]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ScannerEmailDialog(
        address: address,
        domain: scannerEmailDomain,
        destinations: scannerEmailDestinations,
      ),
    );
    if (result == null) return;
    if (address == null) {
      final response = await http.post(
        Uri.parse('$apiBaseUrl/api/scanner-email-addresses'),
        headers: headers,
        body: jsonEncode(result),
      );
      final data = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (!mounted) return;
      if (response.statusCode != 201) {
        _message(data['error']?.toString() ??
            'Das Postfach konnte nicht angelegt werden.');
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MailboxCredentialsDialog(credentials: data),
      );
      if (mounted) await load();
      return;
    }

    final ok = await _send(
      'PUT',
      '/api/scanner-email-addresses/${address['id']}',
      result,
    );
    if (ok) {
      _message('Scanner-Postfach wurde aktualisiert.');
      await load();
    }
  }

  Future<void> deleteScannerEmail(Map<String, dynamic> address) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Scanner-E-Mail-Adresse löschen?'),
        content: Text(
            '${address['email']} wird aus MaterialKompass entfernt. Das echte '
            'Postfach und vorhandene E-Mails bleiben auf dem Mailserver erhalten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Löschen')),
        ],
      ),
    );
    if (confirmed == true &&
        await _send(
            'DELETE', '/api/scanner-email-addresses/${address['id']}')) {
      _message('Scanner-E-Mail-Adresse wurde gelöscht.');
      await load();
    }
  }

  Future<void> showMailboxCredentials(Map<String, dynamic> address) async {
    final passwordController = TextEditingController();
    final adminPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Scanner-Passwort anzeigen'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Bitte bestätigen Sie die Anzeige mit Ihrem aktuellen '
            'MaterialKompass-Passwort.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'MaterialKompass-Passwort',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              if (value.isNotEmpty) Navigator.pop(dialogContext, value);
            },
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              if (passwordController.text.isNotEmpty) {
                Navigator.pop(dialogContext, passwordController.text);
              }
            },
            child: const Text('Zugangsdaten anzeigen'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    if (adminPassword == null || !mounted) return;

    final response = await http.post(
      Uri.parse(
        '$apiBaseUrl/api/scanner-email-addresses/${address['id']}/credentials',
      ),
      headers: headers,
      body: jsonEncode({'password': adminPassword}),
    );
    final data = response.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (!mounted) return;
    if (response.statusCode != 200) {
      _message(data['error']?.toString() ??
          'Die Zugangsdaten konnten nicht geladen werden.');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => MailboxCredentialsDialog(credentials: data),
    );
  }

  Widget scannerEmailTab() => Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Hier werden echte Postfächer auf dem Mailserver angelegt. '
                          'Die verschlüsselt gespeicherten Zugangsdaten können von '
                          'Admins nach erneuter Passwortbestätigung angezeigt werden.',
                        ),
                      ),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => editScannerEmail(),
                icon: const Icon(Icons.add),
                label: const Text('Scanner-Postfach anlegen'),
              ),
            ),
          ]),
        ),
        Expanded(
          child: scannerEmailAddresses.isEmpty
              ? const Center(
                  child: Text('Noch keine Scanner-Postfächer angelegt.'))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: scannerEmailAddresses
                      .map((address) => Card(
                            child: ListTile(
                              leading: Icon(address['active'] == false
                                  ? Icons.mark_email_unread_outlined
                                  : Icons.mark_email_read_outlined),
                              title: Text(address['email'].toString()),
                              subtitle: Text(
                                '${address['name']} · Ziel: ${address['destination']} · '
                                '${address['active'] == false ? 'Deaktiviert' : 'Aktiv'}',
                              ),
                              trailing: Wrap(children: [
                                IconButton(
                                  tooltip: 'Zugangsdaten anzeigen',
                                  onPressed: () =>
                                      showMailboxCredentials(address),
                                  icon: const Icon(Icons.key),
                                ),
                                IconButton(
                                  tooltip: 'Adresse kopieren',
                                  onPressed: () async {
                                    await Clipboard.setData(ClipboardData(
                                        text: address['email'].toString()));
                                    if (mounted) {
                                      _message('E-Mail-Adresse wurde kopiert.');
                                    }
                                  },
                                  icon: const Icon(Icons.copy),
                                ),
                                IconButton(
                                  tooltip: 'Bearbeiten',
                                  onPressed: () => editScannerEmail(address),
                                  icon: const Icon(Icons.edit),
                                ),
                                IconButton(
                                  tooltip: 'Löschen',
                                  onPressed: () => deleteScannerEmail(address),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ]),
                            ),
                          ))
                      .toList(),
                ),
        ),
      ]);

  String date(Object? value) {
    if (value == null) return '—';
    final parsed = DateTime.tryParse(value.toString())?.toLocal();
    return parsed == null
        ? '—'
        : '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}';
  }

  String dateTime(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return '—';
    final datePart =
        '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year}';
    final timePart =
        '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    return '$datePart $timePart Uhr';
  }

  bool verificationCanBeResent(Map<String, dynamic> user) {
    if (user['active'] != true || user['emailVerifiedAt'] != null) return false;
    final availableAt = DateTime.tryParse(
        user['verificationResendAvailableAt']?.toString() ?? '');
    return availableAt == null || !availableAt.isAfter(DateTime.now());
  }

  String verificationStatus(Map<String, dynamic> user) {
    if (user['emailVerifiedAt'] != null) return 'E-Mail bestätigt';
    final availableAt = DateTime.tryParse(
        user['verificationResendAvailableAt']?.toString() ?? '');
    if (availableAt == null || !availableAt.isAfter(DateTime.now())) {
      return 'E-Mail unbestätigt · erneuter Versand möglich';
    }
    return 'E-Mail unbestätigt · erneut ab ${dateTime(availableAt)}';
  }

  String mailPurposeLabel(Object? value) => switch (value) {
        'user-create' => 'Nutzeranlage',
        'password-reset' => 'Passwort-Reset',
        _ => 'Allgemein',
      };

  String placementLabel(Object? value) => switch (value) {
        'before-content' => 'Vor dem Standardtext',
        'after-action' => 'Nach dem Aktionsbutton',
        _ => 'Vor dem Aktionsbutton',
      };

  Widget mailTab() => Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const Icon(Icons.info_outline),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Individuelle Nachrichten unterstützen Markdown oder bereinigtes HTML. '
                      'Standardvorlagen werden automatisch bei Nutzeranlage oder Passwort-Reset verwendet, sofern im Vorgang keine andere Nachricht gewählt wird.',
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: composeIndividualMail,
                  icon: const Icon(Icons.send),
                  label: const Text('Individuelle E-Mail senden'),
                ),
                FilledButton.icon(
                  onPressed: () => editMailTemplate(),
                  icon: const Icon(Icons.add),
                  label: const Text('Vorlage anlegen'),
                ),
              ],
            ),
          ]),
        ),
        Expanded(
          child: mailTemplates.isEmpty
              ? const Center(child: Text('Noch keine Mailvorlagen angelegt.'))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: mailTemplates.map((template) {
                    final defaultFor = template['defaultFor'];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: Text(template['name'].toString()),
                        subtitle: Text(
                          '${mailPurposeLabel(template['purpose'])} · ${template['format'] == 'html' ? 'HTML' : 'Markdown'} · ${placementLabel(template['placement'])}'
                          '${defaultFor == null ? '' : '\nStandard für ${mailPurposeLabel(defaultFor)}'}',
                        ),
                        isThreeLine: defaultFor != null,
                        trailing: Wrap(children: [
                          IconButton(
                            tooltip: 'Vorlage bearbeiten',
                            onPressed: () => editMailTemplate(template),
                            icon: const Icon(Icons.edit),
                          ),
                          IconButton(
                            tooltip: 'Vorlage löschen',
                            onPressed: () => deleteMailTemplate(template),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ]);

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: isAdmin ? 5 : 3,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('Nutzerverwaltung'),
              bottom: TabBar(tabs: [
                const Tab(text: 'Nutzer', icon: Icon(Icons.people)),
                const Tab(
                    text: 'Rollen', icon: Icon(Icons.admin_panel_settings)),
                const Tab(text: 'Fachbereiche', icon: Icon(Icons.account_tree)),
                if (isAdmin)
                  const Tab(text: 'E-Mails', icon: Icon(Icons.mail_outline)),
                if (isAdmin)
                  const Tab(
                      text: 'Scanner-E-Mails',
                      icon: Icon(Icons.document_scanner))
              ])),
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(children: [
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Expanded(
                              child: TextField(
                                  controller: searchController,
                                  onSubmitted: (_) => load(),
                                  decoration: const InputDecoration(
                                      prefixIcon: Icon(Icons.search),
                                      labelText:
                                          'Name, Nutzername oder E-Mail suchen',
                                      border: OutlineInputBorder()))),
                          const SizedBox(width: 12),
                          OutlinedButton(
                              onPressed: load, child: const Text('Suchen')),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                              onPressed: () => editUser(),
                              icon: const Icon(Icons.person_add),
                              label: const Text('Nutzer anlegen')),
                        ])),
                    Expanded(
                        child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: users.length,
                            itemBuilder: (_, index) {
                              final user = users[index];
                              final active = user['active'] == true;
                              return Card(
                                  child: ListTile(
                                leading: CircleAvatar(
                                    child: Icon(active
                                        ? Icons.person
                                        : Icons.person_off)),
                                title: Text((user['name'] ?? '')
                                        .toString()
                                        .trim()
                                        .isEmpty
                                    ? user['username'].toString()
                                    : '${user['name']} (${user['username']})'),
                                subtitle: Text(
                                    '${user['email']} · ${verificationStatus(user)}\n${(user['roles'] as List? ?? const []).join(', ')} · ${active ? 'Aktiv' : 'Deaktiviert'} · Erstellt: ${date(user['createdAt'])} · Letzter Login: ${date(user['lastLoginAt'])}'),
                                isThreeLine: true,
                                trailing: Wrap(children: [
                                  IconButton(
                                      tooltip: 'Anmeldecodes verwalten',
                                      onPressed: active
                                          ? () => manageQrLogins(user)
                                          : null,
                                      icon: const Icon(Icons.qr_code_2)),
                                  IconButton(
                                      tooltip: 'Passwort-Reset senden',
                                      onPressed: () => sendPasswordReset(user),
                                      icon: const Icon(Icons.password)),
                                  IconButton(
                                      tooltip:
                                          'Bestätigungs-E-Mail erneut senden',
                                      onPressed: verificationCanBeResent(user)
                                          ? () async {
                                              if (await _send('POST',
                                                  '/api/users/${user['id']}/verification/resend')) {
                                                _message(
                                                    'Bestätigungs-E-Mail wurde erneut versendet.');
                                                await load();
                                              }
                                            }
                                          : null,
                                      icon:
                                          const Icon(Icons.mark_email_unread)),
                                  IconButton(
                                      tooltip:
                                          'E-Mail-Adresse manuell bestätigen',
                                      onPressed: isAdmin &&
                                              user['emailVerifiedAt'] == null
                                          ? () => confirmEmailManually(user)
                                          : null,
                                      icon: const Icon(Icons.mark_email_read)),
                                  IconButton(
                                      tooltip: 'Bearbeiten',
                                      onPressed: () => editUser(user),
                                      icon: const Icon(Icons.edit)),
                                  IconButton(
                                      tooltip: 'Löschen',
                                      onPressed: () => deleteUser(user),
                                      icon: const Icon(Icons.delete_outline)),
                                ]),
                              ));
                            })),
                  ]),
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton.icon(
                                onPressed: () => editRole(),
                                icon: const Icon(Icons.add),
                                label: const Text('Rolle anlegen')))),
                    Expanded(
                        child: ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: roles
                                .map((role) => Card(
                                    child: ListTile(
                                        title: Text(role['name'].toString()),
                                        subtitle: Text(
                                            '${(role['permissions'] as List? ?? const []).length} Berechtigungen'),
                                        trailing: Wrap(children: [
                                          IconButton(
                                              tooltip: 'Rolle bearbeiten',
                                              onPressed: () => editRole(role),
                                              icon: const Icon(Icons.edit)),
                                          IconButton(
                                              tooltip: 'Rolle löschen',
                                              onPressed: () => deleteRole(role),
                                              icon: const Icon(
                                                  Icons.delete_outline)),
                                        ]))))
                                .toList())),
                  ]),
                  Column(children: [
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          const Expanded(
                              child: Text(
                                  'Zentrale Fachbereiche bilden den Geltungsbereich für Fachbereichsleiter.')),
                          FilledButton.icon(
                              onPressed: () => editDepartment(),
                              icon: const Icon(Icons.add),
                              label: const Text('Fachbereich anlegen')),
                        ])),
                    Expanded(
                        child: ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: departments
                                .map((department) => Card(
                                    child: ListTile(
                                        leading: Icon(
                                            department['active'] == false
                                                ? Icons.account_tree_outlined
                                                : Icons.account_tree),
                                        title:
                                            Text(department['name'].toString()),
                                        subtitle: Text(
                                            '${department['code']} · ${department['active'] == false ? 'Deaktiviert' : 'Aktiv'}'),
                                        trailing: Wrap(children: [
                                          IconButton(
                                              tooltip: 'Fachbereich bearbeiten',
                                              onPressed: () =>
                                                  editDepartment(department),
                                              icon: const Icon(Icons.edit)),
                                          IconButton(
                                              tooltip: 'Fachbereich löschen',
                                              onPressed: () =>
                                                  deleteDepartment(department),
                                              icon: const Icon(
                                                  Icons.delete_outline)),
                                        ]))))
                                .toList())),
                  ]),
                  if (isAdmin) mailTab(),
                  if (isAdmin) scannerEmailTab(),
                ]),
        ),
      );
}

class AccountMessageDialog extends StatefulWidget {
  final String title;
  final String description;
  final List<Map<String, dynamic>> templates;

  const AccountMessageDialog({
    required this.title,
    required this.description,
    required this.templates,
    super.key,
  });

  @override
  State<AccountMessageDialog> createState() => _AccountMessageDialogState();
}

class _AccountMessageDialogState extends State<AccountMessageDialog> {
  final content = TextEditingController();
  String? templateId;
  String format = 'markdown';
  String placement = 'before-action';

  void applyTemplate(String? id) {
    final matches = widget.templates.where((entry) => entry['id'] == id);
    final template = matches.isEmpty ? null : matches.first;
    setState(() {
      templateId = id;
      content.text = template?['content']?.toString() ?? '';
      format = template?['format']?.toString() ?? 'markdown';
      placement = template?['placement']?.toString() ?? 'before-action';
    });
  }

  @override
  void dispose() {
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.description),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String?>(
                    initialValue: templateId,
                    decoration: const InputDecoration(
                      labelText: 'Vorlage (optional)',
                      helperText:
                          'Systemstandard verwendet die als Standard markierte Vorlage.',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('Systemstandard')),
                      ...widget.templates
                          .map((template) => DropdownMenuItem<String?>(
                                value: template['id'].toString(),
                                child: Text(template['name'].toString()),
                              )),
                    ],
                    onChanged: applyTemplate,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: content,
                    minLines: 5,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      labelText: 'Individuelle Nachricht (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(format),
                        initialValue: format,
                        decoration: const InputDecoration(
                            labelText: 'Format', border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'markdown', child: Text('Markdown')),
                          DropdownMenuItem(value: 'html', child: Text('HTML')),
                        ],
                        onChanged: (value) =>
                            setState(() => format = value ?? format),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(placement),
                        initialValue: placement,
                        decoration: const InputDecoration(
                            labelText: 'Position',
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'before-content',
                              child: Text('Vor Standardtext')),
                          DropdownMenuItem(
                              value: 'before-action',
                              child: Text('Vor Aktionsbutton')),
                          DropdownMenuItem(
                              value: 'after-action',
                              child: Text('Nach Aktionsbutton')),
                        ],
                        onChanged: (value) =>
                            setState(() => placement = value ?? placement),
                      ),
                    ),
                  ]),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton.icon(
            onPressed: () => Navigator.pop(
                context,
                content.text.trim().isEmpty
                    ? <String, dynamic>{}
                    : {
                        'content': content.text.trim(),
                        'format': format,
                        'placement': placement,
                      }),
            icon: const Icon(Icons.send),
            label: const Text('E-Mail senden'),
          ),
        ],
      );
}

class IndividualMailDialog extends StatefulWidget {
  final List<Map<String, dynamic>> templates;
  final List<Map<String, dynamic>> users;

  const IndividualMailDialog({
    required this.templates,
    required this.users,
    super.key,
  });

  @override
  State<IndividualMailDialog> createState() => _IndividualMailDialogState();
}

class _IndividualMailDialogState extends State<IndividualMailDialog> {
  final subject = TextEditingController();
  final content = TextEditingController();
  String recipient = '';
  String? templateId;
  String format = 'markdown';

  void applyTemplate(String? id) {
    final matches = widget.templates.where((entry) => entry['id'] == id);
    final template = matches.isEmpty ? null : matches.first;
    setState(() {
      templateId = id;
      subject.text = template?['subject']?.toString() ?? '';
      content.text = template?['content']?.toString() ?? '';
      format = template?['format']?.toString() ?? 'markdown';
    });
  }

  @override
  void dispose() {
    subject.dispose();
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Individuelle E-Mail senden'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(children: [
              Autocomplete<String>(
                optionsBuilder: (value) {
                  final query = value.text.toLowerCase();
                  return widget.users
                      .map((user) => user['email'].toString())
                      .where((email) => email.toLowerCase().contains(query));
                },
                onSelected: (value) => recipient = value,
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Empfängeradresse *',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => recipient = value,
                  );
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: templateId,
                decoration: const InputDecoration(
                    labelText: 'Vorlage (optional)',
                    border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Keine Vorlage')),
                  ...widget.templates
                      .map((template) => DropdownMenuItem<String?>(
                            value: template['id'].toString(),
                            child: Text(template['name'].toString()),
                          )),
                ],
                onChanged: applyTemplate,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: subject,
                decoration: const InputDecoration(
                    labelText: 'Betreff *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: content,
                minLines: 7,
                maxLines: 14,
                decoration: const InputDecoration(
                    labelText: 'Nachricht *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(format),
                initialValue: format,
                decoration: const InputDecoration(
                    labelText: 'Format', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'markdown', child: Text('Markdown')),
                  DropdownMenuItem(value: 'html', child: Text('HTML')),
                ],
                onChanged: (value) => setState(() => format = value ?? format),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton.icon(
            onPressed: () {
              if (recipient.trim().isEmpty ||
                  subject.text.trim().isEmpty ||
                  content.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(context, {
                'to': recipient.trim(),
                'subject': subject.text.trim(),
                'content': content.text.trim(),
                'format': format,
              });
            },
            icon: const Icon(Icons.send),
            label: const Text('Senden'),
          ),
        ],
      );
}

class MailTemplateDialog extends StatefulWidget {
  final Map<String, dynamic>? template;
  const MailTemplateDialog({this.template, super.key});

  @override
  State<MailTemplateDialog> createState() => _MailTemplateDialogState();
}

class _MailTemplateDialogState extends State<MailTemplateDialog> {
  late final name =
      TextEditingController(text: widget.template?['name']?.toString() ?? '');
  late final subject = TextEditingController(
      text: widget.template?['subject']?.toString() ?? '');
  late final content = TextEditingController(
      text: widget.template?['content']?.toString() ?? '');
  late String format = widget.template?['format']?.toString() ?? 'markdown';
  late String purpose = widget.template?['purpose']?.toString() ?? 'general';
  late String placement =
      widget.template?['placement']?.toString() ?? 'before-action';
  late String defaultFor = widget.template?['defaultFor']?.toString() ?? '';

  @override
  void dispose() {
    name.dispose();
    subject.dispose();
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.template == null
            ? 'Mailvorlage anlegen'
            : 'Mailvorlage bearbeiten'),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Column(children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(
                    labelText: 'Vorlagenname *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: subject,
                decoration: const InputDecoration(
                  labelText: 'Betreff (für freie E-Mails)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: content,
                minLines: 7,
                maxLines: 14,
                decoration: const InputDecoration(
                    labelText: 'Nachricht *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: format,
                    decoration: const InputDecoration(
                        labelText: 'Format', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: 'markdown', child: Text('Markdown')),
                      DropdownMenuItem(value: 'html', child: Text('HTML')),
                    ],
                    onChanged: (value) =>
                        setState(() => format = value ?? format),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: purpose,
                    decoration: const InputDecoration(
                        labelText: 'Verwendung', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: 'general', child: Text('Allgemein')),
                      DropdownMenuItem(
                          value: 'user-create', child: Text('Nutzeranlage')),
                      DropdownMenuItem(
                          value: 'password-reset',
                          child: Text('Passwort-Reset')),
                    ],
                    onChanged: (value) => setState(() {
                      purpose = value ?? purpose;
                      if (purpose != 'general' &&
                          defaultFor.isNotEmpty &&
                          defaultFor != purpose) {
                        defaultFor = '';
                      }
                    }),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: placement,
                decoration: const InputDecoration(
                  labelText: 'Position in Konto-E-Mails',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'before-content',
                      child: Text('Vor dem Standardtext')),
                  DropdownMenuItem(
                      value: 'before-action',
                      child: Text('Vor dem Aktionsbutton')),
                  DropdownMenuItem(
                      value: 'after-action',
                      child: Text('Nach dem Aktionsbutton')),
                ],
                onChanged: (value) =>
                    setState(() => placement = value ?? placement),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('$purpose-$defaultFor'),
                initialValue: defaultFor,
                decoration: const InputDecoration(
                  labelText: 'Als Standard verwenden',
                  helperText:
                      'Pro Vorgang kann genau eine Standardvorlage aktiv sein.',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('Nicht als Standard')),
                  if (purpose == 'general' || purpose == 'user-create')
                    const DropdownMenuItem(
                        value: 'user-create', child: Text('Nutzeranlage')),
                  if (purpose == 'general' || purpose == 'password-reset')
                    const DropdownMenuItem(
                        value: 'password-reset', child: Text('Passwort-Reset')),
                ],
                onChanged: (value) =>
                    setState(() => defaultFor = value ?? defaultFor),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty || content.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(context, {
                'name': name.text.trim(),
                'subject': subject.text.trim(),
                'content': content.text.trim(),
                'format': format,
                'purpose': purpose,
                'placement': placement,
                'defaultFor': defaultFor.isEmpty ? null : defaultFor,
              });
            },
            child: const Text('Speichern'),
          ),
        ],
      );
}

class ScannerEmailDialog extends StatefulWidget {
  final Map<String, dynamic>? address;
  final String domain;
  final List<String> destinations;

  const ScannerEmailDialog({
    required this.address,
    required this.domain,
    required this.destinations,
    super.key,
  });

  @override
  State<ScannerEmailDialog> createState() => _ScannerEmailDialogState();
}

class _ScannerEmailDialogState extends State<ScannerEmailDialog> {
  late final TextEditingController localPart = TextEditingController(
      text: widget.address?['localPart']?.toString() ?? '');
  late final TextEditingController name =
      TextEditingController(text: widget.address?['name']?.toString() ?? '');
  late String destination = widget.address?['destination']?.toString() ??
      (widget.destinations.isEmpty ? 'Mängel' : widget.destinations.first);
  late bool active = widget.address?['active'] != false;

  @override
  void dispose() {
    localPart.dispose();
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.address == null
            ? 'Scanner-Postfach anlegen'
            : 'Scanner-Postfach bearbeiten'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: localPart,
              enabled: widget.address == null,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Adresse *',
                suffixText: '@${widget.domain}',
                helperText: widget.address == null
                    ? 'Zum Beispiel „scanner-geraetehaus“'
                    : 'Die Adresse kann nachträglich nicht geändert werden.',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Bezeichnung *',
                hintText: 'Zum Beispiel Mängelscanner',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: destination,
              decoration: const InputDecoration(
                labelText: 'Zielbereich *',
                border: OutlineInputBorder(),
              ),
              items: widget.destinations
                  .map((entry) =>
                      DropdownMenuItem(value: entry, child: Text(entry)))
                  .toList(),
              onChanged: (value) =>
                  setState(() => destination = value ?? destination),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Adresse aktiv'),
              value: active,
              onChanged: (value) => setState(() => active = value),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () {
              if (localPart.text.trim().isEmpty || name.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(context, {
                if (widget.address == null) 'localPart': localPart.text.trim(),
                'name': name.text.trim(),
                'destination': destination,
                'active': active,
              });
            },
            child: const Text('Speichern'),
          ),
        ],
      );
}

class MailboxCredentialsDialog extends StatelessWidget {
  final Map<String, dynamic> credentials;

  const MailboxCredentialsDialog({required this.credentials, super.key});

  String get configuration => [
        'E-Mail/Benutzername: ${credentials['email']}',
        'Passwort: ${credentials['initialPassword']}',
        'SMTP-Server: ${credentials['mailServer']}',
        'SMTP-Port: ${credentials['smtpPort']} (STARTTLS)',
        'IMAP-Server: ${credentials['mailServer']}',
        'IMAP-Port: ${credentials['imapPort']} (TLS)',
      ].join('\n');

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Postfach wurde angelegt'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Das Passwort ist verschlüsselt gespeichert. Bewahren Sie die '
              'Zugangsdaten geschützt auf und hinterlegen Sie sie am Scanner.',
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SelectableText(configuration),
            ),
          ]),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: configuration));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Zugangsdaten wurden kopiert.')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Zugangsdaten kopieren'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Ich habe die Daten gespeichert'),
          ),
        ],
      );
}

class UserDialog extends StatefulWidget {
  final Map<String, dynamic>? user;
  final List<String> roles;
  final List<Map<String, dynamic>> departments;
  final List<Map<String, dynamic>> mailTemplates;
  const UserDialog(
      {required this.user,
      required this.roles,
      this.departments = const [],
      this.mailTemplates = const [],
      super.key});
  @override
  State<UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<UserDialog> {
  late final name =
      TextEditingController(text: widget.user?['name']?.toString());
  late final username =
      TextEditingController(text: widget.user?['username']?.toString());
  late final email =
      TextEditingController(text: widget.user?['email']?.toString());
  final password = TextEditingController();
  final mailMessage = TextEditingController();
  String mailFormat = 'markdown';
  String mailPlacement = 'before-action';
  String? selectedTemplateId;
  late bool active = widget.user?['active'] != false;
  late Set<String> selectedRoles =
      ((widget.user?['roles'] as List?)?.map((e) => e.toString()).toSet()) ??
          {'Nutzer'};
  late Set<String> selectedDepartmentIds =
      ((widget.user?['departmentIds'] as List?)
              ?.map((e) => e.toString())
              .toSet()) ??
          {};

  List<Map<String, dynamic>> get availableTemplates => widget.mailTemplates
      .where((entry) =>
          entry['purpose'] == 'general' || entry['purpose'] == 'user-create')
      .toList();

  void applyTemplate(String? id) {
    setState(() {
      selectedTemplateId = id;
      final matches = availableTemplates.where((entry) => entry['id'] == id);
      final template = matches.isEmpty ? null : matches.first;
      if (template != null) {
        mailMessage.text = template['content']?.toString() ?? '';
        mailFormat = template['format']?.toString() ?? 'markdown';
        mailPlacement = template['placement']?.toString() ?? 'before-action';
      } else {
        mailMessage.clear();
      }
    });
  }

  @override
  void dispose() {
    name.dispose();
    username.dispose();
    email.dispose();
    password.dispose();
    mailMessage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title:
            Text(widget.user == null ? 'Nutzer anlegen' : 'Nutzer bearbeiten'),
        content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name')),
              TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: 'Nutzername *')),
              TextField(
                  controller: email,
                  decoration: const InputDecoration(labelText: 'E-Mail *')),
              if (widget.user == null) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String?>(
                  initialValue: selectedTemplateId,
                  decoration: const InputDecoration(
                    labelText: 'Mailvorlage (optional)',
                    helperText:
                        'Ohne Auswahl wird die hinterlegte Standardvorlage verwendet.',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Systemstandard'),
                    ),
                    ...availableTemplates
                        .map((template) => DropdownMenuItem<String?>(
                              value: template['id'].toString(),
                              child: Text(template['name'].toString()),
                            )),
                  ],
                  onChanged: applyTemplate,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: mailMessage,
                  minLines: 4,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    labelText: 'Individuelle Nachricht (optional)',
                    hintText:
                        'Diese Nachricht wird in die Konto-E-Mails eingefügt.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(mailFormat),
                      isExpanded: true,
                      initialValue: mailFormat,
                      decoration: const InputDecoration(
                        labelText: 'Format',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'markdown', child: Text('Markdown')),
                        DropdownMenuItem(value: 'html', child: Text('HTML')),
                      ],
                      onChanged: (value) =>
                          setState(() => mailFormat = value ?? mailFormat),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(mailPlacement),
                      isExpanded: true,
                      initialValue: mailPlacement,
                      decoration: const InputDecoration(
                        labelText: 'Position',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'before-content',
                            child: Text('Vor Standardtext')),
                        DropdownMenuItem(
                            value: 'before-action',
                            child: Text('Vor Aktionsbutton')),
                        DropdownMenuItem(
                            value: 'after-action',
                            child: Text('Nach Aktionsbutton')),
                      ],
                      onChanged: (value) => setState(
                          () => mailPlacement = value ?? mailPlacement),
                    ),
                  ),
                ]),
              ],
              if (widget.user != null)
                TextField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: 'Neues Passwort (optional)',
                        helperText:
                            'Mind. 12 Zeichen, Groß-/Kleinbuchstabe, Zahl, Sonderzeichen')),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Rollen',
                      style: Theme.of(context).textTheme.titleSmall)),
              ...widget.roles.map((role) => CheckboxListTile(
                  dense: true,
                  value: selectedRoles.contains(role),
                  title: Text(role),
                  onChanged: (value) => setState(() {
                        if (value == true) {
                          selectedRoles.add(role);
                        } else {
                          selectedRoles.remove(role);
                        }
                      }))),
              const SizedBox(height: 12),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Geleitete Fachbereiche',
                      style: Theme.of(context).textTheme.titleSmall)),
              if (widget.departments.isEmpty)
                const ListTile(
                    dense: true,
                    title: Text('Noch keine Fachbereiche angelegt.'))
              else
                ...widget.departments.map((department) => CheckboxListTile(
                    dense: true,
                    value: selectedDepartmentIds.contains(department['id']),
                    title: Text(department['name'].toString()),
                    subtitle: Text(department['code'].toString()),
                    enabled: department['active'] != false,
                    onChanged: (value) => setState(() {
                          if (value == true) {
                            selectedDepartmentIds
                                .add(department['id'].toString());
                          } else {
                            selectedDepartmentIds
                                .remove(department['id'].toString());
                          }
                        }))),
              SwitchListTile(
                  value: active,
                  title: const Text('Account aktiv'),
                  onChanged: (value) => setState(() => active = value)),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () {
                final result = <String, dynamic>{
                  'name': name.text,
                  'username': username.text,
                  'email': email.text,
                  'roles': selectedRoles.toList(),
                  'departmentIds': selectedDepartmentIds.toList(),
                  'active': active
                };
                if (password.text.isNotEmpty) {
                  result['password'] = password.text;
                }
                if (widget.user == null && mailMessage.text.trim().isNotEmpty) {
                  result['mailMessage'] = {
                    'content': mailMessage.text.trim(),
                    'format': mailFormat,
                    'placement': mailPlacement,
                  };
                }
                Navigator.pop(context, result);
              },
              child: const Text('Speichern'))
        ],
      );
}

class DepartmentDialog extends StatefulWidget {
  final Map<String, dynamic>? department;
  const DepartmentDialog({this.department, super.key});

  @override
  State<DepartmentDialog> createState() => _DepartmentDialogState();
}

class _DepartmentDialogState extends State<DepartmentDialog> {
  late final name =
      TextEditingController(text: widget.department?['name']?.toString());
  late final code =
      TextEditingController(text: widget.department?['code']?.toString());
  late bool active = widget.department?['active'] != false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.department == null
            ? 'Fachbereich anlegen'
            : 'Fachbereich bearbeiten'),
        content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration:
                      const InputDecoration(labelText: 'Bezeichnung *')),
              TextField(
                  controller: code,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Kürzel *')),
              SwitchListTile(
                  value: active,
                  title: const Text('Fachbereich aktiv'),
                  onChanged: (value) => setState(() => active = value)),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'name': name.text,
                    'code': code.text,
                    'active': active,
                  }),
              child: const Text('Speichern')),
        ],
      );
}

class RoleDialog extends StatefulWidget {
  final List<String> permissions;
  final Map<String, dynamic>? role;
  const RoleDialog({required this.permissions, this.role, super.key});
  @override
  State<RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends State<RoleDialog> {
  late final name =
      TextEditingController(text: widget.role?['name']?.toString());
  late final selected = (widget.role?['permissions'] as List? ?? const [])
      .map((permission) => permission.toString())
      .toSet();
  @override
  Widget build(BuildContext context) => AlertDialog(
          title:
              Text(widget.role == null ? 'Rolle anlegen' : 'Rolle bearbeiten'),
          content: SizedBox(
              width: 520,
              height: 520,
              child: Column(children: [
                TextField(
                    controller: name,
                    decoration:
                        const InputDecoration(labelText: 'Rollenname *')),
                const SizedBox(height: 8),
                Expanded(
                    child: ListView(
                        children: widget.permissions
                            .map((permission) => CheckboxListTile(
                                dense: true,
                                title: Text(permission),
                                value: selected.contains(permission),
                                onChanged: (value) => setState(() {
                                      if (value == true) {
                                        selected.add(permission);
                                      } else {
                                        selected.remove(permission);
                                      }
                                    })))
                            .toList()))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Abbrechen')),
            FilledButton(
                onPressed: () => Navigator.pop(context,
                    {'name': name.text, 'permissions': selected.toList()}),
                child: Text(widget.role == null ? 'Anlegen' : 'Speichern'))
          ]);
}
