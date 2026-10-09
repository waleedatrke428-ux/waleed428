import 'package:cloud_mobile_starter/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('does not show placeholder signals without a backend', (tester) async {
    await tester.pumpWidget(const SignalsApp());

    expect(find.text('الخدمة الخلفية قيد الإعداد'), findsOneWidget);
    expect(find.textContaining('لن نعرض إشارات أو أسعاراً تجريبية.'), findsOneWidget);
  });
}
