import 'dart:convert';
import 'package:flutter/material.dart';
import '../constants.dart';
import 'app_http_client.dart';

/// Preview and decisions are separate from the request that changes records.
Future<Map<String, dynamic>?> importTable({
  required BuildContext context,
  required String token,
  required String path,
  required String fileName,
  required List<int> bytes,
}) async {
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  final body = <String, dynamic>{
    'fileName': fileName,
    'fileBase64': base64Encode(bytes),
  };
  Future<Map<String, dynamic>> send(Map<String, dynamic> payload) async {
    final response = await AppHttpClient.post(
      Uri.parse('$apiBaseUrl$path'),
      headers: headers,
      body: jsonEncode(payload),
    );
    final result = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode != 200) {
      throw Exception(result['error'] ?? 'Import fehlgeschlagen');
    }
    return result;
  }

  final preview = await send({...body, 'preview': true});
  if (!context.mounted) return null;
  if ((preview['conflicts'] as List? ?? []).isNotEmpty) {
    final policy = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Inventarnummern bereits vergeben'),
        content: Text(
          '${(preview['conflicts'] as List).length} Zeilen verwenden bereits vergebene Inventarnummern. Welche Aktion soll für alle Konflikte gelten? Beim Ersetzen bleiben leere Felder und verknüpfte Vorgänge erhalten. Artikel des anderen Bereichs können nicht ersetzt werden und werden übersprungen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'skip'),
            child: const Text('Überspringen'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'replace'),
            child: const Text('Ersetzen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'renumber'),
            child: const Text('Neue Inventarnummern'),
          ),
        ],
      ),
    );
    if (policy == null) return null;
    body['conflictPolicy'] = policy;
  }
  // Recheck after the replacement decision, which can preserve existing locations.
  final checked = await send({...body, 'preview': true});
  final missing = checked['missingStorage'] as List? ?? [];
  if (missing.isNotEmpty) {
    final response = await AppHttpClient.get(
      Uri.parse('$apiBaseUrl/api/storage-hierarchy'),
      headers: headers,
    );
    if (response.statusCode != 200)
      throw Exception('Lagerorte konnten nicht geladen werden.');
    final hierarchy = jsonDecode(response.body) as Map<String, dynamic>;
    final locations = (hierarchy['locations'] as List)
        .cast<Map<String, dynamic>>();
    final positions = (hierarchy['stockStructures'] as List)
        .cast<Map<String, dynamic>>();
    final mappings = <String, dynamic>{};
    for (final raw in missing) {
      if (!context.mounted) return null;
      final entry = Map<String, dynamic>.from(raw as Map);
      String? locationId;
      String? positionId;
      final mapping = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Lagerort zuordnen'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Alter Standort: ${entry['locationId']}\nAlter Lagerplatz: ${entry['stockStructureId']}\nDie Zuordnung gilt für alle Zeilen mit diesem Lagerort.',
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Aktueller Standort',
                    ),
                    items: locations
                        .map(
                          (location) => DropdownMenuItem(
                            value: location['id'] as String,
                            child: Text(location['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => update(() {
                      locationId = value;
                      positionId = null;
                    }),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(locationId),
                    isExpanded: true,
                    initialValue: '',
                    decoration: const InputDecoration(
                      labelText: 'Aktueller Lagerplatz',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('Nur dem Standort zuordnen'),
                      ),
                      ...positions
                          .where(
                            (position) => position['locationId'] == locationId,
                          )
                          .map(
                            (position) => DropdownMenuItem(
                              value: position['id'] as String,
                              child: Text(
                                position['path']?.toString() ??
                                    position['name']?.toString() ??
                                    '',
                              ),
                            ),
                          ),
                    ],
                    onChanged: (value) => update(() => positionId = value),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: locationId == null
                    ? null
                    : () => Navigator.pop(dialogContext, {
                        'locationId': locationId,
                        'stockStructureId': positionId ?? '',
                      }),
                child: const Text('Zuordnen'),
              ),
            ],
          ),
        ),
      );
      if (mapping == null) return null;
      mappings[entry['key'] as String] = mapping;
    }
    body['storageMappings'] = mappings;
  }
  return send(body);
}
