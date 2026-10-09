import 'dart:convert';

import 'package:crypto_manager/admin_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('refuses manager login when API role is not admin', () async {
    final api = ManagerApi(
      'https://api.example.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/auth/login');
        return http.Response(
          jsonEncode({'role': 'user', 'accessToken': 'token'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await expectLater(
      api.login('user@example.test', 'password'),
      throwsA(isA<ManagerApiException>()),
    );
  });

  test('attaches bearer auth and sends subscription extension request',
      () async {
    final api = ManagerApi(
      'https://api.example.test',
      httpClient: MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          return http.Response(
            jsonEncode({'role': 'admin', 'accessToken': 'admin-token'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        expect(request.url.path, '/api/admin/users/user-id/subscriptions');
        expect(request.headers['authorization'], 'Bearer admin-token');
        expect(jsonDecode(request.body), {'months': 1});
        return http.Response(
          jsonEncode({'active': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await api.login('admin@example.test', 'password');
    final result = await api.extendSubscription('user-id');
    expect(result['active'], isTrue);
  });
}
