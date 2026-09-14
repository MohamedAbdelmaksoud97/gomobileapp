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
    expect(
      resourceQueryFor('/organizations/{organizationId}', 'branch-id'),
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

    expect(find.text('وصول سريع'), findsOneWidget);
    expect(find.text('اكتشف'), findsOneWidget);
    expect(find.text('حجوزاتي'), findsOneWidget);
    expect(tester.takeException(), isNull);

    controller.tab = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MemberShell(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('اكتشف واحجز'), findsOneWidget);
    expect(find.text('الباقات المتاحة'), findsOneWidget);
    expect(find.text('الخدمات المتاحة'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('staff navigation mirrors the cohesive web sections', (
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
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MorePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إدارة النادي', skipOffstage: false), findsOneWidget);
    expect(find.text('الأعمال', skipOffstage: false), findsOneWidget);
    expect(find.text('الإدارة', skipOffstage: false), findsOneWidget);
    expect(find.text('البوابات والبصمة', skipOffstage: false), findsOneWidget);
    expect(find.text('مساحة عملي', skipOffstage: false), findsOneWidget);
    expect(find.text('العمليات المتقدمة', skipOffstage: false), findsNothing);
    expect(find.text('الإجراءات الأساسية', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('system settings exposes the same grouped hierarchy as web', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''));

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SystemSettingsPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مركز إعداد موحّد'), findsOneWidget);
    expect(find.text('النادي والموظفون'), findsOneWidget);
    expect(find.text('الخدمات والتسعير'), findsOneWidget);
    expect(find.text('المرافق والتشغيل'), findsOneWidget);
    expect(find.text('المتجر والمخزون', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('gate workspace combines devices and access events', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''));

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AccessControlMobilePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مراقبة لحظية للبوابة'), findsOneWidget);
    expect(find.text('اللوحات'), findsOneWidget);
    expect(find.text('سجل المرور'), findsOneWidget);
    expect(find.text('بوابة الفرع الرئيسية'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('member barcode has a professional empty state', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''))..staffMode = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MemberBarcodePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('بطاقة دخولي'), findsOneWidget);
    expect(find.text('لا توجد بطاقة دخول نشطة'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('member training plans exposes the interactive workout journey', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''))
      ..staffMode = false
      ..selfMembers = [
        {'memberId': 'member-test', 'memberName': 'عضو تجريبي'},
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: MemberTrainingPlansPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('خططي التدريبية'), findsOneWidget);
    expect(find.text('لا توجد خطة تدريب حالية'), findsOneWidget);
    expect(find.textContaining('تعليمات تنفيذها'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('point of sale groups checkout actions and financial records', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''))
      ..staffMode = true
      ..branchName = 'الفرع التجريبي';

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PointOfSaleMobilePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('بيع وتحصيل من مكان واحد'), findsOneWidget);
    expect(find.text('عمليات البيع'), findsOneWidget);
    expect(find.text('بيع باقة وإصدار فاتورة'), findsOneWidget);
    expect(find.text('بيع خدمة'), findsOneWidget);
    expect(find.text('بيع منتج من المتجر'), findsOneWidget);
    expect(find.text('السجلات والمتابعة', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
