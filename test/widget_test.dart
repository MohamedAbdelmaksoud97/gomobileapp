import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gomobileapp/main.dart';

class _RecordingApiClient extends ApiClient {
  _RecordingApiClient() : super(baseUrl: '');

  final calls = <Map<String, dynamic>>[];

  @override
  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool retryAuthentication = true,
  }) async {
    calls.add({
      'path': path,
      'method': method,
      'body': body,
      'query': query == null ? null : Map<String, String>.from(query),
    });
    if (path.endsWith('/members')) {
      return [
        {'id': 'member-1', 'name': 'عضو تجريبي'},
      ];
    }
    if (path.endsWith('/services')) {
      return [
        {'id': 'service-1', 'name': 'خدمة تجريبية'},
      ];
    }
    if (path.endsWith('/packages')) {
      return [
        {'id': 'package-1', 'name': 'باقة تجريبية'},
      ];
    }
    if (path.endsWith('/bookable-resources')) {
      final memberPath = path.startsWith('/self/');
      return [
        {
          'id': 'resource-1',
          'name': 'حصة تجريبية',
          'type': 'CLASS',
          'resourceType': 'CLASS',
          'serviceId': 'service-1',
          if (memberPath) 'facilityName': 'القاعة الرئيسية',
        },
      ];
    }
    if (path.endsWith('/session-slots')) {
      final start = DateTime.now().toUtc().add(const Duration(days: 2));
      return [
        {
          'id': 'slot-1',
          'startsAt': start.toIso8601String(),
          'endsAt': start.add(const Duration(hours: 1)).toIso8601String(),
          'capacity': 10,
          'bookedCount': 0,
        },
      ];
    }
    if (path.endsWith('/quotes')) return {'grossMinor': '12500'};
    if (path.endsWith('/orders')) {
      return {'id': 'order-1', 'invoiceId': 'invoice-1'};
    }
    return null;
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

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
    final selfSlots = resourceQueryFor(
      '/self/organizations/{organizationId}/bookable-resources/resource-id/session-slots',
      'branch-id',
    );
    expect(selfSlots, containsPair('branchId', 'branch-id'));
    expect(selfSlots.keys, containsAll(<String>['from', 'to']));
  });

  test('mobile workflows cover high-value web mutations', () {
    final operations = mobileWorkflows.map((workflow) => workflow.operationId);
    expect(
      operations,
      containsAll(<String>[
        'createSubscription',
        'rescheduleSubscriptionStart',
        'recordSplitPayment',
        'scheduleServiceAvailability',
        'createBookingAvailability',
        'createBookingBlackout',
        'createSessionSlot',
        'assignEmployee',
        'assignTrainerToBranch',
        'createTrainerAvailability',
        'assignMemberToTrainer',
        'createBarcodePrintBatch',
        'redeemMealPlan',
        'createCommunicationCampaign',
      ]),
    );
  });

  test('booking and communication workflows enforce backend UX rules', () {
    final booking = mobileWorkflows.firstWhere(
      (workflow) => workflow.operationId == 'createBookableResource',
    );
    final controller = GoController(ApiClient(baseUrl: ''))
      ..branchId = 'branch-test';
    expect(
      booking.body({
        'facilityId': 'facility-test',
        'serviceId': 'service-test',
        'cancellationPolicyVersionId': 'policy-test',
        'code': 'court-1',
        'name': 'ملعب تجريبي',
        'type': 'COURT',
        'capacity': '12',
      }, controller)['capacity'],
      1,
    );
    expect(
      booking.body({
        'facilityId': 'facility-test',
        'serviceId': 'service-test',
        'cancellationPolicyVersionId': 'policy-test',
        'code': 'class-1',
        'name': 'حصة تجريبية',
        'type': 'CLASS',
        'capacity': '12',
      }, controller)['capacity'],
      12,
    );

    final campaign = mobileWorkflows.firstWhere(
      (workflow) => workflow.operationId == 'createCommunicationCampaign',
    );
    final template = campaign.fields.firstWhere(
      (field) => field.name == 'templateId',
    );
    expect(template.copyValues, {
      'title': 'title',
      'body': 'body',
      'purpose': 'purpose',
    });
    controller.dispose();
  });

  test('restaurant pricing supports a publication-safe effective date', () {
    final pricing = mobileWorkflows.firstWhere(
      (workflow) => workflow.operationId == 'createRestaurantMealPrice',
    );
    final validFrom = pricing.fields.firstWhere(
      (field) => field.name == 'validFrom',
    );
    expect(validFrom.type, WorkflowFieldType.dateTime);
    expect(validFrom.required, isTrue);
    expect(DateTime.tryParse(validFrom.initialValue), isNotNull);
    expect(
      apiProblemMessage('daily_menu_price_missing', 'fallback'),
      contains('سعر ساري'),
    );
  });

  test(
    'dark mode preference is restored and persisted on the device',
    () async {
      FlutterSecureStorage.setMockInitialValues({'go_theme_mode': 'dark'});
      final controller = GoController(ApiClient(baseUrl: ''));
      await controller.initialize();
      expect(controller.darkMode, isTrue);

      controller.setDarkMode(false);
      await Future<void>.delayed(Duration.zero);
      final restored = GoController(ApiClient(baseUrl: ''));
      await restored.initialize();
      expect(restored.darkMode, isFalse);
      controller.dispose();
      restored.dispose();
    },
  );

  testWidgets(
    'staff booking auto-selects its linked data and creates an invoice',
    (tester) async {
      final api = _RecordingApiClient();
      final controller = GoController(api)
        ..organizationId = 'organization-1'
        ..branchId = 'branch-1';
      final workflow = mobileWorkflows.firstWhere(
        (item) => item.operationId == 'createManualReservation',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: WorkflowPage(controller: controller, workflow: workflow),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('متابعة إنشاء الحجز'),
        450,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('متابعة إنشاء الحجز'));
      await tester.pumpAndSettle();
      expect(find.textContaining('الإجمالي:'), findsOneWidget);
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();

      final order = api.calls.lastWhere(
        (call) => call['path'] == '/organizations/organization-1/orders',
      );
      final orderBody = order['body'] as Map<String, dynamic>;
      final line = (orderBody['lines'] as List).single as Map<String, dynamic>;
      final booking = line['booking'] as Map<String, dynamic>;
      expect(line['targetId'], 'service-1');
      expect(booking['resourceId'], 'resource-1');
      expect(booking['sessionSlotId'], 'slot-1');
      expect(
        api.calls.any((call) => call['path'].toString().endsWith('/quotes')),
        isTrue,
      );
      controller.dispose();
    },
  );

  testWidgets('member booking uses strict self queries and reaches checkout', (
    tester,
  ) async {
    final api = _RecordingApiClient();
    final controller = GoController(api)
      ..staffMode = false
      ..organizationId = 'organization-1'
      ..branchId = 'branch-1'
      ..selfMembers = [
        {'memberId': 'member-1', 'memberName': 'عضو تجريبي', 'canBook': true},
      ];
    final workflow = mobileWorkflows.firstWhere(
      (item) => item.operationId == 'checkoutSelfBooking',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: WorkflowPage(controller: controller, workflow: workflow),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final resourcesCall = api.calls.firstWhere(
      (call) => call['path'].toString().endsWith('/bookable-resources'),
    );
    expect(resourcesCall['query'], {'branchId': 'branch-1'});
    final slotsCall = api.calls.firstWhere(
      (call) => call['path'].toString().endsWith('/session-slots'),
    );
    expect(slotsCall['query'], containsPair('branchId', 'branch-1'));
    await tester.tap(find.text('تأكيد الحجز'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    final order = api.calls.lastWhere(
      (call) => call['path'].toString().endsWith('/orders'),
    );
    final body = order['body'] as Map<String, dynamic>;
    final line = (body['lines'] as List).single as Map<String, dynamic>;
    final booking = line['booking'] as Map<String, dynamic>;
    expect(line['targetId'], 'service-1');
    expect(booking['sessionSlotId'], 'slot-1');
    controller.dispose();
  });

  for (final booking in [false, true]) {
    testWidgets(
      'member marketplace ${booking ? 'booking' : 'service'} binds the selected item to its order',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = _RecordingApiClient();
        final controller = GoController(api)
          ..staffMode = false
          ..organizationId = 'organization-1'
          ..branchId = 'branch-1'
          ..selfMembers = [
            {
              'memberId': 'member-1',
              'canBook': true,
              'canManageMembership': true,
            },
          ];
        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: MemberMarketplacePage(
                controller: controller,
                standalone: true,
                initialTab: booking ? 'booking' : 'services',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('الإجراءات المتاحة'), findsNothing);
        await tester.tap(
          find.text(booking ? 'عرض المواعيد المتاحة' : 'عرض السعر النهائي'),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(DropdownButtonFormField<String>),
          booking ? findsOneWidget : findsNothing,
        );
        await tester.tap(
          find.text(booking ? 'تأكيد الحجز' : 'عرض السعر النهائي'),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('السداد في استقبال النادي'), findsWidgets);
        await tester.tap(find.text('تأكيد'));
        await tester.pumpAndSettle();
        final order = api.calls.lastWhere(
          (call) => call['path'].toString().endsWith('/orders'),
        );
        final line = ((order['body'] as Map)['lines'] as List).single as Map;
        expect(line['type'], booking ? 'BOOKING' : 'SERVICE');
        expect(line['targetId'], 'service-1');
        if (booking) {
          expect((line['booking'] as Map)['resourceId'], 'resource-1');
          expect((line['booking'] as Map)['sessionSlotId'], 'slot-1');
          expect((line['booking'] as Map)['seats'], 1);
        } else {
          expect(line.containsKey('booking'), isFalse);
        }
        expect(
          api.calls.any((call) => call['path'].toString().endsWith('/quotes')),
          isTrue,
        );
        controller.dispose();
      },
    );
  }

  testWidgets(
    'guardian booking-only access does not expose service purchases',
    (tester) async {
      final controller = GoController(_RecordingApiClient())
        ..staffMode = false
        ..selfMembers = [
          {
            'memberId': 'member-1',
            'canBook': true,
            'canManageMembership': false,
          },
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: MemberMarketplacePage(controller: controller, standalone: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('حجز موعد'), findsOneWidget);
      expect(find.text('الخدمات'), findsNothing);
      expect(find.text('الباقات'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'member court booking reserves one unit with participant count and no session-slot request',
    (tester) async {
      final api = _RecordingApiClient();
      final controller = GoController(api)
        ..staffMode = false
        ..organizationId = 'organization-1'
        ..branchId = 'branch-1'
        ..selfMembers = [
          {'memberId': 'member-1', 'canBook': true},
        ];
      final start = DateTime.now().add(const Duration(days: 2));
      await tester.pumpWidget(
        MaterialApp(
          home: WorkflowPage(
            controller: controller,
            workflow: mobileWorkflows.firstWhere(
              (item) => item.operationId == 'checkoutSelfBooking',
            ),
            lockedFields: const {'resourceId'},
            initialValues: {
              'resourceId': 'court-1',
              'resourceType': 'COURT',
              'serviceId': 'service-1',
              'participantCount': '8',
              'startsAt': start.toIso8601String(),
              'endsAt': start.add(const Duration(hours: 1)).toIso8601String(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        api.calls.any(
          (call) => call['path'].toString().endsWith('/session-slots'),
        ),
        isFalse,
      );
      await tester.scrollUntilVisible(
        find.text('تأكيد الحجز'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('تأكيد الحجز'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();
      final order = api.calls.lastWhere(
        (call) => call['path'].toString().endsWith('/orders'),
      );
      final line = ((order['body'] as Map)['lines'] as List).single as Map;
      final booking = line['booking'] as Map;
      expect(line['type'], 'BOOKING');
      expect(line['quantity'], 1);
      expect(booking['seats'], 1);
      expect(booking['participantCount'], 8);
      expect(booking['resourceId'], 'court-1');
      expect(booking.containsKey('sessionSlotId'), isFalse);
      controller.dispose();
    },
  );

  testWidgets('GO login experience renders', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(GoMobileApp(apiClient: ApiClient(baseUrl: '')));
    await tester.pumpAndSettle();
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
      ..staffMode = false
      ..selfMembers = [
        {'memberId': 'member-1', 'canBook': true, 'canManageMembership': true},
      ];

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
    expect(find.text('الباقات'), findsOneWidget);
    expect(find.text('الخدمات'), findsOneWidget);
    expect(find.text('حجز موعد'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets(
    'member notifications stay readable on a compact Android-sized viewport',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = GoController(ApiClient(baseUrl: ''))
        ..staffMode = false
        ..notices = [];

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: MemberShell(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('الإشعارات'));
      await tester.pumpAndSettle();

      expect(find.text('الرسائل والإشعارات'), findsOneWidget);
      expect(find.text('كل شيء هادئ الآن'), findsOneWidget);
      expect(find.textContaining('تنبيهات الحساب'), findsOneWidget);
      final inheritedStyle = DefaultTextStyle.of(
        tester.element(find.text('كل شيء هادئ الآن')),
      ).style;
      expect(inheritedStyle.fontSize, isNot(48));
      expect(inheritedStyle.color, isNot(const Color(0xD0FF0000)));
      expect(inheritedStyle.decoration, isNot(TextDecoration.underline));
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

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
    expect(find.text('الوضع الداكن', skipOffstage: false), findsOneWidget);
    expect(find.text('العمليات المتقدمة', skipOffstage: false), findsNothing);
    expect(find.text('الإجراءات الأساسية', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('CRM workspace mirrors web summary and workflow sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = GoController(ApiClient(baseUrl: ''))
      ..grants = [
        {
          'permission': 'crm.leads.manage',
          'organizationId': 'demo-organization',
          'scopeType': 'ORGANIZATION',
          'branchIds': <String>[],
        },
        {
          'permission': 'crm.follow-ups.manage',
          'organizationId': 'demo-organization',
          'scopeType': 'ORGANIZATION',
          'branchIds': <String>[],
        },
        {
          'permission': 'online-requests.read',
          'organizationId': 'demo-organization',
          'scopeType': 'ORGANIZATION',
          'branchIds': <String>[],
        },
      ];

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CrmMobileWorkspacePage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('فرص مفتوحة'), findsOneWidget);
    expect(find.text('متابعات مجدولة'), findsOneWidget);
    expect(find.text('متابعات متأخرة'), findsOneWidget);
    expect(find.text('تحولوا إلى أعضاء'), findsOneWidget);
    expect(find.text('العملاء المحتملون'), findsOneWidget);
    expect(find.text('جدول المتابعات'), findsOneWidget);
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
