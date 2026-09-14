import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomobileapp/main.dart';

void main() {
  test('production API is the default runtime target', () {
    expect(ApiClient().baseUrl, productionApiBaseUrl);
  });

  testWidgets('GO login experience renders', (tester) async {
    await tester.pumpWidget(GoMobileApp(apiClient: ApiClient(baseUrl: '')));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.colorScheme.primary, goYellow);
    expect(app.theme?.colorScheme.onPrimary, goInk);
    expect(find.text('تسجيل الدخول'), findsNWidgets(2));
    expect(find.text('موظف'), findsOneWidget);
    expect(find.text('عضو / ولي أمر'), findsOneWidget);
    expect(find.text('تفعيل حساب عضو لأول مرة'), findsOneWidget);
  });

  testWidgets('member self-service shell renders', (tester) async {
    final controller = GoController(ApiClient(baseUrl: ''))
      ..bootstrapping = false
      ..authenticated = true
      ..staffMode = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MemberShell(controller: controller),
        ),
      ),
    );

    expect(find.text('خدماتك'), findsOneWidget);
    expect(find.text('اشتراكاتي'), findsOneWidget);
    expect(find.text('طلباتي'), findsWidgets);
    controller.dispose();
  });
}
