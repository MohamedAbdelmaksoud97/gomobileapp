import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gomobileapp/main.dart';

void main() {
  test('production API is the default runtime target', () {
    expect(ApiClient().baseUrl, productionApiBaseUrl);
  });

  test('Riyadh ranges and strict resource queries match backend contracts', () {
    final day = riyadhDateRange();
    expect(
      DateTime.parse(day.to).difference(DateTime.parse(day.from)),
      const Duration(days: 1),
    );

    final rolling = riyadhDateRange(days: 30);
    expect(
      DateTime.parse(rolling.to).difference(DateTime.parse(rolling.from)),
      const Duration(days: 30),
    );

    expect(
      resourceQueryFor(
        '/self/organizations/{organizationId}/services',
        'branch-id',
      ),
      {'branchId': 'branch-id'},
    );
    expect(
      resourceQueryFor(
        '/organizations/{organizationId}/crm/lead-sources',
        'branch-id',
      ),
      isEmpty,
    );
    final attendance = resourceQueryFor(
      '/organizations/{organizationId}/employee-attendance',
      'branch-id',
    );
    expect(attendance.keys, containsAll(<String>['branchId', 'from', 'to']));
    expect(attendance, isNot(contains('limit')));
  });

  testWidgets('GO login experience renders', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(GoMobileApp(apiClient: ApiClient(baseUrl: '')));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.colorScheme.primary, goYellow);
    expect(app.theme?.colorScheme.onPrimary, goInk);
    expect(app.supportedLocales, const [Locale('ar')]);
    expect(find.text('تسجيل الدخول'), findsNWidgets(2));
    expect(find.text('موظف'), findsOneWidget);
    expect(find.text('عضو / ولي أمر'), findsOneWidget);
    expect(find.text('تفعيل حساب عضو لأول مرة'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('staff shell remains usable on a compact RTL phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''))
      ..bootstrapping = false
      ..authenticated = true
      ..staffMode = true;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => GoShell(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('الأعضاء'), findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.setTab(1);
    await tester.pumpAndSettle();
    expect(find.text('دليل الأعضاء'), findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.setTab(2);
    await tester.pumpAndSettle();
    expect(find.text('مركز التشغيل'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('member self-service shell renders', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
