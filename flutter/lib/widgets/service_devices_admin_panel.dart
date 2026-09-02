import 'dart:convert';

import 'package:flutter/material.dart' hide DropdownButtonFormField;
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/app_http_client.dart';
import 'keyboard_dropdown_button_form_field.dart';
import 'qr_login_dialog.dart';

part 'service_device_admin_dialogs.dart';

class ServiceDevicesAdminPanel extends StatefulWidget {
  final String token;
  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> departments;
  const ServiceDevicesAdminPanel({
    required this.token,
    required this.users,
    required this.departments,
    super.key,
  });
  @override
  State<ServiceDevicesAdminPanel> createState() =>
      _ServiceDevicesAdminPanelState();
}

class _ServiceDevicesAdminPanelState extends State<ServiceDevicesAdminPanel> {
  List<Map<String, dynamic>> devices = [];
  List<Map<String, dynamic>> locations = [];
  List<Map<String, dynamic>> offlineClients = [];
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

  void message(String value) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(value)));

  Future<void> load() async {
    setState(() => loading = true);
    final responses = await Future.wait([
      AppHttpClient.get(
        Uri.parse('$apiBaseUrl/api/service-devices'),
        headers: headers,
      ),
      AppHttpClient.get(
        Uri.parse('$apiBaseUrl/api/locations'),
        headers: headers,
      ),
      AppHttpClient.get(
        Uri.parse('$apiBaseUrl/api/offline/clients'),
        headers: headers,
      ),
    ]);
    if (!mounted) return;
    if (responses[0].statusCode == 200) {
      devices = (jsonDecode(responses[0].body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    if (responses[1].statusCode == 200) {
      locations = (jsonDecode(responses[1].body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    if (responses[2].statusCode == 200) {
      offlineClients = (jsonDecode(responses[2].body) as List)
          .cast<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    }
    setState(() => loading = false);
  }

  Future<http.Response> send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    final uri = Uri.parse('$apiBaseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    return switch (method) {
      'POST' => AppHttpClient.post(uri, headers: headers, body: encoded),
      'PUT' => AppHttpClient.put(uri, headers: headers, body: encoded),
      'DELETE' => AppHttpClient.delete(uri, headers: headers, body: encoded),
      _ => throw ArgumentError(method),
    };
  }

  Map<String, dynamic> object(http.Response response) => response.body.isEmpty
      ? {}
      : Map<String, dynamic>.from(jsonDecode(response.body) as Map);

  Future<void> edit([Map<String, dynamic>? device]) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ServiceDeviceDialog(
        device: device,
        users: widget.users,
        departments: widget.departments,
        locations: locations,
      ),
    );
    if (result == null) return;
    final response = await send(
      device == null ? 'POST' : 'PUT',
      device == null
          ? '/api/service-devices'
          : '/api/service-devices/${device['id']}',
      result,
    );
    if (!mounted) return;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return message(
        object(response)['error']?.toString() ??
            'Gerät konnte nicht gespeichert werden.',
      );
    }
    message(
      device == null
          ? 'Dienstgerät wurde angelegt.'
          : 'Dienstgerät wurde aktualisiert.',
    );
    await load();
  }

  Future<String?> textDialog(
    String title,
    String label, {
    bool secret = false,
  }) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: secret,
          onSubmitted: (value) => Navigator.pop(context, value),
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value?.trim();
  }

  Future<void> issueQr(Map<String, dynamic> device) async {
    final label = await textDialog('System-QR-Code anlegen', 'Bezeichnung');
    if (label == null) return;
    final response = await send(
      'POST',
      '/api/service-devices/${device['id']}/qr-credentials',
      {'label': label},
    );
    if (!mounted) return;
    final data = object(response);
    if (response.statusCode != 201) {
      return message(
        data['error']?.toString() ?? 'QR-Code konnte nicht erstellt werden.',
      );
    }
    await showQrLoginCode(
      context,
      qrValue: data['credential'].toString(),
      accountLabel: '${device['name']} · $label',
      oneTime: false,
    );
    await load();
  }

  Future<void> addNfc(Map<String, dynamic> device) async {
    final label = await textDialog('NFC-Karte registrieren', 'Bezeichnung');
    if (label == null) return;
    final credential = await textDialog(
      'NFC-Karte lesen',
      'USB-Kartenleser',
      secret: true,
    );
    if (credential == null) return;
    final response = await send(
      'POST',
      '/api/service-devices/${device['id']}/nfc-factors',
      {'label': label, 'credential': credential},
    );
    if (!mounted) return;
    if (response.statusCode != 201) {
      return message(
        object(response)['error']?.toString() ??
            'NFC-Karte konnte nicht registriert werden.',
      );
    }
    message('NFC-Karte wurde registriert.');
    await load();
  }

  Future<void> addPersonalNfc(Map<String, dynamic> device) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _PersonalNfcDialog(users: widget.users),
    );
    if (result == null) return;
    final response = await send(
      'POST',
      '/api/service-devices/${device['id']}/personal-nfc',
      result,
    );
    if (!mounted) return;
    if (response.statusCode != 201) {
      return message(
        object(response)['error']?.toString() ??
            'Persönliche NFC-Karte konnte nicht registriert werden.',
      );
    }
    message('Persönliche NFC-Karte wurde registriert.');
    await load();
  }

  Future<void> issueOfflineQr(Map<String, dynamic> device) async {
    final allowed = (device['allowedOfflineUserIds'] as List? ?? const [])
        .map((entry) => entry.toString())
        .toSet();
    final users = widget.users
        .where(
          (entry) =>
              entry['active'] == true &&
              allowed.contains(entry['id'].toString()),
        )
        .toList();
    if (users.isEmpty) {
      return message(
        'Zuerst mindestens einen Benutzer für den Offlinezugriff freigeben.',
      );
    }
    var selected = users.first['id'].toString();
    final userId = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Persönlichen Offline-QR-Code ausstellen'),
          content: DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: 'Benutzer'),
            items: users
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry['id'].toString(),
                    child: Text(
                      entry['name']?.toString().trim().isNotEmpty == true
                          ? entry['name'].toString()
                          : entry['username'].toString(),
                    ),
                  ),
                )
                .toList(),
            onChanged: (value) =>
                setDialogState(() => selected = value ?? selected),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Ausstellen'),
            ),
          ],
        ),
      ),
    );
    if (userId == null) return;
    final user = users.firstWhere((entry) => entry['id'].toString() == userId);
    final response =
        await send('POST', '/api/service-devices/${device['id']}/offline-qr', {
          'userId': userId,
          'label':
              user['name']?.toString() ??
              user['username']?.toString() ??
              'Offlinezugang',
        });
    if (!mounted) return;
    final data = object(response);
    if (response.statusCode != 201) {
      return message(
        data['error']?.toString() ??
            'Offline-QR-Code konnte nicht erstellt werden.',
      );
    }
    await showQrLoginCode(
      context,
      qrValue: data['credential'].toString(),
      accountLabel: '${device['name']} · ${data['label']}',
      oneTime: false,
    );
    await load();
  }

  Future<void> removeCredential(String path) async {
    final response = await send('DELETE', path);
    if (!mounted) return;
    if (response.statusCode != 204) {
      return message(
        object(response)['error']?.toString() ??
            'Zugang konnte nicht widerrufen werden.',
      );
    }
    message('Zugang wurde widerrufen.');
    await load();
  }

  String _offlineClientUser(Map<String, dynamic> client) {
    final id = client['userId']?.toString();
    final matches = widget.users.where((entry) => entry['id'].toString() == id);
    if (matches.isEmpty) return id ?? 'Unbekannt';
    final user = matches.first;
    return user['name']?.toString().trim().isNotEmpty == true
        ? user['name'].toString()
        : user['username']?.toString() ?? id ?? 'Unbekannt';
  }

  Future<void> showOfflineClients() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Registrierte Offline-Installationen'),
          content: SizedBox(
            width: 760,
            child: offlineClients.isEmpty
                ? const Text('Noch keine Offline-Installation registriert.')
                : ListView(
                    shrinkWrap: true,
                    children: offlineClients.map((client) {
                      final active = client['active'] == true;
                      return ListTile(
                        leading: Icon(active ? Icons.devices : Icons.block),
                        title: Text(
                          client['name']?.toString() ?? client['id'].toString(),
                        ),
                        subtitle: Text(
                          '${_offlineClientUser(client)} · ${client['platform'] ?? '-'}\n'
                          'Freigabe bis: ${client['leaseExpiresAt'] ?? '-'} · '
                          'Zuletzt online: ${client['lastSeenAt'] ?? '-'}',
                        ),
                        isThreeLine: true,
                        trailing: active
                            ? IconButton(
                                tooltip: 'Offline-Installation widerrufen',
                                icon: const Icon(Icons.block),
                                onPressed: () async {
                                  final response = await send(
                                    'POST',
                                    '/api/offline/clients/${client['id']}/revoke',
                                  );
                                  if (response.statusCode == 200) {
                                    client['active'] = false;
                                    setDialogState(() {});
                                  } else if (context.mounted) {
                                    message(
                                      object(response)['error']?.toString() ??
                                          'Installation konnte nicht widerrufen werden.',
                                    );
                                  }
                                },
                              )
                            : null,
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Schließen'),
            ),
          ],
        ),
      ),
    );
    await load();
  }

  Future<void> addTotp(Map<String, dynamic> device) async {
    final label = await textDialog(
      'TOTP-Berechtigung anlegen',
      'Verantwortliche Person',
    );
    if (label == null) return;
    final response = await send(
      'POST',
      '/api/service-devices/${device['id']}/totp-factors',
      {'label': label},
    );
    if (!mounted) return;
    final data = object(response);
    if (response.statusCode != 201) {
      return message(
        data['error']?.toString() ?? 'TOTP konnte nicht erstellt werden.',
      );
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('TOTP einrichten'),
        content: SizedBox(
          width: 520,
          child: SelectableText(
            'Geheimnis: ${data['secret']}\n\nProvisioning-URI:\n${data['provisioningUri']}\n\nDiese Angaben werden nur einmal angezeigt.',
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Gespeichert'),
          ),
        ],
      ),
    );
    await load();
  }

  Future<void> action(
    Map<String, dynamic> device,
    String action,
    String success,
  ) async {
    final response = await send(
      'POST',
      '/api/service-devices/${device['id']}/$action',
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
        object(response)['error']?.toString() ?? 'Aktion fehlgeschlagen.',
      );
    }
    message(success);
    await load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Dienstgeräte werden einmalig durch einen Admin am Zielgerät aktiviert. MAC-Adressen dienen nur der Dokumentation.',
                ),
              ),
              OutlinedButton.icon(
                onPressed: showOfflineClients,
                icon: const Icon(Icons.offline_bolt),
                label: const Text('Offline-Installationen'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => edit(),
                icon: const Icon(Icons.add),
                label: const Text('Gerät anlegen'),
              ),
            ],
          ),
        ),
        Expanded(
          child: devices.isEmpty
              ? const Center(child: Text('Noch keine Dienstgeräte angelegt.'))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: devices
                      .map(
                        (device) => Card(
                          child: ExpansionTile(
                            leading: Icon(
                              device['active'] == true
                                  ? Icons.devices
                                  : Icons.phonelink_off,
                            ),
                            title: Text(device['name'].toString()),
                            subtitle: Text(
                              '${device['inventoryNumber']} · ${device['locationName']} ${device['room'] ?? ''}\n${device['activated'] == true ? 'Aktiviert' : 'Nicht aktiviert'} · ${device['active'] == true ? 'Freigegeben' : 'Gesperrt'} · Zuletzt online: ${device['lastSeenAt'] ?? '-'}',
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () => edit(device),
                                      icon: const Icon(Icons.edit),
                                      label: const Text('Bearbeiten'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => issueQr(device),
                                      icon: const Icon(Icons.qr_code),
                                      label: const Text('System-QR-Code'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => addNfc(device),
                                      icon: const Icon(Icons.badge),
                                      label: const Text('NFC-Karte'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => addPersonalNfc(device),
                                      icon: const Icon(Icons.person_pin),
                                      label: const Text(
                                        'Persönliche NFC-Karte',
                                      ),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed:
                                          device['offlineEnabled'] == true
                                          ? () => issueOfflineQr(device)
                                          : null,
                                      icon: const Icon(Icons.offline_bolt),
                                      label: const Text('Offline-QR-Code'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => addTotp(device),
                                      icon: const Icon(Icons.password),
                                      label: const Text('TOTP'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: () => action(
                                        device,
                                        'reset-activation',
                                        'Geräteaktivierung wurde zurückgesetzt.',
                                      ),
                                      icon: const Icon(Icons.restart_alt),
                                      label: const Text(
                                        'Aktivierung zurücksetzen',
                                      ),
                                    ),
                                    FilledButton.icon(
                                      onPressed: device['active'] == true
                                          ? () => action(
                                              device,
                                              'revoke',
                                              'Gerät wurde gesperrt.',
                                            )
                                          : null,
                                      icon: const Icon(Icons.block),
                                      label: const Text('Sperren'),
                                    ),
                                  ],
                                ),
                              ),
                              ...((device['qrCredentials'] as List? ?? const [])
                                  .map(
                                    (entry) => ListTile(
                                      leading: const Icon(Icons.qr_code),
                                      title: Text(
                                        'System-QR: ${entry['label']}',
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'QR-Zugang widerrufen',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () => removeCredential(
                                          '/api/service-devices/${device['id']}/qr-credentials/${entry['id']}',
                                        ),
                                      ),
                                    ),
                                  )),
                              ...((device['nfcFactors'] as List? ?? const []).map(
                                (entry) => ListTile(
                                  leading: const Icon(Icons.badge),
                                  title: Text('NFC-Faktor: ${entry['label']}'),
                                  trailing: IconButton(
                                    tooltip: 'NFC-Faktor widerrufen',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => removeCredential(
                                      '/api/service-devices/${device['id']}/second-factors/${entry['id']}',
                                    ),
                                  ),
                                ),
                              )),
                              ...((device['totpFactors'] as List? ?? const []).map(
                                (entry) => ListTile(
                                  leading: const Icon(Icons.password),
                                  title: Text('TOTP: ${entry['label']}'),
                                  trailing: IconButton(
                                    tooltip: 'TOTP widerrufen',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => removeCredential(
                                      '/api/service-devices/${device['id']}/second-factors/${entry['id']}',
                                    ),
                                  ),
                                ),
                              )),
                              ...((device['personalNfcCredentials'] as List? ??
                                      const [])
                                  .map(
                                    (entry) => ListTile(
                                      leading: const Icon(Icons.person_pin),
                                      title: Text(
                                        'Persönliches NFC: ${entry['label']}',
                                      ),
                                      trailing: IconButton(
                                        tooltip:
                                            'Persönlichen NFC-Zugang widerrufen',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () => removeCredential(
                                          '/api/service-devices/${device['id']}/personal-nfc/${entry['id']}',
                                        ),
                                      ),
                                    ),
                                  )),
                              ...((device['offlineQrCredentials'] as List? ??
                                      const [])
                                  .map(
                                    (entry) => ListTile(
                                      leading: const Icon(Icons.offline_bolt),
                                      title: Text(
                                        'Offline-QR: ${entry['label']}',
                                      ),
                                      subtitle: Text(
                                        'Benutzer-ID: ${entry['userId']}',
                                      ),
                                      trailing: IconButton(
                                        tooltip: 'Offline-QR-Code widerrufen',
                                        icon: const Icon(Icons.delete_outline),
                                        onPressed: () => removeCredential(
                                          '/api/service-devices/${device['id']}/offline-qr/${entry['id']}',
                                        ),
                                      ),
                                    ),
                                  )),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
  }
}
