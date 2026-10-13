import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/services/system_message_service.dart';

void main() {
  test('parses public maintenance information', () async {
    final service = SystemMessageService(
      client: MockClient(
        (request) async => http.Response('''
        {"messages":[{"id":"maintenance-1","type":"maintenance",
        "title":"Wartung","message":"Kurze Unterbrechung",
        "publishedAt":"2026-10-11T12:00:00Z",
        "startsAt":"2026-10-12T18:00:00Z","endsAt":"2026-10-12T20:00:00Z"}]}
      ''', 200),
      ),
    );
    final messages = await service.publicMessages();
    expect(messages, hasLength(1));
    expect(messages.single.isMaintenance, isTrue);
    expect(messages.single.title, 'Wartung');
    service.dispose();
  });

  test('acknowledges a release with the user token', () async {
    late http.Request sent;
    final service = SystemMessageService(
      client: MockClient((request) async {
        sent = request;
        return http.Response('', 204);
      }),
    );
    await service.acknowledge('secret-token', 'release-1.6.0');
    expect(sent.method, 'POST');
    expect(sent.headers['authorization'], 'Bearer secret-token');
    expect(sent.url.path, endsWith('/release-1.6.0/acknowledge'));
    service.dispose();
  });
}
