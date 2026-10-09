import 'dart:convert';

import 'package:cloud_mobile_starter/api_client.dart';
import 'package:cloud_mobile_starter/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('requires account login before showing signals', (tester) async {
    final client = ApiClient(
      'https://api.example.test',
      httpClient: MockClient(
        (_) async => throw StateError('Unexpected request before login'),
      ),
    );

    await tester.pumpWidget(
      SignalsApp(client: client, apiBaseUrl: 'https://api.example.test'),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
      'كريبتو البلحوسي',
    );
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('إنشاء حساب جديد'), findsOneWidget);
  });

  test('reports HTML hosting challenge instead of treating it as JSON',
      () async {
    final client = ApiClient(
      'https://api.example.test',
      httpClient: MockClient(
        (_) async => http.Response(
          '<html><body>Challenge</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        ),
      ),
    );

    await expectLater(
      client.getSignals(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          contains('صفحة HTML'),
        ),
      ),
    );
  });

  test('loads protected signals and adapts the FastAPI response', () async {
    final client = ApiClient(
      'https://api.example.test',
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/signals');
        expect(request.headers['authorization'], 'Bearer test-token');
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'signal-1',
                'symbol': 'BTCUSDT',
                'exchange': 'binance',
                'direction': 'long',
                'entry': 60000,
                'stopLoss': 58000,
                'takeProfits': [62000, 64000, 66000],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'test-token';

    final signals = await client.getSignals();

    expect(signals.single['side'], 'long');
    expect(signals.single['entry'], 60000);
    expect(signals.single['stopLoss'], 58000);
    expect(signals.single['targets'], [62000, 64000, 66000]);
  });
}
