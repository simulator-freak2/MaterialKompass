import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants.dart';

class SystemMessage {
  const SystemMessage({
    required this.id,
    required this.type,
    required this.title,
    required this.message,
    required this.publishedAt,
    this.version,
    this.startsAt,
    this.endsAt,
    this.acknowledged = false,
  });

  final String id;
  final String type;
  final String title;
  final String message;
  final DateTime publishedAt;
  final String? version;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool acknowledged;

  bool get isRelease => type == 'release';
  bool get isMaintenance => type == 'maintenance';

  static SystemMessage? fromJson(Object? value) {
    if (value is! Map) return null;
    final data = Map<String, dynamic>.from(value);
    final publishedAt = DateTime.tryParse(
      data['publishedAt']?.toString() ?? '',
    );
    final id = data['id']?.toString() ?? '';
    final type = data['type']?.toString() ?? '';
    final title = data['title']?.toString() ?? '';
    final message = data['message']?.toString() ?? '';
    if (id.isEmpty ||
        !{'release', 'maintenance'}.contains(type) ||
        title.isEmpty ||
        message.isEmpty ||
        publishedAt == null) {
      return null;
    }
    return SystemMessage(
      id: id,
      type: type,
      title: title,
      message: message,
      publishedAt: publishedAt,
      version: data['version']?.toString(),
      startsAt: DateTime.tryParse(data['startsAt']?.toString() ?? ''),
      endsAt: DateTime.tryParse(data['endsAt']?.toString() ?? ''),
      acknowledged: data['acknowledged'] == true,
    );
  }
}

class SystemMessageService {
  SystemMessageService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<SystemMessage>> publicMessages() => _load('/api/system/messages');

  Future<List<SystemMessage>> userMessages(String token) => _load(
    '/api/system/messages/me',
    headers: {'Authorization': 'Bearer $token'},
  );

  Future<void> acknowledge(String token, String messageId) async {
    final response = await _client
        .post(
          Uri.parse(apiBaseUrl).resolve(
            '/api/system/messages/${Uri.encodeComponent(messageId)}/acknowledge',
          ),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 204) {
      throw StateError('Releasehinweis konnte nicht bestätigt werden.');
    }
  }

  Future<List<SystemMessage>> _load(
    String path, {
    Map<String, String>? headers,
  }) async {
    final response = await _client
        .get(Uri.parse(apiBaseUrl).resolve(path), headers: headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw StateError(
        'Systemhinweise konnten nicht geladen werden (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['messages'] is! List) return const [];
    return (decoded['messages'] as List)
        .map(SystemMessage.fromJson)
        .whereType<SystemMessage>()
        .toList(growable: false);
  }

  void dispose() => _client.close();
}
