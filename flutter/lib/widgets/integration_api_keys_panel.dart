import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import '../services/app_http_client.dart';

/// Verwaltung der API-Schlüssel, mit denen Partneranwendungen wie der
/// Übungsplaner Material und Fahrzeuge dieser Ebene lesen.
class IntegrationApiKeysPanel extends StatefulWidget {
  final String token;
  final String baseUrl;

  /// Ersetzbar in Widget-Tests.
  final http.Client? client;

  IntegrationApiKeysPanel({
    required this.token,
    String? baseUrl,
    this.client,
    super.key,
  }) : baseUrl = baseUrl ?? apiBaseUrl;

  @override
  State<IntegrationApiKeysPanel> createState() =>
      _IntegrationApiKeysPanelState();
}

class _IntegrationApiKeysPanelState extends State<IntegrationApiKeysPanel> {
  List<Map<String, dynamic>> keys = [];
  Map<String, String> scopeLabels = const {
    'material:lesen': 'Material lesen',
    'fahrzeuge:lesen': 'Fahrzeuge lesen',
  };
  bool loading = true;
  String? error;

  Map<String, String> get headers => {
    'Authorization': 'Bearer ${widget.token}',
    'Content-Type': 'application/json',
  };

  String get interfaceUrl => '${widget.baseUrl}/api/v1';

  @override
  void initState() {
    super.initState();
    load();
  }

  void message(String value) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(value)));

  Future<http.Response> send(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) {
    final uri = Uri.parse('${widget.baseUrl}$path');
    final encoded = body == null ? null : jsonEncode(body);
    final client = widget.client;
    if (client != null) {
      return switch (method) {
        'GET' => client.get(uri, headers: headers),
        'POST' => client.post(uri, headers: headers, body: encoded),
        'PUT' => client.put(uri, headers: headers, body: encoded),
        'DELETE' => client.delete(uri, headers: headers),
        _ => throw ArgumentError(method),
      };
    }
    return switch (method) {
      'GET' => AppHttpClient.get(uri, headers: headers),
      'POST' => AppHttpClient.post(uri, headers: headers, body: encoded),
      'PUT' => AppHttpClient.put(uri, headers: headers, body: encoded),
      'DELETE' => AppHttpClient.delete(uri, headers: headers),
      _ => throw ArgumentError(method),
    };
  }

  Map<String, dynamic> object(http.Response response) {
    if (response.body.isEmpty) return {};
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on FormatException {
      return {};
    }
  }

  String errorOf(http.Response response, String fallback) =>
      object(response)['error']?.toString() ?? fallback;

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final response = await send('GET', '/api/integration-keys');
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          loading = false;
          error = errorOf(
            response,
            'API-Schlüssel konnten nicht geladen werden.',
          );
        });
        return;
      }
      final data = object(response);
      setState(() {
        keys = ((data['keys'] as List?) ?? const [])
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
        final scopes = (data['scopes'] as List?)?.whereType<Map>();
        if (scopes != null && scopes.isNotEmpty) {
          scopeLabels = {
            for (final scope in scopes)
              scope['id'].toString(): scope['label'].toString(),
          };
        }
        loading = false;
      });
    } on Exception {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'MaterialKompass ist nicht erreichbar.';
      });
    }
  }

  Future<void> create() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => IntegrationApiKeyDialog(scopeLabels: scopeLabels),
    );
    if (result == null) return;
    final response = await send('POST', '/api/integration-keys', result);
    if (!mounted) return;
    if (response.statusCode != 201) {
      return message(
        errorOf(response, 'API-Schlüssel konnte nicht erstellt werden.'),
      );
    }
    await showSecret(object(response));
    await load();
  }

  Future<void> edit(Map<String, dynamic> key) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          IntegrationApiKeyDialog(scopeLabels: scopeLabels, apiKey: key),
    );
    if (result == null) return;
    final response = await send(
      'PUT',
      '/api/integration-keys/${key['id']}',
      result,
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
        errorOf(response, 'API-Schlüssel konnte nicht gespeichert werden.'),
      );
    }
    message('API-Schlüssel wurde gespeichert.');
    await load();
  }

  Future<bool> confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> regenerate(Map<String, dynamic> key) async {
    if (!await confirm(
      'Schlüssel neu erzeugen?',
      'Der bisherige Schlüssel von „${key['name']}“ wird sofort ungültig. '
          'Tragen Sie den neuen Schlüssel anschließend in der Partneranwendung ein.',
      'Neu erzeugen',
    )) {
      return;
    }
    final response = await send(
      'POST',
      '/api/integration-keys/${key['id']}/regenerate',
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
        errorOf(response, 'API-Schlüssel konnte nicht neu erzeugt werden.'),
      );
    }
    await showSecret(object(response));
    await load();
  }

  Future<void> revoke(Map<String, dynamic> key) async {
    if (!await confirm(
      'Schlüssel sperren?',
      'Anwendungen mit dem Schlüssel „${key['name']}“ erhalten sofort keinen '
          'Zugriff mehr. Über „Neu erzeugen“ kann er später wieder aktiviert werden.',
      'Sperren',
    )) {
      return;
    }
    final response = await send(
      'POST',
      '/api/integration-keys/${key['id']}/revoke',
    );
    if (!mounted) return;
    if (response.statusCode != 200) {
      return message(
        errorOf(response, 'API-Schlüssel konnte nicht gesperrt werden.'),
      );
    }
    message('API-Schlüssel wurde gesperrt.');
    await load();
  }

  Future<void> remove(Map<String, dynamic> key) async {
    if (!await confirm(
      'Schlüssel löschen?',
      'Der Schlüssel „${key['name']}“ wird dauerhaft entfernt.',
      'Löschen',
    )) {
      return;
    }
    final response = await send('DELETE', '/api/integration-keys/${key['id']}');
    if (!mounted) return;
    if (response.statusCode != 204) {
      return message(
        errorOf(response, 'API-Schlüssel konnte nicht gelöscht werden.'),
      );
    }
    message('API-Schlüssel wurde gelöscht.');
    await load();
  }

  Future<void> showSecret(Map<String, dynamic> data) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => IntegrationApiKeySecretDialog(
      name: data['name']?.toString() ?? 'API-Schlüssel',
      apiKey: data['apiKey']?.toString() ?? '',
      interfaceUrl: interfaceUrl,
    ),
  );

  String formatTimestamp(Object? value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (parsed == null) return 'nie';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(parsed.day)}.${two(parsed.month)}.${parsed.year} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  Widget keyCard(Map<String, dynamic> key) {
    final active = key['active'] != false;
    final scopes = ((key['scopes'] as List?) ?? const [])
        .map((scope) => scopeLabels[scope.toString()] ?? scope.toString())
        .join(', ');
    return Card(
      child: ListTile(
        leading: Icon(active ? Icons.key : Icons.key_off),
        title: Text(key['name']?.toString() ?? 'API-Schlüssel'),
        subtitle: Text(
          [
            '${key['keyHint'] ?? ''} · ${active ? 'Aktiv' : 'Gesperrt'}',
            'Berechtigungen: $scopes',
            'Zuletzt benutzt: ${formatTimestamp(key['lastUsedAt'])}',
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: Wrap(
          children: [
            IconButton(
              tooltip: 'Bearbeiten',
              onPressed: () => edit(key),
              icon: const Icon(Icons.edit),
            ),
            IconButton(
              tooltip: 'Neu erzeugen',
              onPressed: () => regenerate(key),
              icon: const Icon(Icons.autorenew),
            ),
            if (active)
              IconButton(
                tooltip: 'Sperren',
                onPressed: () => revoke(key),
                icon: const Icon(Icons.block),
              ),
            IconButton(
              tooltip: 'Löschen',
              onPressed: () => remove(key),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      ListTile(
        leading: const Icon(Icons.hub_outlined),
        title: const Text('Schnittstellen für Partneranwendungen'),
        subtitle: Text(
          'Mit einem API-Schlüssel lädt z. B. der Übungsplaner Material und '
          'Fahrzeuge dieser Ebene. Der Zugriff ist nur lesend.\n'
          'Adresse der Schnittstelle: $interfaceUrl',
        ),
        isThreeLine: true,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: loading ? null : create,
          icon: const Icon(Icons.add),
          label: const Text('API-Schlüssel erstellen'),
        ),
      ),
      const SizedBox(height: 12),
      if (loading)
        const Center(child: CircularProgressIndicator())
      else if (error != null)
        ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text(error!),
          trailing: TextButton(
            onPressed: load,
            child: const Text('Erneut laden'),
          ),
        )
      else if (keys.isEmpty)
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Noch keine API-Schlüssel angelegt.'),
        )
      else
        ...keys.map(keyCard),
    ],
  );
}

/// Bezeichnung und Berechtigungen eines API-Schlüssels.
class IntegrationApiKeyDialog extends StatefulWidget {
  final Map<String, String> scopeLabels;
  final Map<String, dynamic>? apiKey;

  const IntegrationApiKeyDialog({
    required this.scopeLabels,
    this.apiKey,
    super.key,
  });

  @override
  State<IntegrationApiKeyDialog> createState() =>
      _IntegrationApiKeyDialogState();
}

class _IntegrationApiKeyDialogState extends State<IntegrationApiKeyDialog> {
  late final TextEditingController name;
  late final Set<String> scopes;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(
      text: widget.apiKey?['name']?.toString() ?? 'Übungsplaner',
    );
    final existing = (widget.apiKey?['scopes'] as List?)
        ?.map((scope) => scope.toString())
        .toSet();
    scopes = existing ?? widget.scopeLabels.keys.toSet();
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  bool get valid => name.text.trim().isNotEmpty && scopes.isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.apiKey == null
          ? 'API-Schlüssel erstellen'
          : 'API-Schlüssel bearbeiten',
    ),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 120,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Bezeichnung',
              helperText: 'z. B. Name der Anwendung, die den Schlüssel nutzt',
            ),
          ),
          const SizedBox(height: 8),
          const Text('Berechtigungen'),
          for (final entry in widget.scopeLabels.entries)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: scopes.contains(entry.key),
              title: Text(entry.value),
              subtitle: Text(entry.key),
              onChanged: (value) => setState(() {
                if (value == true) {
                  scopes.add(entry.key);
                } else {
                  scopes.remove(entry.key);
                }
              }),
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
        onPressed: valid
            ? () => Navigator.pop(context, {
                'name': name.text.trim(),
                'scopes': widget.scopeLabels.keys
                    .where(scopes.contains)
                    .toList(),
              })
            : null,
        child: Text(widget.apiKey == null ? 'Erstellen' : 'Speichern'),
      ),
    ],
  );
}

/// Zeigt einen neu erzeugten Schlüssel genau einmal an.
class IntegrationApiKeySecretDialog extends StatelessWidget {
  final String name;
  final String apiKey;
  final String interfaceUrl;

  const IntegrationApiKeySecretDialog({
    required this.name,
    required this.apiKey,
    required this.interfaceUrl,
    super.key,
  });

  Future<void> copy(BuildContext context, String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$label wurde kopiert.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AlertDialog(
      title: Text('API-Schlüssel „$name“'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Der Schlüssel wird nur jetzt angezeigt und nicht gespeichert. '
              'Tragen Sie Adresse und Schlüssel in der Partneranwendung ein '
              '(im Übungsplaner: Einstellungen → Materialkompass).',
            ),
            const SizedBox(height: 16),
            const Text('Adresse der Schnittstelle'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: surface,
              child: SelectableText(interfaceUrl),
            ),
            const SizedBox(height: 12),
            const Text('API-Schlüssel'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: surface,
              child: SelectableText(apiKey),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: () => copy(context, interfaceUrl, 'Adresse'),
          icon: const Icon(Icons.link),
          label: const Text('Adresse kopieren'),
        ),
        OutlinedButton.icon(
          onPressed: () => copy(context, apiKey, 'API-Schlüssel'),
          icon: const Icon(Icons.copy),
          label: const Text('Schlüssel kopieren'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Ich habe den Schlüssel gespeichert'),
        ),
      ],
    );
  }
}
