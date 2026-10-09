import 'package:cloud_mobile_starter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the starter home page', (tester) async {
    await tester.pumpWidget(const CloudMobileApp());

    expect(find.text('Cloud Mobile Starter'), findsOneWidget);
    expect(find.text('Ready to build in the cloud.'), findsOneWidget);
  });
}
