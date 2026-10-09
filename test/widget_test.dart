import 'dart:convert';

import 'package:cloud_mobile_starter/api_client.dart';
import 'package:cloud_mobile_starter/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows PHP signals in read-only mode', (tester) async {
    final client = ApiClient(
      defaultApiBaseUrl,
      httpClient: MockClient((request) async {
        expect(request.url.scheme, 'https');
        expect(request.url.host, 'waleed.freehosting.dev');
        expect(request.url.path, '/get_signals.php');
        expect(request.method, 'GET');
        return http.Response(
          jsonEncode({
            'status': 'success',
            'count': 1,
            'data': [
              {
                'id': 7,
                'symbol': 'BTCUSDT',
                'direction': 'LONG',
                'entry_price': 60000,
                'target_1': 62000,
                'target_2': 64000,
                'target_3': 66000,
                'stop_loss': 58000,
                'leverage': 3,
                'risk_percent': 1,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await tester.pumpWidget(SignalsApp(client: client));
    await tester.pumpAndSettle();

    expect(find.text('BTCUSDT · —'), findsOneWidget);
    expect(find.text('الدخول: 60000'), findsOneWidget);
    expect(find.textContaining('درجة التوافق:'), findsNothing);

    await tester.tap(find.text('BTCUSDT · —'));
    await tester.pumpAndSettle();

    expect(find.text('وقف الخسارة'), findsOneWidget);
    expect(find.text('الهدف 1'), findsOneWidget);
    expect(find.text('دخلت الصفقة'), findsNothing);
  });
}
