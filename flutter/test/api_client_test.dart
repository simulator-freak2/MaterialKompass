import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:materialkompass/services/api_client.dart';

void main() {
  test('decodes successful JSON responses', () async {
    final api = ApiClient(
      client: MockClient(
        (request) async => http.Response(
          '{"token":"test-token"}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final response = await api.post(
      '/api/auth/login',
      body: {'identifier': 'admin', 'password': 'secret'},
    );

    expect(response.statusCode, 200);
    expect(response.object['token'], 'test-token');
    api.close();
  });

  test('turns timeouts into a user-facing API exception', () async {
    final api = ApiClient(
      client: MockClient(
        (_) => Future<http.Response>.delayed(
          const Duration(milliseconds: 100),
          () => http.Response('{}', 200),
        ),
      ),
      timeout: const Duration(milliseconds: 5),
    );

    await expectLater(
      api.get('/health'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          contains('antwortet nicht'),
        ),
      ),
    );
    api.close();
  });

  test('sends PATCH and DELETE bodies through one reusable client', () async {
    final requests = <http.Request>[];
    final api = ApiClient(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          request.method == 'PATCH' ? '{}' : '',
          request.method == 'PATCH' ? 200 : 204,
        );
      }),
    );

    await api.patch('/api/users/me/passkeys/one', body: {'name': 'Notebook'});
    await api.delete(
      '/api/users/me/passkeys/one',
      body: {'currentPassword': 'secret'},
    );

    expect(requests.map((request) => request.method), ['PATCH', 'DELETE']);
    expect(requests.first.body, contains('Notebook'));
    expect(requests.last.body, contains('currentPassword'));
    api.close();
  });

  test('rejects malformed server responses', () async {
    final api = ApiClient(
      client: MockClient((_) async => http.Response('<html>', 502)),
    );

    await expectLater(
      api.get('/health'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          502,
        ),
      ),
    );
    api.close();
  });
}
