import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:barcode_widget/barcode_widget.dart' as barcode_ui;
import 'package:file_picker/file_picker.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

// The web brand token and the supplied artwork's primary yellow.
const goYellow = Color(0xFFFFCC00);
const goInk = Color(0xFF151515);
const goCanvas = Color(0xFFF7F7F5);
const productionApiBaseUrl = 'https://gosystem.onrender.com/api/v1';

typedef ApiDateRange = ({String from, String to});

/// Saudi Arabia has a fixed UTC+3 offset and no daylight-saving time. Building
/// the boundary in UTC keeps the API range identical on Android, iOS and web,
/// regardless of the device time zone.
ApiDateRange riyadhDateRange({int days = 1}) {
  final riyadhNow = DateTime.now().toUtc().add(const Duration(hours: 3));
  final localMidnightUtc = DateTime.utc(
    riyadhNow.year,
    riyadhNow.month,
    riyadhNow.day,
  ).subtract(const Duration(hours: 3));
  final from = localMidnightUtc.subtract(Duration(days: days - 1));
  final to = localMidnightUtc.add(const Duration(days: 1));
  return (from: from.toIso8601String(), to: to.toIso8601String());
}

String riyadhBusinessDate() {
  final value = DateTime.now().toUtc().add(const Duration(hours: 3));
  String two(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
}

Map<String, String> resourceQueryFor(String path, String branchId) {
  if (path == '/organizations/{organizationId}') return const {};
  if (path.endsWith('/crm/lead-sources')) return const {};
  if (path.endsWith('/daily-menu')) {
    return {'branchId': branchId, 'businessDate': riyadhBusinessDate()};
  }
  if (path.endsWith('/employee-shifts') ||
      path.endsWith('/employee-attendance') ||
      path.endsWith('/other-income')) {
    final range = riyadhDateRange(days: 30);
    return {'branchId': branchId, 'from': range.from, 'to': range.to};
  }
  if (path.contains('/session-slots')) {
    final now = DateTime.now().toUtc();
    return {
      'branchId': branchId,
      'from': now.toIso8601String(),
      'to': now.add(const Duration(days: 30)).toIso8601String(),
    };
  }
  if (path.startsWith('/self/') &&
      (path.endsWith('/services') ||
          path.endsWith('/packages') ||
          path.endsWith('/bookable-resources'))) {
    return {'branchId': branchId};
  }
  return {'branchId': branchId, 'limit': '100'};
}

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;
}

String _errorMessage(Object exception) => exception is ApiFailure
    ? exception.message
    : exception.toString().replaceFirst('Exception: ', '');

String apiProblemMessage(String? code, String fallback) {
  return switch (code) {
    'daily_menu_price_missing' => 'لا يمكن نشر القائمة لأن إحدى الوجبات بلا سعر ساري في هذا الفرع وتاريخ القائمة. أضف السعر أو صحح بداية سريانه ثم أعد المحاولة.',
    'daily_menu_already_exists' => 'توجد قائمة لهذا اليوم بالفعل. افتح القائمة الحالية وعدّلها بدل إنشاء قائمة جديدة.',
    'version_conflict' =>
      'تم تحديث السجل من جهاز آخر. حدّث البيانات ثم أعد المحاولة.',
    'session_slot_capacity_exhausted' =>
      'اكتملت سعة الموعد أثناء الحجز. حدّث المواعيد واختر موعدًا آخر.',
    'booking_overlap' =>
      'المورد محجوز بالفعل خلال جزء من الفترة المختارة. اختر وقتًا آخر.',
    'booking_crosses_business_date' =>
      'يجب أن يبدأ الحجز وينتهي في اليوم نفسه ولا يعبر منتصف الليل.',
    'booking_outside_availability' => 'الوقت المختار خارج ساعات إتاحة المورد. راجع جدول الإتاحة واختر فترة متاحة.',
    'booking_blackout' =>
      'المورد مغلق أو تحت الصيانة خلال الفترة المختارة. اختر موعدًا آخر.',
    'booking_start_not_future' => 'يجب أن يكون موعد الحجز في المستقبل.',
    'invalid_booking_period' =>
      'فترة الحجز غير صحيحة. اجعل وقت النهاية بعد البداية وفي اليوم نفسه.',
    'booking_resource_mismatch' =>
      'تغيرت بيانات المورد أو الخدمة. أعد اختيار المورد من القائمة المحدثة.',
    'booking_service_unavailable' =>
      'الخدمة المرتبطة بالمورد غير متاحة في هذا الفرع حاليًا.',
    'booking_service_not_active' =>
      'الخدمة المرتبطة بالمورد غير نشطة. اختر موردًا آخر أو فعّل الخدمة.',
    'bookable_resource_not_found' =>
      'مورد الحجز لم يعد متاحًا. حدّث القائمة واختر موردًا آخر.',
    'bookable_resource_not_active' =>
      'مورد الحجز متوقف أو تحت الصيانة ولا يقبل حجوزات جديدة.',
    'session_slot_required' || 'session_slot_reference_required' =>
      'اختر موعدًا منشورًا ومتاحًا قبل تأكيد الحجز.',
    'session_slot_not_found' || 'session_slot_not_open' =>
      'الموعد المختار لم يعد متاحًا. حدّث القائمة واختر موعدًا آخر.',
    'session_slot_type_mismatch' =>
      'الموعد لا يطابق نوع المورد. أعد اختيار المورد والموعد.',
    'booking_quote_mismatch' =>
      'تغير سعر الخدمة أو بيانات الحجز. أعد اختيار المورد ثم حاول مجددًا.',
    'manual_booking_sale_forbidden' => 'الحجز التشغيلي بلا مقابل لا يصدر فاتورة. اختر الحجز المفوتر للخدمات المدفوعة.',
    _ => fallback,
  };
}

void main() => runApp(const GoMobileApp());

class MobileNotificationService {
  final plugin = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    try {
      await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      await plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}
  }

  Future<void> show(String title, String body) async {
    try {
      await plugin.show(
        title.hashCode,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'go_updates',
            'GO Updates',
            channelDescription: 'تنبيهات نظام GO',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}

class ApiClient {
  ApiClient({String? baseUrl})
    : baseUrl =
          (baseUrl ??
                  const String.fromEnvironment(
                    'API_BASE_URL',
                    defaultValue: productionApiBaseUrl,
                  ))
              .replaceAll(RegExp(r'/$'), '');
  final String baseUrl;
  final secure = const FlutterSecureStorage();
  Future<bool>? _refreshing;
  bool get configured => baseUrl.isNotEmpty;

  Future<void> saveTokens(Map<String, dynamic> data) async {
    await secure.write(
      key: 'go_access_token',
      value: data['accessToken']?.toString(),
    );
    await secure.write(
      key: 'go_refresh_token',
      value: data['refreshToken']?.toString(),
    );
  }

  Future<void> clearTokens() async {
    await secure.delete(key: 'go_access_token');
    await secure.delete(key: 'go_refresh_token');
    await secure.delete(key: 'go_session_audience');
  }

  Future<String> _deviceId() async {
    final saved = await secure.read(key: 'go_device_id');
    if (saved?.isNotEmpty == true) return saved!;
    final random = Random.secure();
    final generated = List.generate(
      4,
      (_) => random.nextInt(0x7fffffff).toRadixString(16),
    ).join('-');
    await secure.write(key: 'go_device_id', value: generated);
    return generated;
  }

  String _requestId() =>
      'mobile-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  Future<bool> isStaffSession() async =>
      (await secure.read(key: 'go_session_audience')) != 'member';

  Future<dynamic> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool retryAuthentication = true,
  }) async {
    if (!configured) return null;
    final persistedHeaders = <String, String>{...?extraHeaders};
    if (method == 'POST') {
      persistedHeaders.putIfAbsent('Idempotency-Key', _requestId);
    }
    final token = await secure.read(key: 'go_access_token');
    final parsedUri = Uri.parse('$baseUrl$path');
    final uri = parsedUri.replace(
      queryParameters: {...parsedUri.queryParameters, ...?query},
    );
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Device-Id': await _deviceId(),
      'X-Correlation-Id': _requestId(),
      if (token != null) 'Authorization': 'Bearer $token',
      ...persistedHeaders,
    };
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    late final http.Response response;
    try {
      final streamed = await request.send().timeout(
        const Duration(seconds: 30),
      );
      response = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const ApiFailure(
        'استغرق الخادم وقتًا طويلًا. تحقق من الشبكة وحاول مجددًا.',
      );
    } on http.ClientException {
      throw const ApiFailure(
        'تعذر الوصول إلى الخادم. تحقق من اتصال الإنترنت وحاول مجددًا.',
      );
    }
    if (response.statusCode == 401 &&
        retryAuthentication &&
        !path.contains('/auth/')) {
      if (await refreshSession()) {
        return this.request(
          path,
          method: method,
          body: body,
          query: query,
          extraHeaders: persistedHeaders,
          retryAuthentication: false,
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'تعذر إتمام الطلب (${response.statusCode})';
      String? code;
      try {
        final problem = jsonDecode(response.body);
        if (problem is Map) {
          message =
              problem['detail']?.toString() ??
              problem['title']?.toString() ??
              message;
          code = problem['code']?.toString();
        }
      } catch (_) {}
      throw ApiFailure(
        apiProblemMessage(code, message),
        statusCode: response.statusCode,
        code: code,
      );
    }
    if (response.statusCode == 204 || response.body.isEmpty) return null;
    final decoded = jsonDecode(response.body);
    return decoded is Map && decoded.containsKey('data')
        ? decoded['data']
        : decoded;
  }

  /// Uploads bytes to a short-lived storage URL returned by the files API.
  /// The URL is intentionally called without the GO bearer token; storage
  /// grants are scoped to one object and expire server-side.
  Future<void> uploadSignedBytes({
    required String uploadUrl,
    required List<int> bytes,
    required String contentType,
  }) async {
    try {
      final response = await http
          .put(
            Uri.parse(uploadUrl),
            headers: {'Content-Type': contentType},
            body: bytes,
          )
          .timeout(const Duration(seconds: 90));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'تعذر رفع الملف إلى التخزين الآمن (${response.statusCode}).',
        );
      }
    } on TimeoutException {
      throw Exception(
        'استغرق رفع الملف وقتًا طويلًا. تحقق من الشبكة وحاول مجددًا.',
      );
    } on http.ClientException {
      throw Exception('تعذر رفع الملف. تحقق من اتصال الإنترنت.');
    }
  }

  Future<bool> refreshSession() =>
      _refreshing ??= _performRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _performRefresh() async {
    final refreshToken = await secure.read(key: 'go_refresh_token');
    if (refreshToken == null || refreshToken.isEmpty) return false;
    try {
      final data = await request(
        '/auth/sessions/refreshes',
        method: 'POST',
        body: {'refreshToken': refreshToken},
        retryAuthentication: false,
      );
      if (data is! Map) return false;
      await saveTokens(Map<String, dynamic>.from(data));
      return true;
    } catch (_) {
      await clearTokens();
      return false;
    }
  }

  Future<bool> hasSession() async =>
      (await secure.read(key: 'go_access_token'))?.isNotEmpty == true;

  Future<void> login({
    required bool staff,
    required String identifier,
    required String password,
  }) async {
    if (!configured) return;
    final memberUsesTestEmail = !staff && identifier.contains('@');
    final data = await request(
      staff
          ? '/auth/staff/password/sign-ins'
          : memberUsesTestEmail
          ? '/auth/member/test-email/password/sign-ins'
          : '/auth/member/password/sign-ins',
      method: 'POST',
      body: staff
          ? {'identifier': identifier, 'password': password}
          : memberUsesTestEmail
          ? {'email': identifier, 'password': password}
          : {'phone': identifier, 'password': password},
    );
    if (data is Map<String, dynamic>) {
      await saveTokens(data);
      await secure.write(
        key: 'go_session_audience',
        value: staff ? 'staff' : 'member',
      );
    }
  }

  Future<Map<String, dynamic>> currentUser() async {
    final data = await request('/me');
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> selfContext() async {
    final data = await request('/self');
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<List<Map<String, dynamic>>> selfBranches(String organizationId) async {
    final data = await request('/self/organizations/$organizationId/branches');
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<List<Map<String, dynamic>>> availableBranches(
    String organizationId,
  ) async {
    final data = await request(
      '/organizations/$organizationId/available-branches',
    );
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is Map) return [Map<String, dynamic>.from(data)];
    return [];
  }

  Future<List<Map<String, dynamic>>> members(
    String organizationId,
    String branchId,
  ) async {
    final data = await request(
      '/organizations/$organizationId/members',
      query: {'branchId': branchId, 'limit': '100'},
    );
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> registerMember(
    String organizationId,
    String branchId, {
    required String name,
    required String gender,
    required String nationalId,
    String? phone,
    String? email,
    String? birthDate,
    String? notes,
  }) async {
    final contacts = <Map<String, dynamic>>[
      if (phone?.isNotEmpty == true)
        {'type': 'PHONE', 'value': phone, 'isPrimary': true},
      if (email?.isNotEmpty == true)
        {
          'type': 'EMAIL',
          'value': email,
          'isPrimary': phone?.isNotEmpty != true,
        },
    ];
    final data = await request(
      '/organizations/$organizationId/members',
      method: 'POST',
      body: {
        'registrationBranchId': branchId,
        'name': name,
        'gender': gender,
        'nationalId': nationalId,
        if (birthDate?.isNotEmpty == true) 'birthDate': birthDate,
        if (notes?.isNotEmpty == true) 'notes': notes,
        'contacts': contacts,
      },
    );
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  Future<void> manualCheckIn(
    String organizationId,
    String branchId,
    String memberId,
  ) async {
    await request(
      '/organizations/$organizationId/attendance-attempts',
      method: 'POST',
      body: {'branchId': branchId, 'memberId': memberId},
    );
  }

  Future<void> markNotificationRead(String id) async {
    await request('/me/account-notifications/$id/read', method: 'POST');
  }

  Future<Map<String, dynamic>?> dashboard(
    String organizationId,
    String branchId,
  ) async {
    final range = riyadhDateRange();
    final data = await request(
      '/organizations/$organizationId/dashboard/summary',
      query: {'branchId': branchId, 'from': range.from, 'to': range.to},
    );
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  Future<List<Map<String, dynamic>>> revenueTrend(
    String organizationId,
    String branchId,
  ) async {
    final range = riyadhDateRange(days: 30);
    final data = await request(
      '/organizations/$organizationId/reports/revenue-trend',
      query: {'branchId': branchId, 'from': range.from, 'to': range.to},
    );
    if (data is! List) return [];
    return data
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<List<Map<String, dynamic>>> notifications() async {
    final data = await request(
      '/me/account-notifications',
      query: {'limit': '30'},
    );
    if (data is List) {
      return data.whereType<Map>().map((e) {
        final item = Map<String, dynamic>.from(e);
        item['unread'] = item['readAt'] == null;
        item['type'] = item['purpose'] == 'TRANSACTIONAL' ? 'success' : 'info';
        item['createdAtLabel'] = _relativeTime(item['createdAt']?.toString());
        return item;
      }).toList();
    }
    return [];
  }

  Future<void> markAllNotificationsRead() async {
    await request('/me/account-notifications/read-all', method: 'POST');
  }

  Future<List<Map<String, dynamic>>> listResource(
    String organizationId,
    String branchId,
    String path, {
    String? memberId,
  }) async {
    final query = resourceQueryFor(path, branchId);
    final data = await request(
      path
          .replaceAll('{organizationId}', organizationId)
          .replaceAll('{memberId}', memberId ?? '')
          .replaceAll('{branchId}', branchId)
          .replaceAll('{businessDate}', riyadhBusinessDate()),
      query: query,
    );
    if (data is List) {
      return data
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (data is Map) return [Map<String, dynamic>.from(data)];
    return [];
  }

  Future<List<ApiOperation>> openApiOperations() async {
    final document = await request('/openapi.json');
    if (document is! Map || document['paths'] is! Map) return [];
    final operations = <ApiOperation>[];
    for (final pathEntry in (document['paths'] as Map).entries) {
      final rawPath = pathEntry.key.toString();
      if (!rawPath.startsWith('/api/v1')) continue;
      if (pathEntry.value is! Map) continue;
      for (final methodEntry in (pathEntry.value as Map).entries) {
        final method = methodEntry.key.toString().toUpperCase();
        if (!const {'GET', 'POST', 'PATCH', 'PUT', 'DELETE'}.contains(method) ||
            methodEntry.value is! Map) {
          continue;
        }
        final definition = Map<String, dynamic>.from(methodEntry.value as Map);
        final operationId = definition['operationId']?.toString();
        if (operationId == null || operationId.isEmpty) continue;
        operations.add(
          ApiOperation(
            method: method,
            path: rawPath.replaceFirst('/api/v1', ''),
            operationId: operationId,
            description:
                definition['description']?.toString() ??
                definition['summary']?.toString() ??
                '',
          ),
        );
      }
    }
    operations.sort((a, b) => a.path.compareTo(b.path));
    return operations;
  }
}

class ApiOperation {
  const ApiOperation({
    required this.method,
    required this.path,
    required this.operationId,
    required this.description,
  });
  final String method;
  final String path;
  final String operationId;
  final String description;

  String get module {
    if (path.contains('/self/')) return 'self';
    if (path.contains('/members')) return 'members';
    if (path.contains('/employees') ||
        path.contains('/trainer') ||
        path.contains('/measurement') ||
        path.contains('/position')) {
      return 'workforce';
    }
    if (path.contains('/subscription')) return 'subscriptions';
    if (path.contains('/restaurant') || path.contains('/daily-menu')) {
      return 'restaurant';
    }
    if (path.contains('/crm') ||
        path.contains('/notification') ||
        path.contains('/communication') ||
        path.contains('/feedback') ||
        path.contains('/online-request') ||
        path.contains('/whatsapp')) {
      return 'engagement';
    }
    if (path.contains('/invoice') ||
        path.contains('/payment') ||
        path.contains('/refund') ||
        path.contains('/expense') ||
        path.contains('/cash-') ||
        path.contains('/other-income') ||
        path.contains('/orders')) {
      return 'finance';
    }
    if (path.contains('/attendance') ||
        path.contains('/reservation') ||
        path.contains('/bookable') ||
        path.contains('/facilit') ||
        path.contains('/locker') ||
        path.contains('/access-')) {
      return 'operations';
    }
    if (path.contains('/report') ||
        path.contains('/audit') ||
        path.contains('/dashboard')) {
      return 'reporting';
    }
    if (path.contains('/activit') ||
        path.contains('/service') ||
        path.contains('/package') ||
        path.contains('/price') ||
        path.contains('/promotion') ||
        path.contains('/retail') ||
        path.contains('/commercial')) {
      return 'catalog';
    }
    if (path.contains('/roles') ||
        path.contains('/permissions') ||
        path.contains('/user-accounts') ||
        path.contains('/branches')) {
      return 'organization';
    }
    return 'platform';
  }

  bool get isMutation => method != 'GET';
}

const apiModuleLabels = <String, String>{
  'platform': 'المنصة والحساب',
  'organization': 'المؤسسة والصلاحيات',
  'members': 'الأعضاء والملفات',
  'workforce': 'الموظفون والمدربون',
  'catalog': 'الكتالوج والتجارة',
  'subscriptions': 'الاشتراكات',
  'finance': 'المبيعات والمالية',
  'operations': 'الحضور والحجوزات',
  'restaurant': 'المطعم',
  'engagement': 'CRM والتواصل',
  'reporting': 'التقارير والتدقيق',
  'self': 'الخدمة الذاتية',
};

const _permissionImplications = <String, List<String>>{
  'members.manage': ['members.read'],
  'members.block': ['members.read', 'subscriptions.read'],
  'members.sensitive.read': ['members.contacts.read'],
  'members.sensitive.manage': ['members.sensitive.read'],
  'members.accounts.manage': ['members.read'],
  'workforce.manage': ['workforce.read'],
  'workforce.assignments.manage': ['workforce.read'],
  'workforce.accounts.manage': ['workforce.read'],
  'files.manage': ['files.read'],
  'attendance.devices.manage': ['attendance.devices.read'],
  'catalog.manage': ['catalog.read'],
  'catalog.availability.manage': ['catalog.read'],
  'commercial.manage': ['commercial.read'],
  'pricing.manage': ['commercial.read'],
  'promotions.manage': ['commercial.read'],
  'policies.manage': ['commercial.read'],
  'subscriptions.freeze': ['subscriptions.read'],
  'subscriptions.cancel': ['subscriptions.read'],
  'subscriptions.renew': ['subscriptions.read'],
  'subscriptions.adjustments.manage': ['subscriptions.read'],
  'sales.checkout': [
    'sales.read',
    'members.read',
    'commercial.read',
    'restaurant.catalog.read',
    'restaurant.menu.read',
    'retail.catalog.read',
    'retail.inventory.read',
  ],
  'finance.payments.record': ['finance.payments.read', 'finance.invoices.read'],
  'finance.refunds.issue': ['finance.payments.read'],
  'finance.refunds.approve': ['finance.payments.read'],
  'finance.expenses.manage': ['finance.expenses.read'],
  'finance.expenses.approve': ['finance.expenses.read'],
  'finance.expenses.pay': ['finance.expenses.read'],
  'attendance.check-in': [
    'attendance.read',
    'members.read',
    'subscriptions.read',
  ],
  'bookings.create': ['bookings.read', 'members.read', 'catalog.read'],
  'bookings.manage': ['bookings.read', 'members.read', 'catalog.read'],
  'workforce.shifts.manage': ['workforce.shifts.read', 'workforce.read'],
  'workforce.attendance.record': ['workforce.shifts.read', 'workforce.read'],
  'crm.leads.manage': ['crm.leads.read'],
  'restaurant.orders.prepare': ['restaurant.orders.read'],
  'restaurant.orders.manage': ['restaurant.orders.read'],
  'notifications.send': ['notifications.read', 'members.read'],
  'notification-templates.manage': ['notification-templates.read'],
  'feedback.reply': ['feedback.read'],
  'finance.other-income.manage': ['finance.other-income.read'],
  'iam.roles.manage': ['iam.roles.read'],
  'iam.assignments.manage': ['iam.roles.read', 'iam.accounts.read'],
  'measurements.manage': ['measurements.read', 'members.read'],
  'measurement-types.manage': ['measurements.read'],
  'access-credentials.manage': ['access-credentials.read', 'members.read'],
  'online-requests.manage': ['online-requests.read'],
  'lockers.manage': ['lockers.read', 'members.read'],
  'branch.manage': ['branch.read', 'organization.read'],
  'bookings.facilities.manage': ['bookings.read', 'coaching.read'],
  'finance.cash-points.manage': ['finance.cash-points.read'],
  'finance.cash-shifts.manage': ['finance.cash-points.read'],
  'restaurant.catalog.manage': ['restaurant.catalog.read'],
  'restaurant.pricing.manage': ['restaurant.catalog.read'],
  'restaurant.menu.read': ['restaurant.catalog.read'],
  'restaurant.menu.manage': ['restaurant.menu.read', 'restaurant.catalog.read'],
  'restaurant.meal-plans.redeem': [
    'restaurant.menu.read',
    'members.read',
    'subscriptions.read',
  ],
  'coaching.manage': ['coaching.read', 'workforce.read'],
  'coaching.assignments.manage': ['coaching.read', 'members.read'],
  'coaching.schedule.manage': ['coaching.read'],
  'reporting.rebuild': ['reporting.read'],
  'notifications.whatsapp.manage': ['notifications.whatsapp.read'],
  'coaching.commissions.manage': [
    'coaching.commissions.read',
    'coaching.read',
    'workforce.read',
  ],
  'coaching.training-plans.manage': [
    'coaching.training-plans.read',
    'coaching.read',
    'members.read',
  ],
  'crm.follow-ups.manage': ['crm.follow-ups.read', 'crm.leads.read'],
  'retail.catalog.manage': ['retail.catalog.read'],
  'retail.pricing.manage': ['retail.catalog.read'],
  'retail.inventory.manage': ['retail.inventory.read', 'retail.catalog.read'],
};

enum WorkflowFieldType {
  hidden,
  text,
  phone,
  email,
  password,
  number,
  date,
  dateTime,
  textarea,
  select,
  reference,
  multiReference,
  checkbox,
}

class WorkflowChoice {
  const WorkflowChoice(this.value, this.label);
  final String value;
  final String label;
}

class WorkflowField {
  const WorkflowField({
    required this.name,
    required this.label,
    this.type = WorkflowFieldType.text,
    this.required = false,
    this.initialValue = '',
    this.choices = const [],
    this.referencePath,
    this.labelKeys = const ['name', 'displayName'],
    this.subtitleKeys = const [],
    this.copyValues = const {},
    this.visibleWhenField,
    this.visibleWhenValues = const [],
    this.autoFillDate = true,
    this.allowZero = false,
  });
  final String name;
  final String label;
  final WorkflowFieldType type;
  final bool required;
  final String initialValue;
  final List<WorkflowChoice> choices;
  final String? referencePath;
  final List<String> labelKeys;
  final List<String> subtitleKeys;
  final Map<String, String> copyValues;
  final String? visibleWhenField;
  final List<String> visibleWhenValues;
  final bool autoFillDate;
  final bool allowZero;
}

typedef WorkflowBodyBuilder = Map<String, dynamic> Function(
  Map<String, String> values,
  GoController controller,
);

class MobileWorkflow {
  const MobileWorkflow({
    required this.operationId,
    required this.title,
    required this.description,
    required this.submitLabel,
    required this.successMessage,
    required this.method,
    required this.path,
    required this.icon,
    required this.fields,
    required this.body,
  });
  final String operationId;
  final String title;
  final String description;
  final String submitLabel;
  final String successMessage;
  final String method;
  final String path;
  final IconData icon;
  final List<WorkflowField> fields;
  final WorkflowBodyBuilder body;
}

final mobileWorkflows = <MobileWorkflow>[
  MobileWorkflow(
    operationId: 'createSubscription',
    title: 'بيع باقة وإصدار فاتورة',
    description:
        'اختر العضو والبـاقة ووقت البداية. يُفعّل الاشتراك بعد تحصيل الفاتورة.',
    submitLabel: 'إنشاء الاشتراك والفاتورة',
    successMessage: 'تم إنشاء الاشتراك والفاتورة المعلقة.',
    method: 'POST',
    path: '/organizations/{organizationId}/orders',
    icon: Icons.add_card_rounded,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr', 'memberName'],
        subtitleKeys: ['memberNumber', 'phoneE164'],
      ),
      WorkflowField(
        name: 'packageId',
        label: 'الباقة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/packages',
        labelKeys: ['nameAr', 'packageName', 'name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'startAt',
        label: 'تاريخ ووقت البداية',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(name: 'promoCode', label: 'كود الخصم'),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      'memberId': values['memberId'],
      'lines': [
        {
          'type': 'MEMBERSHIP',
          'targetId': values['packageId'],
          'quantity': 1,
          'accessBranchId': controller.branchId,
          'startAt': _asIso(values['startAt']),
          if (values['promoCode']?.isNotEmpty == true)
            'promoCode': values['promoCode'],
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'rescheduleSubscriptionStart',
    title: 'تغيير تاريخ بدء اشتراك',
    description: 'متاح فقط للاشتراكات التي لم تبدأ بعد، ويعيد النظام حساب نهاية المدة وفترات الدخول تلقائيًا.',
    submitLabel: 'حفظ تاريخ البداية الجديد',
    successMessage: 'تم تغيير تاريخ بدء الاشتراك.',
    method: 'POST',
    path: '/organizations/{organizationId}/subscriptions/{subscriptionId}/start-date-changes',
    icon: Icons.edit_calendar_outlined,
    fields: [
      WorkflowField(
        name: 'subscriptionId',
        label: 'الاشتراك الذي لم يبدأ',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/subscriptions',
        labelKeys: ['memberName', 'packageName', 'subscriptionNumber'],
        subtitleKeys: ['status', 'termStart'],
        copyValues: {'expectedVersion': 'version'},
      ),
      WorkflowField(
        name: 'expectedVersion',
        label: 'إصدار السجل',
        type: WorkflowFieldType.hidden,
        required: true,
      ),
      WorkflowField(
        name: 'startAt',
        label: 'تاريخ ووقت البداية الجديد',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'reason',
        label: 'سبب التغيير',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'expectedVersion': int.tryParse(values['expectedVersion'] ?? '') ?? 1,
      'startAt': _asIso(values['startAt']),
      'reason': values['reason']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'recordPayment',
    title: 'تسجيل دفعة',
    description: 'سجل دفعة بطاقة أو تحويل واربطها بالفاتورة المستحقة.',
    submitLabel: 'تسجيل الدفعة',
    successMessage: 'تم تسجيل الدفعة بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/payments',
    icon: Icons.payments_outlined,
    fields: [
      WorkflowField(
        name: 'invoiceId',
        label: 'الفاتورة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/invoices',
        labelKeys: ['invoiceNumber', 'number'],
        subtitleKeys: ['buyerName', 'outstandingMinor'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'المبلغ (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'method',
        label: 'طريقة الدفع',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'CARD',
        choices: [
          WorkflowChoice('CASH', 'نقدي'),
          WorkflowChoice('CARD', 'بطاقة بنكية'),
          WorkflowChoice('BANK_TRANSFER', 'تحويل بنكي'),
          WorkflowChoice('GATEWAY', 'بوابة دفع'),
          WorkflowChoice('WALLET', 'محفظة إلكترونية'),
        ],
      ),
      WorkflowField(
        name: 'cashierShiftId',
        label: 'وردية الصندوق المفتوحة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cashier-shifts',
        labelKeys: ['cashPointName', 'cashierName'],
        subtitleKeys: ['openedAt', 'status'],
        visibleWhenField: 'method',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(
        name: 'cashPointId',
        label: 'نقطة الصندوق',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cash-points',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
        visibleWhenField: 'method',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(name: 'externalReference', label: 'مرجع الدفع'),
    ],
    body: (values, controller) {
      final minor = ((double.tryParse(values['amount'] ?? '') ?? 0) * 100)
          .round()
          .toString();
      return {
        'collectionBranchId': controller.branchId,
        'method': values['method'],
        'amountMinor': minor,
        'allocations': [
          {'invoiceId': values['invoiceId'], 'amountMinor': minor},
        ],
        if (values['method'] == 'CASH') ...{
          'cashierShiftId': values['cashierShiftId'],
          'cashPointId': values['cashPointId'],
        },
        if (values['externalReference']?.isNotEmpty == true)
          'externalReference': values['externalReference'],
      };
    },
  ),
  MobileWorkflow(
    operationId: 'recordSplitPayment',
    title: 'تحصيل مقسّم',
    description: 'قسّم تحصيل فاتورة واحدة بين وسيلتي دفع. يجب أن يساوي مجموع الجزأين الرصيد المستحق.',
    submitLabel: 'تسجيل جزأي الدفع',
    successMessage: 'تم تسجيل التحصيل المقسّم وتحديث الفاتورة.',
    method: 'POST',
    path: '/organizations/{organizationId}/payments',
    icon: Icons.call_split_rounded,
    fields: [
      WorkflowField(
        name: 'invoiceId',
        label: 'الفاتورة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/invoices',
        labelKeys: ['invoiceNumber', 'number'],
        subtitleKeys: ['buyerName', 'outstandingMinor'],
      ),
      WorkflowField(
        name: 'firstAmount',
        label: 'مبلغ الجزء الأول (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'firstMethod',
        label: 'وسيلة الجزء الأول',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'CARD',
        choices: [
          WorkflowChoice('CASH', 'نقدي'),
          WorkflowChoice('CARD', 'بطاقة بنكية'),
          WorkflowChoice('BANK_TRANSFER', 'تحويل بنكي'),
          WorkflowChoice('GATEWAY', 'بوابة دفع'),
          WorkflowChoice('WALLET', 'محفظة إلكترونية'),
        ],
      ),
      WorkflowField(
        name: 'firstCashierShiftId',
        label: 'وردية الجزء النقدي الأول',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cashier-shifts',
        labelKeys: ['cashPointName', 'cashierName'],
        subtitleKeys: ['openedAt', 'status'],
        visibleWhenField: 'firstMethod',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(
        name: 'firstCashPointId',
        label: 'نقطة صندوق الجزء الأول',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cash-points',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
        visibleWhenField: 'firstMethod',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(name: 'firstReference', label: 'مرجع الجزء الأول'),
      WorkflowField(
        name: 'secondAmount',
        label: 'مبلغ الجزء الثاني (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'secondMethod',
        label: 'وسيلة الجزء الثاني',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'BANK_TRANSFER',
        choices: [
          WorkflowChoice('CASH', 'نقدي'),
          WorkflowChoice('CARD', 'بطاقة بنكية'),
          WorkflowChoice('BANK_TRANSFER', 'تحويل بنكي'),
          WorkflowChoice('GATEWAY', 'بوابة دفع'),
          WorkflowChoice('WALLET', 'محفظة إلكترونية'),
        ],
      ),
      WorkflowField(
        name: 'secondCashierShiftId',
        label: 'وردية الجزء النقدي الثاني',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cashier-shifts',
        labelKeys: ['cashPointName', 'cashierName'],
        subtitleKeys: ['openedAt', 'status'],
        visibleWhenField: 'secondMethod',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(
        name: 'secondCashPointId',
        label: 'نقطة صندوق الجزء الثاني',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cash-points',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
        visibleWhenField: 'secondMethod',
        visibleWhenValues: ['CASH'],
      ),
      WorkflowField(name: 'secondReference', label: 'مرجع الجزء الثاني'),
    ],
    body: (values, controller) {
      final firstMinor = _moneyMinor(values['firstAmount']);
      final secondMinor = _moneyMinor(values['secondAmount']);
      Map<String, dynamic> part(String prefix, String amountMinor) => {
        'method': values['${prefix}Method'],
        'amountMinor': amountMinor,
        'allocations': [
          {'invoiceId': values['invoiceId'], 'amountMinor': amountMinor},
        ],
        if (values['${prefix}Method'] == 'CASH') ...{
          'cashierShiftId': values['${prefix}CashierShiftId'],
          'cashPointId': values['${prefix}CashPointId'],
        } else if (values['${prefix}Reference']?.trim().isNotEmpty == true)
          'externalReference': values['${prefix}Reference']?.trim(),
      };

      return {
        'collectionBranchId': controller.branchId,
        'parts': [part('first', firstMinor), part('second', secondMinor)],
      };
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutSelfMemberPackage',
    title: 'شراء باقة عضوية',
    description: 'اختر الباقة وتاريخ البداية. سيُنشئ النظام طلبًا وفاتورة باسم العضو الحالي.',
    submitLabel: 'شراء الباقة وإنشاء الفاتورة',
    successMessage: 'تم إنشاء الطلب والفاتورة، ويبدأ الاشتراك بعد السداد.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/members/{memberId}/orders',
    icon: Icons.card_membership_outlined,
    fields: [
      WorkflowField(
        name: 'packageId',
        label: 'الباقة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/self/organizations/{organizationId}/packages',
        labelKeys: ['nameAr', 'packageName', 'name'],
        subtitleKeys: ['code', 'durationDays'],
      ),
      WorkflowField(
        name: 'startAt',
        label: 'تاريخ ووقت البداية',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(name: 'promoCode', label: 'كود الخصم'),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      'lines': [
        {
          'type': 'MEMBERSHIP',
          'targetId': values['packageId'],
          'quantity': 1,
          'accessBranchId': controller.branchId,
          'startAt': _asIso(values['startAt']),
          if (values['promoCode']?.isNotEmpty == true)
            'promoCode': values['promoCode'],
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'createCrmLead',
    title: 'إضافة عميل محتمل',
    description: 'سجل وسيلة التواصل والاهتمام ليتمكن الفريق من المتابعة.',
    submitLabel: 'إضافة العميل',
    successMessage: 'تمت إضافة العميل إلى قائمة المتابعة.',
    method: 'POST',
    path: '/organizations/{organizationId}/crm/leads',
    icon: Icons.person_add_alt_outlined,
    fields: [
      WorkflowField(name: 'fullName', label: 'الاسم الكامل', required: true),
      WorkflowField(
        name: 'phone',
        label: 'رقم الجوال',
        type: WorkflowFieldType.phone,
      ),
      WorkflowField(
        name: 'email',
        label: 'البريد الإلكتروني',
        type: WorkflowFieldType.email,
      ),
      WorkflowField(
        name: 'originType',
        label: 'مصدر العميل',
        type: WorkflowFieldType.select,
        initialValue: 'WALK_IN',
        choices: [
          WorkflowChoice('WALK_IN', 'زيارة النادي'),
          WorkflowChoice('PHONE', 'اتصال هاتفي'),
          WorkflowChoice('WEBSITE', 'الموقع الإلكتروني'),
          WorkflowChoice('REFERRAL', 'ترشيح'),
          WorkflowChoice('SOCIAL_MEDIA', 'التواصل الاجتماعي'),
          WorkflowChoice('OTHER', 'أخرى'),
        ],
      ),
      WorkflowField(
        name: 'interestType',
        label: 'الاهتمام',
        type: WorkflowFieldType.select,
        initialValue: 'GENERAL',
        choices: [
          WorkflowChoice('GENERAL', 'استفسار عام'),
          WorkflowChoice('PACKAGE', 'باقة عضوية'),
          WorkflowChoice('PERSONAL_TRAINING', 'تدريب شخصي'),
          WorkflowChoice('MEAL_PLAN', 'خطة غذائية'),
        ],
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'fullName': values['fullName']?.trim(),
      if (values['phone']?.trim().isNotEmpty == true)
        'phone': values['phone']?.replaceAll(RegExp(r'[\s()-]'), ''),
      if (values['email']?.trim().isNotEmpty == true)
        'email': values['email']?.trim().toLowerCase(),
      'originType': values['originType'],
      'interestType': values['interestType'],
      if (values['notes']?.trim().isNotEmpty == true)
        'notes': values['notes']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'recordExpense',
    title: 'تسجيل مصروف',
    description: 'سجل المصروف ليبدأ دورة المراجعة والاعتماد.',
    submitLabel: 'تسجيل المصروف',
    successMessage: 'تم تسجيل المصروف بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/expenses',
    icon: Icons.money_off_csred_outlined,
    fields: [
      WorkflowField(
        name: 'categoryId',
        label: 'تصنيف المصروف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/expense-categories',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'المبلغ (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'description',
        label: 'البيان والغرض',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'categoryId': values['categoryId'],
      'amountMinor': ((double.tryParse(values['amount'] ?? '') ?? 0) * 100)
          .round()
          .toString(),
      'description': values['description'],
    },
  ),
  MobileWorkflow(
    operationId: 'recordOtherIncome',
    title: 'تسجيل إيراد آخر',
    description: 'سجل إيرادًا غير مرتبط بفاتورة في السجل المالي.',
    submitLabel: 'تسجيل الإيراد',
    successMessage: 'تم تسجيل الإيراد بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/other-income',
    icon: Icons.savings_outlined,
    fields: [
      WorkflowField(
        name: 'categoryId',
        label: 'تصنيف الإيراد',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath:
            '/organizations/{organizationId}/other-income-categories',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'المبلغ (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'paymentMethodCode',
        label: 'طريقة التحصيل',
        type: WorkflowFieldType.select,
        initialValue: 'CARD',
        choices: [
          WorkflowChoice('CARD', 'بطاقة بنكية'),
          WorkflowChoice('BANK_TRANSFER', 'تحويل بنكي'),
          WorkflowChoice('GATEWAY', 'بوابة دفع'),
          WorkflowChoice('WALLET', 'محفظة إلكترونية'),
        ],
      ),
      WorkflowField(
        name: 'description',
        label: 'البيان',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'categoryId': values['categoryId'],
      'amountMinor': ((double.tryParse(values['amount'] ?? '') ?? 0) * 100)
          .round()
          .toString(),
      'paymentMethodCode': values['paymentMethodCode'],
      'description': values['description'],
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    },
  ),
  MobileWorkflow(
    operationId: 'scheduleEmployeeShift',
    title: 'جدولة مناوبة',
    description: 'اختر الموظف وحدد بداية ونهاية المناوبة في الفرع الحالي.',
    submitLabel: 'حفظ المناوبة',
    successMessage: 'تمت جدولة المناوبة بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/employee-shifts',
    icon: Icons.calendar_view_week_outlined,
    fields: [
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'fullNameAr', 'displayName'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'startsAt',
        label: 'بداية المناوبة',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'endsAt',
        label: 'نهاية المناوبة',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'employeeId': values['employeeId'],
      'startsAt': _asIso(values['startsAt']),
      'endsAt': _asIso(values['endsAt']),
      if (values['notes']?.isNotEmpty == true) 'notes': values['notes'],
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutOrder',
    title: 'طلب مطعم جديد',
    description: 'اختر العضو والصنف والكمية ويُحتسب السعر المعتمد تلقائيًا.',
    submitLabel: 'إنشاء الطلب',
    successMessage: 'تم إنشاء الطلب وإرساله للمتابعة.',
    method: 'POST',
    path: '/organizations/{organizationId}/orders',
    icon: Icons.restaurant_menu_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'memberName'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'mealId',
        label: 'الصنف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/restaurant/meals',
        labelKeys: ['nameAr', 'mealName', 'name'],
        subtitleKeys: ['categoryName'],
      ),
      WorkflowField(
        name: 'quantity',
        label: 'الكمية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      'memberId': values['memberId'],
      'lines': [
        {
          'type': 'RESTAURANT',
          'targetId': values['mealId'],
          'quantity': int.tryParse(values['quantity'] ?? '') ?? 1,
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutServiceAtPos',
    title: 'بيع خدمة',
    description: 'اختر العضو والخدمة والكمية؛ سيُنشئ النظام طلب البيع والفاتورة بالسعر النشط في الفرع.',
    submitLabel: 'إنشاء طلب الخدمة',
    successMessage: 'تم إنشاء طلب الخدمة والفاتورة.',
    method: 'POST',
    path: '/organizations/{organizationId}/orders',
    icon: Icons.sports_gymnastics_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['categoryName', 'code'],
      ),
      WorkflowField(
        name: 'quantity',
        label: 'الكمية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
      WorkflowField(name: 'promoCode', label: 'كود الخصم (اختياري)'),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      'memberId': values['memberId'],
      'memberSegment': 'OTHER',
      'lines': [
        {
          'type': 'SERVICE',
          'targetId': values['serviceId'],
          'quantity': int.tryParse(values['quantity'] ?? '') ?? 1,
          if (values['promoCode']?.trim().isNotEmpty == true)
            'promoCode': values['promoCode']?.trim().toUpperCase(),
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutRetailAtPos',
    title: 'بيع منتج من المتجر',
    description: 'اختر المنتج والكمية والعضو عند الحاجة؛ سيُخصم المخزون ويصدر الطلب والفاتورة تلقائيًا.',
    submitLabel: 'إتمام بيع المنتج',
    successMessage: 'تم تسجيل بيع المنتج وإصدار الفاتورة.',
    method: 'POST',
    path: '/organizations/{organizationId}/orders',
    icon: Icons.shopping_bag_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو (اختياري)',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'productId',
        label: 'المنتج',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/retail/products',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['sku', 'code'],
      ),
      WorkflowField(
        name: 'quantity',
        label: 'الكمية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
      WorkflowField(name: 'promoCode', label: 'كود الخصم (اختياري)'),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      if (values['memberId']?.isNotEmpty == true)
        'memberId': values['memberId'],
      'memberSegment': 'OTHER',
      'lines': [
        {
          'type': 'RETAIL',
          'targetId': values['productId'],
          'quantity': int.tryParse(values['quantity'] ?? '') ?? 1,
          if (values['promoCode']?.trim().isNotEmpty == true)
            'promoCode': values['promoCode']?.trim().toUpperCase(),
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'createManualReservation',
    title: 'حجز جديد',
    description: 'اختر العميل والمورد وطريقة التأكيد؛ يمكنك إصدار فاتورة وتحصيلها من نقطة البيع أو تسجيل حجز تشغيلي بلا مقابل.',
    submitLabel: 'متابعة إنشاء الحجز',
    successMessage: 'تم إنشاء الحجز بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/reservations',
    icon: Icons.event_available_outlined,
    fields: [
      WorkflowField(
        name: 'customerType',
        label: 'نوع العميل',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MEMBER',
        choices: [
          WorkflowChoice('MEMBER', 'عضو'),
          WorkflowChoice('VISITOR', 'زائر'),
        ],
      ),
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr', 'memberName'],
        subtitleKeys: ['memberNumber', 'phoneE164'],
        visibleWhenField: 'customerType',
        visibleWhenValues: ['MEMBER'],
      ),
      WorkflowField(
        name: 'guestName',
        label: 'اسم الزائر',
        required: true,
        visibleWhenField: 'customerType',
        visibleWhenValues: ['VISITOR'],
      ),
      WorkflowField(
        name: 'guestPhoneE164',
        label: 'جوال الزائر',
        type: WorkflowFieldType.phone,
        required: true,
        visibleWhenField: 'customerType',
        visibleWhenValues: ['VISITOR'],
      ),
      WorkflowField(
        name: 'guestEmail',
        label: 'البريد الإلكتروني للزائر',
        type: WorkflowFieldType.email,
        visibleWhenField: 'customerType',
        visibleWhenValues: ['VISITOR'],
      ),
      WorkflowField(
        name: 'billingMode',
        label: 'طريقة تأكيد الحجز',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'INVOICE',
        choices: [
          WorkflowChoice('INVOICE', 'إصدار فاتورة وتحصيل قيمة الحجز'),
          WorkflowChoice('OPERATIONAL', 'حجز تشغيلي بلا مقابل'),
        ],
      ),
      WorkflowField(
        name: 'resourceId',
        label: 'الحصة أو المرفق',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/bookable-resources',
        labelKeys: ['nameAr', 'resourceName', 'name'],
        subtitleKeys: ['type'],
        copyValues: {'serviceId': 'serviceId', 'resourceType': 'type'},
      ),
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.hidden,
        required: true,
      ),
      WorkflowField(
        name: 'resourceType',
        label: 'نوع المورد',
        type: WorkflowFieldType.hidden,
        required: true,
      ),
      WorkflowField(
        name: 'sessionSlotId',
        label: 'الموعد المتاح',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/bookable-resources/{resourceId}/session-slots',
        labelKeys: ['startsAt', 'name'],
        subtitleKeys: ['endsAt', 'remainingCapacity'],
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['CLASS', 'PERSONAL_TRAINING', 'APPOINTMENT'],
      ),
      WorkflowField(
        name: 'startsAt',
        label: 'بداية حجز الملعب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(),
        autoFillDate: false,
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
      WorkflowField(
        name: 'endsAt',
        label: 'نهاية حجز الملعب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(additionalHours: 1),
        autoFillDate: false,
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
      WorkflowField(
        name: 'seats',
        label: 'عدد المقاعد',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['CLASS'],
      ),
      WorkflowField(
        name: 'participantCount',
        label: 'عدد المشاركين',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
    ],
    body: (values, controller) {
      final type = values['resourceType'];
      final seats = type == 'CLASS'
          ? int.tryParse(values['seats'] ?? '') ?? 1
          : 1;
      return {
        'branchId': controller.branchId,
        if (values['customerType'] == 'MEMBER')
          'memberId': values['memberId']
        else ...{
          'guestName': values['guestName'],
          'guestPhoneE164': values['guestPhoneE164']?.replaceAll(
            RegExp(r'[\s()-]'),
            '',
          ),
          if (values['guestEmail']?.isNotEmpty == true)
            'guestEmail': values['guestEmail']?.toLowerCase(),
        },
        'resourceId': values['resourceId'],
        'serviceId': values['serviceId'],
        'type': type,
        if (type == 'COURT') ...{
          'startsAt': _asIso(values['startsAt']),
          'endsAt': _asIso(values['endsAt']),
        } else
          'sessionSlotId': values['sessionSlotId'],
        'seats': seats,
        'participantCount': type == 'COURT'
            ? int.tryParse(values['participantCount'] ?? '') ?? 1
            : seats,
      };
    },
  ),
  MobileWorkflow(
    operationId: 'createEmployee',
    title: 'إضافة موظف وحساب دخول',
    description: 'أنشئ ملف الموظف وحساب دخوله والمسمى الوظيفي في الفرع الحالي في خطوة واحدة.',
    submitLabel: 'إنشاء الموظف وحسابه',
    successMessage: 'تم إنشاء الموظف وربط الحساب والصلاحيات بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/employees',
    icon: Icons.person_add_alt_1_outlined,
    fields: [
      WorkflowField(
        name: 'password',
        label: 'كلمة المرور',
        type: WorkflowFieldType.password,
        required: true,
      ),
      WorkflowField(
        name: 'confirmPassword',
        label: 'تأكيد كلمة المرور',
        type: WorkflowFieldType.password,
        required: true,
      ),
      WorkflowField(name: 'fullNameAr', label: 'اسم الموظف', required: true),
      WorkflowField(
        name: 'phoneE164',
        label: 'رقم الجوال',
        type: WorkflowFieldType.phone,
      ),
      WorkflowField(
        name: 'email',
        label: 'البريد الإلكتروني',
        type: WorkflowFieldType.email,
      ),
      WorkflowField(
        name: 'positionId',
        label: 'المسمى الوظيفي والصلاحيات',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/positions',
        labelKeys: ['nameAr', 'positionName', 'name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'startsOn',
        label: 'تاريخ بدء العمل',
        type: WorkflowFieldType.date,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'password': values['password'],
      'name': values['fullNameAr']?.trim(),
      if (values['phoneE164']?.isNotEmpty == true)
        'phone': values['phoneE164']?.replaceAll(RegExp(r'[\s()-]'), ''),
      if (values['email']?.isNotEmpty == true)
        'email': values['email']?.trim().toLowerCase(),
      'hireDate': values['startsOn'],
      'initialBranchId': controller.branchId,
      'initialPositionId': values['positionId'],
    },
  ),
  MobileWorkflow(
    operationId: 'assignEmployee',
    title: 'إضافة تعيين وظيفي',
    description: 'انقل الموظف أو أضف له تعيينًا جديدًا في فرع ومسمى مع فترة سريان واضحة.',
    submitLabel: 'حفظ التعيين الوظيفي',
    successMessage: 'تم حفظ تعيين الموظف.',
    method: 'POST',
    path: '/organizations/{organizationId}/employees/{employeeId}/assignments',
    icon: Icons.assignment_ind_outlined,
    fields: [
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['employeeNumber', 'positionName'],
      ),
      WorkflowField(
        name: 'positionId',
        label: 'المسمى الوظيفي',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/positions',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'branchId',
        label: 'الفرع',
        type: WorkflowFieldType.reference,
        required: true,
        initialValue: '',
        referencePath: '/organizations/{organizationId}/branches',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية التعيين (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'نهاية التعيين (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'positionId': values['positionId'],
      'branchId': values['branchId'],
      if (values['validFrom']?.isNotEmpty == true)
        'validFrom': _asIso(values['validFrom']),
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': _asIso(values['validUntil']),
    },
  ),
  MobileWorkflow(
    operationId: 'recordSelfTrainerMeasurement',
    title: 'تسجيل قياس للمتدرب',
    description: 'اختر العضو ونوع القياس وسجّل القيمة كما ظهرت في الجهاز.',
    submitLabel: 'حفظ القياس',
    successMessage: 'تم حفظ القياس في ملف العضو.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/trainer/measurement-sessions',
    icon: Icons.monitor_weight_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/self/organizations/{organizationId}/trainer/members',
        labelKeys: ['memberName', 'name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'measurementTypeId',
        label: 'نوع القياس',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/measurement-types',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['unit', 'code'],
      ),
      WorkflowField(
        name: 'value',
        label: 'القيمة',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'memberId': values['memberId'],
      'values': [
        {
          'measurementTypeId': values['measurementTypeId'],
          'value': values['value'],
        },
      ],
      'measuredAt': DateTime.now().toUtc().toIso8601String(),
      if (values['notes']?.isNotEmpty == true) 'notes': values['notes'],
    },
  ),
  MobileWorkflow(
    operationId: 'createSelfTrainerTrainingPlan',
    title: 'إنشاء خطة تدريب للمتدرب',
    description: 'اختر أحد المتدربين المسندين إليك وابدأ الخطة بتمرين واضح؛ يمكنك إنشاء تمارين إضافية ضمن خطط لاحقة.',
    submitLabel: 'إنشاء الخطة',
    successMessage: 'تم إنشاء خطة التدريب وإتاحتها للعضو.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/trainer/training-plans',
    icon: Icons.playlist_add_check_circle_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'المتدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/self/organizations/{organizationId}/trainer/members',
        labelKeys: ['memberName', 'name', 'fullNameAr'],
        subtitleKeys: ['memberNumber', 'branchName'],
      ),
      WorkflowField(name: 'name', label: 'اسم الخطة', required: true),
      WorkflowField(
        name: 'goal',
        label: 'هدف الخطة',
        type: WorkflowFieldType.textarea,
      ),
      WorkflowField(
        name: 'startsOn',
        label: 'تاريخ البداية',
        type: WorkflowFieldType.date,
        required: true,
      ),
      const WorkflowField(
        name: 'endsOn',
        label: 'تاريخ النهاية (اختياري)',
        type: WorkflowFieldType.date,
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'exerciseName',
        label: 'اسم التمرين الأول',
        required: true,
      ),
      WorkflowField(
        name: 'sets',
        label: 'عدد المجموعات',
        type: WorkflowFieldType.number,
      ),
      WorkflowField(name: 'repetitions', label: 'التكرارات'),
      WorkflowField(
        name: 'durationMinutes',
        label: 'المدة بالدقائق',
        type: WorkflowFieldType.number,
      ),
      WorkflowField(
        name: 'instructions',
        label: 'تعليمات التنفيذ',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'memberId': values['memberId'],
      'name': values['name']?.trim(),
      if (values['goal']?.trim().isNotEmpty == true)
        'goal': values['goal']?.trim(),
      'startsOn': values['startsOn'],
      if (values['endsOn']?.isNotEmpty == true) 'endsOn': values['endsOn'],
      'items': [
        {
          'dayNumber': 1,
          'sequenceNumber': 1,
          'exerciseName': values['exerciseName']?.trim(),
          if (values['sets']?.isNotEmpty == true)
            'sets': int.tryParse(values['sets']!),
          if (values['repetitions']?.trim().isNotEmpty == true)
            'repetitions': values['repetitions']?.trim(),
          if (values['durationMinutes']?.isNotEmpty == true)
            'durationMinutes': int.tryParse(values['durationMinutes']!),
          if (values['instructions']?.trim().isNotEmpty == true)
            'instructions': values['instructions']?.trim(),
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'recordMeasurementSession',
    title: 'تسجيل جلسة قياس',
    description: 'اختر العضو ونوع القياس وسجّل القيمة في ملفه الصحي.',
    submitLabel: 'حفظ جلسة القياس',
    successMessage: 'تم حفظ جلسة القياس في ملف العضو.',
    method: 'POST',
    path: '/organizations/{organizationId}/measurement-sessions',
    icon: Icons.monitor_weight_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr', 'memberName'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'measurementTypeId',
        label: 'نوع القياس',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/measurement-types',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['unit', 'code'],
      ),
      WorkflowField(
        name: 'value',
        label: 'القيمة',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'memberId': values['memberId'],
      'values': [
        {
          'measurementTypeId': values['measurementTypeId'],
          'value': values['value'],
        },
      ],
      'measuredAt': DateTime.now().toUtc().toIso8601String(),
      if (values['notes']?.isNotEmpty == true) 'notes': values['notes'],
    },
  ),
  MobileWorkflow(
    operationId: 'createSelfMemberFeedback',
    title: 'تذكرة تواصل جديدة',
    description: 'أرسل شكوى أو اقتراحًا إلى فريق النادي، وستتابع الردود من شاشة الرسائل.',
    submitLabel: 'إرسال التذكرة',
    successMessage: 'تم إرسال التذكرة إلى فريق النادي.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/members/{memberId}/feedback-cases',
    icon: Icons.add_comment_outlined,
    fields: [
      WorkflowField(
        name: 'caseType',
        label: 'نوع التذكرة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'SUGGESTION',
        choices: [
          WorkflowChoice('SUGGESTION', 'اقتراح'),
          WorkflowChoice('COMPLAINT', 'شكوى'),
        ],
      ),
      WorkflowField(name: 'subject', label: 'الموضوع', required: true),
      WorkflowField(
        name: 'description',
        label: 'التفاصيل',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
      WorkflowField(
        name: 'priority',
        label: 'الأولوية',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'NORMAL',
        choices: [
          WorkflowChoice('LOW', 'منخفضة'),
          WorkflowChoice('NORMAL', 'عادية'),
          WorkflowChoice('HIGH', 'مرتفعة'),
          WorkflowChoice('URGENT', 'عاجلة'),
        ],
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'caseType': values['caseType'],
      'subject': values['subject'],
      'description': values['description'],
      'priority': values['priority'],
    },
  ),
  MobileWorkflow(
    operationId: 'requestReportingRebuild',
    title: 'إعادة بناء التقارير',
    description: 'استخدم الإجراء إذا لم تعكس التقارير آخر العمليات المسجلة.',
    submitLabel: 'بدء التحديث',
    successMessage: 'بدأ تحديث بيانات التقارير في الخلفية.',
    method: 'POST',
    path: '/organizations/{organizationId}/reporting-rebuilds',
    icon: Icons.sync_rounded,
    fields: [
      WorkflowField(
        name: 'fromDate',
        label: 'من تاريخ',
        type: WorkflowFieldType.date,
        required: true,
      ),
      WorkflowField(
        name: 'toDate',
        label: 'إلى تاريخ',
        type: WorkflowFieldType.date,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'fromDate': values['fromDate'],
      'toDate': values['toDate'],
      'branchId': controller.branchId,
    },
  ),
  MobileWorkflow(
    operationId: 'createBranch',
    title: 'إضافة فرع',
    description: 'أضف فرعًا جديدًا للنادي ببيانات التشغيل والتوقيت المحلي.',
    submitLabel: 'حفظ الفرع',
    successMessage: 'تمت إضافة الفرع بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/branches',
    icon: Icons.add_business_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز الفرع', required: true),
      WorkflowField(name: 'name', label: 'اسم الفرع', required: true),
      WorkflowField(
        name: 'timezone',
        label: 'المنطقة الزمنية',
        initialValue: 'Asia/Riyadh',
      ),
      WorkflowField(
        name: 'address',
        label: 'العنوان',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      if (values['timezone']?.trim().isNotEmpty == true)
        'timezone': values['timezone']?.trim(),
      if (values['address']?.trim().isNotEmpty == true)
        'address': values['address']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createActivity',
    title: 'إضافة نشاط',
    description: 'عرّف نشاطًا رياضيًا جديدًا لربطه بالخدمات والمرافق.',
    submitLabel: 'إضافة النشاط',
    successMessage: 'تمت إضافة النشاط.',
    method: 'POST',
    path: '/organizations/{organizationId}/activities',
    icon: Icons.directions_run_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز النشاط', required: true),
      WorkflowField(name: 'name', label: 'اسم النشاط', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createServiceCategory',
    title: 'إضافة تصنيف خدمات',
    description: 'أضف تصنيفًا يسهّل تنظيم خدمات النادي.',
    submitLabel: 'حفظ التصنيف',
    successMessage: 'تمت إضافة تصنيف الخدمات.',
    method: 'POST',
    path: '/organizations/{organizationId}/service-categories',
    icon: Icons.category_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التصنيف', required: true),
      WorkflowField(name: 'name', label: 'اسم التصنيف', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createService',
    title: 'إضافة خدمة',
    description: 'عرّف الخدمة وتصنيفها والأنشطة المرتبطة بها.',
    submitLabel: 'إضافة الخدمة',
    successMessage: 'تمت إضافة الخدمة.',
    method: 'POST',
    path: '/organizations/{organizationId}/services',
    icon: Icons.sports_gymnastics_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز الخدمة', required: true),
      WorkflowField(name: 'name', label: 'اسم الخدمة', required: true),
      WorkflowField(
        name: 'categoryId',
        label: 'تصنيف الخدمة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/service-categories',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'activityIds',
        label: 'الأنشطة',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/activities',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'fulfillmentKind',
        label: 'نوع التنفيذ',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'FACILITY_ACCESS',
        choices: [
          WorkflowChoice('FACILITY_ACCESS', 'دخول مرفق'),
          WorkflowChoice('SESSION', 'جلسة'),
          WorkflowChoice('MEAL_PLAN', 'خطة وجبات'),
        ],
      ),
      WorkflowField(
        name: 'description',
        label: 'الوصف',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'categoryId': values['categoryId'],
      'activityIds': _selectedValues(values['activityIds']),
      'fulfillmentKind': values['fulfillmentKind'],
      if (values['description']?.trim().isNotEmpty == true)
        'description': values['description']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createCashPoint',
    title: 'إضافة نقطة تحصيل',
    description: 'أضف صندوقًا أو نقطة بيع للفرع الحالي.',
    submitLabel: 'حفظ نقطة التحصيل',
    successMessage: 'تمت إضافة نقطة التحصيل.',
    method: 'POST',
    path: '/organizations/{organizationId}/cash-points',
    icon: Icons.point_of_sale_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز نقطة التحصيل', required: true),
      WorkflowField(name: 'name', label: 'اسم نقطة التحصيل', required: true),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createLocker',
    title: 'إضافة خزانة',
    description: 'أضف خزانة جديدة إلى الفرع الحالي.',
    submitLabel: 'حفظ الخزانة',
    successMessage: 'تمت إضافة الخزانة.',
    method: 'POST',
    path: '/organizations/{organizationId}/lockers',
    icon: Icons.door_sliding_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز الخزانة', required: true),
      WorkflowField(
        name: 'lockerType',
        label: 'نوع الخزانة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'STANDARD',
        choices: [
          WorkflowChoice('STANDARD', 'عادية'),
          WorkflowChoice('LARGE', 'كبيرة'),
          WorkflowChoice('VALUABLES', 'مقتنيات ثمينة'),
        ],
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'code': values['code']?.trim().toUpperCase(),
      'lockerType': values['lockerType'],
      if (values['notes']?.trim().isNotEmpty == true)
        'notes': values['notes']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createMeasurementType',
    title: 'إضافة نوع قياس',
    description: 'عرّف قياسًا بدنيًا جديدًا ووحدته ونطاقه المقبول.',
    submitLabel: 'حفظ نوع القياس',
    successMessage: 'تمت إضافة نوع القياس.',
    method: 'POST',
    path: '/organizations/{organizationId}/measurement-types',
    icon: Icons.straighten_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز القياس', required: true),
      WorkflowField(name: 'name', label: 'اسم القياس', required: true),
      WorkflowField(name: 'unit', label: 'الوحدة', required: true),
      WorkflowField(
        name: 'dataKind',
        label: 'نوع الرقم',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'DECIMAL',
        choices: [
          WorkflowChoice('DECIMAL', 'عشري'),
          WorkflowChoice('INTEGER', 'عدد صحيح'),
        ],
      ),
      WorkflowField(
        name: 'minimumValue',
        label: 'أقل قيمة',
        type: WorkflowFieldType.number,
      ),
      WorkflowField(
        name: 'maximumValue',
        label: 'أعلى قيمة',
        type: WorkflowFieldType.number,
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'unit': values['unit']?.trim(),
      'dataKind': values['dataKind'],
      if (values['minimumValue']?.isNotEmpty == true)
        'minimumValue': double.tryParse(values['minimumValue']!),
      if (values['maximumValue']?.isNotEmpty == true)
        'maximumValue': double.tryParse(values['maximumValue']!),
    },
  ),
  MobileWorkflow(
    operationId: 'createPosition',
    title: 'إضافة مسمى وظيفي',
    description: 'أنشئ مسمى وظيفيًا وحدد صلاحياته مرة واحدة.',
    submitLabel: 'حفظ المسمى',
    successMessage: 'تمت إضافة المسمى الوظيفي.',
    method: 'POST',
    path: '/organizations/{organizationId}/positions',
    icon: Icons.account_tree_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز المسمى', required: true),
      WorkflowField(name: 'name', label: 'المسمى الوظيفي', required: true),
      WorkflowField(
        name: 'permissions',
        label: 'صلاحيات المسمى',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/permissions',
        labelKeys: ['description', 'code'],
        subtitleKeys: ['code', 'category'],
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'permissions': _selectedValues(values['permissions']),
    },
  ),
  MobileWorkflow(
    operationId: 'createFacility',
    title: 'إضافة مرفق',
    description: 'أضف ملعبًا أو قاعة أو مسبحًا إلى الفرع الحالي.',
    submitLabel: 'حفظ المرفق',
    successMessage: 'تمت إضافة المرفق.',
    method: 'POST',
    path: '/organizations/{organizationId}/facilities',
    icon: Icons.apartment_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز المرفق', required: true),
      WorkflowField(name: 'name', label: 'اسم المرفق', required: true),
      WorkflowField(
        name: 'type',
        label: 'نوع المرفق',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'COURT',
        choices: [
          WorkflowChoice('COURT', 'ملعب'),
          WorkflowChoice('ROOM', 'غرفة'),
          WorkflowChoice('POOL', 'مسبح'),
          WorkflowChoice('STUDIO', 'استوديو'),
          WorkflowChoice('TRAINING_AREA', 'منطقة تدريب'),
        ],
      ),
      WorkflowField(
        name: 'activityId',
        label: 'النشاط المرتبط',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/activities',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'type': values['type'],
      if (values['activityId']?.isNotEmpty == true)
        'activityId': values['activityId'],
    },
  ),
  MobileWorkflow(
    operationId: 'createBookableResource',
    title: 'إضافة مورد قابل للحجز',
    description: 'اربط المرفق بالخدمة وحدد السعة وسياسة الإلغاء.',
    submitLabel: 'حفظ مورد الحجز',
    successMessage: 'تمت إضافة مورد الحجز.',
    method: 'POST',
    path: '/organizations/{organizationId}/bookable-resources',
    icon: Icons.event_available_outlined,
    fields: [
      WorkflowField(
        name: 'facilityId',
        label: 'المرفق',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/facilities',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة المرتبطة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'cancellationPolicyVersionId',
        label: 'سياسة إلغاء الحجز',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/commercial-policies',
        labelKeys: ['name'],
        subtitleKeys: ['policyType', 'versionNumber'],
      ),
      WorkflowField(name: 'code', label: 'رمز المورد', required: true),
      WorkflowField(name: 'name', label: 'اسم المورد', required: true),
      WorkflowField(
        name: 'type',
        label: 'نوع الحجز',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'COURT',
        choices: [
          WorkflowChoice('COURT', 'ملعب'),
          WorkflowChoice('CLASS', 'حصة جماعية'),
          WorkflowChoice('PERSONAL_TRAINING', 'تدريب شخصي'),
          WorkflowChoice('APPOINTMENT', 'موعد خدمة فردية'),
        ],
      ),
      WorkflowField(
        name: 'capacity',
        label: 'سعة الحصة الجماعية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
        visibleWhenField: 'type',
        visibleWhenValues: ['CLASS'],
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'facilityId': values['facilityId'],
      'serviceId': values['serviceId'],
      'cancellationPolicyVersionId': values['cancellationPolicyVersionId'],
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'type': values['type'],
      'capacity': values['type'] == 'CLASS'
          ? int.tryParse(values['capacity'] ?? '') ?? 1
          : 1,
    },
  ),
  MobileWorkflow(
    operationId: 'scheduleServiceAvailability',
    title: 'تفعيل خدمة في فرع',
    description: 'حدد الخدمة وفترة إتاحتها في الفرع الحالي. يمكن أيضًا جدولة إيقافها من التاريخ المحدد.',
    submitLabel: 'حفظ إتاحة الخدمة',
    successMessage: 'تم حفظ إتاحة الخدمة في الفرع.',
    method: 'POST',
    path: '/organizations/{organizationId}/services/{serviceId}/availabilities',
    icon: Icons.event_available_outlined,
    fields: [
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['code', 'status'],
      ),
      WorkflowField(
        name: 'enabled',
        label: 'الخدمة متاحة للبيع والحجز',
        type: WorkflowFieldType.checkbox,
        initialValue: 'true',
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية السريان',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'نهاية السريان (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'enabled': _checked(values['enabled']),
      'validFrom': _asIso(values['validFrom']),
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': _asIso(values['validUntil']),
    },
  ),
  MobileWorkflow(
    operationId: 'createBookingAvailability',
    title: 'إضافة ساعات إتاحة',
    description: 'حدد أيام وساعات العمل الدورية لمورد الحجز في الفرع الحالي.',
    submitLabel: 'حفظ ساعات الإتاحة',
    successMessage: 'تمت إضافة ساعات إتاحة المورد.',
    method: 'POST',
    path: '/organizations/{organizationId}/bookable-resources/{resourceId}/availability-rules',
    icon: Icons.calendar_view_week_outlined,
    fields: [
      WorkflowField(
        name: 'resourceId',
        label: 'مورد الحجز',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/bookable-resources',
        labelKeys: ['name'],
        subtitleKeys: ['type', 'facilityName'],
      ),
      WorkflowField(
        name: 'dayOfWeek',
        label: 'اليوم',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: '0',
        choices: [
          WorkflowChoice('0', 'الأحد'),
          WorkflowChoice('1', 'الاثنين'),
          WorkflowChoice('2', 'الثلاثاء'),
          WorkflowChoice('3', 'الأربعاء'),
          WorkflowChoice('4', 'الخميس'),
          WorkflowChoice('5', 'الجمعة'),
          WorkflowChoice('6', 'السبت'),
        ],
      ),
      WorkflowField(
        name: 'startLocal',
        label: 'وقت البداية (HH:mm)',
        required: true,
        initialValue: '08:00',
      ),
      WorkflowField(
        name: 'endLocal',
        label: 'وقت النهاية (HH:mm)',
        required: true,
        initialValue: '22:00',
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'ساري من',
        type: WorkflowFieldType.date,
        required: true,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'ساري حتى (اختياري)',
        type: WorkflowFieldType.date,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'dayOfWeek': int.tryParse(values['dayOfWeek'] ?? '') ?? 0,
      'startLocal': values['startLocal'],
      'endLocal': values['endLocal'],
      'validFrom': values['validFrom'],
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': values['validUntil'],
    },
  ),
  MobileWorkflow(
    operationId: 'createBookingBlackout',
    title: 'إضافة فترة حجب',
    description: 'امنع الحجوزات خلال صيانة أو فعالية خاصة مع تسجيل السبب.',
    submitLabel: 'حفظ فترة الحجب',
    successMessage: 'تم حجب المورد خلال الفترة المحددة.',
    method: 'POST',
    path: '/organizations/{organizationId}/bookable-resources/{resourceId}/blackout-periods',
    icon: Icons.event_busy_outlined,
    fields: [
      WorkflowField(
        name: 'resourceId',
        label: 'مورد الحجز',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/bookable-resources',
        labelKeys: ['name'],
        subtitleKeys: ['type', 'facilityName'],
      ),
      WorkflowField(
        name: 'startsAt',
        label: 'بداية الحجب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(),
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'endsAt',
        label: 'نهاية الحجب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(additionalHours: 1),
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'reason',
        label: 'سبب الحجب',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'startsAt': _asIso(values['startsAt']),
      'endsAt': _asIso(values['endsAt']),
      'reason': values['reason']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createSessionSlot',
    title: 'إضافة موعد حصة',
    description:
        'أنشئ موعدًا فعليًا للحصة أو التدريب، مع المدرب والسعة عند الحاجة.',
    submitLabel: 'حفظ موعد الحصة',
    successMessage: 'تم إنشاء موعد الحصة وأصبح متاحًا للحجز.',
    method: 'POST',
    path: '/organizations/{organizationId}/bookable-resources/{resourceId}/session-slots',
    icon: Icons.add_alarm_outlined,
    fields: [
      WorkflowField(
        name: 'resourceId',
        label: 'مورد الحجز',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/bookable-resources',
        labelKeys: ['name'],
        subtitleKeys: ['type', 'facilityName'],
      ),
      WorkflowField(
        name: 'trainerProfileId',
        label: 'المدرب (اختياري)',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'startsAt',
        label: 'بداية الموعد',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'endsAt',
        label: 'نهاية الموعد',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'capacity',
        label: 'السعة (اختياري)',
        type: WorkflowFieldType.number,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      if (values['trainerProfileId']?.isNotEmpty == true)
        'trainerProfileId': values['trainerProfileId'],
      'startsAt': _asIso(values['startsAt']),
      'endsAt': _asIso(values['endsAt']),
      if (values['capacity']?.isNotEmpty == true)
        'capacity': int.tryParse(values['capacity']!),
    },
  ),
  MobileWorkflow(
    operationId: 'createRole',
    title: 'إضافة مجموعة صلاحيات',
    description: 'جهّز مجموعة صلاحيات إضافية يمكن إسنادها لموظف.',
    submitLabel: 'حفظ مجموعة الصلاحيات',
    successMessage: 'تمت إضافة مجموعة الصلاحيات.',
    method: 'POST',
    path: '/organizations/{organizationId}/roles',
    icon: Icons.admin_panel_settings_outlined,
    fields: [
      WorkflowField(name: 'name', label: 'اسم المجموعة', required: true),
      WorkflowField(
        name: 'description',
        label: 'سبب ومجال الاستخدام',
        type: WorkflowFieldType.textarea,
      ),
      WorkflowField(
        name: 'permissions',
        label: 'الصلاحيات الإضافية',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/permissions',
        labelKeys: ['description', 'code'],
        subtitleKeys: ['code', 'category'],
      ),
    ],
    body: (values, controller) => {
      'name': values['name']?.trim(),
      if (values['description']?.trim().isNotEmpty == true)
        'description': values['description']?.trim(),
      'permissions': _selectedValues(values['permissions']),
    },
  ),
  MobileWorkflow(
    operationId: 'createRoleAssignment',
    title: 'إسناد صلاحيات إضافية',
    description: 'اختر الموظف ومجموعة الصلاحيات ونطاق الفروع.',
    submitLabel: 'حفظ الإسناد',
    successMessage: 'تم إسناد الصلاحيات.',
    method: 'POST',
    path: '/organizations/{organizationId}/role-assignments',
    icon: Icons.assignment_ind_outlined,
    fields: [
      WorkflowField(
        name: 'userAccountId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/user-accounts?ownerType=EMPLOYEE&limit=500',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber', 'email'],
      ),
      WorkflowField(
        name: 'roleId',
        label: 'مجموعة الصلاحيات',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/roles',
        labelKeys: ['name'],
        subtitleKeys: ['description'],
      ),
      WorkflowField(
        name: 'scopeType',
        label: 'نطاق الصلاحيات',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'SELECTED_BRANCHES',
        choices: [
          WorkflowChoice('SELECTED_BRANCHES', 'فروع محددة'),
          WorkflowChoice('ORGANIZATION', 'جميع الفروع'),
        ],
      ),
      WorkflowField(
        name: 'branchIds',
        label: 'الفروع المشمولة',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/branches',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
        visibleWhenField: 'scopeType',
        visibleWhenValues: ['SELECTED_BRANCHES'],
      ),
    ],
    body: (values, controller) => {
      'userAccountId': values['userAccountId'],
      'roleId': values['roleId'],
      'scopeType': values['scopeType'],
      'branchIds': values['scopeType'] == 'SELECTED_BRANCHES'
          ? _selectedValues(values['branchIds'])
          : <String>[],
    },
  ),
  MobileWorkflow(
    operationId: 'createNotificationTemplate',
    title: 'إضافة قالب رسالة',
    description: 'أنشئ قالبًا موحدًا للرسائل مع المتغيرات المسموحة.',
    submitLabel: 'حفظ القالب',
    successMessage: 'تم حفظ قالب الرسالة.',
    method: 'POST',
    path: '/organizations/{organizationId}/notification-templates',
    icon: Icons.dynamic_feed_outlined,
    fields: [
      WorkflowField(name: 'templateKey', label: 'مفتاح القالب', required: true),
      WorkflowField(
        name: 'language',
        label: 'اللغة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'ar',
        choices: [
          WorkflowChoice('ar', 'العربية'),
          WorkflowChoice('en', 'English'),
        ],
      ),
      WorkflowField(
        name: 'body',
        label: 'نص الرسالة',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
      WorkflowField(
        name: 'variables',
        label: 'المتغيرات المسموحة (مفصولة بفواصل)',
      ),
    ],
    body: (values, controller) => {
      'templateKey': values['templateKey']?.trim(),
      'language': values['language'],
      'body': values['body'],
      'allowedVariables': _selectedValues(values['variables']),
    },
  ),
  MobileWorkflow(
    operationId: 'createRetailCategory',
    title: 'إضافة تصنيف متجر',
    description: 'أضف تصنيفًا لتنظيم منتجات المتجر.',
    submitLabel: 'حفظ التصنيف',
    successMessage: 'تمت إضافة تصنيف المتجر.',
    method: 'POST',
    path: '/organizations/{organizationId}/retail/categories',
    icon: Icons.sell_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التصنيف', required: true),
      WorkflowField(name: 'name', label: 'اسم التصنيف', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createRetailProduct',
    title: 'إضافة منتج',
    description: 'عرّف منتجًا جديدًا وباركوده ووحدة بيعه.',
    submitLabel: 'حفظ المنتج',
    successMessage: 'تمت إضافة المنتج.',
    method: 'POST',
    path: '/organizations/{organizationId}/retail/products',
    icon: Icons.shopping_basket_outlined,
    fields: [
      WorkflowField(
        name: 'categoryId',
        label: 'التصنيف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/retail/categories',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(name: 'code', label: 'رمز المنتج', required: true),
      WorkflowField(name: 'barcode', label: 'الباركود'),
      WorkflowField(name: 'name', label: 'اسم المنتج', required: true),
      WorkflowField(
        name: 'unit',
        label: 'وحدة البيع',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'UNIT',
        choices: [
          WorkflowChoice('UNIT', 'قطعة'),
          WorkflowChoice('PAIR', 'زوج'),
          WorkflowChoice('BOTTLE', 'زجاجة'),
          WorkflowChoice('CAN', 'علبة'),
          WorkflowChoice('PACK', 'عبوة'),
          WorkflowChoice('BOX', 'صندوق'),
          WorkflowChoice('KG', 'كيلوجرام'),
        ],
      ),
      WorkflowField(
        name: 'description',
        label: 'الوصف',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'categoryId': values['categoryId'],
      'code': values['code']?.trim().toUpperCase(),
      if (values['barcode']?.trim().isNotEmpty == true)
        'barcode': values['barcode']?.trim(),
      'name': values['name']?.trim(),
      'unit': values['unit'],
      if (values['description']?.trim().isNotEmpty == true)
        'description': values['description']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createRetailPrice',
    title: 'إضافة سعر منتج',
    description: 'حدد سعر البيع والضريبة للفرع الحالي.',
    submitLabel: 'حفظ السعر',
    successMessage: 'تم حفظ سعر المنتج.',
    method: 'POST',
    path: '/organizations/{organizationId}/retail/prices',
    icon: Icons.price_change_outlined,
    fields: [
      WorkflowField(
        name: 'productId',
        label: 'المنتج',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/retail/products',
        labelKeys: ['name'],
        subtitleKeys: ['code', 'barcode'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'سعر البيع (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'taxRate',
        label: 'نسبة الضريبة %',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '15',
      ),
      WorkflowField(
        name: 'taxInclusive',
        label: 'السعر شامل الضريبة',
        type: WorkflowFieldType.checkbox,
        initialValue: 'true',
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'productId': values['productId'],
      'amountMinor': _moneyMinor(values['amount']),
      'taxRateBps': ((double.tryParse(values['taxRate'] ?? '') ?? 0) * 100)
          .round(),
      'taxInclusive': _checked(values['taxInclusive']),
      'validFrom': DateTime.now().toUtc().toIso8601String(),
    },
  ),
  MobileWorkflow(
    operationId: 'adjustRetailStock',
    title: 'تسجيل حركة مخزون',
    description: 'سجل استلامًا أو مرتجعًا أو تسوية في مخزون الفرع.',
    submitLabel: 'تسجيل الحركة',
    successMessage: 'تم تحديث المخزون.',
    method: 'POST',
    path: '/organizations/{organizationId}/retail/stock-adjustments',
    icon: Icons.inventory_outlined,
    fields: [
      WorkflowField(
        name: 'productId',
        label: 'المنتج',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/retail/products',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'movementType',
        label: 'نوع الحركة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'RECEIPT',
        choices: [
          WorkflowChoice('RECEIPT', 'استلام بضاعة'),
          WorkflowChoice('RETURN', 'مرتجع عميل سليم'),
          WorkflowChoice('ADJUSTMENT_IN', 'تسوية بالزيادة'),
          WorkflowChoice('ADJUSTMENT_OUT', 'تسوية بالنقص'),
        ],
      ),
      WorkflowField(
        name: 'quantity',
        label: 'الكمية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
      WorkflowField(
        name: 'reorderLevel',
        label: 'حد إعادة الطلب',
        type: WorkflowFieldType.number,
      ),
      WorkflowField(
        name: 'notes',
        label: 'سبب الحركة / رقم المستند',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'productId': values['productId'],
      'movementType': values['movementType'],
      'quantity': double.tryParse(values['quantity'] ?? '') ?? 0,
      if (values['reorderLevel']?.isNotEmpty == true)
        'reorderLevel': double.tryParse(values['reorderLevel']!),
      'notes': values['notes'],
    },
  ),
  MobileWorkflow(
    operationId: 'createExpenseCategory',
    title: 'إضافة تصنيف مصروف',
    description: 'عرّف تصنيف المصروف وحد المبلغ الذي يتطلب اعتمادًا.',
    submitLabel: 'حفظ التصنيف',
    successMessage: 'تمت إضافة تصنيف المصروفات.',
    method: 'POST',
    path: '/organizations/{organizationId}/expense-categories',
    icon: Icons.category_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التصنيف', required: true),
      WorkflowField(name: 'name', label: 'اسم التصنيف', required: true),
      WorkflowField(
        name: 'approvalThreshold',
        label: 'يتطلب اعتمادًا من مبلغ (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '0',
        allowZero: true,
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'approvalThresholdMinor': _moneyMinor(values['approvalThreshold']),
    },
  ),
  MobileWorkflow(
    operationId: 'createMealCategory',
    title: 'إضافة تصنيف وجبات',
    description: 'أضف تصنيفًا لتنظيم كتالوج مطعم النادي.',
    submitLabel: 'حفظ التصنيف',
    successMessage: 'تمت إضافة تصنيف الوجبات.',
    method: 'POST',
    path: '/organizations/{organizationId}/restaurant/meal-categories',
    icon: Icons.ramen_dining_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التصنيف', required: true),
      WorkflowField(name: 'name', label: 'اسم التصنيف', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createPrice',
    title: 'إضافة سعر',
    description: 'حدد سعر باقة أو خدمة ونطاق الفرع والضريبة.',
    submitLabel: 'حفظ السعر',
    successMessage: 'تم حفظ السعر.',
    method: 'POST',
    path: '/organizations/{organizationId}/prices',
    icon: Icons.price_change_outlined,
    fields: [
      WorkflowField(
        name: 'targetType',
        label: 'نوع الهدف',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'PACKAGE',
        choices: [
          WorkflowChoice('PACKAGE', 'باقة'),
          WorkflowChoice('SERVICE', 'خدمة'),
        ],
      ),
      WorkflowField(
        name: 'packageId',
        label: 'الباقة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/packages',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
        visibleWhenField: 'targetType',
        visibleWhenValues: ['PACKAGE'],
      ),
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
        visibleWhenField: 'targetType',
        visibleWhenValues: ['SERVICE'],
      ),
      WorkflowField(
        name: 'branchId',
        label: 'فرع السعر (اختياري)',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/branches',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'السعر (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'taxRate',
        label: 'نسبة الضريبة %',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '15',
      ),
      WorkflowField(
        name: 'taxInclusive',
        label: 'السعر شامل الضريبة',
        type: WorkflowFieldType.checkbox,
        initialValue: 'true',
      ),
    ],
    body: (values, controller) => {
      if (values['branchId']?.isNotEmpty == true)
        'branchId': values['branchId'],
      'targetType': values['targetType'],
      'targetId': values['targetType'] == 'SERVICE'
          ? values['serviceId']
          : values['packageId'],
      'amountMinor': _moneyMinor(values['amount']),
      'taxRateBps': ((double.tryParse(values['taxRate'] ?? '') ?? 0) * 100)
          .round(),
      'taxInclusive': _checked(values['taxInclusive']),
      'validFrom': DateTime.now().toUtc().toIso8601String(),
    },
  ),
  MobileWorkflow(
    operationId: 'createPackage',
    title: 'إضافة باقة',
    description: 'أنشئ باقة عضوية متكاملة بالمدة والخدمات وسياسات التجميد والإلغاء والتجديد.',
    submitLabel: 'حفظ الباقة',
    successMessage: 'تم حفظ الباقة.',
    method: 'POST',
    path: '/organizations/{organizationId}/packages',
    icon: Icons.inventory_2_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز الباقة', required: true),
      WorkflowField(name: 'name', label: 'اسم الباقة', required: true),
      WorkflowField(
        name: 'fulfillmentKind',
        label: 'نوع الباقة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'FACILITY_ACCESS',
        choices: [
          WorkflowChoice('FACILITY_ACCESS', 'دخول مرفق'),
          WorkflowChoice('SESSION', 'جلسات'),
          WorkflowChoice('MEAL_PLAN', 'خطة وجبات'),
        ],
      ),
      WorkflowField(
        name: 'durationValue',
        label: 'مدة الباقة',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
      WorkflowField(
        name: 'durationUnit',
        label: 'وحدة المدة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MONTHS',
        choices: [
          WorkflowChoice('DAYS', 'أيام'),
          WorkflowChoice('WEEKS', 'أسابيع'),
          WorkflowChoice('MONTHS', 'أشهر'),
        ],
      ),
      WorkflowField(
        name: 'mealAllowance',
        label: 'عدد الوجبات في الخطة',
        type: WorkflowFieldType.number,
        required: true,
        visibleWhenField: 'fulfillmentKind',
        visibleWhenValues: ['MEAL_PLAN'],
      ),
      WorkflowField(
        name: 'accessFrequency',
        label: 'نظام الحضور',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'UNLIMITED',
        choices: [
          WorkflowChoice('UNLIMITED', 'غير محدود'),
          WorkflowChoice('TOTAL', 'عدد إجمالي طوال الباقة'),
          WorkflowChoice('WEEK', 'عدد محدد كل أسبوع'),
          WorkflowChoice('MONTH', 'عدد محدد كل شهر'),
        ],
      ),
      WorkflowField(
        name: 'visitAllowance',
        label: 'إجمالي مرات الحضور',
        type: WorkflowFieldType.number,
        required: true,
        visibleWhenField: 'accessFrequency',
        visibleWhenValues: ['TOTAL'],
      ),
      WorkflowField(
        name: 'visitsPerPeriod',
        label: 'مرات الحضور في الفترة',
        type: WorkflowFieldType.number,
        required: true,
        visibleWhenField: 'accessFrequency',
        visibleWhenValues: ['WEEK', 'MONTH'],
      ),
      WorkflowField(
        name: 'branchAccessPolicy',
        label: 'سياسة الوصول للفروع',
        type: WorkflowFieldType.select,
        initialValue: 'SINGLE_BRANCH',
        choices: [
          WorkflowChoice('SINGLE_BRANCH', 'فرع البيع فقط'),
          WorkflowChoice('SELECTED_BRANCHES', 'فروع مختارة'),
          WorkflowChoice('ALL_ORGANIZATION_BRANCHES', 'كل الفروع'),
        ],
      ),
      WorkflowField(
        name: 'branchIds',
        label: 'الفروع المتاحة',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/branches',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
        visibleWhenField: 'branchAccessPolicy',
        visibleWhenValues: ['SELECTED_BRANCHES'],
      ),
      WorkflowField(
        name: 'serviceIds',
        label: 'الخدمات المشمولة',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'freezePolicyVersionId',
        label: 'سياسة التجميد',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/commercial-policies',
        labelKeys: ['name'],
        subtitleKeys: ['policyType', 'versionNumber'],
      ),
      WorkflowField(
        name: 'cancellationPolicyVersionId',
        label: 'سياسة إلغاء الاشتراك',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/commercial-policies',
        labelKeys: ['name'],
        subtitleKeys: ['policyType', 'versionNumber'],
      ),
      WorkflowField(
        name: 'renewalPolicyVersionId',
        label: 'سياسة التجديد',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/commercial-policies',
        labelKeys: ['name'],
        subtitleKeys: ['policyType', 'versionNumber'],
      ),
      WorkflowField(
        name: 'description',
        label: 'الوصف',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) {
      final multiplier = switch (values['durationUnit']) {
        'WEEKS' => 7,
        'MONTHS' => 30,
        _ => 1,
      };
      final mealPlan = values['fulfillmentKind'] == 'MEAL_PLAN';
      final frequency = values['accessFrequency'];
      final allowance = mealPlan
          ? int.tryParse(values['mealAllowance'] ?? '')
          : frequency == 'TOTAL'
          ? int.tryParse(values['visitAllowance'] ?? '')
          : null;
      final periodic =
          !mealPlan && (frequency == 'WEEK' || frequency == 'MONTH');
      return {
        'code': values['code']?.trim().toUpperCase(),
        'name': values['name']?.trim(),
        if (values['description']?.trim().isNotEmpty == true)
          'description': values['description']?.trim(),
        'durationDays':
            (int.tryParse(values['durationValue'] ?? '') ?? 1) * multiplier,
        'visitAllowance': ?allowance,
        if (periodic) 'visitLimitPeriod': frequency,
        if (periodic)
          'visitsPerPeriod': int.tryParse(values['visitsPerPeriod'] ?? '') ?? 0,
        'fulfillmentKind': values['fulfillmentKind'],
        'branchAccessPolicy': values['branchAccessPolicy'],
        'branchIds': _selectedValues(values['branchIds']),
        'entitlements': _selectedValues(values['serviceIds'])
            .map(
              (serviceId) => {
                'serviceId': serviceId,
                if (mealPlan && allowance != null) 'visitAllowance': allowance,
              },
            )
            .toList(growable: false),
        'freezePolicyVersionId': values['freezePolicyVersionId'],
        'cancellationPolicyVersionId': values['cancellationPolicyVersionId'],
        'renewalPolicyVersionId': values['renewalPolicyVersionId'],
      };
    },
  ),
  MobileWorkflow(
    operationId: 'createPromotion',
    title: 'إضافة عرض ترويجي',
    description: 'أنشئ خصمًا بكود أو عرضًا تلقائيًا مستهدفًا.',
    submitLabel: 'حفظ العرض',
    successMessage: 'تم حفظ العرض الترويجي.',
    method: 'POST',
    path: '/organizations/{organizationId}/promotions',
    icon: Icons.local_offer_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'كود العرض', required: true),
      WorkflowField(name: 'name', label: 'اسم العرض', required: true),
      WorkflowField(
        name: 'benefitType',
        label: 'نوع الفائدة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'PERCENTAGE',
        choices: [
          WorkflowChoice('PERCENTAGE', 'خصم بالنسبة'),
          WorkflowChoice('FIXED_DISCOUNT', 'خصم مبلغ ثابت'),
          WorkflowChoice('FIXED_FINAL_PRICE', 'سعر نهائي ثابت'),
        ],
      ),
      WorkflowField(
        name: 'benefitValue',
        label: 'قيمة العرض',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'eligibility',
        label: 'طريقة التطبيق',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'PROMO_CODE',
        choices: [
          WorkflowChoice('EVERYONE', 'تلقائي للجميع'),
          WorkflowChoice('NEW_MEMBER', 'للأعضاء الجدد'),
          WorkflowChoice('FORMER_MEMBER', 'للأعضاء السابقين'),
          WorkflowChoice('PROMO_CODE', 'يدوي بكود الخصم'),
        ],
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'يبدأ العرض',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'ينتهي العرض',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
      WorkflowField(
        name: 'branchIds',
        label: 'الفروع المستهدفة',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/branches',
        labelKeys: ['name', 'nameAr'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'packageIds',
        label: 'الباقات المشمولة',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/packages',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'serviceIds',
        label: 'الخدمات المشمولة',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      'benefitType': values['benefitType'],
      'benefitValue':
          ((double.tryParse(values['benefitValue'] ?? '') ?? 0) * 100).round(),
      'eligibility': values['eligibility'],
      'validFrom': _asIso(values['validFrom']),
      'validUntil': _asIso(values['validUntil']),
      'branchIds': _selectedValues(values['branchIds']),
      'targets': [
        ..._selectedValues(values['packageIds'])
            .map((id) => {'type': 'PACKAGE', 'id': id}),
        ..._selectedValues(values['serviceIds'])
            .map((id) => {'type': 'SERVICE', 'id': id}),
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'createCommercialPolicy',
    title: 'إضافة سياسة تجارية',
    description: 'عرّف إصدارًا محكمًا لسياسة التجميد أو الإلغاء أو التجديد.',
    submitLabel: 'حفظ إصدار السياسة',
    successMessage: 'تم حفظ السياسة.',
    method: 'POST',
    path: '/organizations/{organizationId}/commercial-policies',
    icon: Icons.policy_outlined,
    fields: [
      WorkflowField(
        name: 'policyType',
        label: 'نوع السياسة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'FREEZE',
        choices: [
          WorkflowChoice('FREEZE', 'تجميد الاشتراك'),
          WorkflowChoice('CANCELLATION', 'إلغاء الاشتراك'),
          WorkflowChoice('RENEWAL', 'تجديد الاشتراك'),
          WorkflowChoice('BOOKING_CANCELLATION', 'إلغاء الحجز'),
        ],
      ),
      WorkflowField(name: 'policyKey', label: 'رمز السياسة', required: true),
      WorkflowField(
        name: 'versionNumber',
        label: 'رقم الإصدار',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
      WorkflowField(name: 'name', label: 'اسم السياسة', required: true),
      WorkflowField(
        name: 'maxDaysPerFreeze',
        label: 'أقصى أيام للتجميد',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['FREEZE'],
      ),
      WorkflowField(
        name: 'maxFreezesPerTerm',
        label: 'أقصى مرات تجميد',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['FREEZE'],
      ),
      WorkflowField(
        name: 'minimumActiveDaysBeforeFreeze',
        label: 'أيام السريان قبل التجميد',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['FREEZE'],
      ),
      WorkflowField(
        name: 'cancellationMode',
        label: 'موعد الإلغاء',
        type: WorkflowFieldType.select,
        initialValue: 'END_OF_TERM',
        choices: [
          WorkflowChoice('END_OF_TERM', 'نهاية فترة الاشتراك'),
          WorkflowChoice('IMMEDIATE_PRORATED', 'فوري مع استرداد نسبي'),
        ],
        visibleWhenField: 'policyType',
        visibleWhenValues: ['CANCELLATION'],
      ),
      WorkflowField(
        name: 'noticeDays',
        label: 'فترة الإشعار بالأيام',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['CANCELLATION'],
      ),
      WorkflowField(
        name: 'fee',
        label: 'رسوم الإلغاء (ر.س)',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['CANCELLATION'],
      ),
      WorkflowField(
        name: 'graceDays',
        label: 'مهلة التجديد بالأيام',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['RENEWAL'],
      ),
      WorkflowField(
        name: 'cutoffHours',
        label: 'آخر موعد للإلغاء (ساعات)',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['BOOKING_CANCELLATION'],
      ),
      WorkflowField(
        name: 'refundPercentage',
        label: 'نسبة الاسترداد %',
        type: WorkflowFieldType.number,
        visibleWhenField: 'policyType',
        visibleWhenValues: ['BOOKING_CANCELLATION'],
      ),
    ],
    body: (values, controller) {
      final type = values['policyType'];
      final configuration = switch (type) {
        'FREEZE' => {
          'maxDaysPerFreeze':
              int.tryParse(values['maxDaysPerFreeze'] ?? '') ?? 0,
          'maxFreezesPerTerm':
              int.tryParse(values['maxFreezesPerTerm'] ?? '') ?? 0,
          'minimumActiveDaysBeforeFreeze':
              int.tryParse(values['minimumActiveDaysBeforeFreeze'] ?? '') ?? 0,
        },
        'CANCELLATION' => {
          'noticeDays': int.tryParse(values['noticeDays'] ?? '') ?? 0,
          'refundable': values['cancellationMode'] == 'IMMEDIATE_PRORATED',
          'feeMinor': int.tryParse(_moneyMinor(values['fee'])) ?? 0,
          'cancellationMode': values['cancellationMode'],
        },
        'RENEWAL' => {
          'graceDays': int.tryParse(values['graceDays'] ?? '') ?? 0,
          'allowEarlyRenewalDays': 0,
        },
        _ => {
          'cutoffHours': int.tryParse(values['cutoffHours'] ?? '') ?? 0,
          'refundPercentageBps':
              ((double.tryParse(values['refundPercentage'] ?? '') ?? 0) * 100)
                  .round(),
        },
      };
      return {
        'policyKey': values['policyKey']?.trim().toUpperCase(),
        'versionNumber': int.tryParse(values['versionNumber'] ?? '') ?? 1,
        'policyType': type,
        'name': values['name']?.trim(),
        'configuration': configuration,
      };
    },
  ),
  MobileWorkflow(
    operationId: 'redeemMealPlan',
    title: 'استبدال وجبة من الخطة',
    description: 'اختر العضو واشتراك خطة الوجبات والصنف؛ سيُخصم الاستحقاق دون إنشاء تحصيل جديد.',
    submitLabel: 'تأكيد استبدال الوجبة',
    successMessage: 'تم استبدال الوجبة وإرسال الطلب إلى المطبخ.',
    method: 'POST',
    path: '/organizations/{organizationId}/restaurant-orders/meal-plan-redemptions',
    icon: Icons.redeem_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'subscriptionId',
        label: 'اشتراك خطة الوجبات',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath:
            '/organizations/{organizationId}/subscriptions?memberId={memberId}',
        labelKeys: ['packageName', 'subscriptionNumber'],
        subtitleKeys: ['status', 'visitsRemaining'],
      ),
      WorkflowField(
        name: 'mealId',
        label: 'الوجبة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/restaurant/meals',
        labelKeys: ['name', 'mealName'],
        subtitleKeys: ['categoryName'],
      ),
      WorkflowField(
        name: 'quantity',
        label: 'الكمية',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'memberId': values['memberId'],
      'subscriptionId': values['subscriptionId'],
      'mealId': values['mealId'],
      'quantity': int.tryParse(values['quantity'] ?? '') ?? 1,
    },
  ),
  MobileWorkflow(
    operationId: 'createRestaurantMeal',
    title: 'إضافة وجبة',
    description: 'أضف الوجبة مع تصنيفها وحجمها وقيمها الغذائية.',
    submitLabel: 'إضافة الوجبة',
    successMessage: 'تمت إضافة الوجبة.',
    method: 'POST',
    path: '/organizations/{organizationId}/restaurant/meals',
    icon: Icons.lunch_dining_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز الوجبة', required: true),
      WorkflowField(name: 'name', label: 'اسم الوجبة', required: true),
      WorkflowField(
        name: 'categoryId',
        label: 'التصنيف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath:
            '/organizations/{organizationId}/restaurant/meal-categories',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'kind',
        label: 'النوع',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MEAL',
        choices: [
          WorkflowChoice('MEAL', 'وجبة'),
          WorkflowChoice('PRODUCT', 'منتج'),
          WorkflowChoice('DRINK', 'مشروب'),
        ],
      ),
      WorkflowField(
        name: 'portionClass',
        label: 'حجم الحصة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'UNRESTRICTED',
        choices: [
          WorkflowChoice('UNRESTRICTED', 'حصة قياسية'),
          WorkflowChoice('STANDARD_150G', '150 جرام'),
          WorkflowChoice('LARGE_200G', '200 جرام'),
        ],
      ),
      WorkflowField(
        name: 'caloriesKcal',
        label: 'السعرات الحرارية',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'proteinGrams',
        label: 'البروتين (جم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'carbohydratesGrams',
        label: 'الكربوهيدرات (جم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'fatGrams',
        label: 'الدهون (جم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'fiberGrams',
        label: 'الألياف (جم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'sugarGrams',
        label: 'السكر (جم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(
        name: 'sodiumMilligrams',
        label: 'الصوديوم (ملجم)',
        type: WorkflowFieldType.number,
        initialValue: '0',
        allowZero: true,
      ),
      WorkflowField(name: 'allergens', label: 'الحساسيات (مفصولة بفواصل)'),
      WorkflowField(
        name: 'description',
        label: 'الوصف',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'categoryId': values['categoryId'],
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      if (values['description']?.trim().isNotEmpty == true)
        'description': values['description']?.trim(),
      'kind': values['kind'],
      'portionClass': values['portionClass'],
      'nutrition': {
        for (final key in [
          'caloriesKcal',
          'proteinGrams',
          'carbohydratesGrams',
          'fatGrams',
          'fiberGrams',
          'sugarGrams',
          'sodiumMilligrams',
        ])
          key: double.tryParse(values[key] ?? '') ?? 0,
      },
      'allergens': _selectedValues(values['allergens']),
    },
  ),
  MobileWorkflow(
    operationId: 'createRestaurantMealPrice',
    title: 'تسعير وجبة',
    description: 'حدد سعر الوجبة وضريبتها وتاريخ بدء السريان في الفرع الحالي. لن تُنشر قائمة يومية إذا بدأ السعر بعد ظهر تاريخ القائمة.',
    submitLabel: 'حفظ سعر الوجبة',
    successMessage: 'تم حفظ سعر الوجبة.',
    method: 'POST',
    path: '/organizations/{organizationId}/restaurant/meal-prices',
    icon: Icons.price_check_outlined,
    fields: [
      WorkflowField(
        name: 'mealId',
        label: 'الوجبة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/restaurant/meals',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'amount',
        label: 'السعر (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
      ),
      WorkflowField(
        name: 'taxRate',
        label: 'نسبة الضريبة %',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '15',
      ),
      WorkflowField(
        name: 'taxInclusive',
        label: 'السعر شامل الضريبة',
        type: WorkflowFieldType.checkbox,
        initialValue: 'true',
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية سريان السعر',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _localDateTimeValue(
          DateTime.now().subtract(const Duration(days: 1)),
        ),
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'mealId': values['mealId'],
      'amountMinor': _moneyMinor(values['amount']),
      'taxRateBps': ((double.tryParse(values['taxRate'] ?? '') ?? 0) * 100)
          .round(),
      'taxInclusive': _checked(values['taxInclusive']),
      'validFrom': _asIso(values['validFrom']),
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutSelfService',
    title: 'طلب خدمة',
    description: 'اختر الخدمة المتاحة في الفرع؛ سينشئ النظام الطلب والفاتورة.',
    submitLabel: 'طلب الخدمة',
    successMessage: 'تم إنشاء طلب الخدمة والفاتورة.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/members/{memberId}/orders',
    icon: Icons.shopping_bag_outlined,
    fields: [
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/self/organizations/{organizationId}/services',
        labelKeys: ['name'],
        subtitleKeys: ['categoryName', 'amountMinor'],
      ),
    ],
    body: (values, controller) => {
      'sellingBranchId': controller.branchId,
      'lines': [
        {'type': 'SERVICE', 'targetId': values['serviceId'], 'quantity': 1},
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'checkoutSelfBooking',
    title: 'حجز موعد',
    description: 'اختر المورد والموعد المتاح لإنشاء الحجز والفاتورة.',
    submitLabel: 'تأكيد الحجز',
    successMessage: 'تم إنشاء الحجز والفاتورة.',
    method: 'POST',
    path: '/self/organizations/{organizationId}/members/{memberId}/orders',
    icon: Icons.event_available_outlined,
    fields: [
      WorkflowField(
        name: 'resourceId',
        label: 'المورد القابل للحجز',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath:
            '/self/organizations/{organizationId}/bookable-resources',
        labelKeys: ['name', 'resourceName'],
        subtitleKeys: ['facilityName', 'resourceType'],
        copyValues: {'serviceId': 'serviceId', 'resourceType': 'resourceType'},
      ),
      WorkflowField(
        name: 'serviceId',
        label: 'الخدمة',
        type: WorkflowFieldType.hidden,
        required: true,
      ),
      WorkflowField(
        name: 'resourceType',
        label: 'نوع المورد',
        type: WorkflowFieldType.hidden,
        required: true,
      ),
      WorkflowField(
        name: 'sessionSlotId',
        label: 'الموعد المتاح',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/self/organizations/{organizationId}/bookable-resources/{resourceId}/session-slots',
        labelKeys: ['startsAt', 'name'],
        subtitleKeys: ['endsAt', 'remainingCapacity'],
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['CLASS', 'PERSONAL_TRAINING', 'APPOINTMENT'],
      ),
      WorkflowField(
        name: 'startsAt',
        label: 'بداية حجز الملعب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(),
        autoFillDate: false,
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
      WorkflowField(
        name: 'endsAt',
        label: 'نهاية حجز الملعب',
        type: WorkflowFieldType.dateTime,
        required: true,
        initialValue: _nextBookingDateTime(additionalHours: 1),
        autoFillDate: false,
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
      WorkflowField(
        name: 'participantCount',
        label: 'عدد المشاركين',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '1',
        visibleWhenField: 'resourceType',
        visibleWhenValues: ['COURT'],
      ),
    ],
    body: (values, controller) {
      final type = values['resourceType'];
      return {
        'sellingBranchId': controller.branchId,
        'lines': [
          {
            'type': 'BOOKING',
            'targetId': values['serviceId'],
            'quantity': 1,
            'booking': {
              'resourceId': values['resourceId'],
              'type': type,
              if (type == 'COURT') ...{
                'startsAt': _asIso(values['startsAt']),
                'endsAt': _asIso(values['endsAt']),
              } else
                'sessionSlotId': values['sessionSlotId'],
              'seats': 1,
              'participantCount':
                  int.tryParse(values['participantCount'] ?? '') ?? 1,
            },
          },
        ],
      };
    },
  ),
  MobileWorkflow(
    operationId: 'openCashierShift',
    title: 'فتح وردية صندوق',
    description: 'اختر نقطة التحصيل وسجل الرصيد الافتتاحي قبل التحصيل النقدي.',
    submitLabel: 'فتح الوردية',
    successMessage: 'تم فتح وردية الصندوق.',
    method: 'POST',
    path: '/organizations/{organizationId}/cashier-shifts',
    icon: Icons.lock_open_outlined,
    fields: [
      WorkflowField(
        name: 'cashPointId',
        label: 'نقطة التحصيل',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cash-points',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'openingBalance',
        label: 'الرصيد الافتتاحي (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '0',
        allowZero: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'cashPointId': values['cashPointId'],
      'openingBalanceMinor': _moneyMinor(values['openingBalance']),
    },
  ),
  MobileWorkflow(
    operationId: 'closeCashierShift',
    title: 'إغلاق وردية الصندوق',
    description: 'اختر الوردية المفتوحة وأدخل الرصيد الفعلي. يسجل النظام فرق الصندوق للمراجعة.',
    submitLabel: 'إغلاق الوردية',
    successMessage: 'تم إغلاق وردية الصندوق وتسجيل الرصيد الفعلي.',
    method: 'POST',
    path: '/organizations/{organizationId}/cashier-shifts/{cashierShiftId}/closures',
    icon: Icons.lock_clock_outlined,
    fields: [
      WorkflowField(
        name: 'cashierShiftId',
        label: 'وردية الصندوق',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/cashier-shifts',
        labelKeys: ['cashPointName', 'cashierName'],
        subtitleKeys: ['openedAt', 'status'],
      ),
      WorkflowField(
        name: 'actualClosingBalance',
        label: 'الرصيد الفعلي عند الإغلاق (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
        allowZero: true,
      ),
      WorkflowField(
        name: 'reason',
        label: 'ملاحظة الإغلاق أو سبب الفرق',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'actualClosingMinor': _moneyMinor(values['actualClosingBalance']),
      'reason': values['reason']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'registerAccessDevice',
    title: 'تسجيل لوحة بوابة',
    description: 'أضف لوحة ZKTeco أو بوابة متوافقة واربطها بالفرع. سيظهر مفتاح الاتصال مرة واحدة بعد الحفظ.',
    submitLabel: 'تسجيل اللوحة',
    successMessage: 'تم تسجيل لوحة البوابة وإصدار مفتاح الاتصال.',
    method: 'POST',
    path: '/organizations/{organizationId}/access-devices',
    icon: Icons.add_to_home_screen_outlined,
    fields: [
      WorkflowField(name: 'name', label: 'اسم البوابة', required: true),
      WorkflowField(
        name: 'serialNumber',
        label: 'الرقم التسلسلي',
        required: true,
      ),
      WorkflowField(name: 'model', label: 'الموديل'),
      WorkflowField(name: 'firmwareVersion', label: 'إصدار النظام'),
      WorkflowField(name: 'ipAddress', label: 'عنوان IP'),
      WorkflowField(
        name: 'doorCount',
        label: 'عدد الأبواب',
        type: WorkflowFieldType.number,
        initialValue: '1',
      ),
      WorkflowField(
        name: 'readerCount',
        label: 'عدد القارئات',
        type: WorkflowFieldType.number,
        initialValue: '1',
      ),
      WorkflowField(
        name: 'mode',
        label: 'وضع التشغيل الأولي',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'OBSERVE',
        choices: [
          WorkflowChoice('OBSERVE', 'مراقبة فقط'),
          WorkflowChoice('ENFORCE', 'تنفيذ قرارات الدخول'),
        ],
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'name': values['name']?.trim(),
      'serialNumber': values['serialNumber']?.trim(),
      if (values['model']?.trim().isNotEmpty == true)
        'model': values['model']?.trim(),
      if (values['firmwareVersion']?.trim().isNotEmpty == true)
        'firmwareVersion': values['firmwareVersion']?.trim(),
      if (values['ipAddress']?.trim().isNotEmpty == true)
        'ipAddress': values['ipAddress']?.trim(),
      if (values['doorCount']?.isNotEmpty == true)
        'doorCount': int.tryParse(values['doorCount']!),
      if (values['readerCount']?.isNotEmpty == true)
        'readerCount': int.tryParse(values['readerCount']!),
      'mode': values['mode'],
    },
  ),
  MobileWorkflow(
    operationId: 'issueAccessBarcode',
    title: 'إصدار بطاقة دخول',
    description: 'أصدر باركود دخول فريدًا لعضو أو موظف.',
    submitLabel: 'إصدار البطاقة',
    successMessage: 'تم إصدار بطاقة الدخول.',
    method: 'POST',
    path: '/organizations/{organizationId}/access-credentials/barcodes',
    icon: Icons.qr_code_2_rounded,
    fields: [
      WorkflowField(
        name: 'subjectType',
        label: 'نوع صاحب البطاقة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MEMBER',
        choices: [
          WorkflowChoice('MEMBER', 'عضو'),
          WorkflowChoice('EMPLOYEE', 'موظف'),
        ],
      ),
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
        visibleWhenField: 'subjectType',
        visibleWhenValues: ['MEMBER'],
      ),
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'displayName'],
        subtitleKeys: ['employeeNumber'],
        visibleWhenField: 'subjectType',
        visibleWhenValues: ['EMPLOYEE'],
      ),
    ],
    body: (values, controller) => {
      'subjectType': values['subjectType'],
      'subjectId': values['subjectType'] == 'MEMBER'
          ? values['memberId']
          : values['employeeId'],
    },
  ),
  MobileWorkflow(
    operationId: 'createBarcodePrintBatch',
    title: 'إصدار دفعة بطاقات أعضاء',
    description:
        'اختر مجموعة أعضاء لإصدار بطاقات الدخول دفعة واحدة وتجهيزها للطباعة.',
    submitLabel: 'إصدار دفعة البطاقات',
    successMessage: 'تم إصدار دفعة بطاقات الدخول.',
    method: 'POST',
    path: '/organizations/{organizationId}/access-credentials/barcode-print-batches',
    icon: Icons.print_outlined,
    fields: [
      WorkflowField(
        name: 'memberIds',
        label: 'الأعضاء',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
    ],
    body: (values, controller) => {
      'subjects': _selectedValues(values['memberIds'])
          .map((id) => {'subjectType': 'MEMBER', 'subjectId': id})
          .toList(),
    },
  ),
  MobileWorkflow(
    operationId: 'assignFingerprintPin',
    title: 'ربط PIN البصمة',
    description: 'اربط رقم جهاز البصمة بعضو أو موظف دون نقل قالب البصمة.',
    submitLabel: 'ربط PIN',
    successMessage: 'تم ربط PIN بنجاح.',
    method: 'POST',
    path: '/organizations/{organizationId}/access-credentials/fingerprint-pins',
    icon: Icons.fingerprint_rounded,
    fields: [
      WorkflowField(
        name: 'subjectType',
        label: 'النوع',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MEMBER',
        choices: [
          WorkflowChoice('MEMBER', 'عضو'),
          WorkflowChoice('EMPLOYEE', 'موظف'),
        ],
      ),
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
        visibleWhenField: 'subjectType',
        visibleWhenValues: ['MEMBER'],
      ),
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'displayName'],
        subtitleKeys: ['employeeNumber'],
        visibleWhenField: 'subjectType',
        visibleWhenValues: ['EMPLOYEE'],
      ),
      WorkflowField(
        name: 'pin',
        label: 'PIN جهاز البصمة',
        type: WorkflowFieldType.number,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'subjectType': values['subjectType'],
      'subjectId': values['subjectType'] == 'MEMBER'
          ? values['memberId']
          : values['employeeId'],
      'pin': values['pin']?.replaceAll(RegExp(r'\D'), ''),
    },
  ),
  MobileWorkflow(
    operationId: 'createCoachingSpecialty',
    title: 'إضافة تخصص تدريب',
    description: 'عرّف تخصصًا جديدًا لملفات المدربين.',
    submitLabel: 'حفظ التخصص',
    successMessage: 'تمت إضافة تخصص التدريب.',
    method: 'POST',
    path: '/organizations/{organizationId}/coaching-specialties',
    icon: Icons.workspace_premium_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التخصص', required: true),
      WorkflowField(name: 'name', label: 'اسم التخصص', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createTrainerProfile',
    title: 'إنشاء ملف مدرب',
    description: 'اربط الموظف بملف مدرب وحدد اسمه الظاهر وتخصصاته.',
    submitLabel: 'إنشاء ملف المدرب',
    successMessage: 'تم إنشاء ملف المدرب.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainers',
    icon: Icons.fitness_center_outlined,
    fields: [
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'displayName'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'displayName',
        label: 'الاسم الظاهر للأعضاء',
        required: true,
      ),
      WorkflowField(
        name: 'specialtyIds',
        label: 'التخصصات',
        type: WorkflowFieldType.multiReference,
        referencePath: '/organizations/{organizationId}/coaching-specialties',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'publicBio',
        label: 'نبذة مختصرة',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'employeeId': values['employeeId'],
      'displayName': values['displayName']?.trim(),
      'specialtyIds': _selectedValues(values['specialtyIds']),
      if (values['publicBio']?.trim().isNotEmpty == true)
        'publicBio': values['publicBio']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'assignTrainerToBranch',
    title: 'إسناد مدرب إلى فرع',
    description:
        'اربط ملف المدرب بالفرع الحالي وحدد فترة سريان الإسناد عند الحاجة.',
    submitLabel: 'حفظ إسناد الفرع',
    successMessage: 'تم إسناد المدرب إلى الفرع.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainers/{trainerId}/branch-assignments',
    icon: Icons.add_business_outlined,
    fields: [
      WorkflowField(
        name: 'trainerId',
        label: 'المدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber', 'status'],
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية الإسناد (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'نهاية الإسناد (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      if (values['validFrom']?.isNotEmpty == true)
        'validFrom': _asIso(values['validFrom']),
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': _asIso(values['validUntil']),
    },
  ),
  MobileWorkflow(
    operationId: 'createTrainerAvailability',
    title: 'إضافة أوقات عمل مدرب',
    description:
        'حدد اليوم وساعات توفر المدرب في الفرع لبناء جدول التدريب والحجوزات.',
    submitLabel: 'حفظ وقت المدرب',
    successMessage: 'تمت إضافة وقت توفر المدرب.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainers/{trainerId}/availability-rules',
    icon: Icons.schedule_outlined,
    fields: [
      WorkflowField(
        name: 'trainerId',
        label: 'المدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'dayOfWeek',
        label: 'اليوم',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: '0',
        choices: [
          WorkflowChoice('0', 'الأحد'),
          WorkflowChoice('1', 'الاثنين'),
          WorkflowChoice('2', 'الثلاثاء'),
          WorkflowChoice('3', 'الأربعاء'),
          WorkflowChoice('4', 'الخميس'),
          WorkflowChoice('5', 'الجمعة'),
          WorkflowChoice('6', 'السبت'),
        ],
      ),
      WorkflowField(
        name: 'startLocal',
        label: 'وقت البداية (HH:mm)',
        required: true,
        initialValue: '08:00',
      ),
      WorkflowField(
        name: 'endLocal',
        label: 'وقت النهاية (HH:mm)',
        required: true,
        initialValue: '22:00',
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'ساري من',
        type: WorkflowFieldType.date,
        required: true,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'ساري حتى (اختياري)',
        type: WorkflowFieldType.date,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'dayOfWeek': int.tryParse(values['dayOfWeek'] ?? '') ?? 0,
      'startLocal': values['startLocal'],
      'endLocal': values['endLocal'],
      'validFrom': values['validFrom'],
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': values['validUntil'],
    },
  ),
  MobileWorkflow(
    operationId: 'assignMemberToTrainer',
    title: 'إسناد عضو إلى مدرب',
    description:
        'اربط العضو بالمدرب في الفرع الحالي ليظهر في مساحة عمل المدرب الذاتية.',
    submitLabel: 'حفظ إسناد العضو',
    successMessage: 'تم إسناد العضو إلى المدرب.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainers/{trainerId}/member-assignments',
    icon: Icons.group_add_outlined,
    fields: [
      WorkflowField(
        name: 'trainerId',
        label: 'المدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber', 'phoneE164'],
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية الإسناد (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'نهاية الإسناد (اختياري)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'memberId': values['memberId'],
      'branchId': controller.branchId,
      if (values['validFrom']?.isNotEmpty == true)
        'validFrom': _asIso(values['validFrom']),
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': _asIso(values['validUntil']),
    },
  ),
  MobileWorkflow(
    operationId: 'createOtherIncomeCategory',
    title: 'إضافة تصنيف إيراد',
    description: 'أضف بندًا لتصنيف الإيرادات غير المرتبطة بالمبيعات.',
    submitLabel: 'حفظ التصنيف',
    successMessage: 'تمت إضافة تصنيف الإيراد.',
    method: 'POST',
    path: '/organizations/{organizationId}/other-income-categories',
    icon: Icons.account_tree_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز التصنيف', required: true),
      WorkflowField(name: 'name', label: 'اسم التصنيف', required: true),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createCommunicationTemplate',
    title: 'حفظ رسالة متكررة',
    description: 'أنشئ رسالة محفوظة لإعادة استخدامها في الحملات.',
    submitLabel: 'حفظ الرسالة',
    successMessage: 'تم حفظ الرسالة.',
    method: 'POST',
    path: '/organizations/{organizationId}/communication-templates',
    icon: Icons.mark_email_unread_outlined,
    fields: [
      WorkflowField(name: 'name', label: 'اسم الرسالة', required: true),
      WorkflowField(
        name: 'purpose',
        label: 'الغرض',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'ANNOUNCEMENT',
        choices: [
          WorkflowChoice('MARKETING', 'ترويج'),
          WorkflowChoice('RENEWAL', 'تجديد'),
          WorkflowChoice('REMINDER', 'تذكير'),
          WorkflowChoice('ANNOUNCEMENT', 'إعلان'),
          WorkflowChoice('FOLLOW_UP', 'متابعة'),
          WorkflowChoice('OTHER', 'أخرى'),
        ],
      ),
      WorkflowField(name: 'title', label: 'عنوان الإشعار', required: true),
      WorkflowField(
        name: 'body',
        label: 'نص الرسالة',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'name': values['name']?.trim(),
      'purpose': values['purpose'],
      'title': values['title']?.trim(),
      'body': values['body']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createCommunicationCampaign',
    title: 'إرسال رسالة للأعضاء',
    description:
        'كوّن رسالة احترافية، عاين عدد المستلمين، ثم أرسلها فورًا أو جدولها.',
    submitLabel: 'إرسال الرسالة',
    successMessage: 'تم إنشاء حملة التواصل.',
    method: 'POST',
    path: '/organizations/{organizationId}/communication-campaigns',
    icon: Icons.campaign_outlined,
    fields: [
      WorkflowField(name: 'name', label: 'اسم الحملة داخليًا', required: true),
      WorkflowField(
        name: 'purpose',
        label: 'الغرض',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'ANNOUNCEMENT',
        choices: [
          WorkflowChoice('MARKETING', 'ترويج'),
          WorkflowChoice('RENEWAL', 'تجديد'),
          WorkflowChoice('REMINDER', 'تذكير'),
          WorkflowChoice('ANNOUNCEMENT', 'إعلان'),
          WorkflowChoice('FOLLOW_UP', 'متابعة'),
          WorkflowChoice('OTHER', 'أخرى'),
        ],
      ),
      WorkflowField(
        name: 'templateId',
        label: 'رسالة محفوظة (اختياري)',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/communication-templates?includeInactive=false',
        labelKeys: ['name'],
        subtitleKeys: ['title', 'purpose'],
        copyValues: {'title': 'title', 'body': 'body', 'purpose': 'purpose'},
      ),
      WorkflowField(
        name: 'audienceType',
        label: 'الجمهور',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'ALL_MEMBERS',
        choices: [
          WorkflowChoice('ALL_MEMBERS', 'كل الأعضاء النشطين'),
          WorkflowChoice('SINGLE_MEMBER', 'عضو محدد'),
          WorkflowChoice('MEMBER_SEGMENT', 'اشتراكات تنتهي قريبًا'),
          WorkflowChoice('ALL_LEADS', 'كل العملاء المحتملين'),
          WorkflowChoice('SINGLE_LEAD', 'عميل محتمل محدد'),
          WorkflowChoice('LEAD_SEGMENT', 'شريحة عملاء محتملين'),
        ],
      ),
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
        visibleWhenField: 'audienceType',
        visibleWhenValues: ['SINGLE_MEMBER'],
      ),
      WorkflowField(
        name: 'leadId',
        label: 'العميل المحتمل',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/crm/leads',
        labelKeys: ['fullName', 'name'],
        subtitleKeys: ['phoneE164', 'status'],
        visibleWhenField: 'audienceType',
        visibleWhenValues: ['SINGLE_LEAD'],
      ),
      WorkflowField(
        name: 'expiryDays',
        label: 'تنتهي العضوية خلال عدد أيام',
        type: WorkflowFieldType.number,
        required: true,
        initialValue: '7',
        visibleWhenField: 'audienceType',
        visibleWhenValues: ['MEMBER_SEGMENT'],
      ),
      WorkflowField(
        name: 'leadStatuses',
        label: 'مراحل العملاء (افصل بينها بفاصلة)',
        initialValue: 'NEW,CONTACTED,QUALIFIED,TRIAL_SCHEDULED',
        visibleWhenField: 'audienceType',
        visibleWhenValues: ['ALL_LEADS', 'LEAD_SEGMENT'],
      ),
      WorkflowField(name: 'title', label: 'عنوان الإشعار', required: true),
      WorkflowField(
        name: 'body',
        label: 'نص الرسالة',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
      WorkflowField(
        name: 'scheduledAt',
        label: 'موعد الإرسال (اتركه للإرسال الآن)',
        type: WorkflowFieldType.dateTime,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'name': values['name']?.trim(),
      'purpose': values['purpose'],
      'title': values['title']?.trim(),
      'body': values['body']?.trim(),
      if (values['templateId']?.isNotEmpty == true)
        'templateId': values['templateId'],
      'audienceType': values['audienceType'],
      'audienceFilter': switch (values['audienceType']) {
        'SINGLE_MEMBER' => {'memberId': values['memberId']},
        'SINGLE_LEAD' => {'leadId': values['leadId']},
        'MEMBER_SEGMENT' => {
          'memberStatus': 'ACTIVE',
          'subscriptionEndingWithinDays':
              int.tryParse(values['expiryDays'] ?? '') ?? 7,
        },
        'ALL_LEADS' || 'LEAD_SEGMENT' => {
          'leadStatuses': (values['leadStatuses'] ?? '')
              .split(',')
              .map((item) => item.trim())
              .where((item) => item.isNotEmpty)
              .toList(),
        },
        _ => {'memberStatus': 'ACTIVE'},
      },
      'channels': ['IN_APP'],
      if (values['scheduledAt']?.isNotEmpty == true)
        'scheduledAt': _asIso(values['scheduledAt']),
    },
  ),
  MobileWorkflow(
    operationId: 'recordEmployeeAttendance',
    title: 'تسجيل حضور موظف',
    description: 'سجل الحضور أو الانصراف اليدوي مع الوقت الفعلي للعملية.',
    submitLabel: 'تسجيل الحركة',
    successMessage: 'تم تسجيل حركة دوام الموظف.',
    method: 'POST',
    path: '/organizations/{organizationId}/employee-attendance',
    icon: Icons.punch_clock_outlined,
    fields: [
      WorkflowField(
        name: 'employeeId',
        label: 'الموظف',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/employees',
        labelKeys: ['name', 'displayName'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'eventType',
        label: 'الحركة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'CLOCK_IN',
        choices: [
          WorkflowChoice('CLOCK_IN', 'حضور'),
          WorkflowChoice('CLOCK_OUT', 'انصراف'),
        ],
      ),
      WorkflowField(
        name: 'occurredAt',
        label: 'وقت الحركة',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'employeeId': values['employeeId'],
      'eventType': values['eventType'],
      'accessMethod': 'MANUAL',
      'occurredAt': _asIso(values['occurredAt']),
    },
  ),
  MobileWorkflow(
    operationId: 'createWhatsAppCampaign',
    title: 'إنشاء حملة واتساب',
    description: 'أنشئ مسودة رسالة واتساب معتمدة للأعضاء النشطين، ثم راجعها قبل وضعها في طابور الإرسال.',
    submitLabel: 'حفظ المسودة',
    successMessage: 'تم حفظ حملة واتساب كمسودة.',
    method: 'POST',
    path: '/organizations/{organizationId}/whatsapp-campaigns',
    icon: Icons.chat_outlined,
    fields: [
      WorkflowField(name: 'name', label: 'اسم الحملة', required: true),
      WorkflowField(
        name: 'providerTemplateName',
        label: 'اسم قالب مزود واتساب',
        required: true,
      ),
      WorkflowField(
        name: 'languageCode',
        label: 'كود اللغة',
        required: true,
        initialValue: 'ar',
      ),
      WorkflowField(
        name: 'messageTemplate',
        label: 'نص الرسالة (يدعم {{memberName}})',
        type: WorkflowFieldType.textarea,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'name': values['name']?.trim(),
      'providerTemplateName': values['providerTemplateName']?.trim(),
      'languageCode': values['languageCode']?.trim(),
      'messageTemplate': values['messageTemplate']?.trim(),
      'audienceFilter': {
        'memberStatus': 'ACTIVE',
        'verifiedPrimaryPhoneOnly': true,
      },
    },
  ),
  MobileWorkflow(
    operationId: 'createCommissionPlan',
    title: 'إضافة خطة عمولة',
    description: 'حدد طريقة احتساب عمولة المدرب وتاريخ سريانها.',
    submitLabel: 'حفظ خطة العمولة',
    successMessage: 'تمت إضافة خطة عمولة المدرب.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainer-commission-plans',
    icon: Icons.rule_outlined,
    fields: [
      WorkflowField(
        name: 'trainerProfileId',
        label: 'المدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'commissionType',
        label: 'نوع العمولة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'PERCENTAGE',
        choices: [
          WorkflowChoice('PERCENTAGE', 'نسبة مئوية'),
          WorkflowChoice('FIXED_PER_SESSION', 'مبلغ ثابت للجلسة'),
        ],
      ),
      WorkflowField(
        name: 'ratePercent',
        label: 'النسبة المئوية',
        type: WorkflowFieldType.number,
        required: true,
        visibleWhenField: 'commissionType',
        visibleWhenValues: ['PERCENTAGE'],
      ),
      WorkflowField(
        name: 'fixedAmount',
        label: 'المبلغ الثابت (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
        visibleWhenField: 'commissionType',
        visibleWhenValues: ['FIXED_PER_SESSION'],
      ),
      WorkflowField(
        name: 'validFrom',
        label: 'بداية السريان',
        type: WorkflowFieldType.date,
        required: true,
      ),
      WorkflowField(
        name: 'validUntil',
        label: 'نهاية السريان (اختياري)',
        type: WorkflowFieldType.date,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'trainerProfileId': values['trainerProfileId'],
      'commissionType': values['commissionType'],
      if (values['commissionType'] == 'PERCENTAGE')
        'rateBps': ((double.tryParse(values['ratePercent'] ?? '') ?? 0) * 100)
            .round(),
      if (values['commissionType'] == 'FIXED_PER_SESSION')
        'fixedAmountMinor': _moneyMinor(values['fixedAmount']),
      'validFrom': values['validFrom'],
      if (values['validUntil']?.isNotEmpty == true)
        'validUntil': values['validUntil'],
    },
  ),
  MobileWorkflow(
    operationId: 'accrueTrainerCommission',
    title: 'تسجيل عمولة مدرب',
    description: 'سجل مصدر وقيمة العملية ليحسب النظام العمولة المستحقة.',
    submitLabel: 'احتساب العمولة',
    successMessage: 'تم احتساب عمولة المدرب.',
    method: 'POST',
    path: '/organizations/{organizationId}/trainer-commissions',
    icon: Icons.percent_outlined,
    fields: [
      WorkflowField(
        name: 'trainerProfileId',
        label: 'المدرب',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(
        name: 'sourceType',
        label: 'مصدر العمولة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: 'MANUAL_ADJUSTMENT',
        choices: [
          WorkflowChoice('PERSONAL_TRAINING', 'تدريب شخصي'),
          WorkflowChoice('SUBSCRIPTION_SALE', 'بيع اشتراك'),
          WorkflowChoice('MANUAL_ADJUSTMENT', 'تسوية يدوية'),
        ],
      ),
      WorkflowField(
        name: 'sourceId',
        label: 'معرّف العملية المصدرية',
        required: true,
      ),
      WorkflowField(
        name: 'basisAmount',
        label: 'قيمة أساس العمولة (ر.س)',
        type: WorkflowFieldType.number,
        required: true,
        allowZero: true,
      ),
      WorkflowField(
        name: 'occurredAt',
        label: 'تاريخ العملية',
        type: WorkflowFieldType.dateTime,
        required: true,
      ),
    ],
    body: (values, controller) => {
      'branchId': controller.branchId,
      'trainerProfileId': values['trainerProfileId'],
      'sourceType': values['sourceType'],
      'sourceId': values['sourceId']?.trim(),
      'basisAmountMinor': _moneyMinor(values['basisAmount']),
      'occurredAt': _asIso(values['occurredAt']),
    },
  ),
  MobileWorkflow(
    operationId: 'createTrainingPlanTemplate',
    title: 'إنشاء قالب خطة تدريب',
    description: 'أنشئ قالبًا سريعًا يبدأ بتمرين واحد؛ يمكن توسيعه لاحقًا من إدارة الخطط.',
    submitLabel: 'حفظ القالب',
    successMessage: 'تم إنشاء قالب خطة التدريب.',
    method: 'POST',
    path: '/organizations/{organizationId}/training-plan-templates',
    icon: Icons.content_paste_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز القالب', required: true),
      WorkflowField(name: 'name', label: 'اسم الخطة', required: true),
      WorkflowField(name: 'goal', label: 'الهدف'),
      WorkflowField(
        name: 'exerciseName',
        label: 'اسم التمرين الأول',
        required: true,
      ),
      WorkflowField(
        name: 'sets',
        label: 'عدد المجموعات',
        type: WorkflowFieldType.number,
      ),
      WorkflowField(name: 'repetitions', label: 'التكرارات'),
      WorkflowField(
        name: 'instructions',
        label: 'تعليمات التمرين',
        type: WorkflowFieldType.textarea,
      ),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'name': values['name']?.trim(),
      if (values['goal']?.trim().isNotEmpty == true)
        'goal': values['goal']?.trim(),
      'items': [
        {
          'dayNumber': 1,
          'sequenceNumber': 1,
          'exerciseName': values['exerciseName']?.trim(),
          if (values['sets']?.isNotEmpty == true)
            'sets': int.tryParse(values['sets']!),
          if (values['repetitions']?.trim().isNotEmpty == true)
            'repetitions': values['repetitions']?.trim(),
          if (values['instructions']?.trim().isNotEmpty == true)
            'instructions': values['instructions']?.trim(),
        },
      ],
    },
  ),
  MobileWorkflow(
    operationId: 'createMemberTrainingPlan',
    title: 'إسناد خطة تدريب لعضو',
    description: 'اختر العضو والقالب والمدرب وحدد مدة الخطة.',
    submitLabel: 'إسناد الخطة',
    successMessage: 'تم إسناد الخطة التدريبية للعضو.',
    method: 'POST',
    path: '/organizations/{organizationId}/member-training-plans',
    icon: Icons.fitness_center_outlined,
    fields: [
      WorkflowField(
        name: 'memberId',
        label: 'العضو',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath: '/organizations/{organizationId}/members',
        labelKeys: ['name', 'fullNameAr'],
        subtitleKeys: ['memberNumber'],
      ),
      WorkflowField(
        name: 'sourceTemplateId',
        label: 'قالب الخطة',
        type: WorkflowFieldType.reference,
        required: true,
        referencePath:
            '/organizations/{organizationId}/training-plan-templates',
        labelKeys: ['name'],
        subtitleKeys: ['code'],
      ),
      WorkflowField(
        name: 'trainerProfileId',
        label: 'المدرب (اختياري)',
        type: WorkflowFieldType.reference,
        referencePath: '/organizations/{organizationId}/trainers',
        labelKeys: ['displayName', 'name'],
        subtitleKeys: ['employeeNumber'],
      ),
      WorkflowField(name: 'name', label: 'اسم الخطة', required: true),
      WorkflowField(name: 'goal', label: 'الهدف'),
      WorkflowField(
        name: 'startsOn',
        label: 'تاريخ البداية',
        type: WorkflowFieldType.date,
        required: true,
      ),
      WorkflowField(
        name: 'endsOn',
        label: 'تاريخ النهاية (اختياري)',
        type: WorkflowFieldType.date,
        autoFillDate: false,
      ),
    ],
    body: (values, controller) => {
      'memberId': values['memberId'],
      'sourceTemplateId': values['sourceTemplateId'],
      if (values['trainerProfileId']?.isNotEmpty == true)
        'trainerProfileId': values['trainerProfileId'],
      'name': values['name']?.trim(),
      if (values['goal']?.trim().isNotEmpty == true)
        'goal': values['goal']?.trim(),
      'startsOn': values['startsOn'],
      if (values['endsOn']?.isNotEmpty == true) 'endsOn': values['endsOn'],
      'items': <Map<String, dynamic>>[],
    },
  ),
  MobileWorkflow(
    operationId: 'createCrmLeadSource',
    title: 'إضافة مصدر عميل',
    description: 'عرّف قناة اكتساب جديدة لتقارير العملاء المحتملين.',
    submitLabel: 'حفظ المصدر',
    successMessage: 'تمت إضافة مصدر العميل.',
    method: 'POST',
    path: '/organizations/{organizationId}/crm/lead-sources',
    icon: Icons.source_outlined,
    fields: [
      WorkflowField(name: 'code', label: 'رمز المصدر', required: true),
      WorkflowField(name: 'nameAr', label: 'الاسم بالعربية', required: true),
      WorkflowField(name: 'nameEn', label: 'الاسم بالإنجليزية'),
    ],
    body: (values, controller) => {
      'code': values['code']?.trim().toUpperCase(),
      'nameAr': values['nameAr']?.trim(),
      if (values['nameEn']?.trim().isNotEmpty == true)
        'nameEn': values['nameEn']?.trim(),
    },
  ),
  MobileWorkflow(
    operationId: 'createDailyMenu',
    title: 'إنشاء قائمة اليوم',
    description: 'اختر الوجبات التي ستظهر للأعضاء في الفرع اليوم، ثم انشر القائمة من إجراءات السجل.',
    submitLabel: 'إنشاء قائمة اليوم',
    successMessage: 'تم إنشاء مسودة قائمة اليوم. انشرها لتظهر للأعضاء.',
    method: 'POST',
    path: '/organizations/{organizationId}/branches/{branchId}/daily-menus',
    icon: Icons.restaurant_menu_outlined,
    fields: [
      WorkflowField(
        name: 'mealIds',
        label: 'وجبات القائمة',
        type: WorkflowFieldType.multiReference,
        required: true,
        referencePath: '/organizations/{organizationId}/restaurant/meals',
        labelKeys: ['name', 'mealName'],
        subtitleKeys: ['categoryName', 'code'],
      ),
    ],
    body: (values, controller) => {
      'businessDate': riyadhBusinessDate(),
      'items': _selectedValues(values['mealIds'])
          .map((id) => {'mealId': id, 'enabled': true})
          .toList(),
    },
  ),
];

String _asIso(String? value) {
  final parsed = DateTime.tryParse(value ?? '');
  return (parsed ?? DateTime.now()).toUtc().toIso8601String();
}

List<String> _selectedValues(String? value) => (value ?? '')
    .split(',')
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toList(growable: false);

String _moneyMinor(String? value) =>
    ((double.tryParse(value ?? '') ?? 0) * 100).round().toString();

bool _checked(String? value) => value == 'true' || value == '1';

class ResourceFeature {
  const ResourceFeature({
    required this.title,
    required this.subtitle,
    required this.path,
    required this.icon,
    required this.fields,
  });
  final String title;
  final String subtitle;
  final String path;
  final IconData icon;
  final List<(String, String)> fields;
}

const organizationFeature = ResourceFeature(
  title: 'بيانات النادي',
  subtitle: 'الاسم والرمز والمنطقة الزمنية وحالة النادي',
  path: '/organizations/{organizationId}',
  icon: Icons.business_outlined,
  fields: [
    ('nameAr', 'اسم النادي'),
    ('code', 'الرمز'),
    ('timezone', 'المنطقة الزمنية'),
    ('status', 'الحالة'),
  ],
);

const resourceFeatures = <ResourceFeature>[
  ResourceFeature(
    title: 'الاشتراكات',
    subtitle: 'حالة الاشتراكات ودورة العضوية',
    path: '/organizations/{organizationId}/subscriptions',
    icon: Icons.credit_card_outlined,
    fields: [
      ('memberName', 'العضو'),
      ('subscriptionNumber', 'رقم الاشتراك'),
      ('packageName', 'الباقة'),
      ('endsOn', 'النهاية'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الحضور والدخول',
    subtitle: 'محاولات الدخول المسجلة في الفرع',
    path: '/organizations/{organizationId}/attendance-attempts',
    icon: Icons.qr_code_scanner_rounded,
    fields: [
      ('memberName', 'العضو'),
      ('memberNumber', 'رقم العضوية'),
      ('occurredAt', 'الوقت'),
      ('method', 'الطريقة'),
      ('decision', 'القرار'),
    ],
  ),
  ResourceFeature(
    title: 'الحجوزات',
    subtitle: 'المواعيد والموارد المحجوزة',
    path: '/organizations/{organizationId}/reservations',
    icon: Icons.calendar_month_outlined,
    fields: [
      ('customerName', 'العميل'),
      ('reservationNumber', 'رقم الحجز'),
      ('resourceName', 'المورد'),
      ('startsAt', 'الموعد'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الفواتير',
    subtitle: 'فواتير الفرع والتحصيل',
    path: '/organizations/{organizationId}/invoices',
    icon: Icons.receipt_long_outlined,
    fields: [
      ('buyerName', 'العميل'),
      ('invoiceNumber', 'الفاتورة'),
      ('grossMinor', 'الإجمالي'),
      ('outstandingMinor', 'المتبقي'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'المصروفات',
    subtitle: 'طلبات ومصروفات الفرع',
    path: '/organizations/{organizationId}/expenses',
    icon: Icons.payments_outlined,
    fields: [
      ('description', 'البيان'),
      ('categoryName', 'التصنيف'),
      ('amountMinor', 'القيمة'),
      ('incurredOn', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'العملاء والمتابعات',
    subtitle: 'فرص CRM والمتابعة القادمة',
    path: '/organizations/{organizationId}/crm/leads',
    icon: Icons.bolt_outlined,
    fields: [
      ('fullName', 'الاسم'),
      ('phoneE164', 'الجوال'),
      ('interestType', 'الاهتمام'),
      ('nextFollowUpAt', 'المتابعة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'طلبات المطعم',
    subtitle: 'طابور المطبخ والطلبات',
    path: '/organizations/{organizationId}/restaurant-orders',
    icon: Icons.restaurant_outlined,
    fields: [
      ('memberName', 'العضو'),
      ('orderNumber', 'الطلب'),
      ('createdAt', 'الوقت'),
      ('grossMinor', 'القيمة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الموظفون',
    subtitle: 'الفريق والمناوبات والحالة',
    path: '/organizations/{organizationId}/employees',
    icon: Icons.badge_outlined,
    fields: [
      ('name', 'الموظف'),
      ('employeeNumber', 'الرقم الوظيفي'),
      ('positionName', 'المسمى'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'المدربون',
    subtitle: 'المدربون وتخصصاتهم',
    path: '/organizations/{organizationId}/trainers',
    icon: Icons.fitness_center_outlined,
    fields: [
      ('name', 'المدرب'),
      ('employeeNumber', 'الرقم الوظيفي'),
      ('specialtyName', 'التخصص'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الشكاوى والاقتراحات',
    subtitle: 'تذاكر التواصل المفتوحة',
    path: '/organizations/{organizationId}/feedback-cases',
    icon: Icons.feedback_outlined,
    fields: [
      ('subject', 'الموضوع'),
      ('memberName', 'العضو'),
      ('type', 'النوع'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'سجل نشاط النظام',
    subtitle: 'العمليات والتغييرات المدققة',
    path: '/organizations/{organizationId}/audit-records',
    icon: Icons.history_rounded,
    fields: [
      ('action', 'الإجراء'),
      ('actorName', 'المنفذ'),
      ('aggregateType', 'النوع'),
      ('occurredAt', 'الوقت'),
    ],
  ),
  ResourceFeature(
    title: 'الطلبات والمبيعات',
    subtitle: 'طلبات البيع والتنفيذ في الفرع',
    path: '/organizations/{organizationId}/orders',
    icon: Icons.shopping_bag_outlined,
    fields: [
      ('orderNumber', 'رقم الطلب'),
      ('buyerName', 'العميل'),
      ('grossMinor', 'الإجمالي'),
      ('createdAt', 'الوقت'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'المدفوعات',
    subtitle: 'عمليات التحصيل وتوزيع الدفعات',
    path: '/organizations/{organizationId}/payments',
    icon: Icons.account_balance_wallet_outlined,
    fields: [
      ('paymentNumber', 'رقم الدفعة'),
      ('payerName', 'الدافع'),
      ('amountMinor', 'المبلغ'),
      ('method', 'الطريقة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الاستردادات',
    subtitle: 'طلبات ومبالغ الاسترداد المالي',
    path: '/organizations/{organizationId}/refunds',
    icon: Icons.currency_exchange_rounded,
    fields: [
      ('refundNumber', 'رقم الاسترداد'),
      ('amountMinor', 'المبلغ'),
      ('reason', 'السبب'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'نقاط الصندوق',
    subtitle: 'نقاط التحصيل المعرفة في الفروع',
    path: '/organizations/{organizationId}/cash-points',
    icon: Icons.point_of_sale_outlined,
    fields: [
      ('name', 'النقطة'),
      ('code', 'الرمز'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'ورديات الصندوق',
    subtitle: 'الورديات المفتوحة والمغلقة والمبالغ المسجلة',
    path: '/organizations/{organizationId}/cashier-shifts',
    icon: Icons.lock_clock_outlined,
    fields: [
      ('cashPointName', 'نقطة الصندوق'),
      ('cashierName', 'الكاشير'),
      ('openedAt', 'وقت الفتح'),
      ('closingBalanceMinor', 'رصيد الإغلاق'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الأنشطة',
    subtitle: 'الأنشطة الرياضية المعرفة في النظام',
    path: '/organizations/{organizationId}/activities',
    icon: Icons.directions_run_outlined,
    fields: [
      ('name', 'النشاط'),
      ('code', 'الرمز'),
      ('description', 'الوصف'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تصنيفات الخدمات',
    subtitle: 'هيكلة وتصنيف الخدمات المقدمة',
    path: '/organizations/{organizationId}/service-categories',
    icon: Icons.category_outlined,
    fields: [('name', 'التصنيف'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'الخدمات',
    subtitle: 'الخدمات الرياضية والتشغيلية المتاحة',
    path: '/organizations/{organizationId}/services',
    icon: Icons.sports_gymnastics_outlined,
    fields: [
      ('name', 'الخدمة'),
      ('code', 'الرمز'),
      ('categoryName', 'التصنيف'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الباقات',
    subtitle: 'باقات الاشتراك المنشورة والمسودات',
    path: '/organizations/{organizationId}/packages',
    icon: Icons.inventory_2_outlined,
    fields: [
      ('name', 'الباقة'),
      ('code', 'الرمز'),
      ('durationDays', 'المدة بالأيام'),
      ('visitLimit', 'الزيارات'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الأسعار',
    subtitle: 'إصدارات الأسعار السارية والقادمة',
    path: '/organizations/{organizationId}/prices',
    icon: Icons.price_change_outlined,
    fields: [
      ('targetName', 'العنصر'),
      ('amountMinor', 'السعر'),
      ('validFrom', 'بداية السريان'),
      ('validUntil', 'نهاية السريان'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'العروض الترويجية',
    subtitle: 'العروض والأكواد الترويجية',
    path: '/organizations/{organizationId}/promotions',
    icon: Icons.local_offer_outlined,
    fields: [
      ('name', 'العرض'),
      ('code', 'الكود'),
      ('discountType', 'نوع الخصم'),
      ('validUntil', 'النهاية'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'المرافق',
    subtitle: 'الملاعب والقاعات والاستوديوهات',
    path: '/organizations/{organizationId}/facilities',
    icon: Icons.apartment_outlined,
    fields: [
      ('name', 'المرفق'),
      ('code', 'الرمز'),
      ('type', 'النوع'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الموارد القابلة للحجز',
    subtitle: 'الموارد والسعة والحالة التشغيلية',
    path: '/organizations/{organizationId}/bookable-resources',
    icon: Icons.event_available_outlined,
    fields: [
      ('name', 'المورد'),
      ('facilityName', 'المرفق'),
      ('type', 'النوع'),
      ('capacity', 'السعة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تصنيفات الوجبات',
    subtitle: 'تصنيفات كتالوج مطعم النادي',
    path: '/organizations/{organizationId}/restaurant/meal-categories',
    icon: Icons.ramen_dining_outlined,
    fields: [('name', 'التصنيف'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'كتالوج الوجبات',
    subtitle: 'الوجبات والقيم الغذائية والحالة',
    path: '/organizations/{organizationId}/restaurant/meals',
    icon: Icons.lunch_dining_outlined,
    fields: [
      ('name', 'الوجبة'),
      ('categoryName', 'التصنيف'),
      ('calories', 'السعرات'),
      ('proteinGrams', 'البروتين'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تخصصات التدريب',
    subtitle: 'تخصصات المدربين المعتمدة',
    path: '/organizations/{organizationId}/coaching-specialties',
    icon: Icons.workspace_premium_outlined,
    fields: [('name', 'التخصص'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'جلسات القياس',
    subtitle: 'جلسات القياسات البدنية المسجلة',
    path: '/organizations/{organizationId}/measurement-sessions',
    icon: Icons.monitor_weight_outlined,
    fields: [
      ('memberName', 'العضو'),
      ('trainerName', 'المدرب'),
      ('measuredAt', 'وقت القياس'),
      ('notes', 'الملاحظات'),
    ],
  ),
  ResourceFeature(
    title: 'المسميات الوظيفية',
    subtitle: 'الهيكل والمسميات الوظيفية',
    path: '/organizations/{organizationId}/positions',
    icon: Icons.account_tree_outlined,
    fields: [
      ('name', 'المسمى'),
      ('code', 'الرمز'),
      ('description', 'الوصف'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'ورديات الموظفين',
    subtitle: 'جداول ومناوبات فريق العمل',
    path: '/organizations/{organizationId}/employee-shifts',
    icon: Icons.calendar_view_week_outlined,
    fields: [
      ('employeeName', 'الموظف'),
      ('startsAt', 'البداية'),
      ('endsAt', 'النهاية'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'دوام الموظفين',
    subtitle: 'سجل الحضور والانصراف للفريق',
    path: '/organizations/{organizationId}/employee-attendance',
    icon: Icons.punch_clock_outlined,
    fields: [
      ('employeeName', 'الموظف'),
      ('eventType', 'الحدث'),
      ('occurredAt', 'الوقت'),
      ('branchName', 'الفرع'),
    ],
  ),
  ResourceFeature(
    title: 'بطاقات الدخول',
    subtitle: 'باركودات وبطاقات الوصول وحالتها',
    path: '/organizations/{organizationId}/access-credentials',
    icon: Icons.badge_outlined,
    fields: [
      ('subjectName', 'صاحب البطاقة'),
      ('subjectType', 'النوع'),
      ('credentialValue', 'الرمز'),
      ('expiresAt', 'الانتهاء'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'طلبات الانضمام',
    subtitle: 'الطلبات الإلكترونية الواردة ومراحلها',
    path: '/organizations/{organizationId}/online-requests',
    icon: Icons.person_add_alt_outlined,
    fields: [
      ('fullName', 'الاسم'),
      ('phoneE164', 'الجوال'),
      ('requestType', 'نوع الطلب'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الخزائن',
    subtitle: 'الخزائن والتخصيصات والحالة',
    path: '/organizations/{organizationId}/lockers',
    icon: Icons.door_sliding_outlined,
    fields: [
      ('code', 'الخزانة'),
      ('location', 'الموقع'),
      ('memberName', 'العضو'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الملفات والمرفقات',
    subtitle: 'ملفات الأعضاء والموظفين الآمنة',
    path: '/organizations/{organizationId}/files',
    icon: Icons.folder_outlined,
    fields: [
      ('originalFilename', 'اسم الملف'),
      ('purpose', 'الغرض'),
      ('ownerType', 'المالك'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'قوالب الإشعارات',
    subtitle: 'إصدارات قوالب الرسائل المعتمدة',
    path: '/organizations/{organizationId}/notification-templates',
    icon: Icons.dynamic_feed_outlined,
    fields: [
      ('name', 'القالب'),
      ('key', 'المفتاح'),
      ('channel', 'القناة'),
      ('version', 'الإصدار'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'سجل الإرسال',
    subtitle: 'الرسائل المرسلة وحالة التسليم',
    path: '/organizations/{organizationId}/notifications',
    icon: Icons.mark_email_read_outlined,
    fields: [
      ('recipientMasked', 'المستلم'),
      ('channel', 'القناة'),
      ('templateKey', 'القالب'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'حملات واتساب',
    subtitle: 'المسودات والحملات المجدولة',
    path: '/organizations/{organizationId}/whatsapp-campaigns',
    icon: Icons.chat_outlined,
    fields: [
      ('name', 'الحملة'),
      ('audienceType', 'الجمهور'),
      ('scheduledAt', 'الموعد'),
      ('recipientCount', 'المستلمون'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الإيرادات الأخرى',
    subtitle: 'بنود الإيراد خارج المبيعات الأساسية',
    path: '/organizations/{organizationId}/other-income',
    icon: Icons.savings_outlined,
    fields: [
      ('description', 'البيان'),
      ('categoryName', 'التصنيف'),
      ('amountMinor', 'المبلغ'),
      ('receivedOn', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الأدوار والصلاحيات',
    subtitle: 'أدوار المستخدمين داخل المؤسسة',
    path: '/organizations/{organizationId}/roles',
    icon: Icons.admin_panel_settings_outlined,
    fields: [
      ('name', 'الدور'),
      ('description', 'الوصف'),
      ('assignmentCount', 'المستخدمون'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'حسابات المستخدمين',
    subtitle: 'حسابات الفريق المرتبطة بالمؤسسة',
    path: '/organizations/{organizationId}/user-accounts',
    icon: Icons.manage_accounts_outlined,
    fields: [
      ('displayName', 'المستخدم'),
      ('email', 'البريد'),
      ('phoneE164', 'الجوال'),
      ('lastSignedInAt', 'آخر دخول'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الفروع',
    subtitle: 'فروع المؤسسة وحالتها وتوقيتها',
    path: '/organizations/{organizationId}/branches',
    icon: Icons.business_outlined,
    fields: [
      ('nameAr', 'الفرع'),
      ('code', 'الرمز'),
      ('timezone', 'التوقيت'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تعيينات الأدوار',
    subtitle: 'نطاقات صلاحيات حسابات الفريق',
    path: '/organizations/{organizationId}/role-assignments',
    icon: Icons.assignment_ind_outlined,
    fields: [
      ('userDisplayName', 'المستخدم'),
      ('roleName', 'الدور'),
      ('scopeType', 'النطاق'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'دليل الصلاحيات',
    subtitle: 'الصلاحيات المتاحة داخل النظام',
    path: '/organizations/{organizationId}/permissions',
    icon: Icons.key_outlined,
    fields: [
      ('code', 'الصلاحية'),
      ('description', 'الوصف'),
      ('category', 'التصنيف'),
    ],
  ),
  ResourceFeature(
    title: 'السياسات التجارية',
    subtitle: 'سياسات الإلغاء والتجميد والحجز',
    path: '/organizations/{organizationId}/commercial-policies',
    icon: Icons.policy_outlined,
    fields: [
      ('name', 'السياسة'),
      ('policyType', 'النوع'),
      ('version', 'الإصدار'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'طلبات الاسترداد',
    subtitle: 'طلبات رد المبالغ ومراحل الاعتماد',
    path: '/organizations/{organizationId}/refund-requests',
    icon: Icons.assignment_return_outlined,
    fields: [
      ('requestNumber', 'الطلب'),
      ('memberName', 'العضو'),
      ('amountMinor', 'المبلغ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تصنيفات المصروفات',
    subtitle: 'تصنيفات وضوابط اعتماد المصروفات',
    path: '/organizations/{organizationId}/expense-categories',
    icon: Icons.category_outlined,
    fields: [
      ('name', 'التصنيف'),
      ('code', 'الرمز'),
      ('approvalLimitMinor', 'حد الاعتماد'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'أسعار الوجبات',
    subtitle: 'الأسعار الفعالة حسب الفرع والتاريخ',
    path: '/organizations/{organizationId}/restaurant/meal-prices',
    icon: Icons.price_check_outlined,
    fields: [
      ('mealName', 'الوجبة'),
      ('amountMinor', 'السعر'),
      ('validFrom', 'بداية السريان'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'قائمة اليوم',
    subtitle: 'الوجبات التي تظهر للأعضاء اليوم وحالة النشر',
    path: '/organizations/{organizationId}/branches/{branchId}/daily-menus/{businessDate}',
    icon: Icons.restaurant_menu_outlined,
    fields: [
      ('businessDate', 'التاريخ'),
      ('status', 'حالة النشر'),
      ('version', 'الإصدار'),
    ],
  ),
  ResourceFeature(
    title: 'تصنيفات المتجر',
    subtitle: 'تصنيفات منتجات البيع بالتجزئة',
    path: '/organizations/{organizationId}/retail/categories',
    icon: Icons.sell_outlined,
    fields: [('name', 'التصنيف'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'منتجات المتجر',
    subtitle: 'كتالوج المنتجات والباركود',
    path: '/organizations/{organizationId}/retail/products',
    icon: Icons.shopping_basket_outlined,
    fields: [
      ('name', 'المنتج'),
      ('sku', 'SKU'),
      ('barcode', 'الباركود'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'أسعار المتجر',
    subtitle: 'أسعار المنتجات حسب الفرع',
    path: '/organizations/{organizationId}/retail/prices',
    icon: Icons.price_change_outlined,
    fields: [
      ('productName', 'المنتج'),
      ('amountMinor', 'السعر'),
      ('validFrom', 'بداية السريان'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'مخزون المتجر',
    subtitle: 'الرصيد المتاح وحدود إعادة الطلب',
    path: '/organizations/{organizationId}/retail/inventory',
    icon: Icons.inventory_outlined,
    fields: [
      ('productName', 'المنتج'),
      ('quantityOnHand', 'المتاح'),
      ('reorderLevel', 'حد الطلب'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'أنواع القياسات',
    subtitle: 'تعريف وحدات وقواعد القياس البدني',
    path: '/organizations/{organizationId}/measurement-types',
    icon: Icons.straighten_outlined,
    fields: [
      ('name', 'القياس'),
      ('code', 'الرمز'),
      ('unit', 'الوحدة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'عمولات المدربين',
    subtitle: 'العمولات المحتسبة لفريق التدريب',
    path: '/organizations/{organizationId}/trainer-commissions',
    icon: Icons.percent_outlined,
    fields: [
      ('trainerName', 'المدرب'),
      ('period', 'الفترة'),
      ('amountMinor', 'العمولة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'خطط عمولات المدربين',
    subtitle: 'قواعد ونسب احتساب العمولات',
    path: '/organizations/{organizationId}/trainer-commission-plans',
    icon: Icons.rule_outlined,
    fields: [
      ('name', 'الخطة'),
      ('code', 'الرمز'),
      ('effectiveFrom', 'السريان'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'قوالب خطط التدريب',
    subtitle: 'خطط تمارين قابلة لإعادة الاستخدام',
    path: '/organizations/{organizationId}/training-plan-templates',
    icon: Icons.content_paste_outlined,
    fields: [
      ('name', 'القالب'),
      ('goal', 'الهدف'),
      ('itemCount', 'التمارين'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'خطط تدريب الأعضاء',
    subtitle: 'الخطط المسندة وحالة الإنجاز',
    path: '/organizations/{organizationId}/member-training-plans',
    icon: Icons.fitness_center_outlined,
    fields: [
      ('memberName', 'العضو'),
      ('name', 'الخطة'),
      ('startsOn', 'البداية'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'مصادر العملاء',
    subtitle: 'قنوات اكتساب العملاء المحتملين',
    path: '/organizations/{organizationId}/crm/lead-sources',
    icon: Icons.source_outlined,
    fields: [('name', 'المصدر'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'متابعات CRM',
    subtitle: 'المهام والمواعيد المرتبطة بالعملاء',
    path: '/organizations/{organizationId}/crm/follow-ups',
    icon: Icons.follow_the_signs_outlined,
    fields: [
      ('leadName', 'العميل'),
      ('dueAt', 'الموعد'),
      ('assignedToName', 'المسؤول'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'أجهزة بوابات الدخول',
    subtitle: 'الأجهزة المسجلة وحالة الاتصال',
    path: '/organizations/{organizationId}/access-devices',
    icon: Icons.sensors_outlined,
    fields: [
      ('name', 'الجهاز'),
      ('serialNumber', 'الرقم التسلسلي'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'أحداث أجهزة الدخول',
    subtitle: 'سجل المزامنة والأحداث الخام للأجهزة',
    path: '/organizations/{organizationId}/access-device-events',
    icon: Icons.rss_feed_outlined,
    fields: [
      ('deviceName', 'الجهاز'),
      ('eventType', 'الحدث'),
      ('occurredAt', 'الوقت'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'تصنيفات الإيرادات الأخرى',
    subtitle: 'تعريف بنود الإيراد غير المرتبط بالمبيعات',
    path: '/organizations/{organizationId}/other-income-categories',
    icon: Icons.account_tree_outlined,
    fields: [('name', 'التصنيف'), ('code', 'الرمز'), ('status', 'الحالة')],
  ),
  ResourceFeature(
    title: 'قوالب التواصل',
    subtitle: 'قوالب الرسائل متعددة القنوات',
    path: '/organizations/{organizationId}/communication-templates',
    icon: Icons.mark_email_unread_outlined,
    fields: [
      ('name', 'القالب'),
      ('channel', 'القناة'),
      ('version', 'الإصدار'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'حملات التواصل',
    subtitle: 'حملات الرسائل والجمهور وحالة التسليم',
    path: '/organizations/{organizationId}/communication-campaigns',
    icon: Icons.campaign_outlined,
    fields: [
      ('name', 'الحملة'),
      ('channel', 'القناة'),
      ('recipientCount', 'المستلمون'),
      ('status', 'الحالة'),
    ],
  ),
];

const memberResourceFeatures = <ResourceFeature>[
  ResourceFeature(
    title: 'اشتراكاتي',
    subtitle: 'الباقات الحالية والسابقة وحالة العضوية',
    path:
        '/self/organizations/{organizationId}/members/{memberId}/subscriptions',
    icon: Icons.credit_card_outlined,
    fields: [
      ('packageName', 'الباقة'),
      ('subscriptionNumber', 'رقم الاشتراك'),
      ('termStart', 'البداية'),
      ('termEnd', 'النهاية'),
      ('visitsRemaining', 'الزيارات المتبقية'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'طلباتي',
    subtitle: 'طلبات الشراء والتجديد والحجز',
    path: '/self/organizations/{organizationId}/members/{memberId}/orders',
    icon: Icons.shopping_bag_outlined,
    fields: [
      ('orderNumber', 'رقم الطلب'),
      ('createdAt', 'التاريخ'),
      ('grossMinor', 'الإجمالي'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'فواتيري',
    subtitle: 'الفواتير والمبالغ المتبقية للسداد',
    path: '/self/organizations/{organizationId}/members/{memberId}/invoices',
    icon: Icons.receipt_long_outlined,
    fields: [
      ('invoiceNumber', 'رقم الفاتورة'),
      ('issuedAt', 'التاريخ'),
      ('grossMinor', 'الإجمالي'),
      ('outstandingMinor', 'المتبقي'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'سجل حضوري',
    subtitle: 'زيارات النادي ونتيجة كل محاولة دخول',
    path: '/self/organizations/{organizationId}/members/{memberId}/attendance',
    icon: Icons.directions_walk_outlined,
    fields: [
      ('occurredAt', 'الوقت'),
      ('branchName', 'الفرع'),
      ('method', 'الطريقة'),
      ('decision', 'النتيجة'),
    ],
  ),
  ResourceFeature(
    title: 'حجوزاتي',
    subtitle: 'المواعيد السابقة والقادمة',
    path:
        '/self/organizations/{organizationId}/members/{memberId}/reservations',
    icon: Icons.event_available_outlined,
    fields: [
      ('resourceName', 'المورد'),
      ('startsAt', 'الموعد'),
      ('branchName', 'الفرع'),
      ('seats', 'المقاعد'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'طلبات المطعم',
    subtitle: 'وجباتك السابقة وحالة تجهيزها',
    path: '/self/organizations/{organizationId}/members/{memberId}/restaurant-orders',
    icon: Icons.restaurant_outlined,
    fields: [
      ('orderNumber', 'رقم الطلب'),
      ('createdAt', 'التاريخ'),
      ('grossMinor', 'الإجمالي'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'قياساتي',
    subtitle: 'تطور القياسات البدنية المسجلة',
    path:
        '/self/organizations/{organizationId}/members/{memberId}/measurements',
    icon: Icons.monitor_weight_outlined,
    fields: [
      ('measuredAt', 'تاريخ القياس'),
      ('measurementName', 'القياس'),
      ('value', 'القيمة'),
      ('trainerName', 'المدرب'),
      ('notes', 'ملاحظات'),
    ],
  ),
  ResourceFeature(
    title: 'خططي التدريبية',
    subtitle: 'التمارين والخطط ومتابعة الإنجاز',
    path: '/self/organizations/{organizationId}/members/{memberId}/training-plans',
    icon: Icons.fitness_center_outlined,
    fields: [
      ('name', 'الخطة'),
      ('goal', 'الهدف'),
      ('startsOn', 'البداية'),
      ('endsOn', 'النهاية'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'ملفاتي',
    subtitle: 'مستندات العضوية والمرفقات الآمنة',
    path: '/self/organizations/{organizationId}/members/{memberId}/files',
    icon: Icons.folder_outlined,
    fields: [
      ('originalFilename', 'الملف'),
      ('purpose', 'الغرض'),
      ('createdAt', 'التاريخ'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الشكاوى والاقتراحات',
    subtitle: 'تذاكر التواصل والردود مع فريق النادي',
    path: '/self/organizations/{organizationId}/members/{memberId}/feedback-cases',
    icon: Icons.forum_outlined,
    fields: [
      ('caseNumber', 'رقم التذكرة'),
      ('subject', 'الموضوع'),
      ('caseType', 'النوع'),
      ('updatedAt', 'آخر تحديث'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الأنشطة المتاحة',
    subtitle: 'استكشف أنشطة النادي المتاحة لك',
    path: '/self/organizations/{organizationId}/activities',
    icon: Icons.directions_run_outlined,
    fields: [
      ('name', 'النشاط'),
      ('description', 'الوصف'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الخدمات المتاحة',
    subtitle: 'شراء خدمة وإصدار فاتورة؛ لحجز موعد استخدم حجز موعد',
    path: '/self/organizations/{organizationId}/services',
    icon: Icons.sports_gymnastics_outlined,
    fields: [
      ('name', 'الخدمة'),
      ('categoryName', 'التصنيف'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'الباقات المتاحة',
    subtitle: 'قارن الباقات المنشورة قبل الشراء أو التجديد',
    path: '/self/organizations/{organizationId}/packages',
    icon: Icons.card_membership_outlined,
    fields: [
      ('name', 'الباقة'),
      ('durationDays', 'المدة بالأيام'),
      ('visitLimit', 'الزيارات'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'حجز موعد',
    subtitle: 'اختر المورد ثم موعدًا متاحًا أو فترة حجز الملعب',
    path: '/self/organizations/{organizationId}/bookable-resources',
    icon: Icons.event_available_outlined,
    fields: [
      ('name', 'المورد'),
      ('type', 'النوع'),
      ('capacity', 'السعة'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'قائمة اليوم',
    subtitle: 'الوجبات المتاحة اليوم وأسعارها',
    path: '/self/organizations/{organizationId}/daily-menu',
    icon: Icons.restaurant_menu_outlined,
    fields: [
      ('businessDate', 'التاريخ'),
      ('branchName', 'الفرع'),
      ('status', 'الحالة'),
    ],
  ),
  ResourceFeature(
    title: 'بطاقة دخولي',
    subtitle: 'رمز العضوية النشط للاستخدام عند بوابة النادي',
    path: '/self/organizations/{organizationId}/members/{memberId}/barcode',
    icon: Icons.qr_code_2_rounded,
    fields: [
      ('memberNumber', 'رقم العضوية'),
      ('credentialValue', 'رمز الدخول'),
      ('expiresAt', 'الانتهاء'),
      ('status', 'الحالة'),
    ],
  ),
];

class GoController extends ChangeNotifier {
  GoController(this.api);
  final ApiClient api;
  final mobileNotifications = MobileNotificationService();
  bool authenticated = false;
  bool bootstrapping = true;
  bool loading = false;
  bool refreshing = false;
  bool darkMode = false;
  bool staffMode = true;
  int tab = 0;
  String? error;
  String? dashboardError;
  String? analyticsError;
  String? membersError;
  String? notificationsError;
  Map<String, dynamic> summary = {};
  List<Map<String, dynamic>> revenue = [];
  List<Map<String, dynamic>> notices = [];
  List<Map<String, dynamic>> members = [];
  List<Map<String, dynamic>> selfMembers = [];
  List<Map<String, dynamic>> grants = [];
  List<Map<String, dynamic>> branches = [];
  List<String> organizationIds = [];
  Map<String, dynamic> account = {};
  String currentUserAccountId = '';
  String organizationId = 'demo-organization';
  String branchId = 'main-branch';
  String branchName = 'فرع العليا';
  String get displayName =>
      account['displayName']?.toString().trim().isNotEmpty == true
      ? account['displayName'].toString()
      : staffMode
      ? 'موظف GO'
      : selectedSelfMember?['memberName']?.toString() ?? 'عضو GO';
  Map<String, dynamic>? get selectedSelfMember =>
      selfMembers.isEmpty ? null : selfMembers.first;
  String? get selectedMemberId => selectedSelfMember?['memberId']?.toString();
  final demoMembers = const <Map<String, Object>>[
    {
      'name': 'أحمد محمد',
      'number': 'GO-10482',
      'plan': 'باقة البلاتينيوم',
      'status': 'نشط',
      'color': 0xFF2F80ED,
    },
    {
      'name': 'سارة علي',
      'number': 'GO-10471',
      'plan': 'باقة العافية',
      'status': 'نشط',
      'color': 0xFF9B51E0,
    },
    {
      'name': 'خالد عبدالله',
      'number': 'GO-10460',
      'plan': 'باقة القوة',
      'status': 'ينتهي قريباً',
      'color': 0xFFE59C16,
    },
    {
      'name': 'نورة صالح',
      'number': 'GO-10428',
      'plan': 'باقة البلاتينيوم',
      'status': 'مجمّد',
      'color': 0xFF8C8C86,
    },
  ];

  Timer? _notificationTimer;
  static const _themePreferenceKey = 'go_theme_mode';

  Future<void> initialize() async {
    await _loadThemePreference();
    if (!api.configured) {
      bootstrapping = false;
      notifyListeners();
      return;
    }
    try {
      if (await api.hasSession()) {
        staffMode = await api.isStaffSession();
        await _loadAccountContext();
        authenticated = true;
        await refresh();
        _startNotificationPolling();
      }
    } catch (_) {
      await api.clearTokens();
      authenticated = false;
    } finally {
      bootstrapping = false;
      notifyListeners();
    }
  }

  Future<void> _loadAccountContext() async {
    try {
      final profile = await api.request('/self/account');
      account = profile is Map
          ? Map<String, dynamic>.from(profile)
          : <String, dynamic>{};
    } catch (_) {}
    if (!staffMode) {
      final self = await api.selfContext();
      selfMembers =
          (self['members'] as List?)
              ?.whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList() ??
          [];
      final employees =
          (self['employees'] as List?)?.whereType<Map>().toList() ?? [];
      final link = selfMembers.firstOrNull ?? employees.firstOrNull;
      if (link == null) {
        throw Exception('لا توجد عضوية مرتبطة بهذا الحساب. راجع إدارة النادي.');
      }
      organizationId = link['organizationId']?.toString() ?? organizationId;
      branchId = link['registrationBranchId']?.toString() ?? branchId;
      branches = await api.selfBranches(organizationId);
      organizationIds = selfMembers
          .map((member) => member['organizationId']?.toString())
          .whereType<String>()
          .toSet()
          .toList();
      final selected = branches
          .where((branch) => branch['id']?.toString() == branchId)
          .firstOrNull;
      final branch = selected ?? branches.firstOrNull;
      if (branch != null) {
        branchId = branch['id']?.toString() ?? branchId;
        branchName =
            branch['nameAr']?.toString() ??
            branch['name']?.toString() ??
            branchName;
      }
      return;
    }
    final me = await api.currentUser();
    currentUserAccountId = me['userAccountId']?.toString() ?? '';
    grants =
        (me['grants'] as List?)
            ?.whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList() ??
        [];
    organizationIds = grants
        .map((grant) => grant['organizationId']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (organizationIds.isEmpty) return;
    final savedOrganization = await api.secure.read(key: 'go_organization');
    organizationId = organizationIds.contains(savedOrganization)
        ? savedOrganization!
        : organizationIds.first;
    branches = await api.availableBranches(organizationId);
    if (branches.isNotEmpty) {
      final savedBranch = await api.secure.read(key: 'go_branch');
      final selected = branches
          .where((branch) => branch['id']?.toString() == savedBranch)
          .firstOrNull;
      final branch = selected ?? branches.first;
      branchId = branch['id']?.toString() ?? branchId;
      branchName =
          branch['nameAr']?.toString() ??
          branch['name']?.toString() ??
          branchName;
    }
  }

  Future<void> selectOrganization(String id) async {
    if (id == organizationId || !organizationIds.contains(id)) return;
    organizationId = id;
    branches = staffMode
        ? await api.availableBranches(id)
        : await api.selfBranches(id);
    if (branches.isNotEmpty) {
      await selectBranch(branches.first['id'].toString(), refreshData: false);
    }
    await api.secure.write(key: 'go_organization', value: id);
    await refresh();
  }

  Future<void> selectBranch(String id, {bool refreshData = true}) async {
    final branch = branches
        .where((item) => item['id']?.toString() == id)
        .firstOrNull;
    if (branch == null) return;
    branchId = id;
    branchName =
        branch['nameAr']?.toString() ??
        branch['name']?.toString() ??
        branchName;
    await api.secure.write(key: 'go_branch', value: id);
    notifyListeners();
    if (refreshData) await refresh();
  }

  bool can(String permission) {
    if (!api.configured || !staffMode) return true;
    bool satisfies(String granted, String requested, [Set<String>? seen]) {
      if (granted == requested) return true;
      final visited = seen ?? <String>{};
      if (!visited.add(granted)) return false;
      return (_permissionImplications[granted] ?? const []).any(
        (implied) => satisfies(implied, requested, visited),
      );
    }

    bool applies(Map<String, dynamic> grant, String requested) {
      if (grant['organizationId']?.toString() != organizationId) return false;
      final scope = grant['scopeType']?.toString();
      final ids =
          (grant['branchIds'] as List?)?.map((id) => '$id').toList() ?? [];
      if (scope != 'ORGANIZATION' && !ids.contains(branchId)) return false;
      final granted = grant['permission']?.toString() ?? '';
      return satisfies(granted, requested);
    }

    return grants.any((grant) => applies(grant, permission));
  }

  void applyAccount(Map<String, dynamic> value) {
    account = value;
    notifyListeners();
  }

  void _startNotificationPolling() {
    _notificationTimer?.cancel();
    _notificationTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(refresh(announce: true)),
    );
  }

  Future<void> login(bool staff, String identifier, String password) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      await api.login(staff: staff, identifier: identifier, password: password);
      staffMode = staff;
      if (api.configured) {
        await _loadAccountContext();
      }
      authenticated = true;
      await refresh();
      _startNotificationPolling();
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    loading = false;
    notifyListeners();
  }

  Future<void> refresh({bool announce = false}) async {
    final previous = notices
        .map((n) => n['id']?.toString() ?? n['title']?.toString())
        .toSet();
    if (api.configured) {
      refreshing = true;
      notifyListeners();
      await Future.wait<void>([
        () async {
          try {
            notices = await api.notifications();
            notificationsError = null;
          } catch (exception) {
            notificationsError = _errorMessage(exception);
          }
        }(),
        if (staffMode && can('reporting.read'))
          () async {
            try {
              summary = await api.dashboard(organizationId, branchId) ?? {};
              dashboardError = null;
            } catch (exception) {
              dashboardError = _errorMessage(exception);
            }
          }(),
        if (staffMode && can('reporting.read'))
          () async {
            try {
              revenue = await api.revenueTrend(organizationId, branchId);
              analyticsError = null;
            } catch (exception) {
              analyticsError = _errorMessage(exception);
            }
          }(),
        if (staffMode && can('members.read'))
          () async {
            try {
              members = await api.members(organizationId, branchId);
              membersError = null;
            } catch (exception) {
              membersError = _errorMessage(exception);
            }
          }(),
      ]);
      refreshing = false;
    }
    if (!api.configured && summary.isEmpty) {
      summary = {
        'activeMembers': 1284,
        'activeSubscriptions': 946,
        'acceptedAttendance': 312,
        'invoicedGrossMinor': 186400,
        'pendingOnlineRequests': 7,
        'openFeedbackCases': 3,
      };
    }
    if (!api.configured && notices.isEmpty) {
      notices = [
        {
          'title': 'اشتراك جديد بانتظار التفعيل',
          'body': 'تم تسجيل طلب اشتراك أحمد محمد في فرع العليا.',
          'createdAt': 'منذ 12 دقيقة',
          'unread': true,
          'type': 'success',
        },
        {
          'title': 'تنبيه بوابة الدخول',
          'body': 'محاولة دخول مرفوضة للعضو GO-10388.',
          'createdAt': 'منذ 38 دقيقة',
          'unread': true,
          'type': 'warning',
        },
        {
          'title': 'تحديث وردية الصندوق',
          'body': 'تم إغلاق وردية الصندوق المسائية بنجاح.',
          'createdAt': 'أمس',
          'unread': false,
          'type': 'info',
        },
      ];
    }
    if (announce) {
      for (final notice in notices) {
        final key = notice['id']?.toString() ?? notice['title']?.toString();
        if (key != null && !previous.contains(key)) {
          unawaited(
            mobileNotifications.show(
              notice['title'].toString(),
              notice['body'].toString(),
            ),
          );
        }
      }
    }
    notifyListeners();
  }

  void logout() {
    _notificationTimer?.cancel();
    authenticated = false;
    tab = 0;
    unawaited(api.clearTokens());
    notifyListeners();
  }

  Future<void> markAllRead() async {
    for (final notice in notices) {
      notice['unread'] = false;
    }
    notifyListeners();
    if (!api.configured) return;
    try {
      await api.markAllNotificationsRead();
      notificationsError = null;
    } catch (exception) {
      notificationsError = _errorMessage(exception);
    }
    notifyListeners();
  }

  Future<void> openNotification(Map<String, dynamic> notice) async {
    if (notice['unread'] != true) return;
    notice['unread'] = false;
    notifyListeners();
    final id = notice['id']?.toString();
    if (api.configured && id != null) {
      try {
        await api.markNotificationRead(id);
        notificationsError = null;
      } catch (exception) {
        notificationsError = _errorMessage(exception);
        notifyListeners();
      }
    }
  }

  void setTab(int value) {
    tab = value;
    notifyListeners();
  }

  void toggleTheme() {
    setDarkMode(!darkMode);
  }

  void setDarkMode(bool value) {
    if (darkMode == value) return;
    darkMode = value;
    notifyListeners();
    unawaited(_saveThemePreference());
  }

  Future<void> _loadThemePreference() async {
    try {
      darkMode = await api.secure.read(key: _themePreferenceKey) == 'dark';
    } catch (_) {}
  }

  Future<void> _saveThemePreference() async {
    try {
      await api.secure.write(
        key: _themePreferenceKey,
        value: darkMode ? 'dark' : 'light',
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _notificationTimer?.cancel();
    super.dispose();
  }
}

class GoMobileApp extends StatefulWidget {
  const GoMobileApp({super.key, this.apiClient});
  final ApiClient? apiClient;
  @override
  State<GoMobileApp> createState() => _GoMobileAppState();
}

ThemeData _goTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark
      ? FlexThemeData.dark(
          colorScheme: ColorScheme.fromSeed(
            seedColor: goYellow,
            brightness: Brightness.dark,
            primary: goYellow,
            onPrimary: goInk,
            surface: goInk,
          ),
          surfaceMode: FlexSurfaceMode.level,
          blendLevel: 8,
          fontFamily: GoogleFonts.cairo().fontFamily,
          useMaterial3: true,
        )
      : FlexThemeData.light(
          colorScheme: ColorScheme.fromSeed(
            seedColor: goYellow,
            primary: goYellow,
            onPrimary: goInk,
            surface: goCanvas,
          ),
          surfaceMode: FlexSurfaceMode.level,
          blendLevel: 4,
          fontFamily: GoogleFonts.cairo().fontFamily,
          scaffoldBackground: goCanvas,
          useMaterial3: true,
        );
  final colors = base.colorScheme;
  return base.copyWith(
    visualDensity: VisualDensity.standard,
    appBarTheme: base.appBarTheme.copyWith(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
      backgroundColor: dark ? goInk : goCanvas,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .65)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: goYellow, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      elevation: 3,
      backgroundColor: colors.surfaceContainerLowest,
      indicatorColor: goYellow.withValues(alpha: .22),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w800
              : FontWeight.w600,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant.withValues(alpha: .7),
      thickness: 1,
    ),
  );
}

class _GoMobileAppState extends State<GoMobileApp> with WidgetsBindingObserver {
  late final GoController controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller = GoController(widget.apiClient ?? ApiClient());
    unawaited(controller.mobileNotifications.initialize());
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && controller.authenticated) {
      unawaited(controller.refresh(announce: true));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (_, child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GO Fitness',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child ?? const SizedBox.shrink(),
      ),
      themeMode: controller.darkMode ? ThemeMode.dark : ThemeMode.light,
      theme: _goTheme(Brightness.light),
      darkTheme: _goTheme(Brightness.dark),
      home: controller.bootstrapping
          ? const _BootstrapScreen()
          : controller.authenticated
          ? controller.staffMode
                ? GoShell(controller: controller)
                : MemberShell(controller: controller)
          : LoginScreen(controller: controller),
    ),
  );
}

class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GoLogo(),
          SizedBox(height: 24),
          CircularProgressIndicator(),
          SizedBox(height: 14),
          Text('جارٍ استعادة جلسة العمل…'),
        ],
      ),
    ),
  );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});
  final GoController controller;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool staff = true, obscure = true;
  final identifier = TextEditingController();
  final password = TextEditingController();
  @override
  void dispose() {
    identifier.dispose();
    password.dispose();
    super.dispose();
  }

  void submit() {
    if (identifier.text.trim().isEmpty || password.text.isEmpty) {
      setState(() {});
      return;
    }
    unawaited(
      widget.controller.login(staff, identifier.text.trim(), password.text),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, c) => Row(
          children: [
            if (c.maxWidth > 900)
              Expanded(
                child: Container(
                  color: goInk,
                  padding: const EdgeInsets.all(56),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const GoLogo(light: true),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: goYellow.withValues(alpha: .12),
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: const Text(
                              'إدارة أذكى. أداء أقوى.',
                              style: TextStyle(
                                color: goYellow,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'كل ما يحتاجه ناديك\nفي مكان واحد.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 42,
                              height: 1.25,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            'من العضوية إلى الحضور والمالية والتواصل، صمّم تجربة أفضل لفريقك وأعضائك.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 16,
                              height: 1.8,
                            ),
                          ),
                        ],
                      ),
                      const Text(
                        'GO FITNESS  •  ZULFI',
                        style: TextStyle(
                          color: Colors.white38,
                          letterSpacing: 1.5,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (c.maxWidth <= 900)
                          const Center(child: GoLogo(prominent: true)),
                        const SizedBox(height: 26),
                        const Icon(
                          Icons.lock_outline_rounded,
                          size: 30,
                          color: goYellow,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'تسجيل الدخول',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'أهلاً بك مجدداً، سجّل الدخول لإدارة مساحة عملك.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 30),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                              value: true,
                              label: Text('موظف'),
                              icon: Icon(Icons.badge_outlined),
                            ),
                            ButtonSegment(
                              value: false,
                              label: Text('عضو / ولي أمر'),
                              icon: Icon(Icons.person_outline),
                            ),
                          ],
                          selected: {staff},
                          onSelectionChanged: (v) =>
                              setState(() => staff = v.first),
                        ),
                        const SizedBox(height: 22),
                        TextField(
                          controller: identifier,
                          textDirection: TextDirection.ltr,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: staff
                              ? const [AutofillHints.username]
                              : const [
                                  AutofillHints.telephoneNumber,
                                  AutofillHints.email,
                                ],
                          decoration: InputDecoration(
                            labelText: staff
                                ? 'الرقم الوظيفي أو البريد الإلكتروني'
                                : 'رقم الجوال أو البريد الإلكتروني',
                            helperText: staff ? null : 'أدخل وسيلة الدخول المرتبطة بحساب العضو أو ولي الأمر',
                            prefixIcon: Icon(
                              staff
                                  ? Icons.badge_outlined
                                  : Icons.alternate_email_rounded,
                            ),
                          ),
                        ),
                        const SizedBox(height: 15),
                        TextField(
                          controller: password,
                          obscureText: obscure,
                          textDirection: TextDirection.ltr,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            labelText: 'كلمة المرور',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(
                                obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => obscure = !obscure),
                            ),
                          ),
                        ),
                        if (widget.controller.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: Text(
                              widget.controller.error!,
                              style: const TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        const SizedBox(height: 22),
                        FilledButton.icon(
                          onPressed: widget.controller.loading ? null : submit,
                          icon: widget.controller.loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.arrow_back_rounded),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              'تسجيل الدخول',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            final phone = await Navigator.of(context)
                                .push<String>(
                                  MaterialPageRoute<String>(
                                    builder: (_) => MemberActivationPage(
                                      api: widget.controller.api,
                                    ),
                                  ),
                                );
                            if (phone != null && mounted) {
                              setState(() {
                                staff = false;
                                identifier.text = phone;
                              });
                            }
                          },
                          icon: const Icon(Icons.key_outlined),
                          label: const Text('تفعيل حساب عضو لأول مرة'),
                        ),
                        if (!widget.controller.api.configured)
                          TextButton(
                            onPressed: () => unawaited(
                              widget.controller.login(
                                staff,
                                'demo',
                                'demo-password',
                              ),
                            ),
                            child: const Text('الدخول إلى النسخة الاستعراضية'),
                          ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.shield_outlined,
                              size: 15,
                              color: Colors.green,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'اتصال آمن وجلسة محمية',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class MemberActivationPage extends StatefulWidget {
  const MemberActivationPage({super.key, required this.api});
  final ApiClient api;

  @override
  State<MemberActivationPage> createState() => _MemberActivationPageState();
}

class _MemberActivationPageState extends State<MemberActivationPage> {
  final organizationId = TextEditingController();
  final memberNumber = TextEditingController();
  final phone = TextEditingController();
  final code = TextEditingController();
  final password = TextEditingController();
  final confirmPassword = TextEditingController();
  bool loading = false;
  String? error;

  @override
  void dispose() {
    organizationId.dispose();
    memberNumber.dispose();
    phone.dispose();
    code.dispose();
    password.dispose();
    confirmPassword.dispose();
    super.dispose();
  }

  Future<void> activateAccount() async {
    final normalizedPhone = phone.text.replaceAll(RegExp(r'[\s()-]'), '');
    if (organizationId.text.trim().isEmpty ||
        memberNumber.text.trim().length < 3 ||
        normalizedPhone.length < 8) {
      setState(() => error = 'أكمل بيانات المؤسسة والعضوية والجوال.');
      return;
    }
    if (!RegExp(r'^\d{8}$').hasMatch(code.text)) {
      setState(() => error = 'رمز التفعيل يجب أن يتكون من 8 أرقام.');
      return;
    }
    if (password.text.length < 7) {
      setState(() => error = 'كلمة المرور يجب ألا تقل عن 7 محارف.');
      return;
    }
    if (password.text != confirmPassword.text) {
      setState(() => error = 'تأكيد كلمة المرور غير مطابق.');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.api.request(
        '/auth/member/account-activations',
        method: 'POST',
        body: {
          'organizationId': organizationId.text.trim(),
          'memberNumber': memberNumber.text.trim(),
          'phone': normalizedPhone,
          'activationCode': code.text,
          'password': password.text,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تفعيل الحساب. يمكنك تسجيل الدخول الآن.'),
          ),
        );
        Navigator.pop(context, normalizedPhone);
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const GoLogo()),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Icon(Icons.verified_user_outlined, size: 46, color: goYellow),
        const SizedBox(height: 14),
        const Text(
          'تفعيل حساب العضو',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'اطلب رمز التفعيل من الاستقبال، ثم أدخل بيانات العضوية وحدد كلمة المرور.',
          textAlign: TextAlign.center,
          style: TextStyle(height: 1.6),
        ),
        const SizedBox(height: 24),
        ...[
          (organizationId, 'معرّف المؤسسة', Icons.business_outlined),
          (memberNumber, 'رقم العضوية', Icons.badge_outlined),
          (phone, 'رقم الجوال المسجل', Icons.phone_outlined),
          (code, 'رمز التفعيل المكوّن من 8 أرقام', Icons.pin_outlined),
        ].map(
          (field) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: field.$1,
              textDirection: TextDirection.ltr,
              keyboardType: field.$1 == phone || field.$1 == code
                  ? TextInputType.phone
                  : TextInputType.text,
              maxLength: field.$1 == code ? 8 : null,
              decoration: InputDecoration(
                labelText: field.$2,
                prefixIcon: Icon(field.$3),
              ),
            ),
          ),
        ),
        TextField(
          controller: password,
          obscureText: true,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'كلمة المرور الجديدة',
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: confirmPassword,
          obscureText: true,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'تأكيد كلمة المرور',
            prefixIcon: Icon(Icons.lock_reset_outlined),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: loading ? null : activateAccount,
          icon: loading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.key_rounded),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('تفعيل الحساب وربطه بالعضوية'),
          ),
        ),
      ],
    ),
  );
}

class GoLogo extends StatelessWidget {
  const GoLogo({super.key, this.light = false, this.prominent = false});
  final bool light;
  final bool prominent;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'GO Fitness',
    image: true,
    child: SizedBox(
      width: prominent ? 148 : (light ? 132 : 72),
      height: prominent ? 68 : (light ? 60 : 34),
      child: ClipRect(
        child: Image.asset(
          'assets/go-fitness-emblem.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    ),
  );
}

class GoShell extends StatelessWidget {
  const GoShell({super.key, required this.controller});
  final GoController controller;
  static const destinations = [
    (0, 'الرئيسية', Icons.space_dashboard_rounded),
    (1, 'الأعضاء', Icons.people_alt_outlined),
    (2, 'التشغيل', Icons.calendar_month_outlined),
    (3, 'التنبيهات', Icons.notifications_none_rounded),
    (4, 'المزيد', Icons.grid_view_rounded),
  ];
  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final visibleDestinations = destinations.where((destination) {
      if (destination.$1 == 1) return controller.can('members.read');
      if (destination.$1 == 2) {
        return controller.can('attendance.read') ||
            controller.can('bookings.read') ||
            controller.can('workforce.shifts.read') ||
            controller.can('restaurant.orders.read') ||
            controller.can('finance.invoices.read');
      }
      return true;
    }).toList();
    final selectedDestination = max(
      0,
      visibleDestinations.indexWhere((item) => item.$1 == controller.tab),
    );
    final pages = [
      DashboardPage(controller: controller),
      MembersPage(controller: controller),
      OperationsPage(controller: controller),
      MessagesPage(controller: controller),
      MorePage(controller: controller),
    ];
    final content = IndexedStack(index: controller.tab, children: pages);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: compact ? 12 : 16,
        title: const GoLogo(),
        actions: [
          if (compact)
            IconButton(
              onPressed: () => _openContextSheet(context, controller),
              icon: const Icon(Icons.location_on_outlined),
              tooltip: 'الفرع: ${controller.branchName}',
            )
          else
            TextButton.icon(
              onPressed: () => _openContextSheet(context, controller),
              icon: const Icon(Icons.location_on_outlined, size: 18),
              label: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  controller.branchName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (!compact)
            IconButton(
              onPressed: controller.toggleTheme,
              icon: Icon(
                controller.darkMode
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
              ),
              tooltip: 'تغيير المظهر',
            ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => GlobalSearchPage(controller: controller),
              ),
            ),
            icon: const Icon(Icons.search_rounded),
            tooltip: 'بحث شامل',
          ),
          NotificationButton(controller: controller),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, size) {
          if (size.maxWidth >= 900) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: selectedDestination,
                  onDestinationSelected: (index) =>
                      controller.setTab(visibleDestinations[index].$1),
                  labelType: NavigationRailLabelType.all,
                  destinations: visibleDestinations
                      .map(
                        (d) => NavigationRailDestination(
                          icon: Icon(d.$3),
                          label: Text(d.$2),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            );
          }
          return content;
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 900
          ? NavigationBar(
              selectedIndex: selectedDestination,
              onDestinationSelected: (index) =>
                  controller.setTab(visibleDestinations[index].$1),
              destinations: visibleDestinations
                  .map(
                    (d) => NavigationDestination(
                      icon: Icon(d.$3),
                      selectedIcon: Icon(d.$3, fill: 1),
                      label: d.$2,
                    ),
                  )
                  .toList(),
            )
          : null,
    );
  }
}

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, required this.controller});
  final GoController controller;
  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  final query = TextEditingController();
  Timer? debounce;
  bool loading = false;
  String? error;
  List<({String kind, String title, String subtitle, String id})> results = [];

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void search(String value) {
    debounce?.cancel();
    final text = value.trim();
    if (text.length < 2) {
      setState(() {
        results = [];
        loading = false;
      });
      return;
    }
    debounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_run(text)),
    );
  }

  Future<void> _run(String text) async {
    setState(() {
      loading = true;
      error = null;
    });
    final c = widget.controller;
    final org = c.organizationId;
    final branch = c.branchId;
    try {
      final responses = await Future.wait<dynamic>([
        if (c.can('members.read'))
          c.api.request(
            '/organizations/$org/members',
            query: {'branchId': branch, 'search': text, 'limit': '8'},
          ),
        if (c.can('employees.read'))
          c.api.request(
            '/organizations/$org/employees',
            query: {'branchId': branch, 'search': text, 'limit': '8'},
          ),
        if (c.can('subscriptions.read'))
          c.api.request(
            '/organizations/$org/subscriptions',
            query: {'branchId': branch, 'search': text, 'limit': '8'},
          ),
        if (c.can('finance.invoices.read'))
          c.api.request(
            '/organizations/$org/invoices',
            query: {'branchId': branch, 'q': text, 'limit': '8'},
          ),
      ]);
      final next =
          <({String kind, String title, String subtitle, String id})>[];
      void add(dynamic data, String kind, String fallback) {
        final rows = data is List
            ? data
            : data is Map && data['items'] is List
            ? data['items']
            : data is Map
            ? [data]
            : const [];
        for (final item in rows.whereType<Map>()) {
          final row = Map<String, dynamic>.from(item);
          final id = row['id']?.toString() ?? row['memberId']?.toString() ?? '';
          if (id.isEmpty) continue;
          final title =
              (row['name'] ??
                      row['fullNameAr'] ??
                      row['memberName'] ??
                      row['buyerName'] ??
                      row['invoiceNumber'] ??
                      row['subscriptionNumber'] ??
                      fallback)
                  .toString();
          final subtitle = [
            row['memberNumber'],
            row['employeeNumber'],
            row['phoneE164'],
            row['invoiceNumber'],
            row['packageName'],
            row['status'],
          ].where((v) => v != null && v.toString().isNotEmpty).join(' • ');
          next.add((kind: kind, title: title, subtitle: subtitle, id: id));
        }
      }

      var index = 0;
      if (c.can('members.read')) add(responses[index++], 'member', 'عضو');
      if (c.can('employees.read')) add(responses[index++], 'employee', 'موظف');
      if (c.can('subscriptions.read')) {
        add(responses[index++], 'subscription', 'اشتراك');
      }
      if (c.can('finance.invoices.read')) {
        add(responses[index++], 'invoice', 'فاتورة');
      }
      if (mounted) {
        setState(() {
          results = next;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  void openResult(
    ({String kind, String title, String subtitle, String id}) result,
  ) {
    if (result.kind == 'member') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MemberDetailPage(
            controller: widget.controller,
            memberId: result.id,
            initial: const {},
          ),
        ),
      );
      return;
    }
    final feature = result.kind == 'employee'
        ? resourceFeatures.firstWhere((f) => f.path.endsWith('/employees'))
        : result.kind == 'subscription'
        ? resourceFeatures.firstWhere((f) => f.path.endsWith('/subscriptions'))
        : resourceFeatures.firstWhere((f) => f.path.endsWith('/invoices'));
    _openResource(context, widget.controller, feature);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'بحث شامل',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        TextField(
          controller: query,
          autofocus: true,
          onChanged: search,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search_rounded),
            hintText: 'اسم، رقم عضوية، فاتورة أو اشتراك…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        if (!loading &&
            error == null &&
            query.text.trim().length >= 2 &&
            results.isEmpty)
          const _ResourceMessage(
            icon: Icons.search_off_rounded,
            title: 'لا توجد نتائج',
            body: 'جرّب اسمًا أو رقمًا مختلفًا.',
          ),
        ...results.map(
          (result) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              onTap: () => openResult(result),
              leading: CircleAvatar(
                backgroundColor: goYellow.withValues(alpha: .18),
                child: Icon(
                  result.kind == 'member'
                      ? Icons.person_outline
                      : result.kind == 'employee'
                      ? Icons.badge_outlined
                      : result.kind == 'invoice'
                      ? Icons.receipt_long_outlined
                      : Icons.credit_card_outlined,
                  color: Colors.amber[800],
                ),
              ),
              title: Text(
                result.title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(result.subtitle),
              trailing: const Icon(Icons.chevron_left_rounded),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _openContextSheet(
  BuildContext context,
  GoController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'سياق العمل',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'كل البيانات والإجراءات التالية ستُنفذ داخل المؤسسة والفرع المحددين.',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              if (controller.organizationIds.length > 1) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: controller.organizationId,
                  decoration: const InputDecoration(
                    labelText: 'المؤسسة',
                    prefixIcon: Icon(Icons.business_outlined),
                  ),
                  items: controller.organizationIds
                      .map(
                        (id) => DropdownMenuItem(
                          value: id,
                          child: Text(
                            'المؤسسة …${id.substring(max(0, id.length - 8))}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (id) {
                    if (id != null) {
                      unawaited(controller.selectOrganization(id));
                    }
                  },
                ),
              ],
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue:
                    controller.branches.any(
                      (branch) =>
                          branch['id']?.toString() == controller.branchId,
                    )
                    ? controller.branchId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'الفرع',
                  prefixIcon: Icon(Icons.location_on_outlined),
                ),
                items: controller.branches
                    .map(
                      (branch) => DropdownMenuItem(
                        value: branch['id']?.toString(),
                        child: Text(
                          branch['nameAr']?.toString() ??
                              branch['name']?.toString() ??
                              'فرع',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (id) {
                  if (id != null) unawaited(controller.selectBranch(id));
                },
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('متابعة في هذا السياق'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class MemberShell extends StatelessWidget {
  const MemberShell({super.key, required this.controller});
  final GoController controller;
  static const destinations = [
    ('الرئيسية', Icons.home_rounded),
    ('اكتشف', Icons.explore_outlined),
    ('عضويتي', Icons.credit_card_outlined),
    ('نشاطي', Icons.directions_run_outlined),
    ('حسابي', Icons.person_outline_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      MemberHomePage(controller: controller),
      MemberMarketplacePage(controller: controller),
      MemberHubPage(
        controller: controller,
        title: 'عضويتي',
        subtitle: 'اشتراكاتك وملفاتك وقياساتك في مكان واحد.',
        features: [
          memberResourceFeatures[0],
          memberResourceFeatures[6],
          memberResourceFeatures[8],
        ],
      ),
      MemberHubPage(
        controller: controller,
        title: 'نشاطي',
        subtitle: 'الحضور والحجوزات والخطط التدريبية.',
        features: [
          memberResourceFeatures[3],
          memberResourceFeatures[4],
          memberResourceFeatures[7],
        ],
      ),
      MemberMorePage(controller: controller),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const GoLogo(),
        actions: [
          if (controller.branches.length > 1)
            IconButton(
              onPressed: () => _openContextSheet(context, controller),
              icon: const Icon(Icons.location_on_outlined),
              tooltip: controller.branchName,
            ),
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AccountPage(controller: controller),
              ),
            ),
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'إعدادات الحساب',
          ),
          IconButton(
            onPressed: controller.toggleTheme,
            icon: Icon(
              controller.darkMode
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
            tooltip: 'تغيير المظهر',
          ),
          _MemberNotificationButton(controller: controller),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, size) {
          final page = pages[controller.tab];
          if (size.maxWidth >= 900) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: controller.tab,
                  onDestinationSelected: controller.setTab,
                  labelType: NavigationRailLabelType.all,
                  destinations: destinations
                      .map(
                        (item) => NavigationRailDestination(
                          icon: Icon(item.$2),
                          label: Text(item.$1),
                        ),
                      )
                      .toList(),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: page),
              ],
            );
          }
          return page;
        },
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 900
          ? NavigationBar(
              selectedIndex: controller.tab,
              onDestinationSelected: controller.setTab,
              destinations: destinations
                  .map(
                    (item) => NavigationDestination(
                      icon: Icon(item.$2),
                      label: item.$1,
                    ),
                  )
                  .toList(),
            )
          : null,
    );
  }
}

class _MemberNotificationButton extends StatelessWidget {
  const _MemberNotificationButton({required this.controller});
  final GoController controller;

  @override
  Widget build(BuildContext context) {
    final count = controller.notices
        .where((row) => row['unread'] == true)
        .length;
    return Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: IconButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _MemberMessagesPage(controller: controller),
          ),
        ),
        icon: const Icon(Icons.notifications_none_rounded),
        tooltip: 'الإشعارات',
      ),
    );
  }
}

class _MemberMessagesPage extends StatelessWidget {
  const _MemberMessagesPage({required this.controller});
  final GoController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'الرسائل والإشعارات',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
      actions: [
        IconButton(
          onPressed: controller.refreshing
              ? null
              : () => unawaited(controller.refresh(announce: true)),
          icon: const Icon(Icons.refresh_rounded),
          tooltip: 'تحديث الإشعارات',
        ),
        const SizedBox(width: 6),
      ],
    ),
    body: SafeArea(
      top: false,
      child: MessagesPage(controller: controller, showHeading: false),
    ),
  );
}

class MemberHomePage extends StatelessWidget {
  const MemberHomePage({super.key, required this.controller});
  final GoController controller;

  @override
  Widget build(BuildContext context) {
    final member = controller.selectedSelfMember ?? const <String, dynamic>{};
    final name = member['memberName']?.toString() ?? 'عضو GO';
    final number = member['memberNumber']?.toString() ?? 'GO-MEMBER';
    return PageFrame(
      onRefresh: () => controller.refresh(announce: true),
      title: 'أهلًا بك، $name',
      subtitle: 'أدر عضويتك وحجوزاتك وطلباتك من تطبيق GO.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [goInk, Color(0xFF33332E)],
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              children: [
                const CircleAvatar(
                  radius: 30,
                  backgroundColor: goYellow,
                  child: Icon(Icons.person_rounded, color: goInk, size: 34),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$number  •  ${controller.branchName}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: controller.logout,
                  color: Colors.white,
                  tooltip: 'تسجيل الخروج',
                  icon: const Icon(Icons.logout_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const SectionHeader(title: 'وصول سريع'),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.15,
            children:
                [
                      memberResourceFeatures[12],
                      memberResourceFeatures[4],
                      memberResourceFeatures[14],
                      memberResourceFeatures[8],
                      memberResourceFeatures[9],
                      memberResourceFeatures[15],
                    ]
                    .map(
                      (feature) => _MemberServiceCard(
                        feature: feature,
                        onTap: () =>
                            _openResource(context, controller, feature),
                      ),
                    )
                    .toList(),
          ),
        ],
      ),
    );
  }
}

class MemberMarketplacePage extends StatefulWidget {
  const MemberMarketplacePage({
    super.key,
    required this.controller,
    this.standalone = false,
    this.initialTab,
  });
  final GoController controller;
  final bool standalone;
  final String? initialTab;

  @override
  State<MemberMarketplacePage> createState() => _MemberMarketplacePageState();
}

class _MemberMarketplacePageState extends State<MemberMarketplacePage> {
  List<Map<String, dynamic>> items = [];
  late String tab;
  bool loading = true;
  String? error;
  int generation = 0;
  String loadedContext = '';

  String get contextKey =>
      '${widget.controller.organizationId}:${widget.controller.branchId}:${widget.controller.selectedMemberId}';

  @override
  void didUpdateWidget(covariant MemberMarketplacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (loadedContext != contextKey) {
      if (!tabs.contains(tab)) tab = tabs.firstOrNull ?? 'booking';
      unawaited(load());
    }
  }

  List<String> get tabs => [
    if (widget.controller.selectedSelfMember?['canManageMembership'] ==
        true) ...[
      'packages',
      'services',
    ],
    if (widget.controller.selectedSelfMember?['canBook'] == true) 'booking',
  ];

  String label(String value) => switch (value) {
    'packages' => 'الباقات',
    'services' => 'الخدمات',
    _ => 'حجز موعد',
  };

  @override
  void initState() {
    super.initState();
    tab = tabs.contains(widget.initialTab)
        ? widget.initialTab!
        : tabs.firstOrNull ?? 'booking';
    unawaited(load());
  }

  Future<void> load() async {
    final current = ++generation;
    loadedContext = contextKey;
    setState(() {
      loading = true;
      error = null;
      items = [];
    });
    if (!tabs.contains(tab)) {
      setState(() => loading = false);
      return;
    }
    try {
      final suffix = tab == 'booking' ? 'bookable-resources' : tab;
      final data = await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/$suffix',
        query: {'branchId': widget.controller.branchId},
      );
      final raw = data is List
          ? data
          : data is Map
          ? data['items']
          : null;
      if (!mounted || current != generation) return;
      setState(() {
        items = raw is List
            ? raw.whereType<Map>().map(Map<String, dynamic>.from).toList()
            : [];
        loading = false;
      });
    } catch (exception) {
      if (!mounted || current != generation) return;
      setState(() {
        error = _errorMessage(exception);
        loading = false;
      });
    }
  }

  Future<void> choose(Map<String, dynamic> item) async {
    final controller = widget.controller;
    final operation = switch (tab) {
      'packages' => 'checkoutSelfMemberPackage',
      'services' => 'checkoutSelfService',
      _ => 'checkoutSelfBooking',
    };
    final base = _workflowById(operation);
    if (!_canRunWorkflow(controller, base)) return;
    final id = item['id']?.toString() ?? '';
    final type =
        item['resourceType']?.toString() ?? item['type']?.toString() ?? '';
    final serviceId = item['serviceId']?.toString() ?? '';
    if (id.isEmpty ||
        (tab == 'booking' &&
            (serviceId.isEmpty ||
                !const [
                  'COURT',
                  'CLASS',
                  'PERSONAL_TRAINING',
                  'APPOINTMENT',
                ].contains(type)))) {
      setState(
        () => error =
            'هذا الخيار غير مرتبط ببيانات صالحة للحجز. راجع استقبال النادي.',
      );
      return;
    }
    final selectedTab = tab;
    final primaryField = selectedTab == 'packages'
        ? 'packageId'
        : selectedTab == 'services'
        ? 'serviceId'
        : 'resourceId';
    final selectedMember = controller.selectedMemberId ?? '';
    final organization = controller.organizationId;
    final branch = controller.branchId;
    final workflow = MobileWorkflow(
      operationId: base.operationId,
      title: base.title,
      description: selectedTab == 'booking'
          ? type == 'COURT'
                ? 'احجز الملعب كوحدة واحدة داخل ساعات إتاحته. عدد المشاركين للتشغيل والتقارير فقط.'
                : 'اختر موعدًا شاغرًا خلال الثلاثين يومًا القادمة. الحجز لمقعد واحد ويُؤكد بعد السداد في الاستقبال.'
          : selectedTab == 'services'
          ? 'شراء خدمة فقط وليس حجز موعد. راجع السعر النهائي قبل إصدار الفاتورة، ثم اسدد في الاستقبال.'
          : base.description,
      submitLabel: selectedTab == 'booking'
          ? 'تأكيد الحجز'
          : 'عرض السعر النهائي',
      successMessage: selectedTab == 'booking'
          ? 'تم تسجيل الحجز والفاتورة. يرجى السداد في استقبال النادي لتأكيد الموعد.'
          : 'تم تسجيل الطلب والفاتورة. يرجى السداد في استقبال النادي لإتمام الاشتراك أو الخدمة.',
      method: base.method,
      path: base.path
          .replaceAll('{organizationId}', organization)
          .replaceAll('{memberId}', selectedMember),
      icon: base.icon,
      fields: base.fields,
      body: (values, currentController) {
        final body = base.body(values, currentController);
        body['sellingBranchId'] = branch;
        if (selectedTab == 'packages') {
          for (final line in body['lines'] as List) {
            line['accessBranchId'] = branch;
          }
        }
        return body;
      },
    );
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WorkflowPage(
          controller: controller,
          workflow: workflow,
          selectionLabel:
              '${item['name'] ?? item['code'] ?? label(selectedTab)} • ${controller.branchName}',
          initialValues: {
            primaryField: id,
            if (selectedTab == 'booking') ...{
              'serviceId': serviceId,
              'resourceType': type,
            },
          },
          lockedFields: {primaryField},
        ),
      ),
    );
    if (saved != true || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(workflow.successMessage)));
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final body = PageFrame(
      title: 'اكتشف واحجز',
      subtitle:
          'الخيارات المنشورة في ${widget.controller.branchName}. شراء خدمة لا يحجز موعدًا؛ استخدم تبويب حجز موعد للحصص والملاعب.',
      onRefresh: load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tabs.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: tabs
                    .map(
                      (value) => Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: ChoiceChip(
                          label: Text(label(value)),
                          selected: tab == value,
                          onSelected: (_) {
                            if (tab != value) {
                              tab = value;
                              unawaited(load());
                            }
                          },
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          const SizedBox(height: 18),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (error != null)
            _ResourceMessage(
              icon: Icons.cloud_off_outlined,
              title: 'تعذر تحميل الخيارات',
              body: error!,
              action: load,
            )
          else if (tabs.isEmpty)
            const _ResourceMessage(
              icon: Icons.lock_outline,
              title: 'لا توجد صلاحية لإنشاء طلب أو حجز',
              body: 'يمكنك متابعة بيانات العضوية. راجع النادي لمنح صلاحيات الحجز أو إدارة العضوية.',
            )
          else if (items.isEmpty)
            const _ResourceMessage(
              icon: Icons.event_busy_outlined,
              title: 'لا توجد خيارات منشورة في هذا الفرع',
              body: 'اختر فرعًا آخر أو راجع استقبال النادي.',
            )
          else
            ...items.map(
              (item) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${item['name'] ?? item['code'] ?? 'خيار متاح'}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${item['description'] ?? item['facilityName'] ?? item['categoryName'] ?? label(tab)}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (item['amountMinor'] != null)
                        Text(
                          _money(item['amountMinor']),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      if (tab == 'packages' && item['durationDays'] != null)
                        Text(
                          'المدة: ${item['durationDays']} يوم${item['visitAllowance'] != null ? ' • ${item['visitAllowance']} زيارة' : ''}',
                        ),
                      if (tab == 'packages' &&
                          item['contract'] is Map &&
                          (item['contract'] as Map)['content'] != null)
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            '${(item['contract'] as Map)['title'] ?? 'عقد الاشتراك'}',
                          ),
                          children: [
                            Text(
                              '${(item['contract'] as Map)['content']}',
                              style: const TextStyle(height: 1.7),
                            ),
                          ],
                        ),
                      const SizedBox(height: 14),
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(choose(item)),
                        icon: Icon(
                          tab == 'booking'
                              ? Icons.event_available_outlined
                              : Icons.shopping_bag_outlined,
                        ),
                        label: Text(
                          tab != 'booking'
                              ? 'عرض السعر النهائي'
                              : (item['resourceType'] ?? item['type']) ==
                                    'COURT'
                              ? 'اختيار وقت الحجز'
                              : 'عرض المواعيد المتاحة',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return widget.standalone
        ? Scaffold(
            appBar: AppBar(title: const Text('اكتشف واحجز')),
            body: body,
          )
        : body;
  }
}

class MemberHubPage extends StatelessWidget {
  const MemberHubPage({
    super.key,
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.features,
  });
  final GoController controller;
  final String title;
  final String subtitle;
  final List<ResourceFeature> features;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    subtitle: subtitle,
    child: GridView.count(
      crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.15,
      children: features
          .map(
            (feature) => _MemberServiceCard(
              feature: feature,
              onTap: () => _openResource(context, controller, feature),
            ),
          )
          .toList(),
    ),
  );
}

class MemberMorePage extends StatelessWidget {
  const MemberMorePage({super.key, required this.controller});
  final GoController controller;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'حسابي',
    subtitle: 'الطلبات والفواتير والتواصل وإعدادات الحساب.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.15,
          children:
              [
                    memberResourceFeatures[1],
                    memberResourceFeatures[2],
                    memberResourceFeatures[5],
                    memberResourceFeatures[9],
                    memberResourceFeatures[15],
                  ]
                  .map(
                    (feature) => _MemberServiceCard(
                      feature: feature,
                      onTap: () => _openResource(context, controller, feature),
                    ),
                  )
                  .toList(),
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              ListTile(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _MemberMessagesPage(controller: controller),
                  ),
                ),
                leading: const Icon(Icons.notifications_none_rounded),
                title: const Text('الإشعارات'),
                subtitle: const Text('تابع تنبيهات النادي والعمليات الجديدة'),
                trailing: const Icon(Icons.chevron_left_rounded),
              ),
              const Divider(height: 1),
              ListTile(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AccountPage(controller: controller),
                  ),
                ),
                leading: const Icon(Icons.manage_accounts_outlined),
                title: const Text('إعدادات الحساب'),
                subtitle: const Text('المظهر والإشعارات وأمان الجلسة'),
                trailing: const Icon(Icons.chevron_left_rounded),
              ),
              const Divider(height: 1),
              ListTile(
                onTap: controller.logout,
                leading: Icon(
                  Icons.logout_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'تسجيل الخروج',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _MemberServiceCard extends StatelessWidget {
  const _MemberServiceCard({required this.feature, required this.onTap});
  final ResourceFeature feature;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            CircleAvatar(
              backgroundColor: goYellow.withValues(alpha: .16),
              child: Icon(feature.icon, color: Colors.amber[800]),
            ),
            Text(
              feature.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

class FeedbackCasesPage extends StatefulWidget {
  const FeedbackCasesPage({
    super.key,
    required this.controller,
    required this.memberMode,
  });
  final GoController controller;
  final bool memberMode;
  @override
  State<FeedbackCasesPage> createState() => _FeedbackCasesPageState();
}

class _FeedbackCasesPageState extends State<FeedbackCasesPage> {
  List<Map<String, dynamic>> cases = [];
  Map<String, dynamic>? selected;
  List<Map<String, dynamic>> messages = [];
  final reply = TextEditingController();
  bool loading = true;
  bool busy = false;
  String? error;

  GoController get controller => widget.controller;
  String get org => controller.organizationId;
  String? get member => controller.selectedMemberId;
  String get base => widget.memberMode
      ? '/self/organizations/$org/members/$member/feedback-cases'
      : '/organizations/$org/feedback-cases';

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    reply.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> rows(dynamic data) {
    if (data is List) {
      return data
          .whereType<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }
    if (data is Map) return [Map<String, dynamic>.from(data)];
    return [];
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      cases = controller.api.configured
          ? rows(
              await controller.api.request(
                base,
                query: {'branchId': controller.branchId, 'limit': '100'},
              ),
            )
          : const [
              {
                'id': 'demo-ticket',
                'caseNumber': 'FB-1001',
                'subject': 'اقتراح تحسين الحصص',
                'caseType': 'SUGGESTION',
                'status': 'OPEN',
                'messageCount': 1,
              },
            ];
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> openCase(Map<String, dynamic> item) async {
    final id = item['id']?.toString();
    if (id == null) return;
    setState(() {
      selected = item;
      messages = [];
      busy = true;
    });
    try {
      final detailPath = '$base/$id';
      final data = await controller.api.request(detailPath);
      final detail = data is Map ? Map<String, dynamic>.from(data) : item;
      final raw = detail['messages'];
      if (raw is List) {
        messages = raw
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
      }
      selected = detail;
      if (controller.api.configured) {
        await controller.api.request(
          '$detailPath/read',
          method: 'POST',
          body: {},
        );
      }
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> sendReply() async {
    final item = selected;
    final text = reply.text.trim();
    if (item == null || text.isEmpty) return;
    setState(() => busy = true);
    try {
      await controller.api.request(
        '$base/${item['id']}/messages',
        method: 'POST',
        body: {'body': text},
      );
      reply.clear();
      await openCase(item);
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> transition(String status) async {
    final item = selected;
    if (item == null) return;
    setState(() => busy = true);
    try {
      await controller.api.request(
        '$base/${item['id']}/transitions',
        method: 'POST',
        body: {
          'status': status,
          'expectedVersion': int.tryParse('${item['version'] ?? 1}') ?? 1,
        },
      );
      await load();
      await openCase(item);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.memberMode ? 'الشكاوى والاقتراحات' : 'تذاكر التواصل',
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      actions: [
        IconButton(
          onPressed: loading ? null : () => unawaited(load()),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, size) {
        final list = ListView(
          padding: const EdgeInsets.all(14),
          children: [
            if (widget.memberMode)
              FilledButton.icon(
                onPressed: busy ? null : () => unawaited(_create()),
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('تذكرة جديدة'),
              ),
            const SizedBox(height: 8),
            if (loading)
              const LinearProgressIndicator()
            else if (cases.isEmpty)
              const _ResourceMessage(
                icon: Icons.forum_outlined,
                title: 'لا توجد تذاكر',
                body: 'ستظهر محادثاتك مع فريق النادي هنا.',
              )
            else
              ...cases.map(
                (item) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => unawaited(openCase(item)),
                    selected: selected?['id'] == item['id'],
                    leading: CircleAvatar(
                      backgroundColor: goYellow.withValues(alpha: .18),
                      child: const Icon(
                        Icons.forum_outlined,
                        color: Colors.amber,
                      ),
                    ),
                    title: Text(
                      item['subject']?.toString() ?? 'تذكرة',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${item['caseNumber'] ?? ''}  •  ${item['status'] ?? ''}  •  ${item['messageCount'] ?? 0} رسائل',
                    ),
                    trailing: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
              ),
          ],
        );
        final conversation = selected == null
            ? const _ResourceMessage(
                icon: Icons.forum_outlined,
                title: 'اختر تذكرة',
                body: 'ستظهر الرسائل والإجراءات هنا.',
              )
            : _feedbackConversation(context);
        if (size.maxWidth >= 800) {
          return Row(
            children: [
              SizedBox(width: 360, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: conversation),
            ],
          );
        }
        return selected == null ? list : conversation;
      },
    ),
  );

  Widget _feedbackConversation(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected?['subject']?.toString() ?? 'تذكرة',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            if (!widget.memberMode)
              IconButton(
                onPressed: busy
                    ? null
                    : () => unawaited(
                        transition(
                          selected?['status'] == 'CLOSED' ? 'OPEN' : 'CLOSED',
                        ),
                      ),
                icon: Icon(
                  selected?['status'] == 'CLOSED'
                      ? Icons.lock_open_outlined
                      : Icons.check_circle_outline,
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          children: messages.isEmpty
              ? [const Text('لا توجد رسائل بعد.', textAlign: TextAlign.center)]
              : messages
                    .map(
                      (message) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(13),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message['senderName']?.toString() ?? 'فريق GO',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                message['body']?.toString() ?? '',
                                style: const TextStyle(height: 1.6),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
        ),
      ),
      if (selected?['status'] != 'CLOSED')
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: reply,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(hintText: 'اكتب ردك…'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: busy ? null : () => unawaited(sendReply()),
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
    ],
  );

  Future<void> _create() async {
    final workflow = _workflowById('createSelfMemberFeedback');
    await _openWorkflow(context, controller, workflow);
    await load();
  }
}

/// Native file workspace for private member/employee documents. It mirrors
/// the web signed-upload flow: request a grant, PUT bytes directly to storage,
/// then complete the record so scanning can run before download.
class FilesPage extends StatefulWidget {
  const FilesPage({
    super.key,
    required this.controller,
    this.memberMode = false,
    this.initialOwnerId,
  });
  final GoController controller;
  final bool memberMode;
  final String? initialOwnerId;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<Map<String, dynamic>> files = [];
  List<Map<String, dynamic>> owners = [];
  String ownerType = 'MEMBER';
  String? ownerId;
  String purpose = 'IDENTITY_DOCUMENT';
  bool loading = true;
  bool uploading = false;
  String? error;
  double uploadProgress = 0;

  GoController get controller => widget.controller;
  String get organization => controller.organizationId;
  String? get selfMemberId => controller.selectedMemberId;

  @override
  void initState() {
    super.initState();
    ownerId = widget.initialOwnerId;
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (!controller.api.configured) {
        files = const [
          {
            'id': 'demo-file-1',
            'originalFilename': 'بطاقة-العضوية.pdf',
            'purpose': 'IDENTITY_DOCUMENT',
            'uploadStatus': 'UPLOADED',
            'scanStatus': 'CLEAN',
          },
        ];
      } else if (widget.memberMode) {
        final id = selfMemberId;
        final data = id == null
            ? null
            : await controller.api.request(
                '/self/organizations/$organization/members/$id/files',
                query: {'limit': '100'},
              );
        files = _fileRows(data);
      } else {
        final data = await controller.api.request(
          '/organizations/$organization/files',
          query: {'branchId': controller.branchId, 'limit': '100'},
        );
        files = _fileRows(data);
        await _loadOwners();
      }
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  List<Map<String, dynamic>> _fileRows(dynamic data) {
    if (data is List) {
      return data
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    if (data is Map && data['items'] is List) {
      return (data['items'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }
    if (data is Map) return [Map<String, dynamic>.from(data)];
    return [];
  }

  Future<void> _loadOwners() async {
    try {
      final data = await controller.api.request(
        '/organizations/$organization/${ownerType == 'MEMBER' ? 'members' : 'employees'}',
        query: {'branchId': controller.branchId, 'limit': '100'},
      );
      owners = _fileRows(data);
      if (ownerId != null &&
          !owners.any((row) => row['id']?.toString() == ownerId)) {
        ownerId = null;
      }
    } catch (_) {
      owners = [];
    }
  }

  Future<void> pickAndUpload() async {
    final owner = widget.memberMode ? selfMemberId : ownerId;
    if (owner == null) {
      _toast(
        widget.memberMode
            ? 'لا توجد عضوية مرتبطة بهذا الحساب.'
            : 'اختر صاحب المستند أولًا.',
      );
      return;
    }
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final picked = result?.files.single;
    final bytes = picked?.bytes;
    if (picked == null || bytes == null || bytes.isEmpty) return;
    if (bytes.length > 10 * 1024 * 1024) {
      _toast('الحد الأقصى لحجم الملف هو 10 ميجابايت.');
      return;
    }
    final contentType = _mimeFor(picked.name);
    if (contentType == null) {
      _toast('استخدم JPG أو PNG أو PDF فقط.');
      return;
    }
    setState(() {
      uploading = true;
      uploadProgress = .1;
      error = null;
    });
    try {
      final self = widget.memberMode;
      final digest = sha256.convert(bytes).toString();
      final requestPath = self
          ? '/self/organizations/$organization/members/$owner/files/upload-requests'
          : '/organizations/$organization/files/upload-requests';
      final body = self
          ? <String, dynamic>{
              'purpose': purpose,
              'originalFilename': picked.name,
              'mimeType': contentType,
              'size': bytes.length,
              'checksumSha256': digest,
            }
          : <String, dynamic>{
              'ownerModule': ownerType == 'MEMBER' ? 'members' : 'workforce',
              'ownerType': ownerType,
              'ownerId': owner,
              'purpose': purpose,
              'originalFilename': picked.name,
              'mimeType': contentType,
              'size': bytes.length,
              'checksumSha256': digest,
            };
      final grant = await controller.api.request(
        requestPath,
        method: 'POST',
        body: body,
      );
      if (grant is! Map ||
          grant['uploadUrl'] == null ||
          grant['fileId'] == null) {
        throw Exception('لم يُرجع الخادم تصريح رفع صالحًا.');
      }
      setState(() => uploadProgress = .35);
      await controller.api.uploadSignedBytes(
        uploadUrl: grant['uploadUrl'].toString(),
        bytes: bytes,
        contentType: contentType,
      );
      setState(() => uploadProgress = .8);
      final completionPath = self
          ? '/self/organizations/$organization/members/$owner/files/${grant['fileId']}/upload-completions'
          : '/organizations/$organization/files/${grant['fileId']}/upload-completions';
      await controller.api.request(
        completionPath,
        method: 'POST',
        body: {
          'expectedVersion': int.tryParse('${grant['expectedVersion']}') ?? 1,
        },
      );
      _toast('تم رفع المستند وسيخضع للفحص الأمني قبل إتاحته.');
      await load();
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          uploading = false;
          uploadProgress = 0;
        });
      }
    }
  }

  Future<void> download(Map<String, dynamic> file) async {
    final id = file['id']?.toString() ?? file['fileId']?.toString();
    if (id == null) return;
    final member = selfMemberId;
    final path = widget.memberMode
        ? '/self/organizations/$organization/members/$member/files/$id/download-url'
        : '/organizations/$organization/files/$id/download-url';
    try {
      final data = await controller.api.request(path);
      final url = data is Map ? data['downloadUrl']?.toString() : null;
      if (url == null ||
          !await launchUrl(
            Uri.parse(url),
            mode: LaunchMode.externalApplication,
          )) {
        _toast('تعذر فتح رابط التنزيل الآمن.');
      }
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUpload = widget.memberMode || controller.can('files.manage');
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.memberMode ? 'ملفاتي ومستنداتي' : 'الملفات والمرفقات',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : () => unawaited(load()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              widget.memberMode
                  ? 'احتفظ بمستنداتك الخاصة في مساحة آمنة. لا يصبح الملف قابلًا للتنزيل حتى ينجح الفحص الأمني.'
                  : 'مستندات الأعضاء والموظفين مع رفع مباشر إلى التخزين الخاص وفحص تلقائي.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            if (canUpload) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!widget.memberMode) ...[
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'MEMBER',
                              label: Text('عضو'),
                              icon: Icon(Icons.person_outline),
                            ),
                            ButtonSegment(
                              value: 'EMPLOYEE',
                              label: Text('موظف'),
                              icon: Icon(Icons.badge_outlined),
                            ),
                          ],
                          selected: {ownerType},
                          onSelectionChanged: (value) {
                            setState(() {
                              ownerType = value.first;
                              ownerId = null;
                            });
                            unawaited(_loadOwners());
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: ownerId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'صاحب المستند',
                            prefixIcon: Icon(Icons.person_search_outlined),
                          ),
                          items: owners.map((row) {
                            final id = row['id']?.toString() ?? '';
                            final name =
                                row['name'] ??
                                row['fullNameAr'] ??
                                row['displayName'] ??
                                row['memberName'] ??
                                row['employeeNumber'] ??
                                'سجل';
                            return DropdownMenuItem(
                              value: id,
                              child: Text('$name'),
                            );
                          }).toList(),
                          onChanged: (value) => setState(() => ownerId = value),
                        ),
                        const SizedBox(height: 12),
                      ],
                      DropdownButtonFormField<String>(
                        initialValue: purpose,
                        decoration: const InputDecoration(
                          labelText: 'نوع المستند',
                          prefixIcon: Icon(Icons.category_outlined),
                        ),
                        items:
                            (widget.memberMode
                                    ? const [
                                        ('PROFILE_PHOTO', 'صورة شخصية'),
                                        ('IDENTITY_DOCUMENT', 'هوية'),
                                        ('CONSENT', 'موافقة'),
                                      ]
                                    : const [
                                        ('PROFILE_PHOTO', 'صورة شخصية'),
                                        ('IDENTITY_DOCUMENT', 'هوية'),
                                        ('CONSENT', 'موافقة'),
                                        ('EMPLOYMENT_DOCUMENT', 'مستند وظيفي'),
                                      ])
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item.$1,
                                    child: Text(item.$2),
                                  ),
                                )
                                .toList(),
                        onChanged: (value) =>
                            setState(() => purpose = value ?? purpose),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: uploading
                            ? null
                            : () => unawaited(pickAndUpload()),
                        icon: uploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.file_upload_outlined),
                        label: Text(
                          uploading ? 'جارٍ الرفع…' : 'اختيار ورفع مستند',
                        ),
                      ),
                      if (uploading) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(value: uploadProgress),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (files.isEmpty)
              const _ResourceMessage(
                icon: Icons.folder_open_outlined,
                title: 'لا توجد مستندات',
                body: 'ستظهر الملفات هنا بعد رفعها واعتماد فحصها.',
              )
            else
              ...files.map(
                (file) => Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: goYellow.withValues(alpha: .18),
                      child: Icon(_fileIcon(file), color: Colors.amber[800]),
                    ),
                    title: Text(
                      file['originalFilename']?.toString() ??
                          file['filename']?.toString() ??
                          'مستند',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${_fileStatus(file)}  •  ${file['purpose'] ?? ''}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      onPressed: _fileDownloadable(file)
                          ? () => unawaited(download(file))
                          : null,
                      icon: const Icon(Icons.download_outlined),
                      tooltip: _fileDownloadable(file)
                          ? 'تنزيل آمن'
                          : 'بانتظار الفحص',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: canUpload
          ? FloatingActionButton.extended(
              onPressed: uploading ? null : () => unawaited(pickAndUpload()),
              icon: const Icon(Icons.attach_file_rounded),
              label: const Text('إضافة مرفق'),
            )
          : null,
    );
  }
}

String? _mimeFor(String filename) {
  final extension = filename.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'pdf' => 'application/pdf',
    _ => null,
  };
}

IconData _fileIcon(Map<String, dynamic> row) =>
    (row['expectedMimeType'] ?? row['mimeType']).toString() == 'application/pdf'
    ? Icons.picture_as_pdf_outlined
    : Icons.image_outlined;
String _fileStatus(Map<String, dynamic> row) {
  final scan = row['scanStatus']?.toString();
  if (scan == 'CLEAN') return 'آمن وجاهز للتنزيل';
  if (scan == 'PENDING') return 'قيد الفحص الأمني';
  if (row['uploadStatus'] == 'REJECTED') return 'مرفوض';
  return row['uploadStatus']?.toString() ?? 'قيد المعالجة';
}

bool _fileDownloadable(Map<String, dynamic> row) =>
    row['uploadStatus'] == 'UPLOADED' && row['scanStatus'] == 'CLEAN';

class NotificationButton extends StatelessWidget {
  const NotificationButton({super.key, required this.controller});
  final GoController controller;
  @override
  Widget build(BuildContext context) {
    final count = controller.notices.where((n) => n['unread'] == true).length;
    return Stack(
      children: [
        IconButton(
          onPressed: () => controller.setTab(3),
          icon: const Icon(Icons.notifications_none_rounded),
          tooltip: 'الإشعارات',
        ),
        if (count > 0)
          PositionedDirectional(
            top: 7,
            end: 7,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: goYellow,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.onRefresh,
  });
  final Widget child;
  final String? title, subtitle;
  final Future<void> Function()? onRefresh;
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh ?? () async {},
    child: ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 5, bottom: 18),
              child: Text(
                subtitle!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ),
        ],
        child,
      ],
    ),
  );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.controller});
  final GoController controller;
  @override
  Widget build(BuildContext context) {
    final s = controller.summary;
    final demo = !controller.api.configured;
    final canReport = controller.can('reporting.read');
    final today = MaterialLocalizations.of(context)
        .formatFullDate(DateTime.now());
    num metric(String camel, String snake, [num fallback = 0]) =>
        num.tryParse('${s[camel] ?? s[snake] ?? fallback}') ?? fallback;
    final cards = [
      (
        'الأعضاء النشطون',
        '${metric('activeMembers', 'active_members', demo ? 1284 : 0)}',
        Icons.people_alt_outlined,
        Colors.blue,
      ),
      (
        'الاشتراكات النشطة',
        '${metric('activeSubscriptions', 'active_subscriptions', demo ? 946 : 0)}',
        Icons.credit_card_outlined,
        Colors.purple,
      ),
      (
        'دخول اليوم',
        '${metric('acceptedAttendance', 'accepted_attendance', demo ? 312 : 0)}',
        Icons.login_rounded,
        Colors.green,
      ),
      (
        'إيرادات اليوم',
        _money(
          metric('invoicedGrossMinor', 'invoiced_gross_minor') +
              metric(
                'otherIncomeMinor',
                'other_income_minor',
                demo ? 186400 : 0,
              ),
        ),
        Icons.payments_outlined,
        goYellow,
      ),
    ];
    return PageFrame(
      onRefresh: () => controller.refresh(announce: true),
      title: 'مرحبًا، ${controller.displayName}',
      subtitle: '$today  •  ${controller.branchName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!canReport) ...[
            _AccessWelcomeCard(controller: controller),
            const SizedBox(height: 16),
            _quickCard(context, controller),
          ] else if (controller.refreshing && s.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 100),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (controller.dashboardError != null)
              _InlineError(
                message: controller.dashboardError!,
                onRetry: controller.refresh,
              ),
            if (controller.dashboardError != null) const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: cards
                  .map(
                    (c) => SizedBox(
                      width: 235,
                      child: MetricCard(
                        label: c.$1,
                        value: c.$2,
                        icon: c.$3,
                        color: c.$4,
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionHeader(
                      title: 'أداء الإيرادات',
                      action: 'آخر ٣٠ يومًا',
                    ),
                    const SizedBox(height: 18),
                    if (controller.analyticsError != null)
                      _InlineError(
                        message: controller.analyticsError!,
                        onRetry: controller.refresh,
                        compact: true,
                      )
                    else if (controller.revenue.isEmpty)
                      const SizedBox(
                        height: 150,
                        child: Center(
                          child: Text(
                            'لا توجد حركة إيرادات في الفترة الحالية.',
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        height: 190,
                        child: RevenueBars(rows: controller.revenue),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, c) => c.maxWidth < 650
                  ? Column(
                      children: [
                        _quickCard(context, controller),
                        const SizedBox(height: 16),
                        _attentionCard(s, demo: demo),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _quickCard(context, controller)),
                        const SizedBox(width: 16),
                        Expanded(child: _attentionCard(s, demo: demo)),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AccessWelcomeCard extends StatelessWidget {
  const _AccessWelcomeCard({required this.controller});
  final GoController controller;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: goYellow,
            child: Icon(Icons.verified_user_outlined, color: goInk),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مساحة عملك جاهزة',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                Text(
                  'تظهر لك الأدوات المسموح بها حسب دورك في ${controller.branchName}. استخدم الإجراءات السريعة أو تبويب المزيد للوصول إليها.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({
    required this.message,
    required this.onRetry,
    this.compact = false,
  });
  final String message;
  final Future<void> Function() onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 15),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.error.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: colors.error),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(height: 1.5))),
          IconButton(
            onPressed: () => unawaited(onRetry()),
            tooltip: 'إعادة المحاولة',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }
}

Widget _quickCard(BuildContext context, GoController controller) => Card(
  child: Padding(
    padding: const EdgeInsets.all(18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'إجراءات سريعة'),
        const SizedBox(height: 12),
        if (controller.can('members.manage'))
          QuickAction(
            icon: Icons.person_add_alt_1_rounded,
            text: 'تسجيل عضو جديد',
            onTap: () => controller.setTab(1),
          ),
        if (controller.can('attendance.check-in'))
          QuickAction(
            icon: Icons.qr_code_scanner_rounded,
            text: 'تسجيل دخول عضو',
            onTap: () => controller.setTab(2),
          ),
        if (controller.can('sales.checkout'))
          QuickAction(
            icon: Icons.add_card_rounded,
            text: 'إنشاء اشتراك',
            onTap: () => unawaited(
              _openWorkflow(
                context,
                controller,
                _workflowById('createSubscription'),
              ),
            ),
          ),
      ],
    ),
  ),
);
Widget _attentionCard(Map<String, dynamic> s, {required bool demo}) {
  String value(String camel, String snake, num fallback) =>
      '${s[camel] ?? s[snake] ?? fallback}';
  final pending = value(
    'pendingOnlineRequests',
    'pending_online_requests',
    demo ? 7 : 0,
  );
  final feedback = value(
    'openFeedbackCases',
    'open_feedback_cases',
    demo ? 3 : 0,
  );
  return Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: 'يحتاج انتباهك', action: '$pending طلبات'),
          const SizedBox(height: 12),
          AttentionRow(
            icon: Icons.person_add_alt_rounded,
            title: 'طلبات انضمام جديدة',
            value: pending,
            color: Colors.orange,
          ),
          AttentionRow(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'شكاوى مفتوحة',
            value: feedback,
            color: Colors.red,
          ),
        ],
      ),
    ),
  );
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label, value;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              icon,
              color: color == goYellow ? Colors.amber[800] : color,
            ),
          ),
          const SizedBox(height: 17),
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    ),
  );
}

class RevenueBars extends StatelessWidget {
  const RevenueBars({super.key, required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final visible = rows.length > 10 ? rows.sublist(rows.length - 10) : rows;
    num amount(Map<String, dynamic> row) =>
        num.tryParse(
          '${row['totalRevenueMinor'] ?? row['total_revenue_minor'] ?? 0}',
        ) ??
        0;
    final maximum = visible.map(amount).fold<num>(0, max);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: visible.map((row) {
        final value = amount(row);
        final ratio = maximum <= 0 ? 0.0 : (value / maximum).toDouble();
        final date = '${row['businessDate'] ?? row['business_date'] ?? ''}';
        final label = date.length >= 10
            ? '${date.substring(8, 10)}/${date.substring(5, 7)}'
            : date;
        return Expanded(
          child: Tooltip(
            message: '$label • ${_money(value)}',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    _compactMoney(value),
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    style: const TextStyle(fontSize: 9),
                  ),
                  const SizedBox(height: 5),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    height: 12 + (112 * ratio),
                    decoration: BoxDecoration(
                      color: goYellow,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(7),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(label, style: const TextStyle(fontSize: 9)),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

String _compactMoney(num minor) {
  final riyals = minor / 100;
  if (riyals >= 1000000) return '${(riyals / 1000000).toStringAsFixed(1)}م';
  if (riyals >= 1000) return '${(riyals / 1000).toStringAsFixed(1)}ألف';
  return riyals.toStringAsFixed(0);
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});
  final String title;
  final String? action;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
      ),
      if (action != null)
        Flexible(
          child: Text(
            action!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ],
  );
}

class QuickAction extends StatelessWidget {
  const QuickAction({
    super.key,
    required this.icon,
    required this.text,
    required this.onTap,
  });
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    contentPadding: EdgeInsets.zero,
    leading: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: goYellow.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: Colors.amber[800], size: 20),
    ),
    title: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    ),
    trailing: const Icon(Icons.chevron_left_rounded, size: 18),
  );
}

class AttentionRow extends StatelessWidget {
  const AttentionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.color,
  });
  final IconData icon;
  final String title, value;
  final Color color;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: color),
    title: Text(title, style: const TextStyle(fontSize: 12)),
    trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
  );
}

class MembersPage extends StatefulWidget {
  const MembersPage({super.key, required this.controller});
  final GoController controller;
  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  String query = '';
  final searchController = TextEditingController();

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.controller.api.configured
        ? widget.controller.members
        : widget.controller.demoMembers;
    final normalizedQuery = query.trim().toLowerCase();
    final rows = source
        .where(
          (m) =>
              m['name'].toString().toLowerCase().contains(normalizedQuery) ||
              (m['memberNumber'] ?? m['number'])
                  .toString()
                  .toLowerCase()
                  .contains(normalizedQuery),
        )
        .toList();
    final initialLoading = widget.controller.refreshing && source.isEmpty;
    final loadError = widget.controller.membersError;
    return RefreshIndicator(
      onRefresh: widget.controller.refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'دليل الأعضاء',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'ابحث في الملفات وتابع حالة العضوية والاشتراكات بسرعة.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 18),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final search = TextField(
                        controller: searchController,
                        onChanged: (value) => setState(() => query = value),
                        decoration: InputDecoration(
                          hintText: 'الاسم أو رقم العضوية',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'مسح البحث',
                                  onPressed: () {
                                    searchController.clear();
                                    setState(() => query = '');
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                        ),
                      );
                      final add = FilledButton.icon(
                        onPressed: () => unawaited(
                          _openNewMemberSheet(context, widget.controller),
                        ),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('عضو جديد'),
                      );
                      if (constraints.maxWidth < 520) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            search,
                            if (widget.controller.can('members.manage')) ...[
                              const SizedBox(height: 10),
                              add,
                            ],
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: search),
                          if (widget.controller.can('members.manage')) ...[
                            const SizedBox(width: 10),
                            add,
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: const Icon(Icons.people_alt_outlined, size: 17),
                        label: Text('${rows.length} عضو'),
                      ),
                      Chip(
                        avatar: const Icon(
                          Icons.location_on_outlined,
                          size: 17,
                        ),
                        label: Text(
                          widget.controller.api.configured
                              ? widget.controller.branchName
                              : 'وضع العرض',
                        ),
                      ),
                    ],
                  ),
                  if (widget.controller.refreshing && source.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                ],
              ),
            ),
          ),
          if (initialLoading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (loadError != null && source.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل الأعضاء',
                body: loadError,
                action: widget.controller.refresh,
              ),
            )
          else if (rows.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _ResourceMessage(
                icon: query.isEmpty
                    ? Icons.people_outline_rounded
                    : Icons.search_off_rounded,
                title: query.isEmpty
                    ? 'لا يوجد أعضاء في هذا الفرع'
                    : 'لا توجد نتائج',
                body: query.isEmpty
                    ? 'اسحب لأسفل لتحديث القائمة أو أضف أول عضو إذا كانت لديك الصلاحية.'
                    : 'جرّب البحث باسم آخر أو امسح عبارة البحث.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
              sliver: SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Card(
                    child: MemberTile(
                      controller: widget.controller,
                      member: rows[index],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MemberTile extends StatelessWidget {
  const MemberTile({super.key, required this.controller, required this.member});
  final GoController controller;
  final Map<String, dynamic> member;
  @override
  Widget build(BuildContext context) {
    final name = member['name']?.toString() ?? 'عضو';
    final number = (member['memberNumber'] ?? member['number'] ?? '—')
        .toString();
    final statusValue = member['status']?.toString() ?? 'UNKNOWN';
    final status = switch (statusValue) {
      'ACTIVE' => 'نشط',
      'INACTIVE' => 'غير نشط',
      _ => statusValue,
    };
    final contacts = member['contacts'] is List
        ? member['contacts'] as List
        : const [];
    final phone = contacts
        .whereType<Map>()
        .where((c) => c['type'] == 'PHONE')
        .map((c) => c['value'])
        .firstOrNull
        ?.toString();
    final plan = member['plan']?.toString() ?? phone ?? 'ملف العضو';
    final rawColor = member['color'];
    final avatarColor = rawColor is int ? Color(rawColor) : _avatarColor(name);
    return ListTile(
      onTap: () {
        final id = _rowId(member, ['id', 'memberId']);
        if (id.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MemberDetailPage(
                controller: controller,
                memberId: id,
                initial: member,
              ),
            ),
          );
        }
      },
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: CircleAvatar(
        backgroundColor: avatarColor,
        child: Text(
          name.characters.first,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('$number  •  $plan', style: const TextStyle(fontSize: 11)),
      trailing: Chip(
        label: Text(
          status,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
        ),
        backgroundColor: status == 'نشط'
            ? Colors.green.withValues(alpha: .12)
            : Colors.orange.withValues(alpha: .12),
        side: BorderSide.none,
      ),
    );
  }
}

class MemberDetailPage extends StatefulWidget {
  const MemberDetailPage({
    super.key,
    required this.controller,
    required this.memberId,
    required this.initial,
  });
  final GoController controller;
  final String memberId;
  final Map<String, dynamic> initial;

  @override
  State<MemberDetailPage> createState() => _MemberDetailPageState();
}

MobileWorkflow _editMemberWorkflow(
  GoController controller,
  String memberId,
  Map<String, dynamic> member,
) {
  String contact(String type) {
    final contacts =
        (member['contacts'] as List?)?.whereType<Map>() ?? const [];
    return contacts
            .where((item) => item['type']?.toString() == type)
            .map((item) => item['value']?.toString() ?? '')
            .firstOrNull ??
        '';
  }

  final version = int.tryParse('${member['version'] ?? 1}') ?? 1;
  return MobileWorkflow(
    operationId: 'editMember:$memberId',
    title: 'تعديل بيانات العضو',
    description: 'حدّث البيانات الأساسية ووسائل التواصل التي يعتمد عليها الدخول والإشعارات.',
    submitLabel: 'حفظ التعديلات',
    successMessage: 'تم تحديث ملف العضو.',
    method: 'PATCH',
    path: '/organizations/{organizationId}/members/$memberId',
    icon: Icons.edit_outlined,
    fields: [
      WorkflowField(
        name: 'name',
        label: 'الاسم الكامل',
        required: true,
        initialValue: member['name']?.toString() ?? '',
      ),
      WorkflowField(
        name: 'gender',
        label: 'النوع',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: member['gender']?.toString() ?? 'UNSPECIFIED',
        choices: [
          WorkflowChoice('MALE', 'ذكر'),
          WorkflowChoice('FEMALE', 'أنثى'),
          WorkflowChoice('UNSPECIFIED', 'غير محدد'),
        ],
      ),
      WorkflowField(
        name: 'birthDate',
        label: 'تاريخ الميلاد',
        type: WorkflowFieldType.date,
        autoFillDate: false,
        initialValue: member['birthDate']?.toString() ?? '',
      ),
      WorkflowField(
        name: 'nationalId',
        label: 'رقم الهوية',
        initialValue: member['nationalId']?.toString() ?? '',
      ),
      WorkflowField(
        name: 'phone',
        label: 'الجوال الأساسي',
        type: WorkflowFieldType.phone,
        initialValue: contact('PHONE'),
      ),
      WorkflowField(
        name: 'email',
        label: 'البريد الأساسي',
        type: WorkflowFieldType.email,
        initialValue: contact('EMAIL'),
      ),
      WorkflowField(
        name: 'status',
        label: 'حالة الملف',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: member['status']?.toString() ?? 'ACTIVE',
        choices: [
          WorkflowChoice('ACTIVE', 'نشط'),
          WorkflowChoice('INACTIVE', 'غير نشط'),
        ],
      ),
      WorkflowField(
        name: 'notes',
        label: 'ملاحظات',
        type: WorkflowFieldType.textarea,
        initialValue: member['notes']?.toString() ?? '',
      ),
    ],
    body: (values, controller) => {
      'expectedVersion': version,
      'name': values['name']?.trim(),
      'gender': values['gender'],
      'birthDate': values['birthDate']?.isEmpty == true
          ? null
          : values['birthDate'],
      'nationalId': values['nationalId']?.trim().isEmpty == true
          ? null
          : values['nationalId']?.trim(),
      'status': values['status'],
      'notes': values['notes']?.trim().isEmpty == true
          ? null
          : values['notes']?.trim(),
      'contacts': [
        if (values['phone']?.trim().isNotEmpty == true)
          {
            'type': 'PHONE',
            'value': values['phone']?.trim(),
            'isPrimary': true,
          },
        if (values['email']?.trim().isNotEmpty == true)
          {
            'type': 'EMAIL',
            'value': values['email']?.trim(),
            'isPrimary': true,
          },
      ],
    },
  );
}

MobileWorkflow _guardianWorkflow(String memberId) => MobileWorkflow(
  operationId: 'addGuardian:$memberId',
  title: 'إضافة ولي أمر',
  description:
      'سجل ولي أمر جديد وحدد ما يستطيع الاطلاع عليه أو إدارته في بوابة العضو.',
  submitLabel: 'ربط ولي الأمر',
  successMessage: 'تم ربط ولي الأمر بالعضو.',
  method: 'POST',
  path: '/organizations/{organizationId}/members/$memberId/guardian-links',
  icon: Icons.family_restroom_outlined,
  fields: const [
    WorkflowField(name: 'name', label: 'اسم ولي الأمر', required: true),
    WorkflowField(
      name: 'phone',
      label: 'رقم الجوال',
      type: WorkflowFieldType.phone,
    ),
    WorkflowField(
      name: 'relationship',
      label: 'صلة القرابة',
      type: WorkflowFieldType.select,
      required: true,
      initialValue: 'FATHER',
      choices: [
        WorkflowChoice('FATHER', 'الأب'),
        WorkflowChoice('MOTHER', 'الأم'),
        WorkflowChoice('LEGAL_GUARDIAN', 'وصي قانوني'),
        WorkflowChoice('OTHER', 'أخرى'),
      ],
    ),
    WorkflowField(
      name: 'isPrimary',
      label: 'ولي الأمر الأساسي',
      type: WorkflowFieldType.checkbox,
      initialValue: 'true',
    ),
    WorkflowField(
      name: 'canView',
      label: 'يمكنه مشاهدة بيانات العضو',
      type: WorkflowFieldType.checkbox,
      initialValue: 'true',
    ),
    WorkflowField(
      name: 'canBook',
      label: 'يمكنه إجراء الحجوزات',
      type: WorkflowFieldType.checkbox,
    ),
    WorkflowField(
      name: 'canManageMembership',
      label: 'يمكنه إدارة العضوية',
      type: WorkflowFieldType.checkbox,
    ),
  ],
  body: (values, controller) => {
    'name': values['name']?.trim(),
    if (values['phone']?.trim().isNotEmpty == true)
      'phone': values['phone']?.trim(),
    'relationship': values['relationship'],
    'isPrimary': _checked(values['isPrimary']),
    'canView': _checked(values['canView']),
    'canBook': _checked(values['canBook']),
    'canManageMembership': _checked(values['canManageMembership']),
  },
);

class _MemberDetailPageState extends State<MemberDetailPage> {
  Map<String, dynamic> member = {};
  bool loading = true;
  bool acting = false;
  String? error;

  @override
  void initState() {
    super.initState();
    member = Map<String, dynamic>.from(widget.initial);
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final data = await widget.controller.api.request(
        '/organizations/${widget.controller.organizationId}/members/${widget.memberId}',
      );
      if (data is Map) member = Map<String, dynamic>.from(data);
      error = null;
    } catch (exception) {
      error = _errorMessage(exception);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<String?> prompt(String title, {bool password = false}) async {
    final value = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: value,
          obscureText: password,
          minLines: password ? 1 : 3,
          maxLines: password ? 1 : 5,
          textDirection: password ? TextDirection.ltr : TextDirection.rtl,
          decoration: InputDecoration(
            labelText: password ? 'كلمة المرور الجديدة' : 'السبب',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value.text.trim()),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    value.dispose();
    return result;
  }

  Future<void> issueActivationCode() async {
    setState(() => acting = true);
    try {
      final data = await widget.controller.api.request(
        '/organizations/${widget.controller.organizationId}/members/${widget.memberId}/account-activation-codes',
        method: 'POST',
      );
      if (!mounted) return;
      final result = data is Map ? data : const <String, dynamic>{};
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('بيانات تفعيل الحساب'),
          content: SelectableText(
            'رمز التفعيل: ${result['activationCode'] ?? '—'}\n'
            'رقم العضوية: ${result['memberNumber'] ?? '—'}\n'
            'الجوال: ${result['phoneE164'] ?? '—'}\n'
            'صالح حتى: ${result['expiresAt'] ?? '—'}',
            textDirection: TextDirection.ltr,
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('تم'),
            ),
          ],
        ),
      );
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> resetPassword() async {
    final password = await prompt('إعادة تعيين كلمة المرور', password: true);
    if (password == null) return;
    if (password.length < 7) {
      setState(() => error = 'كلمة المرور يجب ألا تقل عن 7 محارف.');
      return;
    }
    setState(() => acting = true);
    try {
      await widget.controller.api.request(
        '/organizations/${widget.controller.organizationId}/members/${widget.memberId}/password-resets',
        method: 'POST',
        body: {'password': password},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم تعيين كلمة المرور الجديدة.')),
        );
      }
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> toggleBlock() async {
    final blocked = member['activeBlock'] != null || member['blocked'] == true;
    final reason = await prompt(blocked ? 'رفع الحظر عن العضو' : 'حظر العضو');
    if (reason == null) return;
    if (reason.length < 3) {
      setState(() => error = 'اكتب سببًا واضحًا من 3 أحرف على الأقل.');
      return;
    }
    setState(() => acting = true);
    try {
      await widget.controller.api.request(
        '/organizations/${widget.controller.organizationId}/members/${widget.memberId}/${blocked ? 'block-lifts' : 'blocks'}',
        method: 'POST',
        body: {'expectedVersion': member['version'] ?? 1, 'reason': reason},
      );
      await load();
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> openMemberWorkflow(MobileWorkflow workflow) async {
    await _openWorkflow(context, widget.controller, workflow);
    if (mounted) await load();
  }

  Future<void> showBlockHistory() async {
    setState(() => acting = true);
    try {
      final data = await widget.controller.api.request(
        '/organizations/${widget.controller.organizationId}/members/${widget.memberId}/block-history',
      );
      final rows = data is List
          ? data.whereType<Map>().toList()
          : data is Map && data['items'] is List
          ? (data['items'] as List).whereType<Map>().toList()
          : <Map>[];
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'سجل حظر العضو',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Text(
                      'لا توجد عمليات حظر مسجلة لهذا العضو.',
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final lifted = row['liftedAt'] != null;
                        return ListTile(
                          leading: Icon(
                            lifted
                                ? Icons.lock_open_outlined
                                : Icons.block_outlined,
                            color: lifted ? Colors.green : Colors.red,
                          ),
                          title: Text(row['reason']?.toString() ?? 'عملية حظر'),
                          subtitle: Text(
                            '${row['blockedAt'] ?? row['createdAt'] ?? ''}'
                            '${lifted ? '\nتم رفعه: ${row['liftedAt']}' : ''}',
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } catch (exception) {
      if (mounted) setState(() => error = _errorMessage(exception));
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = member['name']?.toString() ?? 'ملف العضو';
    final related = resourceFeatures.where(
      (feature) => const {
        '/organizations/{organizationId}/subscriptions',
        '/organizations/{organizationId}/orders',
        '/organizations/{organizationId}/invoices',
        '/organizations/{organizationId}/attendance-attempts',
        '/organizations/{organizationId}/reservations',
        '/organizations/{organizationId}/files',
      }.contains(feature.path),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            if (loading) const LinearProgressIndicator(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: _avatarColor(name),
                          child: Text(
                            name.characters.first,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                member['memberNumber']?.toString() ?? '—',
                                textDirection: TextDirection.ltr,
                              ),
                            ],
                          ),
                        ),
                        Chip(
                          label: Text(
                            _displayValue('status', member['status']),
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 28),
                    ...member.entries
                        .where(
                          (entry) =>
                              entry.value != null &&
                              entry.value is! Map &&
                              entry.value is! List &&
                              !const {
                                'id',
                                'name',
                                'memberNumber',
                              }.contains(entry.key),
                        )
                        .take(10)
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(_humanizeOperation(entry.key)),
                                ),
                                Text(_displayValue(entry.key, entry.value)),
                              ],
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: related
                  .map(
                    (feature) => ActionChip(
                      avatar: Icon(feature.icon, size: 17),
                      label: Text(feature.title),
                      onPressed: () => _openResource(
                        context,
                        widget.controller,
                        feature,
                        memberFilterId: widget.memberId,
                      ),
                    ),
                  )
                  .toList(),
            ),
            if (widget.controller.can('members.accounts.manage')) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: acting ? null : issueActivationCode,
                icon: const Icon(Icons.key_outlined),
                label: const Text('إصدار رمز تفعيل الحساب'),
              ),
              OutlinedButton.icon(
                onPressed: acting ? null : resetPassword,
                icon: const Icon(Icons.lock_reset_outlined),
                label: const Text('إعادة تعيين كلمة المرور'),
              ),
            ],
            if (widget.controller.can('members.manage')) ...[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: acting
                    ? null
                    : () => unawaited(
                        openMemberWorkflow(
                          _editMemberWorkflow(
                            widget.controller,
                            widget.memberId,
                            member,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('تعديل بيانات العضو'),
              ),
              OutlinedButton.icon(
                onPressed: acting
                    ? null
                    : () => unawaited(
                        openMemberWorkflow(_guardianWorkflow(widget.memberId)),
                      ),
                icon: const Icon(Icons.family_restroom_outlined),
                label: const Text('إضافة ولي أمر'),
              ),
            ],
            if (widget.controller.can('members.block'))
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: acting ? null : toggleBlock,
                    icon: const Icon(Icons.block_outlined),
                    label: Text(
                      member['activeBlock'] != null || member['blocked'] == true
                          ? 'رفع الحظر عن العضو'
                          : 'حظر العضو',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: acting ? null : showBlockHistory,
                    icon: const Icon(Icons.history_rounded),
                    label: const Text('عرض سجل الحظر'),
                  ),
                ],
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }
}

class OperationsPage extends StatefulWidget {
  const OperationsPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<OperationsPage> createState() => _OperationsPageState();
}

class _OperationsPageState extends State<OperationsPage> {
  List<Map<String, dynamic>> schedule = [];
  bool loading = true;
  String? error;
  String? loadedBranch;

  GoController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant OperationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (loadedBranch != controller.branchId && !loading) unawaited(load());
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    final rows = <Map<String, dynamic>>[];
    final errors = <String>[];
    Future<void> fetch(ResourceFeature feature, String kind) async {
      try {
        final result = controller.api.configured
            ? await controller.api.listResource(
                controller.organizationId,
                controller.branchId,
                feature.path,
              )
            : _demoResourceRows(feature);
        for (final row in result) {
          rows.add({...row, '_scheduleKind': kind});
        }
      } catch (exception) {
        errors.add(_errorMessage(exception));
      }
    }

    await Future.wait<void>([
      if (controller.can('bookings.read'))
        fetch(resourceFeatures[2], 'booking'),
      if (controller.can('workforce.shifts.read'))
        fetch(
          resourceFeatures.firstWhere(
            (item) => item.path.endsWith('/employee-shifts'),
          ),
          'shift',
        ),
    ]);
    rows.sort((a, b) => _scheduleDate(a).compareTo(_scheduleDate(b)));
    if (!mounted) return;
    setState(() {
      schedule = rows;
      loadedBranch = controller.branchId;
      loading = false;
      error = errors.isEmpty ? null : errors.first;
    });
  }

  static DateTime _scheduleDate(Map<String, dynamic> row) =>
      DateTime.tryParse('${row['startsAt'] ?? row['starts_at'] ?? ''}') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = schedule.where((row) {
      final date = _scheduleDate(row).toLocal();
      return date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
    }).toList();
    return PageFrame(
      onRefresh: load,
      title: 'مركز التشغيل',
      subtitle: 'إجراءات الفرع وجدول اليوم من البيانات الفعلية.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(title: 'الوصول السريع'),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (controller.can('attendance.check-in'))
                        OperationButton(
                          icon: Icons.qr_code_scanner_rounded,
                          title: 'مسح دخول',
                          color: Colors.green,
                          onPressed: () =>
                              unawaited(_openCheckInSheet(context, controller)),
                        ),
                      if (controller.can('bookings.create'))
                        OperationButton(
                          icon: Icons.calendar_month_outlined,
                          title: 'حجز مورد',
                          color: Colors.blue,
                          onPressed: () => unawaited(
                            _openWorkflow(
                              context,
                              controller,
                              _workflowById('createManualReservation'),
                            ),
                          ),
                        ),
                      if (controller.can('sales.checkout') ||
                          controller.can('sales.read') ||
                          controller.can('finance.invoices.read') ||
                          controller.can('finance.payments.record') ||
                          controller.can('finance.cash-shifts.manage'))
                        OperationButton(
                          icon: Icons.point_of_sale_outlined,
                          title: 'نقطة البيع',
                          color: Colors.orange,
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  PointOfSaleMobilePage(controller: controller),
                            ),
                          ),
                        ),
                      if (controller.can('restaurant.orders.read'))
                        OperationButton(
                          icon: Icons.restaurant_outlined,
                          title: 'طلبات المطعم',
                          color: Colors.purple,
                          onPressed: () => _openResource(
                            context,
                            controller,
                            resourceFeatures[6],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: SectionHeader(
                    title: 'جدول اليوم',
                    action: loading ? 'جارٍ التحميل' : '${today.length} موعد',
                  ),
                ),
                const Divider(height: 1),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(38),
                    child: CircularProgressIndicator(),
                  )
                else if (error != null && today.isEmpty)
                  _ResourceMessage(
                    icon: Icons.cloud_off_outlined,
                    title: 'تعذر تحميل جدول اليوم',
                    body: error!,
                    action: load,
                  )
                else if (today.isEmpty)
                  const _ResourceMessage(
                    icon: Icons.event_available_outlined,
                    title: 'لا توجد مواعيد اليوم',
                    body:
                        'لا توجد حجوزات أو مناوبات مسجلة لهذا اليوم في الفرع.',
                  )
                else
                  ...today.map((row) => _OperationScheduleRow(row: row)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class OperationButton extends StatelessWidget {
  const OperationButton({
    super.key,
    required this.icon,
    required this.title,
    required this.color,
    required this.onPressed,
  });
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, color: color),
    label: Text(title),
  );
}

class _OperationScheduleRow extends StatelessWidget {
  const _OperationScheduleRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final isShift = row['_scheduleKind'] == 'shift';
    final startsAt = _OperationsPageState._scheduleDate(row).toLocal();
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(startsAt));
    final title = isShift
        ? '${row['employeeName'] ?? row['employee_name'] ?? 'مناوبة موظف'}'
        : '${row['customerName'] ?? row['memberName'] ?? row['resourceName'] ?? 'حجز'}';
    final place = isShift
        ? 'مناوبة • ${_displayValue('status', row['status'])}'
        : '${row['resourceName'] ?? 'حجز'} • ${_displayValue('status', row['status'])}';
    final color = isShift ? Colors.purple : Colors.blue;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18),
      leading: SizedBox(
        width: 48,
        child: Text(time, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
      subtitle: Text(place, style: const TextStyle(fontSize: 11)),
      trailing: Container(
        width: 8,
        height: 35,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class MessagesPage extends StatelessWidget {
  const MessagesPage({
    super.key,
    required this.controller,
    this.showHeading = true,
  });
  final GoController controller;
  final bool showHeading;
  @override
  Widget build(BuildContext context) {
    final unread = controller.notices.where((n) => n['unread'] == true).length;
    return PageFrame(
      onRefresh: () => controller.refresh(announce: true),
      title: showHeading ? 'الرسائل والإشعارات' : null,
      subtitle: showHeading
          ? unread == 0
                ? 'لا توجد رسائل جديدة.'
                : 'لديك $unread رسائل تحتاج مراجعة.'
          : null,
      child: Column(
        children: [
          if (unread > 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => unawaited(controller.markAllRead()),
                icon: const Icon(Icons.done_all, size: 16),
                label: const Text('تحديد الكل كمقروء'),
              ),
            ),
          if (controller.refreshing && controller.notices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 70),
              child: CircularProgressIndicator(),
            )
          else if (controller.notificationsError != null &&
              controller.notices.isEmpty)
            _ResourceMessage(
              icon: Icons.notifications_off_outlined,
              title: 'تعذر تحميل التنبيهات',
              body: controller.notificationsError!,
              action: controller.refresh,
            )
          else if (controller.notices.isEmpty)
            const _ResourceMessage(
              icon: Icons.notifications_none_rounded,
              title: 'كل شيء هادئ الآن',
              body: 'ستظهر هنا تنبيهات الحساب والتحديثات المهمة عند وصولها.',
            )
          else
            Card(
              child: Column(
                children: controller.notices
                    .map((n) => NoticeTile(notice: n, controller: controller))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class NoticeTile extends StatelessWidget {
  const NoticeTile({super.key, required this.notice, required this.controller});
  final Map<String, dynamic> notice;
  final GoController controller;
  @override
  Widget build(BuildContext context) {
    final warning = notice['type'] == 'warning';
    return ListTile(
      onTap: () =>
          unawaited(_openNotificationDestination(context, controller, notice)),
      isThreeLine: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      leading: CircleAvatar(
        backgroundColor: (warning ? Colors.orange : Colors.green).withValues(
          alpha: .14,
        ),
        child: Icon(
          warning
              ? Icons.warning_amber_rounded
              : Icons.check_circle_outline_rounded,
          color: warning ? Colors.orange : Colors.green,
        ),
      ),
      title: Text(
        notice['title'].toString(),
        style: TextStyle(
          fontWeight: notice['unread'] == true
              ? FontWeight.w900
              : FontWeight.w600,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        '${notice['body']}\n${notice['createdAtLabel'] ?? notice['createdAt']}',
        style: const TextStyle(fontSize: 11, height: 1.6),
      ),
      trailing: notice['unread'] == true
          ? const Icon(Icons.circle, color: goYellow, size: 9)
          : null,
    );
  }
}

Future<void> _openNotificationDestination(
  BuildContext context,
  GoController controller,
  Map<String, dynamic> notice,
) async {
  await controller.openNotification(notice);
  if (!context.mounted) return;
  final href = notice['actionHref']?.toString() ?? '';
  if (href.isEmpty) return;
  if (!controller.staffMode) {
    final feature = memberResourceFeatures.where((item) {
      if (href.contains('subscription')) {
        return item.path.contains('subscriptions');
      }
      if (href.contains('reservation') || href.contains('booking')) {
        return item.path.contains('reservations');
      }
      if (href.contains('invoice')) return item.path.contains('invoices');
      if (href.contains('feedback')) return item.path.contains('feedback');
      if (href.contains('order')) return item.path.endsWith('/orders');
      return false;
    }).firstOrNull;
    if (feature != null) _openResource(context, controller, feature);
    return;
  }
  if (href.startsWith('/members')) {
    controller.setTab(1);
    return;
  }
  final feature = resourceFeatures.where((item) {
    final segment = item.path.split('/').last;
    return segment.isNotEmpty && href.contains(segment);
  }).firstOrNull;
  if (feature != null) _openResource(context, controller, feature);
}

void _openResource(
  BuildContext context,
  GoController controller,
  ResourceFeature feature, {
  String? memberFilterId,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          feature.path.startsWith('/self/') &&
              const [
                'services',
                'packages',
                'bookable-resources',
              ].contains(feature.path.split('/').last)
          ? MemberMarketplacePage(
              controller: controller,
              standalone: true,
              initialTab: feature.path.endsWith('/services')
                  ? 'services'
                  : feature.path.endsWith('/packages')
                  ? 'packages'
                  : 'booking',
            )
          : feature.path.endsWith('/daily-menu')
          ? MemberDailyMenuPage(controller: controller)
          : feature.path.endsWith('/barcode')
          ? MemberBarcodePage(controller: controller)
          : feature.path.startsWith('/self/') &&
                feature.path.endsWith('/training-plans')
          ? MemberTrainingPlansPage(controller: controller)
          : feature.path.contains('/feedback-cases')
          ? FeedbackCasesPage(
              controller: controller,
              memberMode: !controller.staffMode,
            )
          : feature.path.endsWith('/files')
          ? FilesPage(
              controller: controller,
              memberMode: !controller.staffMode,
              initialOwnerId: memberFilterId,
            )
          : ResourcePage(
              controller: controller,
              feature: feature,
              memberFilterId: memberFilterId,
            ),
    ),
  );
}

class MemberTrainingPlansPage extends StatefulWidget {
  const MemberTrainingPlansPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<MemberTrainingPlansPage> createState() =>
      _MemberTrainingPlansPageState();
}

class _MemberTrainingPlansPageState extends State<MemberTrainingPlansPage> {
  List<Map<String, dynamic>> plans = [];
  bool loading = true;
  String? busyItemId;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  dynamic _field(Map row, String camel, [String? snake]) =>
      row[camel] ?? (snake == null ? null : row[snake]);

  List<Map<String, dynamic>> _rows(dynamic data) {
    final values = data is List
        ? data
        : data is Map && data['items'] is List
        ? data['items'] as List
        : const <dynamic>[];
    return values
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final controller = widget.controller;
      final memberId = controller.selectedMemberId;
      if (memberId == null || memberId.isEmpty) {
        throw const ApiFailure('تعذر تحديد ملف العضو الحالي.');
      }
      final data = await controller.api.request(
        '/self/organizations/${controller.organizationId}/members/$memberId/training-plans',
        query: const {'limit': '100'},
      );
      plans = _rows(data);
    } catch (exception) {
      error = _errorMessage(exception);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _transition(
    Map<String, dynamic> plan,
    Map<String, dynamic> item,
  ) async {
    final status = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _field(item, 'exerciseName', 'exercise_name')?.toString() ??
                    'التمرين',
                style: Theme.of(sheetContext).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(
                'سجّل النتيجة بعد تنفيذ التمرين. لا يمكن تعديلها من بوابة العضو بعد الحفظ.',
                style: TextStyle(
                  color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => Navigator.pop(sheetContext, 'COMPLETED'),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('تم إنجاز التمرين'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(sheetContext, 'SKIPPED'),
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('تخطي هذا التمرين'),
              ),
            ],
          ),
        ),
      ),
    );
    if (status == null || !mounted) return;
    final planId = _field(plan, 'id')?.toString() ?? '';
    final itemId = _field(item, 'id')?.toString() ?? '';
    final memberId = widget.controller.selectedMemberId ?? '';
    if (planId.isEmpty || itemId.isEmpty || memberId.isEmpty) return;
    setState(() {
      busyItemId = itemId;
      error = null;
    });
    try {
      await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/members/$memberId/training-plans/$planId/items/$itemId/transitions',
        method: 'POST',
        body: {'status': status},
      );
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'COMPLETED'
                ? 'رائع! تم تسجيل إنجاز التمرين.'
                : 'تم تسجيل تخطي التمرين.',
          ),
        ),
      );
    } catch (exception) {
      if (mounted) {
        setState(() => error = _errorMessage(exception));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(exception))));
      }
    } finally {
      if (mounted) setState(() => busyItemId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allItems = plans.expand((plan) {
      final value = _field(plan, 'items');
      return value is List
          ? value.whereType<Map>()
          : const Iterable<Map>.empty();
    }).toList();
    final completed = allItems
        .where(
          (item) =>
              _field(item, 'completionStatus', 'completion_status') ==
              'COMPLETED',
        )
        .length;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'خططي التدريبية',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : () => unawaited(load()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث الخطط',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            if (!loading && plans.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [goInk, Color(0xFF33332E)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 25,
                      backgroundColor: goYellow,
                      child: Icon(Icons.fitness_center_rounded, color: goInk),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'رحلة تدريبك',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            allItems.isEmpty
                                ? '${plans.length} خطط مسجلة'
                                : '$completed من ${allItems.length} تمارين مكتملة',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (allItems.isNotEmpty)
                      Text(
                        '${((completed / allItems.length) * 100).round()}٪',
                        textDirection: TextDirection.rtl,
                        style: const TextStyle(
                          color: goYellow,
                          fontWeight: FontWeight.w900,
                          fontSize: 22,
                        ),
                      ),
                  ],
                ),
              ),
            if (!loading && plans.isNotEmpty) const SizedBox(height: 14),
            if (loading)
              const SizedBox(
                height: 420,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null && plans.isEmpty)
              _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل خطط التدريب',
                body: error!,
                action: load,
              )
            else if (plans.isEmpty)
              const _ResourceMessage(
                icon: Icons.fitness_center_outlined,
                title: 'لا توجد خطة تدريب حالية',
                body: 'عند إسناد خطة لك من المدرب ستظهر هنا التمارين وتعليمات تنفيذها.',
              )
            else
              ...plans.map(_planCard),
          ],
        ),
      ),
    );
  }

  Widget _planCard(Map<String, dynamic> plan) {
    final itemsValue = _field(plan, 'items');
    final items = itemsValue is List
        ? itemsValue
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : <Map<String, dynamic>>[];
    final completed = items
        .where(
          (item) =>
              _field(item, 'completionStatus', 'completion_status') ==
              'COMPLETED',
        )
        .length;
    final status = _field(plan, 'status')?.toString() ?? '';
    final title = _field(plan, 'name')?.toString() ?? 'خطة تدريب';
    final goal = _field(plan, 'goal')?.toString() ?? '';
    final trainer =
        _field(plan, 'trainerName', 'trainer_name')?.toString() ?? '';
    final startsOn = _field(plan, 'startsOn', 'starts_on')?.toString() ?? '';
    final endsOn = _field(plan, 'endsOn', 'ends_on')?.toString() ?? '';
    final days = <int, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final day =
          int.tryParse('${_field(item, 'dayNumber', 'day_number') ?? 1}') ?? 1;
      days.putIfAbsent(day, () => []).add(item);
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: status == 'ACTIVE',
        tilePadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
        leading: CircleAvatar(
          backgroundColor: status == 'ACTIVE'
              ? goYellow.withValues(alpha: .2)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            status == 'ACTIVE' ? Icons.play_arrow_rounded : Icons.check_rounded,
            color: status == 'ACTIVE' ? goInk : null,
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            [
              if (trainer.isNotEmpty) 'المدرب: $trainer',
              if (items.isNotEmpty) '$completed من ${items.length} مكتمل',
            ].join(' • '),
            style: const TextStyle(fontSize: 11),
          ),
        ),
        children: [
          if (goal.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: .42),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text('الهدف: $goal', style: const TextStyle(height: 1.5)),
            ),
          if (startsOn.isNotEmpty || endsOn.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  const Icon(Icons.date_range_outlined, size: 18),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${_shortDate(startsOn)}${endsOn.isNotEmpty ? ' — ${_shortDate(endsOn)}' : ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('لا توجد تمارين داخل هذه الخطة.'),
            )
          else
            ...days.entries.map(
              (entry) => _trainingDay(
                plan,
                entry.key,
                entry.value,
                status == 'ACTIVE',
              ),
            ),
        ],
      ),
    );
  }

  Widget _trainingDay(
    Map<String, dynamic> plan,
    int day,
    List<Map<String, dynamic>> items,
    bool active,
  ) {
    items.sort(
      (a, b) =>
          (int.tryParse(
                    '${_field(a, 'sequenceNumber', 'sequence_number') ?? 0}',
                  ) ??
                  0)
              .compareTo(
                int.tryParse(
                      '${_field(b, 'sequenceNumber', 'sequence_number') ?? 0}',
                    ) ??
                    0,
              ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              'اليوم $day',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
          ...items.map((item) => _exerciseCard(plan, item, active)),
        ],
      ),
    );
  }

  Widget _exerciseCard(
    Map<String, dynamic> plan,
    Map<String, dynamic> item,
    bool planActive,
  ) {
    final id = _field(item, 'id')?.toString() ?? '';
    final status =
        _field(item, 'completionStatus', 'completion_status')?.toString() ??
        'PENDING';
    final name =
        _field(item, 'exerciseName', 'exercise_name')?.toString() ?? 'تمرين';
    final instructions = _field(item, 'instructions')?.toString() ?? '';
    final sets = _field(item, 'sets')?.toString() ?? '';
    final repetitions = _field(item, 'repetitions')?.toString() ?? '';
    final minutes =
        _field(item, 'durationMinutes', 'duration_minutes')?.toString() ?? '';
    final pending = status == 'PENDING';
    final busy = busyItemId == id;
    final accent = status == 'COMPLETED'
        ? Colors.green
        : status == 'SKIPPED'
        ? Colors.orange
        : goYellow;
    final meta = [
      if (sets.isNotEmpty) '$sets مجموعات',
      if (repetitions.isNotEmpty) '$repetitions تكرار',
      if (minutes.isNotEmpty) '$minutes دقيقة',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest
            .withValues(alpha: .42),
        borderRadius: BorderRadius.circular(16),
        border: Border(right: BorderSide(color: accent, width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                status == 'COMPLETED'
                    ? Icons.check_circle_rounded
                    : status == 'SKIPPED'
                    ? Icons.skip_next_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: accent,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        meta.join(' • '),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
              Text(
                status == 'COMPLETED'
                    ? 'مكتمل'
                    : status == 'SKIPPED'
                    ? 'تم التخطي'
                    : 'بانتظار التنفيذ',
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          if (instructions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              instructions,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
          if (pending && planActive) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: busy ? null : () => unawaited(_transition(plan, item)),
              icon: busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_task_rounded, size: 18),
              label: const Text('تسجيل نتيجة التمرين'),
            ),
          ],
        ],
      ),
    );
  }

  String _shortDate(String value) => value.length >= 10
      ? value.substring(0, 10).split('-').reversed.join('/')
      : value;
}

class MemberBarcodePage extends StatefulWidget {
  const MemberBarcodePage({super.key, required this.controller});
  final GoController controller;

  @override
  State<MemberBarcodePage> createState() => _MemberBarcodePageState();
}

class _MemberBarcodePageState extends State<MemberBarcodePage> {
  Map<String, dynamic>? credential;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final controller = widget.controller;
      final data = await controller.api.request(
        '/self/organizations/${controller.organizationId}/members/${controller.selectedMemberId}/barcode',
      );
      credential = data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
    } catch (exception) {
      credential = null;
      if (exception is! ApiFailure || !exception.isNotFound) {
        error = _errorMessage(exception);
      }
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final value =
        credential?['credentialValue']?.toString() ??
        credential?['value']?.toString() ??
        credential?['code']?.toString() ??
        '';
    final memberName =
        credential?['memberName']?.toString() ?? widget.controller.displayName;
    final memberNumber =
        credential?['memberNumber']?.toString() ??
        widget.controller.selectedSelfMember?['memberNumber']?.toString() ??
        '';
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'بطاقة دخولي',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : () => unawaited(load()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث البطاقة',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 36),
          children: [
            if (loading)
              const SizedBox(
                height: 420,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل بطاقة الدخول',
                body: error!,
                action: load,
              )
            else if (value.isEmpty)
              const _ResourceMessage(
                icon: Icons.qr_code_2_rounded,
                title: 'لا توجد بطاقة دخول نشطة',
                body: 'اطلب من استقبال النادي إصدار بطاقة دخول لحسابك، ثم اسحب الشاشة للتحديث.',
              )
            else ...[
              Container(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: goInk, width: 2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 28,
                      offset: Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/go-fitness-emblem.png',
                          width: 56,
                          height: 42,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'GO FITNESS',
                          textDirection: TextDirection.ltr,
                          style: TextStyle(
                            color: goInk,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      memberName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: goInk,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (memberNumber.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        memberNumber,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          color: Colors.black54,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 26),
                    Semantics(
                      label: 'باركود دخول العضو $memberNumber',
                      image: true,
                      child: barcode_ui.BarcodeWidget(
                        barcode: barcode_ui.Barcode.code39(),
                        data: value,
                        width: 290,
                        height: 104,
                        drawText: false,
                        color: Colors.black,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      value,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: goInk,
                        fontFamily: 'monospace',
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline, color: Colors.amber),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'ارفع سطوع الشاشة وقرّب الباركود من قارئ البوابة. البطاقة شخصية ولا ينبغي مشاركتها.',
                          style: TextStyle(fontSize: 12, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MemberDailyMenuPage extends StatefulWidget {
  const MemberDailyMenuPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<MemberDailyMenuPage> createState() => _MemberDailyMenuPageState();
}

class _MemberDailyMenuPageState extends State<MemberDailyMenuPage> {
  List<Map<String, dynamic>> meals = [];
  bool loading = true;
  String? ordering;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/daily-menu',
        query: {
          'branchId': widget.controller.branchId,
          'businessDate': DateTime.now().toIso8601String().substring(0, 10),
        },
      );
      meals = data is Map && data['items'] is List
          ? (data['items'] as List)
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList()
          : [];
    } catch (exception) {
      if (exception is ApiFailure && exception.isNotFound) {
        meals = [];
      } else {
        error = _errorMessage(exception);
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> order(Map<String, dynamic> meal) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(meal['mealName']?.toString() ?? 'طلب الوجبة'),
        content: Text(
          'سيتم إنشاء طلب وفاتورة بقيمة ${_money(meal['priceMinor'] ?? 0)}. يصل الطلب إلى المطبخ بعد السداد.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تأكيد الطلب'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final mealId = meal['mealId']?.toString() ?? '';
    setState(() => ordering = mealId);
    try {
      await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/members/${widget.controller.selectedMemberId}/orders',
        method: 'POST',
        body: {
          'sellingBranchId': widget.controller.branchId,
          'lines': [
            {'type': 'RESTAURANT', 'targetId': mealId, 'quantity': 1},
          ],
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تم إنشاء الطلب والفاتورة. أكمل السداد في الاستقبال.',
            ),
          ),
        );
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => ordering = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'وجبات اليوم',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            'قائمة ${widget.controller.branchName} المنشورة اليوم، مع السعر والقيم الغذائية والحساسيات.',
            style: const TextStyle(height: 1.6),
          ),
          const SizedBox(height: 16),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            _ResourceMessage(
              icon: Icons.cloud_off_outlined,
              title: 'تعذر تحميل قائمة اليوم',
              body: error!,
              action: load,
            )
          else if (meals.isEmpty)
            const _ResourceMessage(
              icon: Icons.restaurant_menu_outlined,
              title: 'لا توجد قائمة منشورة اليوم',
              body: 'اختر فرعًا آخر أو راجع القائمة لاحقًا.',
            )
          else
            ...meals.map(
              (meal) => Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              meal['mealName']?.toString() ?? 'وجبة',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Text(
                            _money(meal['priceMinor'] ?? 0),
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                      if (meal['description'] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            meal['description'].toString(),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 7,
                        children: [
                          Chip(
                            label: Text('${meal['caloriesKcal'] ?? 0} سعرة'),
                          ),
                          Chip(
                            label: Text('${meal['proteinGrams'] ?? 0}غ بروتين'),
                          ),
                          if (meal['availableQuantity'] != null)
                            Chip(
                              label: Text('متاح ${meal['availableQuantity']}'),
                            ),
                        ],
                      ),
                      FilledButton.icon(
                        onPressed: ordering == null
                            ? () => unawaited(order(meal))
                            : null,
                        icon: ordering == meal['mealId']?.toString()
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.shopping_bag_outlined),
                        label: const Text('طلب الوجبة وإنشاء الفاتورة'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class ResourcePage extends StatefulWidget {
  const ResourcePage({
    super.key,
    required this.controller,
    required this.feature,
    this.memberFilterId,
  });
  final GoController controller;
  final ResourceFeature feature;
  final String? memberFilterId;
  @override
  State<ResourcePage> createState() => _ResourcePageState();
}

class _ResourcePageState extends State<ResourcePage> {
  List<Map<String, dynamic>> rows = [];
  bool loading = true;
  String? error;
  String query = '';

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      rows = widget.controller.api.configured
          ? await widget.controller.api.listResource(
              widget.controller.organizationId,
              widget.controller.branchId,
              widget.feature.path,
              memberId:
                  widget.memberFilterId ?? widget.controller.selectedMemberId,
            )
          : _demoResourceRows(widget.feature);
    } catch (exception) {
      if (exception is ApiFailure && exception.isNotFound) {
        rows = [];
      } else {
        error = _errorMessage(exception);
      }
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final workflows = _workflowsForFeature(widget.feature)
        .where((workflow) => _canRunWorkflow(widget.controller, workflow))
        .where(
          (workflow) =>
              !widget.feature.path.contains('/daily-menus/') ||
              rows.isEmpty ||
              workflow.operationId != 'createDailyMenu',
        )
        .toList();
    final visible = rows
        .where(
          (row) =>
              query.isEmpty ||
              row.values.any(
                (value) =>
                    value?.toString().toLowerCase().contains(
                      query.toLowerCase(),
                    ) ==
                    true,
              ),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.feature.title,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          if (workflows.isNotEmpty)
            IconButton(
              onPressed: () async {
                await _openWorkflow(
                  context,
                  widget.controller,
                  workflows.first,
                );
                if (mounted) await load();
              },
              icon: const Icon(Icons.add_circle_outline_rounded),
              tooltip: workflows.first.submitLabel,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              widget.feature.subtitle,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (workflows.isNotEmpty) ...[
              const SectionHeader(title: 'الإجراءات المتاحة'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: workflows
                    .map(
                      (workflow) => FilledButton.tonalIcon(
                        onPressed: () async {
                          await _openWorkflow(
                            context,
                            widget.controller,
                            workflow,
                          );
                          if (mounted) await load();
                        },
                        icon: Icon(workflow.icon, size: 18),
                        label: Text(workflow.submitLabel),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'بحث في النتائج…',
              ),
            ),
            const SizedBox(height: 16),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل البيانات',
                body: error!,
                action: load,
              )
            else if (visible.isEmpty)
              const _ResourceMessage(
                icon: Icons.inbox_outlined,
                title: 'لا توجد نتائج',
                body: 'لا توجد سجلات مطابقة في الفرع الحالي.',
              )
            else
              ...visible.map(
                (row) => _ResourceCard(
                  controller: widget.controller,
                  feature: widget.feature,
                  row: row,
                  onChanged: load,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.controller,
    required this.feature,
    required this.row,
    required this.onChanged,
  });
  final GoController controller;
  final ResourceFeature feature;
  final Map<String, dynamic> row;
  final Future<void> Function() onChanged;
  @override
  Widget build(BuildContext context) {
    final editWorkflow = _editWorkflowForFeature(controller, feature, row);
    final contextualWorkflow = _contextWorkflowForFeature(
      controller,
      feature,
      row,
    );
    final recordActions = _recordActions(controller, feature, row);
    final relatedViews = _relatedViewsForFeature(controller, feature, row);
    final values = feature.fields
        .map((field) => (field.$2, _displayValue(field.$1, row[field.$1])))
        .where((entry) => entry.$2.isNotEmpty)
        .toList();
    final heading = values.isEmpty ? 'سجل' : values.first.$2;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: goYellow.withValues(alpha: .16),
          child: Icon(feature.icon, color: Colors.amber[800], size: 20),
        ),
        title: Text(
          heading,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: values.length > 1
            ? Text(
                '${values[1].$1}: ${values[1].$2}',
                style: const TextStyle(fontSize: 11),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
            child: Column(
              children: [
                ...values.map(
                  (entry) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 92,
                          child: Text(
                            entry.$1,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entry.$2,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (editWorkflow != null ||
                    contextualWorkflow != null ||
                    recordActions.isNotEmpty ||
                    relatedViews.isNotEmpty) ...[
                  const Divider(height: 22),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (editWorkflow != null)
                          OutlinedButton.icon(
                            onPressed: () async {
                              await _openWorkflow(
                                context,
                                controller,
                                editWorkflow,
                              );
                              await onChanged();
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('تعديل البيانات'),
                          ),
                        if (contextualWorkflow != null)
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              await _openWorkflow(
                                context,
                                controller,
                                contextualWorkflow,
                              );
                              await onChanged();
                            },
                            icon: Icon(contextualWorkflow.icon, size: 18),
                            label: Text(contextualWorkflow.submitLabel),
                          ),
                        if (recordActions.isNotEmpty)
                          FilledButton.tonalIcon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => RecordActionsPage(
                                  controller: controller,
                                  feature: feature,
                                  row: row,
                                  onChanged: onChanged,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('إجراءات السجل'),
                          ),
                        if (relatedViews.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _RelatedResourcePage(
                                  controller: controller,
                                  title: heading,
                                  views: relatedViews,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.visibility_outlined),
                            label: const Text('التفاصيل المرتبطة'),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RelatedView {
  const _RelatedView(this.title, this.path, this.icon);
  final String title;
  final String path;
  final IconData icon;
}

List<_RelatedView> _relatedViewsForFeature(
  GoController controller,
  ResourceFeature feature,
  Map<String, dynamic> row,
) {
  final organization = controller.organizationId;
  final branch = row['branchId']?.toString().isNotEmpty == true
      ? row['branchId'].toString()
      : controller.branchId;
  final id = _rowId(row, [
    'id',
    'shiftId',
    'invoiceId',
    'reservationId',
    'sessionId',
  ]);
  if (id.isEmpty) return const [];
  if (feature.path.endsWith('/cashier-shifts')) {
    return [
      _RelatedView(
        'كشف حركة الوردية',
        '/organizations/$organization/cashier-shifts/$id/ledger?branchId=${Uri.encodeQueryComponent(branch)}',
        Icons.receipt_long_outlined,
      ),
    ];
  }
  if (feature.path.endsWith('/bookable-resources')) {
    final from = DateTime.now().toUtc().toIso8601String();
    final to = DateTime.now()
        .add(const Duration(days: 30))
        .toUtc()
        .toIso8601String();
    return [
      _RelatedView(
        'قواعد الإتاحة الأسبوعية',
        '/organizations/$organization/bookable-resources/$id/availability-rules',
        Icons.calendar_view_week_outlined,
      ),
      _RelatedView(
        'المواعيد المتاحة خلال 30 يومًا',
        '/organizations/$organization/bookable-resources/$id/session-slots?from=${Uri.encodeQueryComponent(from)}&to=${Uri.encodeQueryComponent(to)}',
        Icons.event_available_outlined,
      ),
    ];
  }
  if (feature.path.endsWith('/trainers')) {
    return [
      _RelatedView(
        'جدول توفر المدرب',
        '/organizations/$organization/trainers/$id/availability-rules?branchId=${Uri.encodeQueryComponent(branch)}',
        Icons.schedule_outlined,
      ),
      _RelatedView(
        'الأعضاء المسندون للمدرب',
        '/organizations/$organization/trainers/$id/member-assignments?branchId=${Uri.encodeQueryComponent(branch)}&limit=100',
        Icons.groups_2_outlined,
      ),
    ];
  }
  if (feature.path.endsWith('/crm/leads')) {
    return [
      _RelatedView(
        'ملف العميل وسجل المراحل والمتابعات',
        '/organizations/$organization/crm/leads/$id',
        Icons.history_edu_outlined,
      ),
    ];
  }
  final detailPath = switch (feature.path) {
    '/organizations/{organizationId}/invoices' =>
      '/organizations/$organization/invoices/$id',
    '/organizations/{organizationId}/reservations' =>
      '/organizations/$organization/reservations/$id',
    '/organizations/{organizationId}/measurement-sessions' =>
      '/organizations/$organization/measurement-sessions/$id',
    _ => null,
  };
  return detailPath == null
      ? const []
      : [
          _RelatedView(
            'تفاصيل السجل الكاملة',
            detailPath,
            Icons.article_outlined,
          ),
        ];
}

class _RelatedResourcePage extends StatefulWidget {
  const _RelatedResourcePage({
    required this.controller,
    required this.title,
    required this.views,
  });
  final GoController controller;
  final String title;
  final List<_RelatedView> views;

  @override
  State<_RelatedResourcePage> createState() => _RelatedResourcePageState();
}

class _RelatedResourcePageState extends State<_RelatedResourcePage> {
  int selected = 0;
  bool loading = true;
  String? error;
  dynamic data;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      data = await widget.controller.api.request(widget.views[selected].path);
    } catch (exception) {
      error = _errorMessage(exception);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  List<Map<String, dynamic>> get rows {
    final value = data;
    if (value is List) {
      return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
    }
    if (value is Map && value['items'] is List) {
      return (value['items'] as List)
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
    }
    return value is Map ? [Map<String, dynamic>.from(value)] : const [];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.title,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      actions: [
        IconButton(
          onPressed: loading ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(18),
        children: [
          if (widget.views.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.views.indexed
                    .map(
                      (entry) => ChoiceChip(
                        avatar: Icon(entry.$2.icon, size: 18),
                        label: Text(entry.$2.title),
                        selected: selected == entry.$1,
                        onSelected: (_) {
                          setState(() => selected = entry.$1);
                          unawaited(load());
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
          if (loading)
            const Padding(
              padding: EdgeInsets.only(top: 90),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            _ResourceMessage(
              icon: Icons.cloud_off_outlined,
              title: 'تعذر تحميل التفاصيل',
              body: error!,
              action: load,
            )
          else if (rows.isEmpty)
            const _ResourceMessage(
              icon: Icons.inbox_outlined,
              title: 'لا توجد بيانات مرتبطة',
              body: 'ستظهر السجلات هنا فور إضافتها أو تسجيل حركة عليها.',
            )
          else
            ...rows.indexed.map(
              (entry) => _RelatedDataCard(index: entry.$1, row: entry.$2),
            ),
        ],
      ),
    ),
  );
}

class _RelatedDataCard extends StatelessWidget {
  const _RelatedDataCard({required this.index, required this.row});
  final int index;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final visible = row.entries
        .where(
          (entry) => entry.value != null && entry.value.toString().isNotEmpty,
        )
        .toList();
    final title =
        ['name', 'displayName', 'memberName', 'invoiceNumber', 'type', 'status']
            .map((key) => row[key]?.toString() ?? '')
            .firstWhere(
              (value) => value.isNotEmpty,
              orElse: () => 'سجل ${index + 1}',
            );
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        initiallyExpanded: index == 0,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: visible
            .map(
              (entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 116,
                      child: Text(
                        _relatedFieldLabel(entry.key),
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        entry.value is Map || entry.value is List
                            ? const JsonEncoder.withIndent('  ')
                                  .convert(entry.value)
                            : _displayValue(entry.key, entry.value),
                        textDirection: entry.value is Map || entry.value is List
                            ? TextDirection.ltr
                            : null,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

String _relatedFieldLabel(String key) =>
    const {
      'status': 'الحالة',
      'type': 'النوع',
      'name': 'الاسم',
      'displayName': 'الاسم',
      'memberName': 'العضو',
      'branchName': 'الفرع',
      'startsAt': 'يبدأ في',
      'endsAt': 'ينتهي في',
      'startLocal': 'وقت البداية',
      'endLocal': 'وقت النهاية',
      'dayOfWeek': 'يوم الأسبوع',
      'amountMinor': 'المبلغ',
      'balanceMinor': 'الرصيد',
      'invoiceNumber': 'رقم الفاتورة',
      'entries': 'الحركات',
      'items': 'البنود',
      'payments': 'الدفعات',
      'createdAt': 'تاريخ الإنشاء',
      'updatedAt': 'آخر تحديث',
    }[key] ??
    _humanizeOperation(key);

MobileWorkflow? _contextWorkflowForFeature(
  GoController controller,
  ResourceFeature feature,
  Map<String, dynamic> row,
) {
  final status = row['status']?.toString() ?? '';
  final id = _rowId(row, ['id', 'shiftId', 'leadId', 'followUpId']);
  if (id.isEmpty) return null;
  if (feature.path.startsWith('/self/') &&
      feature.path.endsWith('/subscriptions')) {
    final schedules = row['freezeSchedules'] is List
        ? (row['freezeSchedules'] as List).whereType<Map>()
        : const Iterable<Map>.empty();
    final pendingSchedule = schedules
        .where((item) => item['status']?.toString() == 'PENDING')
        .firstOrNull;
    final version = int.tryParse('${row['version'] ?? 1}') ?? 1;
    final base =
        '/self/organizations/${controller.organizationId}/members/${controller.selectedMemberId}/subscriptions/$id';
    if (pendingSchedule != null) {
      final scheduleId = pendingSchedule['id']?.toString() ?? '';
      if (scheduleId.isNotEmpty) {
        return MobileWorkflow(
          operationId: 'cancelSelfFreezeSchedule:$scheduleId',
          title: 'إدارة موعد التجميد',
          description:
              'التجميد مجدول ليبدأ في ${_displayValue('scheduledStartAt', pendingSchedule['scheduledStartAt'])}. يمكنك إلغاء الموعد قبل حلول وقت تنفيذه.',
          submitLabel: 'إلغاء التجميد المجدول',
          successMessage: 'تم إلغاء موعد التجميد المجدول.',
          method: 'POST',
          path: '$base/freeze-schedules/$scheduleId/cancellations',
          icon: Icons.event_busy_outlined,
          fields: [
            WorkflowField(
              name: 'reason',
              label: 'سبب إلغاء الموعد',
              type: WorkflowFieldType.textarea,
              required: true,
            ),
          ],
          body: (values, controller) => {
            'expectedVersion': version,
            'reason': values['reason']?.trim(),
          },
        );
      }
    }
    if (const {'ACTIVE', 'ACTIVE_PROVISIONAL'}.contains(status)) {
      return MobileWorkflow(
        operationId: 'freezeSelfSubscription:$id',
        title: 'تجميد العضوية',
        description: 'ابدأ التجميد الآن أو حدّد موعدًا لاحقًا. سيتحقق النظام من سياسة الباقة قبل الحفظ والتنفيذ.',
        submitLabel: 'تأكيد طلب التجميد',
        successMessage: 'تم تسجيل طلب تجميد العضوية.',
        method: 'POST',
        path: '$base/freezes',
        icon: Icons.ac_unit_rounded,
        fields: [
          WorkflowField(
            name: 'freezeMode',
            label: 'موعد بدء التجميد',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: 'NOW',
            choices: [
              WorkflowChoice('NOW', 'الآن'),
              WorkflowChoice('LATER', 'موعد لاحق'),
            ],
          ),
          WorkflowField(
            name: 'scheduledStartAt',
            label: 'تاريخ ووقت البدء',
            type: WorkflowFieldType.dateTime,
            required: true,
            visibleWhenField: 'freezeMode',
            visibleWhenValues: ['LATER'],
          ),
          WorkflowField(
            name: 'requestedDays',
            label: 'عدد أيام التجميد',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: '7',
          ),
          WorkflowField(
            name: 'reason',
            label: 'سبب التجميد',
            type: WorkflowFieldType.textarea,
            required: true,
          ),
        ],
        body: (values, controller) => {
          'expectedVersion': version,
          'requestedDays': int.tryParse(values['requestedDays'] ?? '') ?? 7,
          'reason': values['reason']?.trim(),
          if (values['freezeMode'] == 'LATER')
            'scheduledStartAt': _asIso(values['scheduledStartAt']),
        },
      );
    }
  }
  if (feature.path.endsWith('/employees') &&
      controller.can('workforce.accounts.manage')) {
    return MobileWorkflow(
      operationId: 'resetEmployeePassword:$id',
      title: row['hasLoginAccount'] == true
          ? 'تغيير كلمة مرور الموظف'
          : 'إنشاء حساب دخول الموظف',
      description: 'يُنشئ النظام حساب الدخول عند عدم وجوده، أو يغيّر كلمة المرور للحساب المرتبط بأمان.',
      submitLabel: 'حفظ كلمة المرور الجديدة',
      successMessage: 'تم تحديث بيانات دخول الموظف.',
      method: 'POST',
      path: '/organizations/{organizationId}/employees/$id/password-resets',
      icon: Icons.password_rounded,
      fields: const [
        WorkflowField(
          name: 'password',
          label: 'كلمة المرور الجديدة',
          type: WorkflowFieldType.password,
          required: true,
        ),
        WorkflowField(
          name: 'confirmPassword',
          label: 'تأكيد كلمة المرور',
          type: WorkflowFieldType.password,
          required: true,
        ),
      ],
      body: (values, controller) => {'password': values['password']},
    );
  }
  if (feature.path.endsWith('/cashier-shifts') &&
      status == 'OPEN' &&
      controller.can('finance.cash-shifts.manage')) {
    final expectedMinor =
        double.tryParse('${row['expectedClosingMinor'] ?? 0}') ?? 0;
    return MobileWorkflow(
      operationId: 'closeCashierShift:$id',
      title: 'إغلاق وردية الصندوق',
      description: 'سجل الرصيد النقدي الفعلي. سيحسب النظام الرصيد المتوقع والفرق ويحفظهما للمراجعة.',
      submitLabel: 'إغلاق الوردية',
      successMessage: 'تم إغلاق الوردية وتسجيل فرق الصندوق.',
      method: 'POST',
      path: '/organizations/{organizationId}/cashier-shifts/$id/closures',
      icon: Icons.lock_outline_rounded,
      fields: [
        WorkflowField(
          name: 'actualClosing',
          label: 'الرصيد الفعلي عند الإغلاق (ر.س)',
          type: WorkflowFieldType.number,
          required: true,
          allowZero: true,
          initialValue: (expectedMinor / 100).toStringAsFixed(2),
        ),
        const WorkflowField(
          name: 'reason',
          label: 'ملاحظة الإغلاق',
          type: WorkflowFieldType.textarea,
          required: true,
          initialValue: 'إغلاق الوردية بعد مطابقة النقدية',
        ),
      ],
      body: (values, controller) => {
        'branchId': row['branchId'] ?? controller.branchId,
        'actualClosingMinor': _moneyMinor(values['actualClosing']),
        'reason': values['reason']?.trim(),
      },
    );
  }
  if (feature.path.endsWith('/crm/leads') &&
      !const {'CONVERTED', 'LOST', 'DISQUALIFIED'}.contains(status) &&
      controller.can('crm.follow-ups.manage')) {
    final next = DateTime.now().add(const Duration(days: 1));
    return MobileWorkflow(
      operationId: 'scheduleLeadFollowUp:$id',
      title: 'جدولة متابعة العميل',
      description: 'حدد الموظف وطريقة وموعد التواصل لتظهر المتابعة في جدول فريق المبيعات.',
      submitLabel: 'حفظ موعد المتابعة',
      successMessage: 'تمت جدولة متابعة العميل.',
      method: 'POST',
      path: '/organizations/{organizationId}/crm/leads/$id/follow-ups',
      icon: Icons.calendar_month_outlined,
      fields: [
        const WorkflowField(
          name: 'assignedToUserAccountId',
          label: 'الموظف المسؤول',
          type: WorkflowFieldType.reference,
          required: true,
          referencePath: '/organizations/{organizationId}/user-accounts?ownerType=EMPLOYEE&limit=500',
          labelKeys: ['displayName', 'name'],
          subtitleKeys: ['employeeNumber', 'email'],
        ),
        const WorkflowField(
          name: 'channel',
          label: 'طريقة التواصل',
          type: WorkflowFieldType.select,
          required: true,
          initialValue: 'CALL',
          choices: [
            WorkflowChoice('CALL', 'مكالمة'),
            WorkflowChoice('WHATSAPP', 'واتساب'),
            WorkflowChoice('SMS', 'رسالة SMS'),
            WorkflowChoice('EMAIL', 'بريد إلكتروني'),
            WorkflowChoice('VISIT', 'زيارة'),
            WorkflowChoice('OTHER', 'أخرى'),
          ],
        ),
        WorkflowField(
          name: 'scheduledAt',
          label: 'موعد المتابعة',
          type: WorkflowFieldType.dateTime,
          required: true,
          initialValue: _localDateTimeValue(next),
        ),
        const WorkflowField(
          name: 'subject',
          label: 'عنوان المتابعة',
          required: true,
          initialValue: 'متابعة العميل المحتمل',
        ),
        const WorkflowField(
          name: 'notes',
          label: 'ملاحظات التحضير',
          type: WorkflowFieldType.textarea,
        ),
      ],
      body: (values, controller) => {
        'assignedToUserAccountId': values['assignedToUserAccountId'],
        'channel': values['channel'],
        'scheduledAt': _asIso(values['scheduledAt']),
        'subject': values['subject']?.trim(),
        if (values['notes']?.trim().isNotEmpty == true)
          'notes': values['notes']?.trim(),
      },
    );
  }
  if (feature.path.endsWith('/crm/follow-ups') &&
      status == 'SCHEDULED' &&
      controller.can('crm.follow-ups.manage')) {
    final version = int.tryParse('${row['version'] ?? 1}') ?? 1;
    return MobileWorkflow(
      operationId: 'completeFollowUp:$id',
      title: 'تسجيل نتيجة المتابعة',
      description:
          'اختر نتيجة التواصل وأضف ملخصًا واضحًا ليستفيد منه فريق المبيعات.',
      submitLabel: 'إكمال المتابعة',
      successMessage: 'تم حفظ نتيجة المتابعة.',
      method: 'POST',
      path: '/organizations/{organizationId}/crm/follow-ups/$id/transitions',
      icon: Icons.task_alt_rounded,
      fields: const [
        WorkflowField(
          name: 'outcome',
          label: 'نتيجة التواصل',
          type: WorkflowFieldType.select,
          required: true,
          initialValue: 'INTERESTED',
          choices: [
            WorkflowChoice('INTERESTED', 'مهتم'),
            WorkflowChoice('CALLBACK', 'طلب معاودة الاتصال'),
            WorkflowChoice('NOT_INTERESTED', 'غير مهتم'),
            WorkflowChoice('NO_ANSWER', 'لا يوجد رد'),
            WorkflowChoice('TRIAL_BOOKED', 'حجز تجربة'),
            WorkflowChoice('MEMBERSHIP_SOLD', 'تم بيع عضوية'),
            WorkflowChoice('OTHER', 'نتيجة أخرى'),
          ],
        ),
        WorkflowField(
          name: 'notes',
          label: 'ملخص المتابعة',
          type: WorkflowFieldType.textarea,
        ),
      ],
      body: (values, controller) => {
        'status': 'COMPLETED',
        'outcome': values['outcome'],
        if (values['notes']?.trim().isNotEmpty == true)
          'notes': values['notes']?.trim(),
        'expectedVersion': version,
      },
    );
  }
  if (feature.path.contains('/daily-menus/') &&
      status != 'CLOSED' &&
      controller.can('restaurant.menu.manage')) {
    final version = int.tryParse('${row['version'] ?? 1}') ?? 1;
    final enabledItems = row['items'] is List
        ? (row['items'] as List)
              .whereType<Map>()
              .where((item) => item['enabled'] != false)
              .toList()
        : const <Map>[];
    return MobileWorkflow(
      operationId: 'reviseDailyMenu:$id',
      title: 'تحديث قائمة اليوم',
      description: 'اختر الوجبات التي ستظل ظاهرة للأعضاء. يحتفظ النظام بإصدار القائمة وسجل تعديلها.',
      submitLabel: 'حفظ تحديث القائمة',
      successMessage: 'تم تحديث قائمة اليوم.',
      method: 'PUT',
      path: '/organizations/{organizationId}/branches/{branchId}/daily-menus/{businessDate}',
      icon: Icons.edit_calendar_outlined,
      fields: [
        WorkflowField(
          name: 'mealIds',
          label: 'الوجبات الظاهرة',
          type: WorkflowFieldType.multiReference,
          required: true,
          initialValue: _initialIds(enabledItems),
          referencePath: '/organizations/{organizationId}/restaurant/meals',
          labelKeys: ['name', 'mealName'],
          subtitleKeys: ['categoryName', 'code'],
        ),
      ],
      body: (values, controller) => {
        'expectedVersion': version,
        'items': _selectedValues(values['mealIds'])
            .map((id) => {'mealId': id, 'enabled': true})
            .toList(),
      },
    );
  }
  if (feature.path.endsWith('/payments') &&
      controller.can('finance.refunds.issue')) {
    final amountMinor = double.tryParse('${row['amountMinor'] ?? 0}') ?? 0;
    final refundedMinor = double.tryParse('${row['refundedMinor'] ?? 0}') ?? 0;
    final refundableMinor = max(0.0, amountMinor - refundedMinor);
    final method =
        row['paymentMethodCode']?.toString() ?? row['method']?.toString() ?? '';
    if (refundableMinor > 0 && status != 'REFUNDED') {
      return MobileWorkflow(
        operationId: 'refundPayment:$id',
        title: 'استرجاع دفعة',
        description:
            'أدخل المبلغ المطلوب استرجاعه. المتاح حاليًا ${(refundableMinor / 100).toStringAsFixed(2)} ر.س.',
        submitLabel: 'تنفيذ الاسترجاع',
        successMessage: 'تم تسجيل استرجاع الدفعة.',
        method: 'POST',
        path: '/organizations/{organizationId}/payments/$id/refunds',
        icon: Icons.currency_exchange_rounded,
        fields: [
          WorkflowField(
            name: 'amount',
            label: 'مبلغ الاسترجاع (ر.س)',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: (refundableMinor / 100).toStringAsFixed(2),
          ),
          const WorkflowField(
            name: 'reason',
            label: 'سبب الاسترجاع',
            type: WorkflowFieldType.textarea,
            required: true,
          ),
          if (method == 'CASH')
            const WorkflowField(
              name: 'cashierShiftId',
              label: 'وردية الصندوق المفتوحة',
              type: WorkflowFieldType.reference,
              required: true,
              referencePath: '/organizations/{organizationId}/cashier-shifts?status=OPEN&limit=100',
              labelKeys: ['cashPointName', 'cashierName'],
              subtitleKeys: ['openedAt'],
            ),
        ],
        body: (values, controller) => {
          'amountMinor': _moneyMinor(values['amount']),
          'reason': values['reason']?.trim(),
          if (method == 'CASH') 'cashierShiftId': values['cashierShiftId'],
        },
      );
    }
  }
  if (feature.path.endsWith('/refund-requests') &&
      status == 'APPROVED' &&
      controller.can('finance.refunds.issue')) {
    final version = int.tryParse('${row['version'] ?? 0}') ?? 0;
    final payments =
        (row['payments'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
    final hasCash = payments.any(
      (payment) => payment['method']?.toString() == 'CASH',
    );
    return MobileWorkflow(
      operationId: 'fulfillRefundRequest:$id',
      title: 'تنفيذ طلب الاسترداد',
      description: 'سيُوزع المبلغ المعتمد تلقائيًا على الدفعات الأصلية ويصدر إشعار دائن مرتبط بالفاتورة.',
      submitLabel: 'تنفيذ الاسترداد',
      successMessage: 'تم تنفيذ الاسترداد وإصدار الإشعار الدائن.',
      method: 'POST',
      path: '/organizations/{organizationId}/refund-requests/$id/fulfillments',
      icon: Icons.assignment_return_outlined,
      fields: [
        if (hasCash)
          const WorkflowField(
            name: 'cashierShiftId',
            label: 'وردية الصندوق المفتوحة للاسترجاع النقدي',
            type: WorkflowFieldType.reference,
            required: true,
            referencePath: '/organizations/{organizationId}/cashier-shifts?status=OPEN&limit=100',
            labelKeys: ['cashPointName', 'cashierName'],
            subtitleKeys: ['openedAt'],
          ),
      ],
      body: (values, controller) {
        var remaining =
            int.tryParse('${row['requestedAmountMinor'] ?? 0}') ?? 0;
        final allocations = <Map<String, dynamic>>[];
        for (final payment in payments) {
          if (remaining <= 0) break;
          final capacity =
              int.tryParse('${payment['refundableMinor'] ?? 0}') ?? 0;
          final amount = min(capacity, remaining);
          if (amount <= 0) continue;
          allocations.add({
            'paymentId': payment['id']?.toString(),
            'amountMinor': '$amount',
            if (payment['method']?.toString() == 'CASH')
              'cashierShiftId': values['cashierShiftId'],
          });
          remaining -= amount;
        }
        return {'expectedVersion': version, 'allocations': allocations};
      },
    );
  }
  if (feature.path.endsWith('/lockers') &&
      status == 'AVAILABLE' &&
      controller.can('lockers.manage')) {
    return MobileWorkflow(
      operationId: 'assignLocker:$id',
      title: 'تخصيص الخزانة لعضو',
      description: 'اختر العضو ومدة الاستخدام والعربون. ستتحول الخزانة تلقائيًا إلى مستخدمة.',
      submitLabel: 'تخصيص الخزانة',
      successMessage: 'تم تخصيص الخزانة للعضو.',
      method: 'POST',
      path: '/organizations/{organizationId}/locker-assignments',
      icon: Icons.how_to_reg_outlined,
      fields: [
        const WorkflowField(
          name: 'memberId',
          label: 'العضو',
          type: WorkflowFieldType.reference,
          required: true,
          referencePath: '/organizations/{organizationId}/members',
          labelKeys: ['name', 'fullNameAr'],
          subtitleKeys: ['memberNumber'],
        ),
        WorkflowField(
          name: 'startsAt',
          label: 'بداية الاستخدام',
          type: WorkflowFieldType.dateTime,
          required: true,
        ),
        const WorkflowField(
          name: 'endsAt',
          label: 'نهاية الاستخدام (اختياري)',
          type: WorkflowFieldType.dateTime,
          autoFillDate: false,
        ),
        const WorkflowField(
          name: 'deposit',
          label: 'العربون (ر.س)',
          type: WorkflowFieldType.number,
          required: true,
          initialValue: '0',
          allowZero: true,
        ),
      ],
      body: (values, controller) => {
        'branchId': row['branchId'] ?? controller.branchId,
        'lockerId': id,
        'memberId': values['memberId'],
        'startsAt': _asIso(values['startsAt']),
        if (values['endsAt']?.isNotEmpty == true)
          'endsAt': _asIso(values['endsAt']),
        'depositMinor': _moneyMinor(values['deposit']),
      },
    );
  }
  return null;
}

typedef _RecordActionBody = Map<String, dynamic> Function(
  String reason,
  int days,
);

class _RecordAction {
  const _RecordAction({
    required this.label,
    required this.icon,
    required this.path,
    required this.body,
    this.permission,
    this.requiresReason = false,
    this.requiresDays = false,
    this.destructive = false,
    this.method = 'POST',
  });
  final String label;
  final IconData icon;
  final String path;
  final String? permission;
  final bool requiresReason;
  final bool requiresDays;
  final bool destructive;
  final String method;
  final _RecordActionBody body;
}

String _rowId(Map<String, dynamic> row, List<String> keys) => keys
    .map((key) => row[key]?.toString() ?? '')
    .firstWhere((value) => value.isNotEmpty, orElse: () => '');

bool _selfRenewalAllowed(Map<String, dynamic> row) {
  if (row['cancellationRequest'] != null) return false;
  final schedules = row['freezeSchedules'];
  if (schedules is List &&
      schedules.whereType<Map>().any(
        (schedule) => schedule['status']?.toString() == 'PENDING',
      )) {
    return false;
  }
  final snapshot = row['policySnapshot'];
  if (snapshot is! Map || snapshot['policies'] is! List) return false;
  final renewal = (snapshot['policies'] as List)
      .whereType<Map>()
      .where((policy) => policy['policyType']?.toString() == 'RENEWAL')
      .firstOrNull;
  final configuration = renewal?['configuration'];
  if (configuration is! Map) return false;
  final graceDays = int.tryParse('${configuration['graceDays'] ?? ''}');
  final termEnd = DateTime.tryParse(row['termEnd']?.toString() ?? '');
  if (graceDays == null || graceDays < 0 || termEnd == null) return false;
  return !DateTime.now().isAfter(termEnd.add(Duration(days: graceDays)));
}

List<_RecordAction> _recordActions(
  GoController controller,
  ResourceFeature feature,
  Map<String, dynamic> row,
) {
  final path = feature.path;
  final version = int.tryParse('${row['version'] ?? 1}') ?? 1;
  final status = row['status']?.toString() ?? '';
  final organization = controller.organizationId;
  final actions = <_RecordAction>[];
  void add(_RecordAction action) {
    if (action.permission == null || controller.can(action.permission!)) {
      actions.add(action);
    }
  }

  if (!path.startsWith('/self/') && path.endsWith('/subscriptions')) {
    final id = _rowId(row, ['id', 'subscriptionId']);
    final schedules = row['freezeSchedules'] is List
        ? (row['freezeSchedules'] as List).whereType<Map>()
        : const Iterable<Map>.empty();
    final pendingSchedule = schedules
        .where((item) => item['status']?.toString() == 'PENDING')
        .firstOrNull;
    if (id.isNotEmpty && pendingSchedule != null) {
      final scheduleId = pendingSchedule['id']?.toString() ?? '';
      if (scheduleId.isNotEmpty) {
        add(
          _RecordAction(
            label: 'إلغاء التجميد المجدول',
            icon: Icons.event_busy_outlined,
            path:
                '/organizations/$organization/subscriptions/$id/freeze-schedules/$scheduleId/cancellations',
            permission: 'subscriptions.freeze',
            requiresReason: true,
            destructive: true,
            body: (reason, _) => {'expectedVersion': version, 'reason': reason},
          ),
        );
      }
    }
    if (id.isNotEmpty && status == 'ACTIVE') {
      add(
        _RecordAction(
          label: 'تجميد الاشتراك',
          icon: Icons.pause_circle_outline,
          path: '/organizations/$organization/subscriptions/$id/freezes',
          permission: 'subscriptions.freeze',
          requiresReason: true,
          requiresDays: true,
          body: (reason, days) => {
            'expectedVersion': version,
            'requestedDays': days,
            'reason': reason,
          },
        ),
      );
    }
    if (id.isNotEmpty && status == 'FROZEN') {
      add(
        _RecordAction(
          label: 'استئناف الاشتراك',
          icon: Icons.play_circle_outline,
          path: '/organizations/$organization/subscriptions/$id/resumptions',
          permission: 'subscriptions.freeze',
          body: (_, _) => {'expectedVersion': version},
        ),
      );
    }
    if (id.isNotEmpty && !const {'CANCELLED', 'EXPIRED'}.contains(status)) {
      add(
        _RecordAction(
          label: 'إضافة أيام للاشتراك',
          icon: Icons.more_time_rounded,
          path: '/organizations/$organization/subscriptions/$id/adjustments',
          permission: 'subscriptions.adjustments.manage',
          requiresReason: true,
          requiresDays: true,
          body: (reason, value) => {
            'expectedVersion': version,
            'type': 'EXTEND_DAYS',
            'value': value,
            'reason': reason,
          },
        ),
      );
      if (row['visitAllowance'] != null) {
        add(
          _RecordAction(
            label: 'إضافة زيارات للاشتراك',
            icon: Icons.add_task_rounded,
            path: '/organizations/$organization/subscriptions/$id/adjustments',
            permission: 'subscriptions.adjustments.manage',
            requiresReason: true,
            requiresDays: true,
            body: (reason, value) => {
              'expectedVersion': version,
              'type': 'ADD_VISITS',
              'value': value,
              'reason': reason,
            },
          ),
        );
      }
      add(
        _RecordAction(
          label: 'إلغاء الاشتراك',
          icon: Icons.cancel_outlined,
          path: '/organizations/$organization/subscriptions/$id/cancellations',
          permission: 'subscriptions.cancel',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'expectedVersion': version, 'reason': reason},
        ),
      );
    }
  }

  if (path.contains('/members/{memberId}/subscriptions')) {
    final id = _rowId(row, ['id', 'subscriptionId']);
    final base =
        '/self/organizations/$organization/members/${controller.selectedMemberId}/subscriptions/$id';
    if (id.isNotEmpty && status == 'FROZEN') {
      add(
        _RecordAction(
          label: 'استئناف الاشتراك',
          icon: Icons.play_circle_outline,
          path: '$base/resumptions',
          body: (_, _) => {'expectedVersion': version},
        ),
      );
    }
    if (id.isNotEmpty && !const {'CANCELLED', 'EXPIRED'}.contains(status)) {
      add(
        _RecordAction(
          label: 'إلغاء الاشتراك',
          icon: Icons.cancel_outlined,
          path: '$base/cancellations',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'expectedVersion': version, 'reason': reason},
        ),
      );
    }
    final packageId = row['packageId']?.toString() ?? '';
    if (id.isNotEmpty && packageId.isNotEmpty && _selfRenewalAllowed(row)) {
      add(
        _RecordAction(
          label: 'تجديد الاشتراك',
          icon: Icons.autorenew_rounded,
          path:
              '/self/organizations/$organization/members/${controller.selectedMemberId}/orders',
          body: (_, _) => {
            'sellingBranchId':
                row['sellingBranchId'] ??
                row['registrationBranchId'] ??
                controller.branchId,
            'lines': [
              {
                'type': 'MEMBERSHIP',
                'targetId': packageId,
                'quantity': 1,
                'renewal': {'subscriptionId': id, 'expectedVersion': version},
              },
            ],
          },
        ),
      );
    }
  }

  if (path.endsWith('/reservations') ||
      path.contains('/members/{memberId}/reservations')) {
    final id = _rowId(row, ['id', 'reservationId']);
    final self = path.startsWith('/self/');
    final base = self
        ? '/self/organizations/$organization/members/${controller.selectedMemberId}/reservations/$id'
        : '/organizations/$organization/reservations/$id';
    if (id.isNotEmpty &&
        !const {'CANCELLED', 'COMPLETED', 'NO_SHOW'}.contains(status)) {
      add(
        _RecordAction(
          label: 'إلغاء الحجز',
          icon: Icons.event_busy_outlined,
          path: '$base/cancellations',
          permission: self ? null : 'bookings.manage',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'expectedVersion': version, 'reason': reason},
        ),
      );
      if (!self && status == 'CONFIRMED') {
        for (final transition in const [
          ('COMPLETE', 'إكمال الحجز', Icons.task_alt_rounded),
          ('NO_SHOW', 'تسجيل عدم حضور', Icons.person_off_outlined),
        ]) {
          add(
            _RecordAction(
              label: transition.$2,
              icon: transition.$3,
              path: '$base/transitions',
              permission: 'bookings.manage',
              body: (_, _) => {
                'expectedVersion': version,
                'action': transition.$1,
              },
            ),
          );
        }
      }
    }
  }

  if (path.endsWith('/restaurant-orders')) {
    final id = _rowId(row, ['id', 'orderId']);
    final action = switch (status) {
      'PENDING' => ('START_PREPARING', 'بدء التحضير'),
      'PREPARING' => ('MARK_READY', 'الطلب جاهز'),
      'READY' => ('COMPLETE', 'تسليم وإكمال الطلب'),
      _ => null,
    };
    if (id.isNotEmpty && action != null) {
      add(
        _RecordAction(
          label: action.$2,
          icon: Icons.restaurant_rounded,
          path:
              '/organizations/$organization/restaurant-orders/$id/transitions',
          permission: 'restaurant.orders.prepare',
          body: (_, _) => {'expectedVersion': version, 'action': action.$1},
        ),
      );
    }
    if (id.isNotEmpty && !const {'COMPLETED', 'CANCELLED'}.contains(status)) {
      add(
        _RecordAction(
          label: 'إلغاء الطلب',
          icon: Icons.cancel_outlined,
          path:
              '/organizations/$organization/restaurant-orders/$id/cancellations',
          permission: 'restaurant.orders.manage',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'expectedVersion': version, 'reason': reason},
        ),
      );
    }
  }

  if (path.endsWith('/crm/leads')) {
    final id = _rowId(row, ['id', 'leadId']);
    if (id.isNotEmpty &&
        !const {'CONVERTED', 'LOST', 'DISQUALIFIED'}.contains(status)) {
      for (final transition in const [
        ('CONTACTED', 'تم التواصل'),
        ('QUALIFIED', 'عميل مؤهل'),
        ('TRIAL_SCHEDULED', 'تم تحديد تجربة'),
        ('LOST', 'فرصة مفقودة'),
      ]) {
        add(
          _RecordAction(
            label: transition.$2,
            icon: Icons.trending_up_rounded,
            path: '/organizations/$organization/crm/leads/$id/transitions',
            permission: 'crm.leads.manage',
            requiresReason: transition.$1 == 'LOST',
            destructive: transition.$1 == 'LOST',
            body: (reason, _) => {
              'status': transition.$1,
              'expectedVersion': version,
              if (reason.isNotEmpty) 'reason': reason,
            },
          ),
        );
      }
    }
  }

  if (path.endsWith('/expenses')) {
    final id = _rowId(row, ['id', 'expenseId']);
    if (id.isEmpty) return actions;
    final transitions = switch (status) {
      'DRAFT' || 'RECORDED' => const [('SUBMIT', 'إرسال للاعتماد')],
      'SUBMITTED' => const [
        ('APPROVE', 'اعتماد المصروف'),
        ('VOID', 'رفض وإلغاء'),
      ],
      'APPROVED' => const [('PAY', 'تسجيل السداد'), ('VOID', 'إلغاء المصروف')],
      _ => const <(String, String)>[],
    };
    for (final transition in transitions) {
      final createdBy = row['createdBy']?.toString() ?? '';
      if (transition.$1 == 'APPROVE' &&
          createdBy.isNotEmpty &&
          createdBy == controller.currentUserAccountId) {
        continue;
      }
      add(
        _RecordAction(
          label: transition.$2,
          icon: Icons.approval_outlined,
          path: '/organizations/$organization/expenses/$id/transitions',
          permission: transition.$1 == 'APPROVE'
              ? 'finance.expenses.approve'
              : transition.$1 == 'PAY'
              ? 'finance.expenses.pay'
              : 'finance.expenses.manage',
          requiresReason: transition.$1 == 'VOID',
          destructive: transition.$1 == 'VOID',
          body: (reason, _) => {
            'branchId': controller.branchId,
            'expectedVersion': version,
            'action': transition.$1,
            if (transition.$1 == 'PAY') 'method': 'BANK_TRANSFER',
            if (reason.isNotEmpty) 'reason': reason,
          },
        ),
      );
    }
  }

  if (path.endsWith('/online-requests')) {
    final id = _rowId(row, ['id', 'requestId']);
    if (id.isNotEmpty &&
        !const {'APPROVED', 'REJECTED', 'CANCELLED'}.contains(status)) {
      for (final transition in const [
        ('APPROVED', 'اعتماد الطلب'),
        ('REJECTED', 'رفض الطلب'),
      ]) {
        add(
          _RecordAction(
            label: transition.$2,
            icon: transition.$1 == 'APPROVED'
                ? Icons.check_circle_outline
                : Icons.cancel_outlined,
            path:
                '/organizations/$organization/online-requests/$id/transitions',
            permission: 'online-requests.manage',
            requiresReason: transition.$1 == 'REJECTED',
            destructive: transition.$1 == 'REJECTED',
            body: (reason, _) => {
              'branchId': controller.branchId,
              'status': transition.$1,
              'expectedVersion': version,
              if (reason.isNotEmpty) 'reason': reason,
            },
          ),
        );
      }
    }
  }

  if (path.endsWith('/refund-requests') && status == 'REQUESTED') {
    final id = _rowId(row, ['id', 'requestId']);
    for (final review in const [
      ('APPROVE', 'اعتماد طلب الاسترداد'),
      ('REJECT', 'رفض طلب الاسترداد'),
    ]) {
      if (id.isEmpty) continue;
      add(
        _RecordAction(
          label: review.$2,
          icon: review.$1 == 'APPROVE'
              ? Icons.verified_outlined
              : Icons.cancel_outlined,
          path: '/organizations/$organization/refund-requests/$id/reviews',
          permission: 'finance.refunds.approve',
          requiresReason: true,
          destructive: review.$1 == 'REJECT',
          body: (reason, _) => {
            'expectedVersion': version,
            'decision': review.$1,
            'reason': reason,
          },
        ),
      );
    }
  }

  if (path.endsWith('/packages')) {
    final id = _rowId(row, ['id', 'packageId']);
    if (id.isNotEmpty && status == 'DRAFT') {
      add(
        _RecordAction(
          label: 'نشر الباقة للبيع',
          icon: Icons.publish_rounded,
          path: '/organizations/$organization/packages/$id/publications',
          permission: 'commercial.manage',
          body: (_, _) => {'expectedVersion': version},
        ),
      );
    }
  }

  if (path.endsWith('/commercial-policies') && status == 'ACTIVE') {
    final id = _rowId(row, ['id', 'policyId']);
    if (id.isNotEmpty) {
      add(
        _RecordAction(
          label: 'أرشفة إصدار السياسة',
          icon: Icons.archive_outlined,
          path: '/organizations/$organization/commercial-policies/$id',
          permission: 'policies.manage',
          destructive: true,
          method: 'PATCH',
          body: (_, _) => {'status': 'INACTIVE'},
        ),
      );
    }
  }

  if (path.endsWith('/communication-campaigns')) {
    final id = _rowId(row, ['id', 'campaignId']);
    if (id.isNotEmpty && status == 'SCHEDULED') {
      add(
        _RecordAction(
          label: 'إلغاء جدولة الرسالة',
          icon: Icons.event_busy_outlined,
          path:
              '/organizations/$organization/communication-campaigns/$id/cancellations',
          permission: 'notifications.send',
          destructive: true,
          body: (_, _) => {
            if (row['branchId'] != null) 'branchId': row['branchId'],
            'expectedVersion': version,
          },
        ),
      );
    }
  }

  if (path.endsWith('/role-assignments')) {
    final id = _rowId(row, ['id', 'assignmentId']);
    if (id.isNotEmpty && row['revokedAt'] == null && status != 'REVOKED') {
      add(
        _RecordAction(
          label: 'إلغاء مجموعة الصلاحيات',
          icon: Icons.person_remove_alt_1_outlined,
          path: '/organizations/$organization/role-assignments/$id/revocations',
          permission: 'iam.assignments.manage',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'expectedVersion': version, 'reason': reason},
        ),
      );
    }
  }

  if (path.endsWith('/roles') && status == 'ACTIVE') {
    final id = _rowId(row, ['id', 'roleId']);
    if (id.isNotEmpty) {
      add(
        _RecordAction(
          label: 'أرشفة مجموعة الصلاحيات',
          icon: Icons.archive_outlined,
          path: '/organizations/$organization/roles/$id/status',
          permission: 'iam.roles.manage',
          destructive: true,
          method: 'PATCH',
          body: (_, _) => {'status': 'INACTIVE', 'expectedVersion': version},
        ),
      );
    }
  }

  if (path.endsWith('/access-credentials')) {
    final id = _rowId(row, ['id', 'credentialId']);
    if (id.isNotEmpty && status == 'ACTIVE') {
      add(
        _RecordAction(
          label: 'إلغاء وسيلة الدخول',
          icon: Icons.key_off_outlined,
          path:
              '/organizations/$organization/access-credentials/$id/revocations',
          permission: 'access-credentials.manage',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {'reason': reason},
        ),
      );
    }
  }

  if (path.endsWith('/other-income')) {
    final id = _rowId(row, ['id', 'incomeId']);
    if (id.isNotEmpty && !const {'VOID', 'VOIDED'}.contains(status)) {
      add(
        _RecordAction(
          label: 'إلغاء قيد الإيراد',
          icon: Icons.money_off_csred_outlined,
          path: '/organizations/$organization/other-income/$id/voids',
          permission: 'finance.other-income.manage',
          requiresReason: true,
          destructive: true,
          body: (reason, _) => {
            'branchId': row['branchId'] ?? controller.branchId,
            'reason': reason,
            'expectedVersion': version,
          },
        ),
      );
    }
  }

  if (path.endsWith('/trainer-commissions')) {
    final id = _rowId(row, ['id', 'commissionId']);
    final nextStatuses = switch (status) {
      'ACCRUED' => const [
        ('APPROVED', 'اعتماد العمولة'),
        ('VOIDED', 'إلغاء العمولة'),
      ],
      'APPROVED' => const [
        ('PAID', 'تسجيل صرف العمولة'),
        ('VOIDED', 'إلغاء العمولة'),
      ],
      _ => const <(String, String)>[],
    };
    for (final transition in nextStatuses) {
      add(
        _RecordAction(
          label: transition.$2,
          icon: transition.$1 == 'PAID'
              ? Icons.paid_outlined
              : transition.$1 == 'APPROVED'
              ? Icons.verified_outlined
              : Icons.cancel_outlined,
          path:
              '/organizations/$organization/trainer-commissions/$id/transitions',
          permission: 'coaching.commissions.manage',
          destructive: transition.$1 == 'VOIDED',
          body: (_, _) => {
            'branchId': row['branchId'] ?? controller.branchId,
            'expectedStatus': status,
            'status': transition.$1,
          },
        ),
      );
    }
  }

  if (path.endsWith('/lockers')) {
    final id = _rowId(row, ['id', 'lockerId']);
    for (final transition in const [
      ('AVAILABLE', 'إتاحة الخزانة'),
      ('MAINTENANCE', 'تحويل للصيانة'),
      ('INACTIVE', 'إيقاف الخزانة'),
    ]) {
      if (id.isEmpty || status == transition.$1) continue;
      add(
        _RecordAction(
          label: transition.$2,
          icon: transition.$1 == 'AVAILABLE'
              ? Icons.lock_open_outlined
              : transition.$1 == 'MAINTENANCE'
              ? Icons.build_outlined
              : Icons.block_outlined,
          path: '/organizations/$organization/lockers/$id/transitions',
          permission: 'lockers.manage',
          destructive: transition.$1 == 'INACTIVE',
          body: (_, _) => {
            'branchId': row['branchId'] ?? controller.branchId,
            'status': transition.$1,
            'expectedVersion': version,
          },
        ),
      );
    }
  }

  if (path.endsWith('/crm/follow-ups')) {
    final id = _rowId(row, ['id', 'followUpId']);
    if (id.isNotEmpty && status == 'SCHEDULED') {
      for (final transition in const [
        ('MISSED', 'تسجيل عدم الرد'),
        ('CANCELLED', 'إلغاء المتابعة'),
      ]) {
        add(
          _RecordAction(
            label: transition.$2,
            icon: transition.$1 == 'MISSED'
                ? Icons.phone_missed_outlined
                : Icons.event_busy_outlined,
            path: '/organizations/$organization/crm/follow-ups/$id/transitions',
            permission: 'crm.follow-ups.manage',
            destructive: transition.$1 == 'CANCELLED',
            body: (_, _) => {
              'status': transition.$1,
              'expectedVersion': version,
            },
          ),
        );
      }
    }
  }

  if (path.endsWith('/employee-shifts')) {
    final id = _rowId(row, ['id', 'shiftId']);
    final nextStatuses = switch (status) {
      'SCHEDULED' => const [
        ('IN_PROGRESS', 'بدء المناوبة'),
        ('CANCELLED', 'إلغاء المناوبة'),
      ],
      'IN_PROGRESS' => const [
        ('COMPLETED', 'إنهاء المناوبة'),
        ('CANCELLED', 'إلغاء المناوبة'),
      ],
      _ => const <(String, String)>[],
    };
    for (final transition in nextStatuses) {
      if (id.isEmpty) continue;
      add(
        _RecordAction(
          label: transition.$2,
          icon: transition.$1 == 'IN_PROGRESS'
              ? Icons.play_circle_outline
              : transition.$1 == 'COMPLETED'
              ? Icons.task_alt_outlined
              : Icons.event_busy_outlined,
          path: '/organizations/$organization/employee-shifts/$id/transitions',
          permission: 'workforce.shifts.manage',
          destructive: transition.$1 == 'CANCELLED',
          body: (_, _) => {
            'branchId': row['branchId'] ?? controller.branchId,
            'status': transition.$1,
            'expectedVersion': version,
          },
        ),
      );
    }
  }

  if (path.endsWith('/whatsapp-campaigns')) {
    final id = _rowId(row, ['id', 'campaignId']);
    if (id.isNotEmpty && status == 'DRAFT') {
      add(
        _RecordAction(
          label: 'وضع الحملة في طابور الإرسال',
          icon: Icons.outbox_outlined,
          path: '/organizations/$organization/whatsapp-campaigns/$id/queue',
          permission: 'notifications.whatsapp.manage',
          body: (_, _) => {
            if (row['branchId'] != null) 'branchId': row['branchId'],
            'expectedVersion': version,
          },
        ),
      );
    }
  }

  if (path.endsWith('/member-training-plans')) {
    final id = _rowId(row, ['id', 'planId']);
    final nextStatuses = switch (status) {
      'DRAFT' => const [
        ('ACTIVE', 'تفعيل الخطة'),
        ('CANCELLED', 'إلغاء الخطة'),
      ],
      'ACTIVE' => const [
        ('COMPLETED', 'إكمال الخطة'),
        ('CANCELLED', 'إلغاء الخطة'),
      ],
      _ => const <(String, String)>[],
    };
    for (final transition in nextStatuses) {
      if (id.isEmpty) continue;
      add(
        _RecordAction(
          label: transition.$2,
          icon: transition.$1 == 'ACTIVE'
              ? Icons.play_circle_outline
              : transition.$1 == 'COMPLETED'
              ? Icons.task_alt_outlined
              : Icons.cancel_outlined,
          path:
              '/organizations/$organization/member-training-plans/$id/transitions',
          permission: 'coaching.training-plans.manage',
          destructive: transition.$1 == 'CANCELLED',
          body: (_, _) => {'status': transition.$1, 'expectedVersion': version},
        ),
      );
    }
  }

  if (path.contains('/daily-menus/')) {
    final businessDate = row['businessDate']?.toString().isNotEmpty == true
        ? row['businessDate'].toString()
        : riyadhBusinessDate();
    final action = switch (status) {
      'DRAFT' => ('publications', 'نشر القائمة للأعضاء'),
      'PUBLISHED' => ('closures', 'إغلاق قائمة اليوم'),
      _ => null,
    };
    if (action != null) {
      add(
        _RecordAction(
          label: action.$2,
          icon: status == 'DRAFT'
              ? Icons.publish_outlined
              : Icons.visibility_off_outlined,
          path:
              '/organizations/$organization/branches/${controller.branchId}/daily-menus/$businessDate/${action.$1}',
          permission: 'restaurant.menu.manage',
          destructive: status == 'PUBLISHED',
          body: (_, _) => {'expectedVersion': version},
        ),
      );
    }
  }

  if (path.endsWith('/lockers')) {
    final assignmentId = _rowId(row, ['assignmentId']);
    if (assignmentId.isNotEmpty && status == 'ASSIGNED') {
      add(
        _RecordAction(
          label: 'إنهاء تخصيص الخزانة',
          icon: Icons.person_remove_outlined,
          path:
              '/organizations/$organization/locker-assignments/$assignmentId/releases',
          permission: 'lockers.manage',
          requiresReason: true,
          body: (reason, _) => {
            'branchId': row['branchId'] ?? controller.branchId,
            'reason': reason,
          },
        ),
      );
    }
  }
  return actions;
}

class RecordActionsPage extends StatefulWidget {
  const RecordActionsPage({
    super.key,
    required this.controller,
    required this.feature,
    required this.row,
    required this.onChanged,
  });
  final GoController controller;
  final ResourceFeature feature;
  final Map<String, dynamic> row;
  final Future<void> Function() onChanged;

  @override
  State<RecordActionsPage> createState() => _RecordActionsPageState();
}

class _RecordActionsPageState extends State<RecordActionsPage> {
  final reason = TextEditingController();
  final days = TextEditingController(text: '7');
  bool saving = false;
  String? error;

  @override
  void dispose() {
    reason.dispose();
    days.dispose();
    super.dispose();
  }

  Future<void> execute(_RecordAction action) async {
    if (action.requiresReason && reason.text.trim().length < 3) {
      setState(() => error = 'اكتب سببًا واضحًا من 3 أحرف على الأقل.');
      return;
    }
    final requestedDays = int.tryParse(days.text) ?? 0;
    if (action.requiresDays && requestedDays < 1) {
      setState(() => error = 'أدخل عدد أيام صحيحًا.');
      return;
    }
    Map<String, dynamic>? cancellationPreview;
    Map<String, dynamic>? renewalQuote;
    if (action.label == 'تجديد الاشتراك') {
      setState(() {
        saving = true;
        error = null;
      });
      try {
        final data = await widget.controller.api.request(
          '/self/organizations/${widget.controller.organizationId}/quotes',
          method: 'POST',
          body: {
            'branchId':
                widget.row['sellingBranchId'] ??
                widget.row['registrationBranchId'] ??
                widget.controller.branchId,
            'targetType': 'PACKAGE',
            'targetId': widget.row['packageId'],
            'quantity': 1,
            'memberId': widget.controller.selectedMemberId,
          },
        );
        renewalQuote = data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
      } catch (exception) {
        setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    if (action.path.contains('/subscriptions/') &&
        !action.path.contains('/freeze-schedules/') &&
        action.path.endsWith('/cancellations')) {
      setState(() {
        saving = true;
        error = null;
      });
      try {
        final data = await widget.controller.api.request(
          action.path.replaceFirst(
            RegExp(r'/cancellations$'),
            '/cancellation-preview',
          ),
        );
        cancellationPreview = data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
        if (cancellationPreview['allowed'] == false) {
          setState(
            () => error =
                cancellationPreview?['blockingReason']?.toString() ??
                'إلغاء الاشتراك غير متاح وفق سياسة الباقة.',
          );
          return;
        }
      } catch (exception) {
        setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action.label),
        content: cancellationPreview != null
            ? _SubscriptionCancellationPreview(preview: cancellationPreview)
            : renewalQuote != null
            ? _RenewalQuotePreview(quote: renewalQuote, row: widget.row)
            : Text(
                action.destructive
                    ? 'هذا الإجراء يغيّر حالة السجل وقد يؤثر في العمليات المرتبطة. هل تريد المتابعة؟'
                    : 'سيتم تنفيذ الإجراء على بيانات الإنتاج. هل تريد المتابعة؟',
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تنفيذ'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.api.request(
        action.path,
        method: action.method,
        body: action.body(reason.text.trim(), requestedDays),
      );
      await widget.onChanged();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('تم تنفيذ: ${action.label}')));
        Navigator.pop(context);
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = _recordActions(
      widget.controller,
      widget.feature,
      widget.row,
    );
    final needsReason = actions.any((action) => action.requiresReason);
    final needsDays = actions.any((action) => action.requiresDays);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'إجراءات السجل',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text(
            widget.feature.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          if (needsDays)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: days,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'العدد المطلوب (أيام أو زيارات)',
                  prefixIcon: Icon(Icons.date_range_outlined),
                ),
              ),
            ),
          if (needsReason)
            TextField(
              controller: reason,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'السبب عند الحاجة',
                alignLabelWithHint: true,
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 12),
          ...actions.map(
            (action) => Card(
              child: ListTile(
                enabled: !saving,
                onTap: saving ? null : () => unawaited(execute(action)),
                leading: Icon(
                  action.icon,
                  color: action.destructive ? Colors.red : Colors.amber[800],
                ),
                title: Text(
                  action.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                trailing: const Icon(Icons.chevron_left_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionCancellationPreview extends StatelessWidget {
  const _SubscriptionCancellationPreview({required this.preview});
  final Map<String, dynamic> preview;

  @override
  Widget build(BuildContext context) {
    final immediate = preview['mode'] == 'IMMEDIATE_PRORATED';
    final calculation = preview['calculation'] is Map
        ? Map<String, dynamic>.from(preview['calculation'] as Map)
        : <String, dynamic>{};
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            immediate
                ? 'سيتوقف الاشتراك فورًا، ويُرسل الاسترداد المتوقع إلى الإدارة المالية للاعتماد.'
                : 'سيظل الاشتراك متاحًا حتى ${_displayValue('effectiveAt', preview['effectiveAt'])} ثم يُلغى تلقائيًا.',
            style: const TextStyle(height: 1.55),
          ),
          if (immediate) ...[
            const SizedBox(height: 14),
            _previewLine(
              'المتبقي قبل الرسوم',
              calculation['proratedGrossMinor'],
            ),
            _previewLine('رسوم الإلغاء', calculation['feeMinor']),
            _previewLine(
              'الاسترداد المتوقع',
              calculation['eligibleRefundMinor'],
              emphasized: true,
            ),
            _previewLine(
              'الضريبة ضمن الاسترداد',
              calculation['estimatedTaxMinor'],
            ),
          ],
        ],
      ),
    );
  }

  Widget _previewLine(
    String label,
    dynamic amount, {
    bool emphasized = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Text(
          _money(amount ?? 0),
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: emphasized ? Colors.green[700] : null,
          ),
        ),
      ],
    ),
  );
}

class _RenewalQuotePreview extends StatelessWidget {
  const _RenewalQuotePreview({required this.quote, required this.row});
  final Map<String, dynamic> quote;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          quote['targetName']?.toString() ??
              row['packageName']?.toString() ??
              'تجديد الاشتراك',
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        const SizedBox(height: 8),
        const Text(
          'سيُنشأ طلب وفاتورة مستقلة بالسعر والسياسات الحالية، ويبدأ التجديد بعد نهاية المدة الحالية دون فقد الأيام المتبقية.',
          style: TextStyle(height: 1.55, fontSize: 12),
        ),
        const SizedBox(height: 14),
        _line('السعر قبل الخصم', quote['baseAmountMinor']),
        if ((num.tryParse('${quote['discountMinor'] ?? 0}') ?? 0) > 0)
          _line('الخصم', quote['discountMinor']),
        _line('الصافي قبل الضريبة', quote['netMinor']),
        _line('الضريبة', quote['taxMinor']),
        const Divider(),
        _line('الإجمالي المطلوب', quote['grossMinor'], emphasized: true),
        _line('موعد البداية', row['termEnd'], date: true),
      ],
    ),
  );

  Widget _line(
    String label,
    dynamic value, {
    bool emphasized = false,
    bool date = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        Text(
          date ? _displayValue('termEnd', value) : _money(value ?? 0),
          style: TextStyle(
            fontWeight: emphasized ? FontWeight.w900 : FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _ResourceMessage extends StatelessWidget {
  const _ResourceMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  final IconData icon;
  final String title, body;
  final Future<void> Function()? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      children: [
        Icon(
          icon,
          size: 44,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: OutlinedButton.icon(
              onPressed: () => unawaited(action!()),
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ),
      ],
    ),
  );
}

String _displayValue(String key, dynamic value) {
  if (value == null) return '';
  if (key.endsWith('Minor')) return _money(value);
  if (key.endsWith('At')) return _relativeTime(value.toString());
  if (key.endsWith('On') ||
      key == 'termStart' ||
      key == 'termEnd' ||
      key == 'businessDate' ||
      key == 'birthDate') {
    final raw = value.toString();
    if (raw.length >= 10) {
      return raw.substring(0, 10).split('-').reversed.join('/');
    }
  }
  final text = value.toString();
  return const {
        'ACTIVE': 'نشط',
        'ACTIVE_PROVISIONAL': 'نشط مؤقتًا',
        'INACTIVE': 'غير نشط',
        'PENDING': 'قيد الانتظار',
        'APPROVED': 'مقبول',
        'REJECTED': 'مرفوض',
        'CANCELLED': 'ملغي',
        'FROZEN': 'مجمّد',
        'EXPIRED': 'منتهي',
        'PAID': 'مدفوع',
        'PARTIALLY_PAID': 'مدفوع جزئيًا',
        'FULFILLED': 'مكتمل',
        'COMPLETED': 'مكتمل',
        'SCHEDULED': 'مجدول',
        'IN_PROGRESS': 'جارٍ التنفيذ',
        'SKIPPED': 'تم التخطي',
        'OPEN': 'مفتوح',
        'CLOSED': 'مغلق',
      }[text] ??
      text;
}

List<Map<String, dynamic>> _demoResourceRows(ResourceFeature feature) =>
    List.generate(
      4,
      (index) => {
        for (final field in feature.fields)
          field.$1: field.$1.endsWith('Minor')
              ? (index + 1) * 24500
              : field.$1 == 'status'
              ? (index == 2 ? 'PENDING' : 'ACTIVE')
              : field.$1.endsWith('At')
              ? DateTime.now()
                    .subtract(Duration(hours: index + 1))
                    .toIso8601String()
              : '${field.$2} ${index + 1}',
      },
    );

ResourceFeature _featureEnding(String ending) =>
    resourceFeatures.firstWhere((feature) => feature.path.endsWith(ending));

List<ResourceFeature> _featuresEnding(Iterable<String> endings) =>
    endings.map(_featureEnding).toList();

class _MobileNavItem {
  const _MobileNavItem({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
}

class _MobileNavSection extends StatelessWidget {
  const _MobileNavSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.items,
    this.initiallyExpanded = false,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final List<_MobileNavItem> items;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        childrenPadding: const EdgeInsets.only(bottom: 8),
        leading: CircleAvatar(
          backgroundColor: goYellow.withValues(alpha: .2),
          child: Icon(icon, color: Colors.amber[800]),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(subtitle, style: const TextStyle(fontSize: 11)),
        ),
        children: [
          Divider(height: 1, color: colors.outlineVariant),
          ...items.indexed.map(
            (entry) => Column(
              children: [
                ListTile(
                  onTap: entry.$2.onTap,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 3,
                  ),
                  leading: Icon(entry.$2.icon, color: colors.onSurfaceVariant),
                  title: Text(
                    entry.$2.title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    entry.$2.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, height: 1.45),
                  ),
                  trailing: const Icon(Icons.chevron_left_rounded),
                ),
                if (entry.$1 < items.length - 1)
                  Divider(height: 1, indent: 58, color: colors.outlineVariant),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CrmMobileWorkspacePage extends StatefulWidget {
  const CrmMobileWorkspacePage({super.key, required this.controller});
  final GoController controller;

  @override
  State<CrmMobileWorkspacePage> createState() => _CrmMobileWorkspacePageState();
}

class _CrmMobileWorkspacePageState extends State<CrmMobileWorkspacePage> {
  Map<String, dynamic> summary = {};
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.controller.api.configured) {
        final now = DateTime.now();
        final data = await widget.controller.api.request(
          '/organizations/${widget.controller.organizationId}/crm/follow-ups/cloud',
          query: {
            'branchId': widget.controller.branchId,
            'from': now
                .subtract(const Duration(days: 30))
                .toUtc()
                .toIso8601String(),
            'to': now.add(const Duration(days: 1)).toUtc().toIso8601String(),
          },
        );
        summary = data is Map && data['summary'] is Map
            ? Map<String, dynamic>.from(data['summary'] as Map)
            : <String, dynamic>{};
      } else {
        summary = const {
          'openLeads': 0,
          'scheduledFollowUps': 0,
          'overdueFollowUps': 0,
          'convertedLeads': 0,
        };
      }
    } catch (exception) {
      error = _errorMessage(exception);
    }
    if (mounted) setState(() => loading = false);
  }

  void openResource(String ending) =>
      _openResource(context, widget.controller, _featureEnding(ending));

  @override
  Widget build(BuildContext context) {
    final sections = [
      if (widget.controller.can('crm.leads.read'))
        (
          'العملاء المحتملون',
          'الملف، المرحلة وسجل المتابعات',
          Icons.person_search_outlined,
          '/crm/leads',
        ),
      if (widget.controller.can('crm.follow-ups.read'))
        (
          'جدول المتابعات',
          'المجدولة والمتأخرة ونتائج التواصل',
          Icons.event_note_outlined,
          '/crm/follow-ups',
        ),
      if (widget.controller.can('crm.leads.read'))
        (
          'مصادر العملاء',
          'قنوات اكتساب العملاء المحتملين',
          Icons.hub_outlined,
          '/crm/lead-sources',
        ),
      if (widget.controller.can('online-requests.read'))
        (
          'طلبات الانضمام',
          'الطلبات الواردة وتحويلها إلى إجراء',
          Icons.mark_email_unread_outlined,
          '/online-requests',
        ),
    ];
    final metrics = [
      (
        'فرص مفتوحة',
        summary['openLeads'],
        Icons.person_search_outlined,
        Colors.blue,
      ),
      (
        'متابعات مجدولة',
        summary['scheduledFollowUps'],
        Icons.calendar_month_outlined,
        Colors.deepPurple,
      ),
      (
        'متابعات متأخرة',
        summary['overdueFollowUps'],
        Icons.schedule_outlined,
        Colors.red,
      ),
      (
        'تحولوا إلى أعضاء',
        summary['convertedLeads'],
        Icons.how_to_reg_outlined,
        Colors.green,
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'العملاء والمتابعات',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          if (widget.controller.can('crm.leads.manage'))
            IconButton(
              tooltip: 'إضافة عميل محتمل',
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: () async {
                final workflow = mobileWorkflows.firstWhere(
                  (item) => item.operationId == 'createCrmLead',
                );
                await _openWorkflow(context, widget.controller, workflow);
                if (mounted) await load();
              },
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              'مساحة موحدة لمسار العميل من أول تواصل حتى التحويل إلى عضو.',
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 16),
            if (loading)
              const LinearProgressIndicator()
            else if (error != null)
              _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل ملخص CRM',
                body: error!,
                action: load,
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: metrics.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: .95,
                ),
                itemBuilder: (_, index) => MetricCard(
                  label: metrics[index].$1,
                  value: '${metrics[index].$2 ?? 0}',
                  icon: metrics[index].$3,
                  color: metrics[index].$4,
                ),
              ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'مسار العمل'),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: sections.indexed.map((entry) {
                  final item = entry.$2;
                  return Column(
                    children: [
                      ListTile(
                        leading: Icon(item.$3),
                        title: Text(
                          item.$1,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(item.$2),
                        trailing: const Icon(Icons.chevron_left_rounded),
                        onTap: () => openResource(item.$4),
                      ),
                      if (entry.$1 < sections.length - 1)
                        const Divider(height: 1),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MorePage extends StatelessWidget {
  const MorePage({super.key, required this.controller});
  final GoController controller;

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  void _resource(BuildContext context, String ending) =>
      _openResource(context, controller, _featureEnding(ending));

  void _hub(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required List<String> endings,
  }) {
    _push(
      context,
      FeatureHubPage(
        controller: controller,
        title: title,
        subtitle: subtitle,
        icon: icon,
        features: _featuresEnding(endings),
      ),
    );
  }

  bool _can(String ending) =>
      _canViewFeature(controller, _featureEnding(ending));

  bool _canAny(Iterable<String> endings) => endings.any(_can);

  @override
  Widget build(BuildContext context) {
    const pos = ['/orders', '/invoices', '/payments', '/cashier-shifts'];
    const finance = [
      '/invoices',
      '/payments',
      '/refunds',
      '/refund-requests',
      '/expenses',
      '/other-income',
      '/trainer-commissions',
      '/trainer-commission-plans',
    ];
    const crm = [
      '/crm/leads',
      '/crm/follow-ups',
      '/crm/lead-sources',
      '/online-requests',
    ];
    const communications = [
      '/notifications',
      '/notification-templates',
      '/whatsapp-campaigns',
      '/communication-templates',
      '/communication-campaigns',
    ];
    const restaurant = [
      '/restaurant-orders',
      '/restaurant/meal-categories',
      '/restaurant/meals',
      '/restaurant/meal-prices',
      '/daily-menus/{businessDate}',
    ];
    const trainer = [
      '/trainers',
      '/coaching-specialties',
      '/measurement-sessions',
      '/measurement-types',
      '/trainer-commissions',
      '/trainer-commission-plans',
      '/training-plan-templates',
      '/member-training-plans',
    ];
    const staff = [
      '/employees',
      '/employee-shifts',
      '/employee-attendance',
      '/positions',
    ];

    final clubItems = <_MobileNavItem>[
      if (controller.can('members.read'))
        _MobileNavItem(
          title: 'الأعضاء',
          subtitle: 'دليل الأعضاء وملفاتهم وحالة عضويتهم',
          icon: Icons.people_alt_outlined,
          onTap: () => controller.setTab(1),
        ),
      if (_can('/subscriptions'))
        _MobileNavItem(
          title: 'الاشتراكات',
          subtitle: 'دورة الاشتراك والتجميد والتجديد',
          icon: Icons.credit_card_outlined,
          onTap: () => _resource(context, '/subscriptions'),
        ),
      if (_can('/attendance-attempts'))
        _MobileNavItem(
          title: 'الحضور والدخول',
          subtitle: 'محاولات الدخول المقبولة والمرفوضة',
          icon: Icons.how_to_reg_outlined,
          onTap: () => _resource(context, '/attendance-attempts'),
        ),
      if (_can('/access-devices') || _can('/access-device-events'))
        _MobileNavItem(
          title: 'البوابات والبصمة',
          subtitle: 'حالة اللوحات وسجل أحداث كل بوابة في مكان واحد',
          icon: Icons.fingerprint_rounded,
          onTap: () =>
              _push(context, AccessControlMobilePage(controller: controller)),
        ),
      if (_can('/reservations'))
        _MobileNavItem(
          title: 'الحجوزات',
          subtitle: 'المواعيد والموارد المحجوزة',
          icon: Icons.calendar_month_outlined,
          onTap: () => _resource(context, '/reservations'),
        ),
      if (_can('/access-credentials'))
        _MobileNavItem(
          title: 'الباركود والطباعة',
          subtitle: 'بطاقات وبيانات الدخول المرتبطة بالأعضاء',
          icon: Icons.qr_code_2_rounded,
          onTap: () => _resource(context, '/access-credentials'),
        ),
      if (_can('/files'))
        _MobileNavItem(
          title: 'الملفات',
          subtitle: 'مرفقات الأعضاء والموظفين الآمنة',
          icon: Icons.folder_copy_outlined,
          onTap: () => _resource(context, '/files'),
        ),
    ];

    final businessItems = <_MobileNavItem>[
      if (_canAny(pos))
        _MobileNavItem(
          title: 'نقطة البيع',
          subtitle: 'الطلبات والفواتير والتحصيل ووردية الصندوق',
          icon: Icons.point_of_sale_outlined,
          onTap: () =>
              _push(context, PointOfSaleMobilePage(controller: controller)),
        ),
      if (_canAny(finance))
        _MobileNavItem(
          title: 'المالية والعمولات',
          subtitle: 'الخزنة والمصروفات والاستردادات وعمولات المدربين',
          icon: Icons.account_balance_wallet_outlined,
          onTap: () => _hub(
            context,
            title: 'المالية والعمولات',
            subtitle: 'رؤية مالية موحدة من الفاتورة حتى المصروف والعمولة.',
            icon: Icons.account_balance_wallet_outlined,
            endings: finance,
          ),
        ),
      if (_can('/cashier-shifts'))
        _MobileNavItem(
          title: 'سجل ورديات الصندوق',
          subtitle: 'مراجعة الورديات المفتوحة والمغلقة',
          icon: Icons.history_rounded,
          onTap: () => _resource(context, '/cashier-shifts'),
        ),
      if (_canAny(crm))
        _MobileNavItem(
          title: 'العملاء والمتابعات',
          subtitle: 'العملاء المحتملون والطلبات والمتابعات القادمة',
          icon: Icons.bolt_outlined,
          onTap: () =>
              _push(context, CrmMobileWorkspacePage(controller: controller)),
        ),
      if (_canAny(communications))
        _MobileNavItem(
          title: 'الرسائل والتواصل',
          subtitle: 'القوالب والحملات وسجل تسليم الرسائل',
          icon: Icons.forum_outlined,
          onTap: () => _hub(
            context,
            title: 'الرسائل والتواصل',
            subtitle: 'إدارة قنوات التواصل والقوالب والحملات.',
            icon: Icons.forum_outlined,
            endings: communications,
          ),
        ),
      if (controller.can('workforce.shifts.read') ||
          controller.can('attendance.read') ||
          controller.can('restaurant.orders.read'))
        _MobileNavItem(
          title: 'مركز العمليات',
          subtitle: 'المناوبات والحضور والطلبات اليومية',
          icon: Icons.assignment_outlined,
          onTap: () => controller.setTab(2),
        ),
      if (_can('/feedback-cases'))
        _MobileNavItem(
          title: 'الشكاوى والاقتراحات',
          subtitle: 'متابعة المحادثات حتى الإغلاق',
          icon: Icons.feedback_outlined,
          onTap: () => _resource(context, '/feedback-cases'),
        ),
      if (_canAny(restaurant))
        _MobileNavItem(
          title: 'المطعم',
          subtitle: 'الطلبات والوجبات والتصنيفات والأسعار',
          icon: Icons.restaurant_outlined,
          onTap: () => _hub(
            context,
            title: 'المطعم',
            subtitle: 'التشغيل اليومي وكتالوج المطعم وأسعاره.',
            icon: Icons.restaurant_outlined,
            endings: restaurant,
          ),
        ),
      if (_canAny(trainer))
        _MobileNavItem(
          title: 'التدريب والمدربون',
          subtitle: 'المدربون والخطط والقياسات والعمولات',
          icon: Icons.fitness_center_outlined,
          onTap: () => _hub(
            context,
            title: 'التدريب والمدربون',
            subtitle: 'إدارة التدريب من التخصص والقياس إلى الخطة والعمولة.',
            icon: Icons.fitness_center_outlined,
            endings: trainer,
          ),
        ),
      if (_canAny(staff))
        _MobileNavItem(
          title: 'الموظفون',
          subtitle: 'الفريق والمناوبات والدوام والمسميات',
          icon: Icons.badge_outlined,
          onTap: () => _hub(
            context,
            title: 'الموظفون',
            subtitle: 'بيانات الفريق وتشغيله اليومي في مكان واحد.',
            icon: Icons.badge_outlined,
            endings: staff,
          ),
        ),
    ];

    final adminItems = <_MobileNavItem>[
      if (controller.can('reporting.read'))
        _MobileNavItem(
          title: 'التقارير',
          subtitle: 'الإيرادات والحضور والاشتراكات وأداء التشغيل',
          icon: Icons.analytics_outlined,
          onTap: () => _push(context, ReportsPage(controller: controller)),
        ),
      if (_can('/audit-records'))
        _MobileNavItem(
          title: 'سجل نشاط النظام',
          subtitle: 'التغييرات والإجراءات المدققة',
          icon: Icons.history_toggle_off_rounded,
          onTap: () => _resource(context, '/audit-records'),
        ),
      if (SystemSettingsPage.hasVisibleSettings(controller))
        _MobileNavItem(
          title: 'إعداد النظام',
          subtitle: 'بيانات النادي والفروع والتسعير والصلاحيات وكل الإعدادات',
          icon: Icons.settings_outlined,
          onTap: () =>
              _push(context, SystemSettingsPage(controller: controller)),
        ),
    ];

    return PageFrame(
      title: 'أقسام النظام',
      subtitle:
          'تنقل منظم مطابق لنسخة الويب، مع إظهار ما تسمح به صلاحياتك فقط.',
      child: Column(
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 14),
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: const CircleAvatar(
                    radius: 25,
                    backgroundColor: goYellow,
                    child: Icon(Icons.person, color: goInk),
                  ),
                  title: Text(
                    controller.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text('${controller.branchName} • حساب موظف'),
                  trailing: IconButton(
                    onPressed: () =>
                        _push(context, AccountPage(controller: controller)),
                    icon: const Icon(Icons.manage_accounts_outlined),
                    tooltip: 'إعدادات حسابي',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  onTap: () => _push(
                    context,
                    EmployeeSelfSpacePage(controller: controller),
                  ),
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text(
                    'مساحة عملي',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text(
                    'مناوباتي وحضوري ومساحة المدرب عند توفرها',
                  ),
                  trailing: const Icon(Icons.chevron_left_rounded),
                ),
              ],
            ),
          ),
          _MobileNavSection(
            title: 'إدارة النادي',
            subtitle: 'الأعضاء والاشتراكات والدخول والحجوزات',
            icon: Icons.apartment_rounded,
            items: clubItems,
            initiallyExpanded: true,
          ),
          _MobileNavSection(
            title: 'الأعمال',
            subtitle: 'البيع والمالية والتشغيل والتواصل',
            icon: Icons.workspaces_outline,
            items: businessItems,
          ),
          _MobileNavSection(
            title: 'الإدارة',
            subtitle: 'التقارير والتدقيق وإعداد النظام',
            icon: Icons.admin_panel_settings_outlined,
            items: adminItems,
          ),
          Card(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  secondary: Icon(
                    controller.darkMode
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                  ),
                  title: const Text(
                    'الوضع الداكن',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text('تبديل مظهر التطبيق وحفظه على الجهاز'),
                  value: controller.darkMode,
                  onChanged: controller.setDarkMode,
                ),
                if (controller.branches.isNotEmpty) const Divider(height: 1),
                if (controller.branches.isNotEmpty) ...[
                  ListTile(
                    onTap: () => _openContextSheet(context, controller),
                    leading: const Icon(Icons.location_on_outlined),
                    title: const Text('تغيير المؤسسة أو الفرع'),
                    subtitle: Text(controller.branchName),
                    trailing: const Icon(Icons.chevron_left_rounded),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<Map<String, dynamic>> _portalRows(dynamic data) {
  final values = data is List
      ? data
      : data is Map && data['items'] is List
      ? data['items'] as List
      : const <dynamic>[];
  return values
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList();
}

class EmployeeSelfSpacePage extends StatefulWidget {
  const EmployeeSelfSpacePage({super.key, required this.controller});
  final GoController controller;

  @override
  State<EmployeeSelfSpacePage> createState() => _EmployeeSelfSpacePageState();
}

class _EmployeeSelfSpacePageState extends State<EmployeeSelfSpacePage> {
  Map<String, dynamic>? employee;
  List<Map<String, dynamic>> shifts = [];
  List<Map<String, dynamic>> attendance = [];
  bool loading = true;
  bool recording = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Map<String, String> get _range {
    final now = DateTime.now().toUtc();
    return {
      'from': now.subtract(const Duration(days: 30)).toIso8601String(),
      'to': now.add(const Duration(days: 30)).toIso8601String(),
    };
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final base =
          '/self/organizations/${widget.controller.organizationId}/employee';
      final profile = await widget.controller.api.request(base);
      employee = profile is Map
          ? Map<String, dynamic>.from(profile)
          : <String, dynamic>{};
      final values = await Future.wait([
        widget.controller.api.request('$base/shifts', query: _range),
        widget.controller.api.request('$base/attendance', query: _range),
      ]);
      shifts = _portalRows(values[0]);
      attendance = _portalRows(values[1]);
    } catch (exception) {
      employee = null;
      shifts = [];
      attendance = [];
      error = exception is ApiFailure && exception.isNotFound
          ? 'لا يوجد ملف موظف مرتبط بحساب الدخول الحالي.'
          : _errorMessage(exception);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> recordAttendance() async {
    final lastEvent = attendance.firstOrNull?['eventType']?.toString();
    final nextEvent = lastEvent == 'CLOCK_IN' ? 'CLOCK_OUT' : 'CLOCK_IN';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          nextEvent == 'CLOCK_IN' ? 'تسجيل الحضور' : 'تسجيل الانصراف',
        ),
        content: Text(
          'سيتم تسجيل الوقت الحالي في ${widget.controller.branchName}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => recording = true);
    try {
      await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/employee/attendance',
        method: 'POST',
        body: {
          'branchId': widget.controller.branchId,
          'eventType': nextEvent,
          'occurredAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextEvent == 'CLOCK_IN'
                ? 'تم تسجيل حضورك بنجاح.'
                : 'تم تسجيل انصرافك بنجاح.',
          ),
        ),
      );
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(exception))));
      }
    } finally {
      if (mounted) setState(() => recording = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lastEvent = attendance.firstOrNull?['eventType']?.toString();
    final nextClockIn = lastEvent != 'CLOCK_IN';
    final name = employee?['name']?.toString() ?? widget.controller.displayName;
    final number = employee?['employeeNumber']?.toString() ?? '';
    final trainer =
        (employee?['trainerProfileId']?.toString() ?? '').isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'مساحة عملي',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : () => unawaited(load()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            if (loading)
              const SizedBox(
                height: 420,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (employee == null)
              _ResourceMessage(
                icon: Icons.badge_outlined,
                title: 'ملف الموظف غير متاح',
                body: error ?? 'تعذر فتح مساحة العمل الشخصية.',
                action: load,
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [goInk, Color(0xFF33332E)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 27,
                      backgroundColor: goYellow,
                      child: Icon(Icons.badge_outlined, color: goInk, size: 29),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          if (number.isNotEmpty)
                            Text(
                              '$number • ${widget.controller.branchName}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: recording
                    ? null
                    : () => unawaited(recordAttendance()),
                icon: recording
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        nextClockIn
                            ? Icons.login_rounded
                            : Icons.logout_rounded,
                      ),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    nextClockIn ? 'تسجيل الحضور الآن' : 'تسجيل الانصراف الآن',
                  ),
                ),
              ),
              if (trainer) ...[
                const SizedBox(height: 9),
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          TrainerSelfSpacePage(controller: widget.controller),
                    ),
                  ),
                  icon: const Icon(Icons.fitness_center_rounded),
                  label: const Text('فتح مساحة المدرب'),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              const SectionHeader(title: 'المناوبات القادمة'),
              const SizedBox(height: 8),
              if (shifts.isEmpty)
                const _CompactEmpty(
                  text: 'لا توجد مناوبات خلال الفترة المحددة.',
                )
              else
                ...shifts
                    .take(8)
                    .map(
                      (row) => _SelfTimelineTile(
                        icon: Icons.calendar_month_outlined,
                        title: row['positionName']?.toString() ?? 'مناوبة عمل',
                        subtitle:
                            '${_displayValue('startsAt', row['startsAt'])} — ${_displayValue('endsAt', row['endsAt'])}',
                        status: row['status']?.toString(),
                      ),
                    ),
              const SizedBox(height: 20),
              const SectionHeader(title: 'آخر حركات الحضور'),
              const SizedBox(height: 8),
              if (attendance.isEmpty)
                const _CompactEmpty(text: 'لم تُسجل حركات حضور بعد.')
              else
                ...attendance
                    .take(10)
                    .map(
                      (row) => _SelfTimelineTile(
                        icon: row['eventType'] == 'CLOCK_IN'
                            ? Icons.login_rounded
                            : Icons.logout_rounded,
                        title: row['eventType'] == 'CLOCK_IN'
                            ? 'تسجيل حضور'
                            : 'تسجيل انصراف',
                        subtitle: _displayValue(
                          'occurredAt',
                          row['occurredAt'],
                        ),
                        status: row['method']?.toString(),
                      ),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompactEmpty extends StatelessWidget {
  const _CompactEmpty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _SelfTimelineTile extends StatelessWidget {
  const _SelfTimelineTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.status,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String? status;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      leading: CircleAvatar(
        backgroundColor: goYellow.withValues(alpha: .16),
        child: Icon(icon, color: Colors.amber[800]),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(subtitle),
      trailing: status?.isNotEmpty == true
          ? Text(
              _displayValue('status', status),
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
            )
          : null,
    ),
  );
}

typedef _PortalLoadResult = ({List<Map<String, dynamic>> rows, String? error});

class TrainerSelfSpacePage extends StatefulWidget {
  const TrainerSelfSpacePage({super.key, required this.controller});
  final GoController controller;

  @override
  State<TrainerSelfSpacePage> createState() => _TrainerSelfSpacePageState();
}

class _TrainerSelfSpacePageState extends State<TrainerSelfSpacePage> {
  Map<String, dynamic>? trainer;
  List<Map<String, dynamic>> members = [];
  List<Map<String, dynamic>> schedule = [];
  List<Map<String, dynamic>> plans = [];
  List<Map<String, dynamic>> commissions = [];
  bool loading = true;
  String? busyItemId;
  String? error;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<_PortalLoadResult> _loadRows(
    String path, {
    Map<String, String>? query,
  }) async {
    try {
      final data = await widget.controller.api.request(path, query: query);
      return (rows: _portalRows(data), error: null);
    } catch (exception) {
      return (rows: <Map<String, dynamic>>[], error: _errorMessage(exception));
    }
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final base =
          '/self/organizations/${widget.controller.organizationId}/trainer';
      final profile = await widget.controller.api.request(base);
      trainer = profile is Map
          ? Map<String, dynamic>.from(profile)
          : <String, dynamic>{};
      final now = DateTime.now().toUtc();
      final values = await Future.wait([
        _loadRows('$base/members'),
        _loadRows(
          '$base/schedule',
          query: {
            'from': now.subtract(const Duration(days: 30)).toIso8601String(),
            'to': now.add(const Duration(days: 60)).toIso8601String(),
          },
        ),
        _loadRows('$base/training-plans', query: const {'limit': '100'}),
        _loadRows('$base/commissions', query: const {'limit': '100'}),
      ]);
      members = values[0].rows;
      schedule = values[1].rows;
      plans = values[2].rows;
      commissions = values[3].rows;
      if (values.any((value) => value.error != null)) {
        error = 'تم فتح مساحة المدرب، لكن تعذر تحديث بعض البيانات. اسحب الشاشة للمحاولة مجددًا.';
      }
    } catch (exception) {
      trainer = null;
      members = [];
      schedule = [];
      plans = [];
      commissions = [];
      error = exception is ApiFailure && exception.isNotFound
          ? 'حساب الموظف غير مرتبط بملف مدرب نشط.'
          : _errorMessage(exception);
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _runWorkflow(String id) async {
    await _openWorkflow(context, widget.controller, _workflowById(id));
    if (mounted) await load();
  }

  Future<void> _showMeasurements(Map<String, dynamic> member) async {
    final id = member['memberId']?.toString() ?? member['id']?.toString() ?? '';
    if (id.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final data = await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/trainer/members/$id/measurements',
        query: const {'limit': '12'},
      );
      if (!mounted) return;
      Navigator.pop(context);
      final rows = _portalRows(data);
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .68,
          maxChildSize: .92,
          builder: (_, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
            children: [
              Text(
                'قياسات ${member['memberName'] ?? member['name'] ?? 'المتدرب'}',
                style: Theme.of(sheetContext).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                const _CompactEmpty(text: 'لم تُسجل قياسات لهذا المتدرب بعد.')
              else
                ...rows.map(
                  (row) => _SelfTimelineTile(
                    icon: Icons.monitor_weight_outlined,
                    title:
                        row['measurementName']?.toString() ??
                        row['typeName']?.toString() ??
                        'جلسة قياس',
                    subtitle: _displayValue('measuredAt', row['measuredAt']),
                    status: row['value']?.toString(),
                  ),
                ),
            ],
          ),
        ),
      );
    } catch (exception) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorMessage(exception))));
    }
  }

  Future<void> _transitionPlanItem(
    Map<String, dynamic> plan,
    Map<String, dynamic> item,
    String status,
  ) async {
    final planId = plan['id']?.toString() ?? '';
    final itemId = item['id']?.toString() ?? '';
    if (planId.isEmpty || itemId.isEmpty) return;
    setState(() => busyItemId = itemId);
    try {
      await widget.controller.api.request(
        '/self/organizations/${widget.controller.organizationId}/trainer/training-plans/$planId/items/$itemId/transitions',
        method: 'POST',
        body: {'status': status},
      );
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              status == 'COMPLETED'
                  ? 'تم اعتماد تنفيذ التمرين.'
                  : 'تم تسجيل تخطي التمرين.',
            ),
          ),
        );
      }
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(exception))));
      }
    } finally {
      if (mounted) setState(() => busyItemId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    const tabs = [
      ('المتدربون', Icons.people_outline_rounded),
      ('جدولي', Icons.calendar_month_outlined),
      ('خطط التدريب', Icons.fitness_center_outlined),
      ('عمولاتي', Icons.payments_outlined),
    ];
    final name = trainer?['displayName']?.toString() ?? 'مدرب النادي';
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'مساحة المدرب',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            onPressed: loading ? null : () => unawaited(load()),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            if (loading)
              const SizedBox(
                height: 420,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (trainer == null)
              _ResourceMessage(
                icon: Icons.fitness_center_outlined,
                title: 'مساحة المدرب غير متاحة',
                body: error ?? 'تأكد من ربط حسابك بملف مدرب نشط.',
                action: load,
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: goYellow.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: goYellow.withValues(alpha: .45)),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 27,
                      backgroundColor: goInk,
                      child: Icon(
                        Icons.fitness_center_rounded,
                        color: goYellow,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'مرحبًا، $name',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '${members.length} متدربين • ${plans.where((row) => row['status'] == 'ACTIVE').length} خطط نشطة',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: members.isEmpty
                          ? null
                          : () => unawaited(
                              _runWorkflow('recordSelfTrainerMeasurement'),
                            ),
                      icon: const Icon(Icons.monitor_weight_outlined),
                      label: const Text('تسجيل قياس'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: members.isEmpty
                          ? null
                          : () => unawaited(
                              _runWorkflow('createSelfTrainerTrainingPlan'),
                            ),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('خطة جديدة'),
                    ),
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: tabs.indexed
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsetsDirectional.only(end: 7),
                          child: ChoiceChip(
                            selected: tab == entry.$1,
                            onSelected: (_) => setState(() => tab = entry.$1),
                            avatar: Icon(entry.$2.$2, size: 17),
                            label: Text(entry.$2.$1),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 12),
              if (tab == 0) _membersTab(),
              if (tab == 1) _scheduleTab(),
              if (tab == 2) _plansTab(),
              if (tab == 3) _commissionsTab(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _membersTab() {
    if (members.isEmpty) {
      return const _CompactEmpty(text: 'لا يوجد متدربون مسندون إليك حاليًا.');
    }
    return Column(
      children: members
          .map(
            (row) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => unawaited(_showMeasurements(row)),
                leading: CircleAvatar(
                  backgroundColor: goYellow.withValues(alpha: .18),
                  child: Text(
                    (row['memberName']?.toString() ?? 'م').characters.first,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                title: Text(
                  row['memberName']?.toString() ?? 'متدرب',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  [
                    row['memberNumber']?.toString(),
                    row['branchName']?.toString(),
                    if (row['activePlanName'] != null)
                      'الخطة: ${row['activePlanName']}',
                  ].whereType<String>().join(' • '),
                ),
                trailing: const Icon(Icons.chevron_left_rounded),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _scheduleTab() {
    if (schedule.isEmpty) {
      return const _CompactEmpty(text: 'لا توجد جلسات في الفترة المحددة.');
    }
    return Column(
      children: schedule
          .map(
            (row) => _SelfTimelineTile(
              icon: Icons.event_available_outlined,
              title: row['resourceName']?.toString() ?? 'جلسة تدريب',
              subtitle:
                  '${_displayValue('startsAt', row['startsAt'])} • ${row['branchName'] ?? widget.controller.branchName}',
              status: row['status']?.toString(),
            ),
          )
          .toList(),
    );
  }

  Widget _plansTab() {
    if (plans.isEmpty) {
      return const _CompactEmpty(text: 'لم تُنشأ خطط تدريب للمتدربين بعد.');
    }
    return Column(
      children: plans.map((plan) {
        final rawItems = plan['items'];
        final items = rawItems is List
            ? rawItems
                  .whereType<Map>()
                  .map((row) => Map<String, dynamic>.from(row))
                  .toList()
            : <Map<String, dynamic>>[];
        return Card(
          margin: const EdgeInsets.only(bottom: 9),
          child: ExpansionTile(
            title: Text(
              plan['name']?.toString() ?? 'خطة تدريب',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              '${plan['memberName'] ?? 'عضو'} • ${_displayValue('status', plan['status'])}',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            children: items.isEmpty
                ? [const _CompactEmpty(text: 'لا توجد تمارين داخل هذه الخطة.')]
                : items.map((item) {
                    final status =
                        item['completionStatus']?.toString() ?? 'PENDING';
                    final id = item['id']?.toString() ?? '';
                    return Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: .4),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            status == 'COMPLETED'
                                ? Icons.check_circle_rounded
                                : status == 'SKIPPED'
                                ? Icons.skip_next_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: status == 'COMPLETED'
                                ? Colors.green
                                : status == 'SKIPPED'
                                ? Colors.orange
                                : Colors.amber[800],
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              item['exerciseName']?.toString() ?? 'تمرين',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (status == 'PENDING' && plan['status'] == 'ACTIVE')
                            PopupMenuButton<String>(
                              enabled: busyItemId != id,
                              onSelected: (value) => unawaited(
                                _transitionPlanItem(plan, item, value),
                              ),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'COMPLETED',
                                  child: Text('اعتماد التنفيذ'),
                                ),
                                PopupMenuItem(
                                  value: 'SKIPPED',
                                  child: Text('تسجيل التخطي'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    );
                  }).toList(),
          ),
        );
      }).toList(),
    );
  }

  Widget _commissionsTab() {
    if (commissions.isEmpty) {
      return const _CompactEmpty(text: 'لا توجد عمولات مسجلة حتى الآن.');
    }
    final total = commissions.fold<int>(
      0,
      (sum, row) =>
          sum + (int.tryParse('${row['commissionAmountMinor'] ?? 0}') ?? 0),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: goYellow.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            'إجمالي العمولات: ${_money(total)}',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        ...commissions.map(
          (row) => _SelfTimelineTile(
            icon: Icons.payments_outlined,
            title: _money(row['commissionAmountMinor'] ?? 0),
            subtitle:
                '${row['sourceType'] ?? 'عمولة'} • ${_displayValue('occurredAt', row['occurredAt'])}',
            status: row['status']?.toString(),
          ),
        ),
      ],
    );
  }
}

class PointOfSaleMobilePage extends StatelessWidget {
  const PointOfSaleMobilePage({super.key, required this.controller});

  final GoController controller;

  static const _workflowIds = <String>[
    'createSubscription',
    'checkoutServiceAtPos',
    'checkoutRetailAtPos',
    'checkoutOrder',
    'recordPayment',
    'recordSplitPayment',
    'openCashierShift',
    'closeCashierShift',
  ];

  static const _resourceEndings = <String>[
    '/orders',
    '/invoices',
    '/payments',
    '/cashier-shifts',
  ];

  Color _actionColor(String operationId) => switch (operationId) {
    'createSubscription' => const Color(0xFF8B5CF6),
    'checkoutServiceAtPos' => const Color(0xFF2563EB),
    'checkoutRetailAtPos' => const Color(0xFF0891B2),
    'checkoutOrder' => const Color(0xFFEA580C),
    'recordPayment' => const Color(0xFF16A34A),
    'recordSplitPayment' => const Color(0xFF0F766E),
    'openCashierShift' => const Color(0xFF475569),
    'closeCashierShift' => const Color(0xFF9F1239),
    _ => goInk,
  };

  String _actionHint(String operationId) => switch (operationId) {
    'createSubscription' => 'عضوية وفاتورة',
    'checkoutServiceAtPos' => 'خدمة بسعر الفرع',
    'checkoutRetailAtPos' => 'منتج ومخزون',
    'checkoutOrder' => 'صنف من المطعم',
    'recordPayment' => 'تحصيل فاتورة',
    'recordSplitPayment' => 'وسيلتا دفع',
    'openCashierShift' => 'بدء التحصيل النقدي',
    'closeCashierShift' => 'جرد وتسجيل الفرق',
    _ => 'إجراء سريع',
  };

  @override
  Widget build(BuildContext context) {
    final actions = _workflowIds
        .map(_workflowById)
        .where((workflow) => _canRunWorkflow(controller, workflow))
        .toList();
    final resources = _resourceEndings
        .map(_featureEnding)
        .where((feature) => _canViewFeature(controller, feature))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'نقطة البيع',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => controller.refresh(announce: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 34),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: goInk,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: goInk.withValues(alpha: .18),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: goYellow,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(
                      Icons.point_of_sale_rounded,
                      color: goInk,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'بيع وتحصيل من مكان واحد',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 17,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'الفرع الحالي: ${controller.branchName}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: .72),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            if (actions.isNotEmpty) ...[
              const SectionHeader(title: 'عمليات البيع'),
              const SizedBox(height: 11),
              LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth = constraints.maxWidth >= 520
                      ? (constraints.maxWidth - 20) / 3
                      : (constraints.maxWidth - 10) / 2;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: actions
                        .map(
                          (workflow) => SizedBox(
                            width: itemWidth,
                            child: _PosActionCard(
                              workflow: workflow,
                              color: _actionColor(workflow.operationId),
                              hint: _actionHint(workflow.operationId),
                              onTap: () => unawaited(
                                _openWorkflow(context, controller, workflow),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
              const SizedBox(height: 23),
            ],
            if (resources.isNotEmpty) ...[
              const SectionHeader(title: 'السجلات والمتابعة'),
              const SizedBox(height: 11),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var index = 0; index < resources.length; index++) ...[
                      ListTile(
                        onTap: () => _openResource(
                          context,
                          controller,
                          resources[index],
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 5,
                        ),
                        leading: CircleAvatar(
                          backgroundColor: goYellow.withValues(alpha: .16),
                          child: Icon(
                            resources[index].icon,
                            color: Colors.amber[800],
                          ),
                        ),
                        title: Text(
                          resources[index].title,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(resources[index].subtitle),
                        trailing: const Icon(Icons.chevron_left_rounded),
                      ),
                      if (index < resources.length - 1)
                        const Divider(height: 1, indent: 70),
                    ],
                  ],
                ),
              ),
            ],
            if (actions.isEmpty && resources.isEmpty)
              const _ResourceMessage(
                icon: Icons.lock_outline_rounded,
                title: 'نقطة البيع غير متاحة',
                body: 'لا تتضمن صلاحيات الحساب الحالية عمليات أو سجلات البيع.',
              ),
          ],
        ),
      ),
    );
  }
}

class _PosActionCard extends StatelessWidget {
  const _PosActionCard({
    required this.workflow,
    required this.color,
    required this.hint,
    required this.onTap,
  });

  final MobileWorkflow workflow;
  final Color color;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color.withValues(alpha: .09),
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 132,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: .22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(workflow.icon, color: Colors.white, size: 21),
            ),
            const Spacer(),
            Text(
              workflow.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13),
            ),
            const SizedBox(height: 3),
            Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class FeatureHubPage extends StatelessWidget {
  const FeatureHubPage({
    super.key,
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.features,
  });
  final GoController controller;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<ResourceFeature> features;

  @override
  Widget build(BuildContext context) {
    final allowed = features
        .where((feature) => _canViewFeature(controller, feature))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: goYellow.withValues(alpha: .13),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: goYellow.withValues(alpha: .45)),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: goInk,
                  child: Icon(icon, color: goYellow),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(subtitle, style: const TextStyle(height: 1.6)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ...allowed.map(
            (feature) => Card(
              margin: const EdgeInsets.only(bottom: 9),
              child: ListTile(
                onTap: () => _openResource(context, controller, feature),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 7,
                ),
                leading: CircleAvatar(
                  backgroundColor: goYellow.withValues(alpha: .16),
                  child: Icon(feature.icon, color: Colors.amber[800]),
                ),
                title: Text(
                  feature.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(feature.subtitle),
                trailing: const Icon(Icons.chevron_left_rounded),
              ),
            ),
          ),
          if (allowed.isEmpty)
            const _ResourceMessage(
              icon: Icons.lock_outline_rounded,
              title: 'لا توجد أدوات متاحة',
              body: 'صلاحيات حسابك لا تتيح أدوات داخل هذا القسم.',
            ),
        ],
      ),
    );
  }
}

class _SettingsGroup {
  const _SettingsGroup(this.title, this.icon, this.features);
  final String title;
  final IconData icon;
  final List<ResourceFeature> features;
}

class SystemSettingsPage extends StatefulWidget {
  const SystemSettingsPage({super.key, required this.controller});
  final GoController controller;

  static List<_SettingsGroup> _groups() => [
    _SettingsGroup('النادي والموظفون', Icons.apartment_outlined, [
      organizationFeature,
      _featureEnding('/branches'),
      _featureEnding('/positions'),
      _featureEnding('/user-accounts'),
    ]),
    _SettingsGroup('الصلاحيات الإضافية', Icons.shield_outlined, [
      _featureEnding('/roles'),
      _featureEnding('/role-assignments'),
    ]),
    _SettingsGroup('الخدمات والتسعير', Icons.sell_outlined, [
      _featureEnding('/activities'),
      _featureEnding('/service-categories'),
      _featureEnding('/services'),
      _featureEnding('/packages'),
      _featureEnding('/prices'),
      _featureEnding('/promotions'),
      _featureEnding('/commercial-policies'),
    ]),
    _SettingsGroup('المرافق والتشغيل', Icons.domain_outlined, [
      _featureEnding('/facilities'),
      _featureEnding('/bookable-resources'),
      _featureEnding('/cash-points'),
      _featureEnding('/lockers'),
    ]),
    _SettingsGroup('التدريب', Icons.fitness_center_outlined, [
      _featureEnding('/measurement-types'),
    ]),
    _SettingsGroup('المطعم', Icons.restaurant_menu_outlined, [
      _featureEnding('/restaurant/meal-categories'),
    ]),
    _SettingsGroup('المتجر والمخزون', Icons.inventory_2_outlined, [
      _featureEnding('/retail/categories'),
      _featureEnding('/retail/products'),
      _featureEnding('/retail/prices'),
      _featureEnding('/retail/inventory'),
    ]),
    _SettingsGroup('المالية', Icons.account_balance_outlined, [
      _featureEnding('/expense-categories'),
    ]),
    _SettingsGroup('التواصل', Icons.mark_email_read_outlined, [
      _featureEnding('/notification-templates'),
    ]),
  ];

  static bool hasVisibleSettings(GoController controller) => _groups().any(
    (group) =>
        group.features.any((feature) => _canViewFeature(controller, feature)),
  );

  @override
  State<SystemSettingsPage> createState() => _SystemSettingsPageState();
}

class _SystemSettingsPageState extends State<SystemSettingsPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final groups = SystemSettingsPage._groups()
        .map(
          (group) => _SettingsGroup(
            group.title,
            group.icon,
            group.features.where((feature) {
              if (!_canViewFeature(widget.controller, feature)) return false;
              final needle = query.trim().toLowerCase();
              return needle.isEmpty ||
                  feature.title.toLowerCase().contains(needle) ||
                  feature.subtitle.toLowerCase().contains(needle) ||
                  group.title.toLowerCase().contains(needle);
            }).toList(),
          ),
        )
        .where((group) => group.features.isNotEmpty)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'إعداد النظام',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: goYellow.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: goYellow.withValues(alpha: .45)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: goInk,
                  child: Icon(Icons.settings_suggest_outlined, color: goYellow),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'مركز إعداد موحّد',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'بيانات النادي والفروع والكتالوج والأسعار والمسميات والصلاحيات من مكان واحد.',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            onChanged: (value) => setState(() => query = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'ابحث داخل إعداد النظام…',
            ),
          ),
          const SizedBox(height: 14),
          ...groups.map(
            (group) => Card(
              margin: const EdgeInsets.only(bottom: 12),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: query.isNotEmpty || groups.length < 4,
                leading: Icon(group.icon, color: Colors.amber[800]),
                title: Text(
                  group.title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text('${group.features.length} إعدادات'),
                children: group.features.indexed
                    .map(
                      (entry) => Column(
                        children: [
                          if (entry.$1 == 0) const Divider(height: 1),
                          ListTile(
                            onTap: () => _openResource(
                              context,
                              widget.controller,
                              entry.$2,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 4,
                            ),
                            leading: Icon(entry.$2.icon, size: 21),
                            title: Text(
                              entry.$2.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              entry.$2.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: const Icon(Icons.chevron_left_rounded),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          if (groups.isEmpty)
            const _ResourceMessage(
              icon: Icons.search_off_rounded,
              title: 'لا توجد إعدادات مطابقة',
              body: 'غيّر عبارة البحث أو راجع صلاحيات حسابك.',
            ),
        ],
      ),
    );
  }
}

class AccessControlMobilePage extends StatefulWidget {
  const AccessControlMobilePage({super.key, required this.controller});
  final GoController controller;

  @override
  State<AccessControlMobilePage> createState() =>
      _AccessControlMobilePageState();
}

class _AccessControlMobilePageState extends State<AccessControlMobilePage> {
  List<Map<String, dynamic>> devices = [];
  List<Map<String, dynamic>> events = [];
  bool loading = true;
  String? deviceError;
  String? eventError;
  String view = 'devices';
  String? selectedDeviceId;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    unawaited(load());
    if (widget.controller.api.configured) {
      refreshTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(load(silent: true)),
      );
    }
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> load({bool silent = false}) async {
    if (!silent && mounted) setState(() => loading = true);
    if (!widget.controller.api.configured) {
      final now = DateTime.now();
      devices = [
        {
          'id': 'demo-gate',
          'name': 'بوابة الفرع الرئيسية',
          'serialNumber': 'BRI3232060149',
          'model': 'ZKTeco ACP-260',
          'mode': 'ENFORCE',
          'status': 'ACTIVE',
          'ipAddress': '192.168.1.201',
          'doorCount': 2,
          'readerCount': 4,
          'lastSeenAt': now
              .subtract(const Duration(seconds: 24))
              .toIso8601String(),
          'lastEventAt': now
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
        },
      ];
      events = [
        {
          'id': 'event-1',
          'deviceId': 'demo-gate',
          'deviceName': 'بوابة الفرع الرئيسية',
          'deviceOccurredAt': now
              .subtract(const Duration(minutes: 3))
              .toIso8601String(),
          'memberName': 'أحمد محمد',
          'memberNumber': 'GO-10482',
          'credentialPin': '22782',
          'doorNumber': 1,
          'direction': 'IN',
          'deviceDecision': 'ALLOWED',
          'processingStatus': 'ATTENDANCE_RECORDED',
          'processingCode': 'SYSTEM_ACCEPTED',
        },
        {
          'id': 'event-2',
          'deviceId': 'demo-gate',
          'deviceName': 'بوابة الفرع الرئيسية',
          'deviceOccurredAt': now
              .subtract(const Duration(minutes: 17))
              .toIso8601String(),
          'employeeName': 'محمد خالد',
          'employeeNumber': 'EMP-018',
          'credentialPin': '1818',
          'doorNumber': 2,
          'direction': 'OUT',
          'deviceDecision': 'ALLOWED',
          'processingStatus': 'ATTENDANCE_RECORDED',
          'processingCode': 'EMPLOYEE_CLOCK_OUT_RECORDED',
        },
        {
          'id': 'event-3',
          'deviceId': 'demo-gate',
          'deviceName': 'بوابة الفرع الرئيسية',
          'deviceOccurredAt': now
              .subtract(const Duration(minutes: 28))
              .toIso8601String(),
          'credentialPin': '99102',
          'doorNumber': 1,
          'direction': 'IN',
          'deviceDecision': 'ALLOWED',
          'processingStatus': 'UNMAPPED_CREDENTIAL',
        },
      ];
      deviceError = null;
      eventError = null;
      if (mounted) setState(() => loading = false);
      return;
    }

    final api = widget.controller.api;
    final org = widget.controller.organizationId;
    final branch = widget.controller.branchId;
    await Future.wait<void>([
      () async {
        try {
          devices = await api.listResource(
            org,
            branch,
            '/organizations/{organizationId}/access-devices',
          );
          deviceError = null;
        } catch (exception) {
          deviceError = _errorMessage(exception);
        }
      }(),
      () async {
        try {
          events = await api.listResource(
            org,
            branch,
            '/organizations/{organizationId}/access-device-events',
          );
          eventError = null;
        } catch (exception) {
          eventError = _errorMessage(exception);
        }
      }(),
    ]);
    if (mounted) setState(() => loading = false);
  }

  Future<void> runCredentialWorkflow(String operationId) async {
    await _openWorkflow(context, widget.controller, _workflowById(operationId));
    if (mounted) await load();
  }

  Future<void> manageDevice(Map<String, dynamic> device) async {
    final id = device['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('تعديل وضع وحالة اللوحة'),
              onTap: () => Navigator.pop(sheetContext, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.key_rounded, color: Colors.orange),
              title: const Text('تدوير مفتاح الاتصال'),
              subtitle: const Text('سيُلغى المفتاح القديم فورًا'),
              onTap: () => Navigator.pop(sheetContext, 'rotate'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final version = int.tryParse('${device['version'] ?? 1}') ?? 1;
    final workflow = action == 'edit'
        ? MobileWorkflow(
            operationId: 'editAccessDevice:$id',
            title: 'إعدادات لوحة البوابة',
            description:
                'غيّر وضع القرار أو أوقف اللوحة للصيانة مع الحفاظ على سجلها.',
            submitLabel: 'حفظ إعدادات اللوحة',
            successMessage: 'تم تحديث إعدادات لوحة البوابة.',
            method: 'PATCH',
            path: '/organizations/{organizationId}/access-devices/$id',
            icon: Icons.tune_rounded,
            fields: [
              WorkflowField(
                name: 'mode',
                label: 'وضع التشغيل',
                type: WorkflowFieldType.select,
                required: true,
                initialValue: device['mode']?.toString() ?? 'OBSERVE',
                choices: [
                  WorkflowChoice('OBSERVE', 'مراقبة فقط'),
                  WorkflowChoice('ENFORCE', 'تنفيذ قرارات الدخول'),
                ],
              ),
              WorkflowField(
                name: 'status',
                label: 'حالة اللوحة',
                type: WorkflowFieldType.select,
                required: true,
                initialValue: device['status']?.toString() ?? 'ACTIVE',
                choices: [
                  WorkflowChoice('ACTIVE', 'نشطة'),
                  WorkflowChoice('MAINTENANCE', 'صيانة'),
                  WorkflowChoice('DISABLED', 'موقوفة'),
                ],
              ),
            ],
            body: (values, controller) => {
              'expectedVersion': version,
              'mode': values['mode'],
              'status': values['status'],
            },
          )
        : MobileWorkflow(
            operationId: 'rotateAccessDeviceKey:$id',
            title: 'تدوير مفتاح الاتصال',
            description: 'سيصدر مفتاح جديد يظهر مرة واحدة، وسيتوقف المفتاح الحالي فور الحفظ.',
            submitLabel: 'إصدار مفتاح جديد',
            successMessage: 'تم تدوير مفتاح لوحة البوابة.',
            method: 'POST',
            path:
                '/organizations/{organizationId}/access-devices/$id/key-rotations',
            icon: Icons.key_rounded,
            fields: const [],
            body: (values, controller) => {'expectedVersion': version},
          );
    await _openWorkflow(context, widget.controller, workflow);
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) {
    final visibleEvents = selectedDeviceId == null
        ? events
        : events
              .where(
                (event) => event['deviceId']?.toString() == selectedDeviceId,
              )
              .toList();
    final online = devices.where(_gateIsOnline).length;
    final accepted = events.where(_gateAccepted).length;
    final review = events.where(_gateNeedsReview).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'البوابات والبصمة',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          if (_canViewFeature(
            widget.controller,
            _featureEnding('/access-credentials'),
          ))
            IconButton(
              onPressed: () => _openResource(
                context,
                widget.controller,
                _featureEnding('/access-credentials'),
              ),
              icon: const Icon(Icons.key_outlined),
              tooltip: 'بطاقات وPIN الدخول',
            ),
          IconButton(
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: goYellow.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: goYellow.withValues(alpha: .45)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: goInk,
                    child: Icon(Icons.fingerprint_rounded, color: goYellow),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'مراقبة لحظية للبوابة',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'حالة اللوحات وأحداث الدخول والخروج وقرار GO داخل سياق واحد.',
                          style: TextStyle(fontSize: 12, height: 1.6),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (widget.controller.can('access-credentials.manage')) ...[
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: () =>
                        unawaited(runCredentialWorkflow('issueAccessBarcode')),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('إصدار بطاقة دخول'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      runCredentialWorkflow('assignFingerprintPin'),
                    ),
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('ربط PIN البصمة'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (widget.controller.can('attendance.devices.manage')) ...[
              FilledButton.tonalIcon(
                onPressed: () =>
                    unawaited(runCredentialWorkflow('registerAccessDevice')),
                icon: const Icon(Icons.add_to_home_screen_outlined),
                label: const Text('تسجيل لوحة بوابة جديدة'),
              ),
              const SizedBox(height: 12),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth > 620
                    ? (constraints.maxWidth - 24) / 3
                    : (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _GateMetric(
                      width: width,
                      icon: Icons.sensors_rounded,
                      label: 'اللوحات المتصلة',
                      value: '$online / ${devices.length}',
                      color: Colors.green,
                    ),
                    _GateMetric(
                      width: width,
                      icon: Icons.verified_user_outlined,
                      label: 'أحداث مقبولة',
                      value: '$accepted',
                      color: Colors.blue,
                    ),
                    _GateMetric(
                      width: width,
                      icon: Icons.rule_folder_outlined,
                      label: 'تحتاج مراجعة',
                      value: '$review',
                      color: Colors.orange,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'devices',
                  label: Text('اللوحات'),
                  icon: Icon(Icons.sensors_outlined),
                ),
                ButtonSegment(
                  value: 'events',
                  label: Text('سجل المرور'),
                  icon: Icon(Icons.history_rounded),
                ),
              ],
              selected: {view},
              onSelectionChanged: (selected) =>
                  setState(() => view = selected.first),
            ),
            const SizedBox(height: 14),
            if (loading && devices.isEmpty && events.isEmpty)
              const Padding(
                padding: EdgeInsets.all(60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (view == 'devices') ...[
              if (deviceError != null)
                _InlineError(message: deviceError!, onRetry: load),
              if (devices.isEmpty && deviceError == null)
                const _ResourceMessage(
                  icon: Icons.sensors_off_outlined,
                  title: 'لا توجد لوحة مسجلة',
                  body: 'لم تُسجّل لوحة دخول لهذا الفرع بعد.',
                ),
              ...devices.map(
                (device) => _GateDeviceCard(
                  device: device,
                  selected: selectedDeviceId == device['id']?.toString(),
                  onManage: widget.controller.can('attendance.devices.manage')
                      ? () => unawaited(manageDevice(device))
                      : null,
                  onEvents: () => setState(() {
                    selectedDeviceId = device['id']?.toString();
                    view = 'events';
                  }),
                ),
              ),
            ] else ...[
              if (eventError != null)
                _InlineError(message: eventError!, onRetry: load),
              if (devices.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String>(
                    initialValue: selectedDeviceId ?? '',
                    decoration: const InputDecoration(
                      labelText: 'تصفية حسب البوابة',
                      prefixIcon: Icon(Icons.filter_alt_outlined),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('كل البوابات'),
                      ),
                      ...devices.map(
                        (device) => DropdownMenuItem(
                          value: device['id']?.toString() ?? '',
                          child: Text(device['name']?.toString() ?? 'بوابة'),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(
                      () => selectedDeviceId = value?.isEmpty == true
                          ? null
                          : value,
                    ),
                  ),
                ),
              if (visibleEvents.isEmpty && eventError == null)
                const _ResourceMessage(
                  icon: Icons.history_toggle_off_rounded,
                  title: 'لا توجد أحداث بعد',
                  body: 'ستظهر محاولات الدخول والخروج فور وصولها من البوابة.',
                ),
              ...visibleEvents.map((event) => _GateEventCard(event: event)),
            ],
          ],
        ),
      ),
    );
  }
}

class _GateMetric extends StatelessWidget {
  const _GateMetric({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });
  final double width;
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            Text(label, style: const TextStyle(fontSize: 10)),
          ],
        ),
      ),
    ),
  );
}

class _GateDeviceCard extends StatelessWidget {
  const _GateDeviceCard({
    required this.device,
    required this.selected,
    required this.onEvents,
    this.onManage,
  });
  final Map<String, dynamic> device;
  final bool selected;
  final VoidCallback onEvents;
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final online = _gateIsOnline(device);
    final mode = device['mode']?.toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: (online ? Colors.green : Colors.red)
                      .withValues(alpha: .12),
                  child: Icon(
                    online ? Icons.sensors_rounded : Icons.sensors_off_outlined,
                    color: online ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['name']?.toString() ?? 'لوحة بوابة',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      Text(
                        '${device['model'] ?? 'ZKTeco'} • ${device['serialNumber'] ?? '—'}',
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
                _GatePill(
                  text: online ? 'متصل' : 'غير متصل',
                  color: online ? Colors.green : Colors.red,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _GatePill(
                  text: mode == 'ENFORCE' ? 'وضع التنفيذ' : 'وضع المراقبة',
                  color: mode == 'ENFORCE' ? Colors.orange : Colors.blueGrey,
                ),
                _GatePill(
                  text:
                      '${device['doorCount'] ?? '—'} مخارج • ${device['readerCount'] ?? '—'} قارئات',
                  color: Colors.blueGrey,
                ),
              ],
            ),
            const SizedBox(height: 13),
            Text(
              'آخر اتصال: ${_displayValue('lastSeenAt', device['lastSeenAt'])}\nآخر حدث: ${_displayValue('lastEventAt', device['lastEventAt'])}',
              style: const TextStyle(fontSize: 11, height: 1.7),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onEvents,
              icon: const Icon(Icons.history_rounded),
              label: Text(
                selected ? 'عرض السجل المحدد' : 'عرض أحداث هذه البوابة',
              ),
            ),
            if (onManage != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onManage,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('إدارة إعدادات اللوحة ومفتاحها'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GateEventCard extends StatelessWidget {
  const _GateEventCard({required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final color = _gateEventColor(event);
    final rejectedAfterOpen =
        event['deviceDecision']?.toString() == 'ALLOWED' &&
        (event['processingCode']?.toString().startsWith('SYSTEM_REJECTED_') ??
            false);
    final subject =
        event['memberName'] ??
        event['employeeName'] ??
        (event['credentialPin'] == null
            ? 'شخص غير معروف'
            : 'PIN ${event['credentialPin']}');
    final number = event['memberNumber'] ?? event['employeeNumber'];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: rejectedAfterOpen ? Colors.red.withValues(alpha: .06) : null,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: .12),
                  child: Icon(_gateEventIcon(event), color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$subject',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (number != null)
                        Text('$number', style: const TextStyle(fontSize: 10)),
                      const SizedBox(height: 3),
                      Text(
                        _displayValue(
                          'deviceOccurredAt',
                          event['deviceOccurredAt'] ?? event['occurredAt'],
                        ),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                ),
                _GatePill(text: _gateSystemReason(event), color: color),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _GatePill(text: _gateReader(event), color: Colors.blueGrey),
                _GatePill(
                  text: event['deviceDecision']?.toString() == 'ALLOWED'
                      ? 'فتحت اللوحة'
                      : event['deviceDecision']?.toString() == 'DENIED'
                      ? 'رفضت اللوحة'
                      : 'قرار غير معروف',
                  color: event['deviceDecision']?.toString() == 'DENIED'
                      ? Colors.red
                      : Colors.blueGrey,
                ),
              ],
            ),
            if (rejectedAfterOpen) ...[
              const SizedBox(height: 10),
              const Text(
                'تنبيه: فتحت اللوحة، لكن GO رفض تسجيل الدخول. راجع الاشتراك أو حالة العضو.',
                style: TextStyle(
                  color: Colors.red,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GatePill extends StatelessWidget {
  const _GatePill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800),
    ),
  );
}

bool _gateIsOnline(Map<String, dynamic> device) {
  final seen = DateTime.tryParse(device['lastSeenAt']?.toString() ?? '');
  return seen != null && DateTime.now().difference(seen).inSeconds < 120;
}

bool _gateAccepted(Map<String, dynamic> event) {
  final code = event['processingCode']?.toString() ?? '';
  return code == 'SYSTEM_ACCEPTED' || code.startsWith('EMPLOYEE_CLOCK_');
}

bool _gateNeedsReview(Map<String, dynamic> event) {
  final status = event['processingStatus']?.toString();
  final code = event['processingCode']?.toString() ?? '';
  return status == 'UNMAPPED_CREDENTIAL' ||
      status == 'FAILED' ||
      code.startsWith('SYSTEM_REJECTED_');
}

Color _gateEventColor(Map<String, dynamic> event) {
  if (event['deviceDecision']?.toString() == 'DENIED' ||
      _gateNeedsReview(event)) {
    return Colors.red;
  }
  return _gateAccepted(event) ? Colors.green : Colors.blueGrey;
}

IconData _gateEventIcon(Map<String, dynamic> event) {
  if (_gateNeedsReview(event)) return Icons.warning_amber_rounded;
  return event['direction']?.toString() == 'OUT'
      ? Icons.logout_rounded
      : Icons.login_rounded;
}

String _gateReader(Map<String, dynamic> event) {
  final direction = event['direction']?.toString();
  if (direction == 'IN') return 'قارئ الدخول';
  if (direction == 'OUT') return 'قارئ الخروج';
  return 'قارئ غير محدد';
}

String _gateSystemReason(Map<String, dynamic> event) {
  const reasons = <String, String>{
    'MEMBER_BLOCKED': 'العضو محظور',
    'MEMBER_INACTIVE': 'العضو غير نشط',
    'NOT_ACTIVE': 'لا يوجد اشتراك نشط',
    'SUBSCRIPTION_FROZEN': 'الاشتراك مجمّد',
    'OUTSIDE_ACCESS_PERIOD': 'خارج فترة الاشتراك',
    'BRANCH_NOT_ALLOWED': 'الفرع غير مسموح',
    'VISITS_EXHAUSTED': 'تم استنفاد الزيارات',
    'EMPLOYEE_INACTIVE': 'الموظف غير نشط',
    'EMPLOYEE_BRANCH_NOT_ALLOWED': 'الموظف غير معيّن هنا',
  };
  final code = event['processingCode']?.toString() ?? '';
  if (code == 'SYSTEM_ACCEPTED') return 'دخول مسجل';
  if (code == 'EMPLOYEE_CLOCK_IN_RECORDED') return 'حضور موظف';
  if (code == 'EMPLOYEE_CLOCK_OUT_RECORDED') return 'انصراف موظف';
  if (code.startsWith('SYSTEM_REJECTED_')) {
    return reasons[code.substring(16)] ?? 'رفضه GO';
  }
  final status = event['processingStatus']?.toString();
  if (status == 'UNMAPPED_CREDENTIAL') return 'PIN غير مربوط';
  if (status == 'DEVICE_DENIED') return 'رفضته اللوحة';
  if (status == 'FAILED') return 'فشل المعالجة';
  return event['direction']?.toString() == 'OUT' ? 'حدث خروج' : 'تم تجاهله';
}

enum ReportRangeType { none, businessDate, instant }

class ReportDefinition {
  const ReportDefinition(this.title, this.path, this.rangeType);
  final String title;
  final String path;
  final ReportRangeType rangeType;
}

const _reports = <ReportDefinition>[
  ReportDefinition(
    'الأداء اليومي للفروع',
    '/organizations/{organizationId}/reports/branch-daily',
    ReportRangeType.businessDate,
  ),
  ReportDefinition(
    'لقطة الفروع الحالية',
    '/organizations/{organizationId}/reports/branch-snapshots',
    ReportRangeType.none,
  ),
  ReportDefinition(
    'أداء الباقات',
    '/organizations/{organizationId}/reports/package-performance',
    ReportRangeType.businessDate,
  ),
  ReportDefinition(
    'خريطة كثافة الحضور',
    '/organizations/{organizationId}/reports/attendance-heatmap',
    ReportRangeType.instant,
  ),
  ReportDefinition(
    'ديون الأعضاء',
    '/organizations/{organizationId}/reports/member-debts',
    ReportRangeType.none,
  ),
  ReportDefinition(
    'حالات الاشتراكات',
    '/organizations/{organizationId}/reports/subscription-status-chart',
    ReportRangeType.none,
  ),
  ReportDefinition(
    'اتجاه الإيرادات',
    '/organizations/{organizationId}/reports/revenue-trend',
    ReportRangeType.instant,
  ),
  ReportDefinition(
    'نشاط الخدمات',
    '/organizations/{organizationId}/reports/service-activity-chart',
    ReportRangeType.instant,
  ),
  ReportDefinition(
    'اتجاه تجميد الاشتراكات',
    '/organizations/{organizationId}/reports/freeze-trend',
    ReportRangeType.instant,
  ),
];

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  ReportDefinition selected = _reports.first;
  final from = TextEditingController();
  final to = TextEditingController();
  List<Map<String, dynamic>> rows = [];
  bool loading = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    from.text = today
        .subtract(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    to.text = today.toIso8601String().substring(0, 10);
    unawaited(load());
  }

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final query = <String, String>{
        'branchId': widget.controller.branchId,
        if (selected.path.endsWith('/member-debts')) 'limit': '100',
      };
      if (selected.rangeType == ReportRangeType.businessDate) {
        query
          ..['from'] = from.text
          ..['to'] = to.text;
      } else if (selected.rangeType == ReportRangeType.instant) {
        query
          ..['from'] = '${from.text}T00:00:00.000Z'
          ..['to'] = '${to.text}T23:59:59.999Z';
      }
      final data = await widget.controller.api.request(
        selected.path.replaceAll(
          '{organizationId}',
          widget.controller.organizationId,
        ),
        query: query,
      );
      rows = data is List
          ? data
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList()
          : data is Map
          ? [Map<String, dynamic>.from(data)]
          : [];
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'التقارير والتحليلات',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
      actions: [
        IconButton(
          onPressed: () => unawaited(
            _openWorkflow(
              context,
              widget.controller,
              _workflowById('requestReportingRebuild'),
            ),
          ),
          icon: const Icon(Icons.sync_rounded),
          tooltip: 'تحديث بيانات التقارير',
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          DropdownButtonFormField<ReportDefinition>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: 'نوع التقرير',
              prefixIcon: Icon(Icons.query_stats_rounded),
            ),
            items: _reports
                .map(
                  (report) => DropdownMenuItem(
                    value: report,
                    child: Text(report.title),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() => selected = value);
              unawaited(load());
            },
          ),
          if (selected.rangeType != ReportRangeType.none) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: from,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(labelText: 'من تاريخ'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: to,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(labelText: 'إلى تاريخ'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: loading ? null : load,
              icon: const Icon(Icons.analytics_outlined),
              label: const Text('تطبيق الفترة'),
            ),
          ],
          const SizedBox(height: 18),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (error != null)
            _ResourceMessage(
              icon: Icons.cloud_off_outlined,
              title: 'تعذر تحميل التقرير',
              body: error!,
              action: load,
            )
          else if (rows.isEmpty)
            const _ResourceMessage(
              icon: Icons.query_stats_outlined,
              title: 'لا توجد بيانات في الفترة',
              body: 'غيّر الفترة أو الفرع ثم أعد المحاولة.',
            )
          else
            ...rows.map(
              (row) => Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: row.entries
                        .where(
                          (entry) =>
                              entry.value != null &&
                              entry.value is! Map &&
                              entry.value is! List,
                        )
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _humanizeOperation(entry.key),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                Text(
                                  _displayValue(entry.key, entry.value),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final displayName = TextEditingController();
  final currentPassword = TextEditingController();
  final newPassword = TextEditingController();
  final confirmPassword = TextEditingController();
  Map<String, dynamic> profile = {};
  String locale = 'ar';
  String timezone = 'Asia/Riyadh';
  bool sms = true;
  bool loading = true;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    displayName.dispose();
    currentPassword.dispose();
    newPassword.dispose();
    confirmPassword.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = widget.controller.api.configured
          ? await widget.controller.api.request('/self/account')
          : widget.controller.account;
      profile = data is Map
          ? Map<String, dynamic>.from(data)
          : <String, dynamic>{};
      displayName.text = profile['displayName']?.toString() ?? '';
      locale = profile['preferredLocale']?.toString() ?? 'ar';
      timezone = profile['preferredTimezone']?.toString() ?? 'Asia/Riyadh';
      sms = profile['smsNotificationsEnabled'] != false;
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> saveProfile() async {
    if (displayName.text.trim().length < 2) {
      setState(() => error = 'أدخل اسم عرض من حرفين على الأقل.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final data = await widget.controller.api.request(
        '/self/account',
        method: 'PATCH',
        body: {
          'displayName': displayName.text.trim(),
          'preferredLocale': locale,
          'preferredTimezone': timezone,
          'smsNotificationsEnabled': sms,
          'whatsappNotificationsEnabled':
              profile['whatsappNotificationsEnabled'] == true,
          'expectedVersion': profile['version'] ?? 1,
        },
      );
      if (data is Map) {
        profile = Map<String, dynamic>.from(data);
        widget.controller.applyAccount(profile);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حفظ إعدادات الحساب.')));
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> changePassword() async {
    if (newPassword.text.length < 7) {
      setState(() => error = 'كلمة المرور الجديدة يجب ألا تقل عن 7 محارف.');
      return;
    }
    if (newPassword.text != confirmPassword.text) {
      setState(() => error = 'تأكيد كلمة المرور الجديدة غير مطابق.');
      return;
    }
    if (currentPassword.text == newPassword.text) {
      setState(() => error = 'اختر كلمة مرور مختلفة عن الحالية.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.api.request(
        '/self/account/password-changes',
        method: 'POST',
        body: {
          'currentPassword': currentPassword.text,
          'newPassword': newPassword.text,
        },
      );
      currentPassword.clear();
      newPassword.clear();
      confirmPassword.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تغيير كلمة المرور وتأمين الحساب بنجاح.'),
          ),
        );
      }
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'إعدادات الحساب',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(18),
            children: [
              Card(
                child: SwitchListTile.adaptive(
                  secondary: Icon(
                    widget.controller.darkMode
                        ? Icons.dark_mode_rounded
                        : Icons.light_mode_rounded,
                  ),
                  title: const Text(
                    'الوضع الداكن',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: const Text('يُحفظ اختيارك تلقائيًا على هذا الجهاز'),
                  value: widget.controller.darkMode,
                  onChanged: (value) {
                    widget.controller.setDarkMode(value);
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionHeader(title: 'الملف الشخصي'),
                      const SizedBox(height: 16),
                      TextField(
                        controller: displayName,
                        decoration: const InputDecoration(
                          labelText: 'الاسم المعروض',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        enabled: false,
                        textDirection: TextDirection.ltr,
                        initialValue:
                            profile['email']?.toString() ??
                            profile['phoneE164']?.toString() ??
                            '',
                        decoration: const InputDecoration(
                          labelText: 'معرّف الدخول',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: locale,
                        decoration: const InputDecoration(labelText: 'اللغة'),
                        items: const [
                          DropdownMenuItem(value: 'ar', child: Text('العربية')),
                          DropdownMenuItem(value: 'en', child: Text('English')),
                        ],
                        onChanged: (value) =>
                            setState(() => locale = value ?? 'ar'),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: timezone,
                        decoration: const InputDecoration(
                          labelText: 'التوقيت المحلي',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'Asia/Riyadh',
                            child: Text('الرياض'),
                          ),
                          DropdownMenuItem(
                            value: 'Africa/Cairo',
                            child: Text('القاهرة'),
                          ),
                        ],
                        onChanged: (value) =>
                            setState(() => timezone = value ?? 'Asia/Riyadh'),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('الرسائل النصية'),
                        value: sms,
                        onChanged: (value) => setState(() => sms = value),
                      ),
                      FilledButton.icon(
                        onPressed: saving ? null : saveProfile,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('حفظ التغييرات'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SectionHeader(title: 'أمان الحساب'),
                      const SizedBox(height: 8),
                      const Text(
                        'بعد التغيير تُنهى الجلسات الأخرى وتظل هذه الجلسة فعالة.',
                        style: TextStyle(fontSize: 12, height: 1.6),
                      ),
                      const SizedBox(height: 14),
                      ...[
                        (currentPassword, 'كلمة المرور الحالية'),
                        (newPassword, 'كلمة المرور الجديدة'),
                        (confirmPassword, 'تأكيد كلمة المرور الجديدة'),
                      ].map(
                        (field) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextField(
                            controller: field.$1,
                            obscureText: true,
                            textDirection: TextDirection.ltr,
                            decoration: InputDecoration(labelText: field.$2),
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: saving ? null : changePassword,
                        icon: const Icon(Icons.key_rounded),
                        label: const Text('تغيير كلمة المرور'),
                      ),
                    ],
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red, height: 1.5),
                  ),
                ),
            ],
          ),
  );
}

class ApiOperationsPage extends StatefulWidget {
  const ApiOperationsPage({super.key, required this.controller});
  final GoController controller;

  @override
  State<ApiOperationsPage> createState() => _ApiOperationsPageState();
}

class _ApiOperationsPageState extends State<ApiOperationsPage> {
  List<ApiOperation> operations = [];
  bool loading = true;
  String? error;
  String query = '';
  String module = 'all';
  bool mutationsOnly = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      operations = await widget.controller.api.openApiOperations();
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final visible = operations.where((operation) {
      if (module != 'all' && operation.module != module) return false;
      if (mutationsOnly && !operation.isMutation) return false;
      return normalized.isEmpty ||
          operation.operationId.toLowerCase().contains(normalized) ||
          operation.path.toLowerCase().contains(normalized) ||
          (apiModuleLabels[operation.module] ?? '').contains(normalized);
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'كل عمليات النظام',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              'هذه الشاشة تُحمّل عقد OpenAPI الحي من خادم الإنتاج وتعرض كل العمليات المتاحة لحسابك. يتحقق الخادم من الصلاحيات وAAL لكل إجراء.',
              style: TextStyle(
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'ابحث باسم العملية أو مسار API…',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: module,
              decoration: const InputDecoration(
                labelText: 'وحدة النظام',
                prefixIcon: Icon(Icons.dashboard_customize_outlined),
              ),
              items: [
                const DropdownMenuItem(value: 'all', child: Text('كل الوحدات')),
                ...apiModuleLabels.entries.map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                ),
              ],
              onChanged: (value) => setState(() => module = value ?? 'all'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('إظهار عمليات الإنشاء والتعديل فقط'),
              value: mutationsOnly,
              onChanged: (value) => setState(() => mutationsOnly = value),
            ),
            Row(
              children: [
                Text(
                  '${visible.length} عملية',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                if (operations.isNotEmpty)
                  Text(
                    '${operations.where((item) => item.isMutation).length} إجراء كتابي',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              _ResourceMessage(
                icon: Icons.cloud_off_outlined,
                title: 'تعذر تحميل عقد API',
                body: error!,
                action: load,
              )
            else
              ...visible.map(
                (operation) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ApiOperationPage(
                          controller: widget.controller,
                          operation: operation,
                        ),
                      ),
                    ),
                    leading: _MethodBadge(method: operation.method),
                    title: Text(
                      _humanizeOperation(operation.operationId),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      operation.path,
                      textDirection: TextDirection.ltr,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10),
                    ),
                    trailing: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 14,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method});
  final String method;

  @override
  Widget build(BuildContext context) {
    final color = switch (method) {
      'GET' => Colors.blue,
      'POST' => Colors.green,
      'PATCH' => Colors.orange,
      'PUT' => Colors.purple,
      _ => Colors.red,
    };
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        method,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 10,
        ),
      ),
    );
  }
}

class ApiOperationPage extends StatefulWidget {
  const ApiOperationPage({
    super.key,
    required this.controller,
    required this.operation,
  });
  final GoController controller;
  final ApiOperation operation;

  @override
  State<ApiOperationPage> createState() => _ApiOperationPageState();
}

class _ApiOperationPageState extends State<ApiOperationPage> {
  final formKey = GlobalKey<FormState>();
  final pathValues = <String, TextEditingController>{};
  late final TextEditingController queryController;
  late final TextEditingController bodyController;
  bool loading = false;
  String? error;
  String? result;

  @override
  void initState() {
    super.initState();
    for (final match in RegExp(
      r'\{([^}]+)\}',
    ).allMatches(widget.operation.path)) {
      final key = match.group(1)!;
      final initial = switch (key) {
        'organizationId' => widget.controller.organizationId,
        'branchId' => widget.controller.branchId,
        'memberId' => widget.controller.selectedMemberId ?? '',
        _ => '',
      };
      pathValues[key] = TextEditingController(text: initial);
    }
    queryController = TextEditingController(
      text: const JsonEncoder.withIndent('  ')
          .convert(_queryPreset(widget.operation, widget.controller)),
    );
    bodyController = TextEditingController(
      text: const JsonEncoder.withIndent('  ')
          .convert(_bodyPreset(widget.operation, widget.controller)),
    );
  }

  @override
  void dispose() {
    for (final controller in pathValues.values) {
      controller.dispose();
    }
    queryController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  Future<void> execute() async {
    if (formKey.currentState?.validate() != true) return;
    if (widget.operation.isMutation) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('تأكيد تنفيذ الإجراء'),
          content: Text(
            'سيتم تنفيذ ${widget.operation.method} على بيانات الإنتاج. راجع القيم جيدًا قبل المتابعة.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('تنفيذ'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    setState(() {
      loading = true;
      error = null;
      result = null;
    });
    try {
      var path = widget.operation.path;
      for (final entry in pathValues.entries) {
        path = path.replaceAll(
          '{${entry.key}}',
          Uri.encodeComponent(entry.value.text.trim()),
        );
      }
      final queryJson = jsonDecode(queryController.text);
      final bodyJson = widget.operation.method == 'GET'
          ? null
          : jsonDecode(bodyController.text);
      if (queryJson is! Map) {
        throw const FormatException('Query must be an object');
      }
      if (bodyJson != null && bodyJson is! Map) {
        throw const FormatException('Body must be an object');
      }
      final response = await widget.controller.api.request(
        path,
        method: widget.operation.method,
        query: queryJson.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
        body: bodyJson == null ? null : Map<String, dynamic>.from(bodyJson),
      );
      result = const JsonEncoder.withIndent('  ').convert(response);
    } on FormatException catch (exception) {
      error = 'صيغة JSON غير صحيحة: ${exception.message}';
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _humanizeOperation(widget.operation.operationId),
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Row(
            children: [
              _MethodBadge(method: widget.operation.method),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  widget.operation.path,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'الوحدة: ${apiModuleLabels[widget.operation.module]}  •  Operation ID: ${widget.operation.operationId}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if (pathValues.isNotEmpty) ...[
            const SizedBox(height: 20),
            const SectionHeader(title: 'معاملات المسار'),
            const SizedBox(height: 10),
            ...pathValues.entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextFormField(
                  controller: entry.value,
                  textDirection: TextDirection.ltr,
                  decoration: InputDecoration(labelText: entry.key),
                  validator: (value) => value?.trim().isEmpty == true
                      ? 'هذه القيمة مطلوبة.'
                      : null,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const SectionHeader(title: 'Query Parameters بصيغة JSON'),
          const SizedBox(height: 8),
          TextFormField(
            controller: queryController,
            minLines: 3,
            maxLines: 10,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(hintText: '{}'),
          ),
          if (widget.operation.method != 'GET') ...[
            const SizedBox(height: 18),
            const SectionHeader(title: 'Request Body بصيغة JSON'),
            const SizedBox(height: 4),
            Text(
              'تم وضع قالب آمن حيث يتوفر. الحقول النهائية تخضع للتحقق من الخادم.',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: bodyController,
              minLines: 8,
              maxLines: 22,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(hintText: '{}'),
            ),
          ],
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.red, height: 1.5),
              ),
            ),
          if (result != null) ...[
            const SizedBox(height: 18),
            const SectionHeader(title: 'استجابة الخادم'),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withValues(alpha: .45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                result!,
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: loading ? null : execute,
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 13),
              child: Text(
                widget.operation.isMutation ? 'مراجعة وتنفيذ' : 'جلب البيانات',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Map<String, dynamic> _queryPreset(
  ApiOperation operation,
  GoController controller,
) {
  if (operation.method != 'GET') return {};
  final result = <String, dynamic>{};
  final now = DateTime.now();
  if (operation.path.endsWith('/reports/branch-daily') ||
      operation.path.endsWith('/reports/package-performance') ||
      operation.path.endsWith('/reports/details')) {
    result['from'] = now
        .subtract(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    result['to'] = now.toIso8601String().substring(0, 10);
    if (operation.path.endsWith('/reports/details')) {
      result['reportType'] = 'MEMBERS';
    }
  } else if (operation.path.contains('/reports/') &&
      !operation.path.endsWith('/branch-snapshots') &&
      !operation.path.endsWith('/member-debts') &&
      !operation.path.endsWith('/subscription-status-chart')) {
    result['from'] = now.subtract(const Duration(days: 30)).toIso8601String();
    result['to'] = now.toIso8601String();
  }
  if (operation.path.endsWith('/session-slots') ||
      operation.path.endsWith('/crm/follow-ups/cloud')) {
    result['from'] = now.toUtc().toIso8601String();
    result['to'] = now.add(const Duration(days: 30)).toUtc().toIso8601String();
  }
  if (operation.path.contains('/stream')) return result;
  if (operation.path.contains('/organizations/')) {
    result['branchId'] = controller.branchId;
  }
  if (operation.operationId.startsWith('list')) result['limit'] = 100;
  return result;
}

Map<String, dynamic> _bodyPreset(
  ApiOperation operation,
  GoController controller,
) {
  final branch = controller.branchId;
  final member = controller.selectedMemberId ?? '';
  final known = <String, Map<String, dynamic>>{
    'updateOwnAccountProfile': {
      'displayName': '',
      'preferredLocale': 'ar',
      'preferredTimezone': 'Asia/Riyadh',
      'smsNotificationsEnabled': true,
      'whatsappNotificationsEnabled': true,
      'expectedVersion': 1,
    },
    'changeOwnPassword': {'currentPassword': '', 'newPassword': ''},
    'registerMember': {
      'registrationBranchId': branch,
      'name': '',
      'gender': 'UNSPECIFIED',
      'nationalId': '',
      'contacts': <dynamic>[],
    },
    'recordManualAttendance': {'branchId': branch, 'memberId': member},
    'createCommercialQuote': {
      'branchId': branch,
      'targetType': 'PACKAGE',
      'targetId': '',
      'quantity': 1,
    },
    'checkoutOrder': {
      'sellingBranchId': branch,
      'memberId': member,
      'lines': <dynamic>[],
    },
    'recordPayment': {
      'collectionBranchId': branch,
      'method': 'CARD',
      'amountMinor': '0',
      'allocations': <dynamic>[],
    },
    'createManualReservation': {
      'branchId': branch,
      'memberId': member,
      'resourceId': '',
      'serviceId': '',
      'type': 'CLASS',
      'sessionSlotId': '',
      'seats': 1,
      'participantCount': 1,
    },
    'createCrmLead': {
      'branchId': branch,
      'fullName': '',
      'originType': 'WALK_IN',
      'interestType': 'GENERAL',
      'phone': '+9665XXXXXXXX',
    },
    'createPublicOnlineRequest': {
      'type': 'MEMBERSHIP_INTEREST',
      'fullName': '',
      'phoneE164': '+9665XXXXXXXX',
    },
    'createEmployee': {
      'name': '',
      'password': '',
      'hireDate': DateTime.now().toIso8601String().substring(0, 10),
      'initialBranchId': branch,
      'initialPositionId': '',
    },
    'recordReservationOutcome': {'expectedVersion': 1, 'action': 'COMPLETE'},
    'transitionRestaurantOrder': {
      'expectedVersion': 1,
      'action': 'START_PREPARING',
    },
    'transitionExpense': {
      'branchId': branch,
      'expectedVersion': 1,
      'action': 'SUBMIT',
    },
    'transitionOnlineRequest': {
      'branchId': branch,
      'status': 'APPROVED',
      'expectedVersion': 1,
    },
    'transitionCrmLead': {'status': 'CONTACTED', 'expectedVersion': 1},
    'requestReportingRebuild': {
      'fromDate': DateTime.now()
          .subtract(const Duration(days: 30))
          .toIso8601String()
          .substring(0, 10),
      'toDate': DateTime.now().toIso8601String().substring(0, 10),
      'branchId': branch,
    },
  };
  if (known.containsKey(operation.operationId)) {
    return known[operation.operationId]!;
  }
  if (operation.path.contains('/cancellations') ||
      operation.path.contains('/revocations') ||
      operation.path.contains('/voids')) {
    return {'reason': '', 'expectedVersion': 1};
  }
  if (operation.path.contains('/transitions')) {
    return {'status': 'COMPLETED', 'expectedVersion': 1, 'reason': ''};
  }
  if (operation.method == 'PATCH' || operation.method == 'PUT') {
    return {'expectedVersion': 1};
  }
  return {};
}

String _humanizeOperation(String value) {
  final spaced = value.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match.group(1)} ${match.group(2)}',
  );
  return spaced[0].toUpperCase() + spaced.substring(1);
}

Future<void> _openWorkflow(
  BuildContext context,
  GoController controller,
  MobileWorkflow workflow,
) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => WorkflowPage(controller: controller, workflow: workflow),
    ),
  );
  if (saved != true || !context.mounted) return;
  await controller.refresh();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(workflow.successMessage)));
}

bool _bookingTimezonesReady = false;

String bookingSlotPeriodLabel(Map row, {String zone = 'Asia/Riyadh'}) {
  final start = DateTime.tryParse('${row['startsAt']}');
  final end = DateTime.tryParse('${row['endsAt']}');
  if (start == null || end == null) return 'موعد غير صالح';
  if (!_bookingTimezonesReady) {
    timezone_data.initializeTimeZones();
    _bookingTimezonesReady = true;
  }
  final location = timezone.getLocation(zone);
  final localStart = timezone.TZDateTime.from(start, location);
  final localEnd = timezone.TZDateTime.from(end, location);
  String time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  return '${localStart.day.toString().padLeft(2, '0')}/${localStart.month.toString().padLeft(2, '0')}/${localStart.year} · ${time(localStart)} – ${time(localEnd)}';
}

String bookingAvailabilityLabel(Map<String, dynamic> rule) {
  const days = [
    'الأحد',
    'الاثنين',
    'الثلاثاء',
    'الأربعاء',
    'الخميس',
    'الجمعة',
    'السبت',
  ];
  final day = int.tryParse('${rule['dayOfWeek']}');
  String short(dynamic value) =>
      value?.toString().split(':').take(2).join(':') ?? '';
  return '${day != null && day >= 0 && day < 7 ? days[day] : 'يوم غير محدد'}: ${short(rule['startLocal'])} – ${short(rule['endLocal'])}'
      '${rule['validFrom'] != null ? ' · من ${rule['validFrom']}${rule['validUntil'] != null ? ' حتى ${rule['validUntil']}' : ' دون تاريخ انتهاء'}' : ''}';
}

class BookingAvailabilityCard extends StatelessWidget {
  const BookingAvailabilityCard({
    super.key,
    required this.rules,
    this.loading = false,
    this.error,
    this.timezone = '',
    this.onRetry,
  });
  final List<Map<String, dynamic>> rules;
  final bool loading;
  final String? error;
  final String timezone;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.access_time_rounded, size: 20),
              SizedBox(width: 8),
              Text(
                'فترات الإتاحة',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loading)
            const LinearProgressIndicator()
          else if (error != null) ...[
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            if (onRetry != null)
              TextButton.icon(
                onPressed: () => unawaited(onRetry!()),
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة تحميل الإتاحة'),
              ),
          ] else if (rules.isEmpty)
            const Text('لا توجد فترات إتاحة سارية أو قادمة لهذا المورد.')
          else
            ...rules.map(
              (rule) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  bookingAvailabilityLabel(rule),
                  style: const TextStyle(fontSize: 12, height: 1.7),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'الساعات بتوقيت الفرع${timezone.isNotEmpty ? ' ($timezone)' : ''}. هذه فترات التشغيل، وليست ضمانًا لشغور الوقت؛ يتحقق النظام من الحجوزات والحجب عند التأكيد.',
            style: TextStyle(
              fontSize: 11,
              height: 1.7,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class WorkflowPage extends StatefulWidget {
  const WorkflowPage({
    super.key,
    required this.controller,
    required this.workflow,
    this.initialValues = const {},
    this.lockedFields = const {},
    this.selectionLabel,
  });
  final GoController controller;
  final MobileWorkflow workflow;
  final Map<String, String> initialValues;
  final Set<String> lockedFields;
  final String? selectionLabel;

  @override
  State<WorkflowPage> createState() => _WorkflowPageState();
}

class _WorkflowPageState extends State<WorkflowPage> {
  final formKey = GlobalKey<FormState>();
  final controllers = <String, TextEditingController>{};
  final references = <String, List<Map<String, dynamic>>>{};
  bool loadingReferences = true;
  bool saving = false;
  String? error;
  List<Map<String, dynamic>> bookingAvailability = [];
  bool loadingAvailability = false;
  String? availabilityError;
  String availabilityTimezone = '';
  int availabilityGeneration = 0;

  bool get isReservation => const {
    'createManualReservation',
    'checkoutSelfBooking',
  }.contains(widget.workflow.operationId);

  Future<void> _loadBookingAvailability() async {
    if (!isReservation) return;
    final resource = controllers['resourceId']?.text ?? '';
    final current = ++availabilityGeneration;
    setState(() {
      bookingAvailability = [];
      availabilityError = null;
      availabilityTimezone = '';
      loadingAvailability = resource.isNotEmpty;
    });
    if (resource.isEmpty) return;
    try {
      dynamic rules;
      String timezone =
          widget.controller.branches
              .where(
                (branch) =>
                    branch['id']?.toString() == widget.controller.branchId,
              )
              .firstOrNull?['timezone']
              ?.toString() ??
          'Asia/Riyadh';
      if (widget.workflow.operationId == 'checkoutSelfBooking') {
        final data = await widget.controller.api.request(
          '/self/organizations/${widget.controller.organizationId}/bookable-resources',
          query: {'branchId': widget.controller.branchId},
        );
        final rows = data is List
            ? data
            : data is Map
            ? data['items']
            : null;
        final selected = rows is List
            ? rows
                  .whereType<Map>()
                  .where((row) => row['id']?.toString() == resource)
                  .firstOrNull
            : null;
        rules = selected?['availabilityRules'];
        timezone = selected?['timezone']?.toString() ?? '';
        if (rules is! List) {
          throw Exception(
            'لم تصل بيانات الإتاحة لهذا المورد. حدّث بيانات الخادم ثم حاول مجددًا.',
          );
        }
      } else {
        final data = await widget.controller.api.request(
          '/organizations/${widget.controller.organizationId}/bookable-resources/$resource/availability-rules',
        );
        rules = data is List
            ? data
            : data is Map
            ? data['items']
            : null;
        if (rules is! List) {
          throw Exception('تعذر تحميل فترات الإتاحة. حاول مجددًا.');
        }
      }
      if (!mounted || current != availabilityGeneration) return;
      setState(() {
        bookingAvailability = (rules as List)
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList();
        availabilityTimezone = timezone;
        for (final slot
            in references['sessionSlotId'] ?? <Map<String, dynamic>>[]) {
          slot['timezone'] = timezone.isEmpty ? 'Asia/Riyadh' : timezone;
        }
      });
    } catch (exception) {
      if (mounted && current == availabilityGeneration) {
        setState(() => availabilityError = _errorMessage(exception));
      }
    } finally {
      if (mounted && current == availabilityGeneration) {
        setState(() => loadingAvailability = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    for (final field in widget.workflow.fields) {
      var initial = field.initialValue;
      if (field.type == WorkflowFieldType.dateTime &&
          field.autoFillDate &&
          initial.isEmpty) {
        final date = field.name.toLowerCase().contains('end')
            ? now.add(const Duration(hours: 1))
            : now;
        initial = _localDateTimeValue(date);
      }
      if (field.type == WorkflowFieldType.date &&
          field.autoFillDate &&
          initial.isEmpty) {
        initial = now.toIso8601String().substring(0, 10);
      }
      controllers[field.name] = TextEditingController(text: initial);
    }
    for (final entry in widget.initialValues.entries) {
      controllers[entry.key]?.text = entry.value;
    }
    if (widget.workflow.operationId == 'createManualReservation' &&
        !widget.controller.can('sales.checkout')) {
      controllers['billingMode']?.text = 'OPERATIONAL';
    }
    unawaited(_loadReferences());
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _resolve(String path) {
    var resolved = path
        .replaceAll('{organizationId}', widget.controller.organizationId)
        .replaceAll('{branchId}', widget.controller.branchId)
        .replaceAll('{memberId}', widget.controller.selectedMemberId ?? '');
    for (final entry in controllers.entries) {
      resolved = resolved.replaceAll('{${entry.key}}', entry.value.text);
    }
    return resolved;
  }

  bool _isVisible(WorkflowField field) {
    if (widget.lockedFields.contains(field.name)) return false;
    if (field.type == WorkflowFieldType.hidden) return false;
    if (field.visibleWhenField == null) return true;
    final value = controllers[field.visibleWhenField]?.text ?? '';
    return field.visibleWhenValues.contains(value);
  }

  Future<void> _loadReferences() async {
    try {
      for (final field in widget.workflow.fields.where(
        (item) =>
            !widget.lockedFields.contains(item.name) &&
            (item.type == WorkflowFieldType.reference ||
                item.type == WorkflowFieldType.multiReference),
      )) {
        await _loadReference(field);
      }
    } catch (exception) {
      error = exception.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) {
      await _loadBookingAvailability();
      if (mounted) setState(() => loadingReferences = false);
    }
  }

  Future<void> _loadReference(WorkflowField field) async {
    if (field.name == 'sessionSlotId' &&
        controllers['resourceType']?.text == 'COURT') {
      references[field.name] = [];
      return;
    }
    if (field.referencePath == null) return;
    final path = _resolve(field.referencePath!);
    if (path.contains(RegExp(r'\{[^}]+\}'))) {
      references[field.name] = [];
      return;
    }
    final query = resourceQueryFor(path, widget.controller.branchId);
    if (path.endsWith('/session-slots')) {
      query
        ..remove('limit')
        ..['from'] = DateTime.now().toUtc().toIso8601String()
        ..['to'] = DateTime.now()
            .add(const Duration(days: 30))
            .toUtc()
            .toIso8601String();
      if (!path.startsWith('/self/')) query.remove('branchId');
    }
    final data = await widget.controller.api.request(path, query: query);
    var rows = data is List
        ? data.whereType<Map>().toList()
        : data is Map && data['items'] is List
        ? (data['items'] as List).whereType<Map>().toList()
        : <Map>[];
    if (widget.workflow.operationId == 'createSessionSlot' &&
        field.name == 'resourceId') {
      rows = rows.where((row) => row['type']?.toString() != 'COURT').toList();
    }
    if (widget.workflow.operationId == 'checkoutSelfBooking' &&
        field.name == 'sessionSlotId') {
      rows = rows.where((row) {
        final available = num.tryParse(
          '${row['availableCount'] ?? row['remainingCapacity'] ?? ''}',
        );
        return (row['status'] == null || row['status'] == 'OPEN') &&
            (available == null || available > 0);
      }).toList();
    }
    references[field.name] = rows
        .map(
          (row) => <String, dynamic>{
            ...Map<String, dynamic>.from(row),
            if (field.name == 'sessionSlotId')
              'timezone': availabilityTimezone.isEmpty
                  ? 'Asia/Riyadh'
                  : availabilityTimezone,
          },
        )
        .toList();
    if (controllers[field.name]?.text.isEmpty == true && rows.length == 1) {
      controllers[field.name]?.text = _referenceId(rows.first);
      _copyReferenceValues(field, Map<String, dynamic>.from(rows.first));
    }
  }

  void _copyReferenceValues(
    WorkflowField field,
    Map<String, dynamic> selected,
  ) {
    for (final binding in field.copyValues.entries) {
      final copied =
          selected[binding.value] ??
          (binding.value == 'resourceType'
              ? selected['type']
              : binding.value == 'type'
              ? selected['resourceType']
              : null);
      controllers[binding.key]?.text = copied?.toString() ?? '';
    }
  }

  Future<void> submit() async {
    if (formKey.currentState?.validate() != true) return;
    if (isReservation &&
        controllers['resourceType']?.text == 'COURT' &&
        (loadingAvailability ||
            availabilityError != null ||
            bookingAvailability.isEmpty)) {
      setState(
        () =>
            error = 'لا يمكن تأكيد الحجز قبل تحميل فترات الإتاحة لهذا المورد.',
      );
      return;
    }
    final values = controllers.map(
      (key, value) => MapEntry(key, value.text.trim()),
    );
    if (widget.workflow.operationId == 'createCrmLead' &&
        values['phone']!.isEmpty &&
        values['email']!.isEmpty) {
      setState(
        () => error = 'أدخل رقم جوال أو بريدًا إلكترونيًا واحدًا على الأقل.',
      );
      return;
    }
    if (widget.workflow.operationId == 'createBookableResource' &&
        values['type'] != 'CLASS' &&
        values['capacity'] != '1') {
      controllers['capacity']?.text = '1';
    }
    if (widget.workflow.operationId.startsWith('freezeSelfSubscription:')) {
      if ((values['reason'] ?? '').length < 3) {
        setState(() => error = 'اكتب سببًا واضحًا من 3 أحرف على الأقل.');
        return;
      }
      if (values['freezeMode'] == 'LATER') {
        final scheduled = DateTime.tryParse(values['scheduledStartAt'] ?? '');
        if (scheduled == null || !scheduled.isAfter(DateTime.now())) {
          setState(() => error = 'اختر موعدًا مستقبليًا صالحًا لبدء التجميد.');
          return;
        }
      }
    }
    if (widget.workflow.operationId.startsWith('cancelSelfFreezeSchedule:') &&
        (values['reason'] ?? '').length < 3) {
      setState(() => error = 'اكتب سببًا واضحًا من 3 أحرف على الأقل.');
      return;
    }
    if (widget.workflow.operationId == 'createEmployee' ||
        widget.workflow.operationId.startsWith('resetEmployeePassword:')) {
      if ((values['password'] ?? '').length < 7) {
        setState(() => error = 'كلمة المرور يجب ألا تقل عن 7 محارف.');
        return;
      }
      if (values['password'] != values['confirmPassword']) {
        setState(() => error = 'تأكيد كلمة المرور غير مطابق.');
        return;
      }
    }
    final isBookingWorkflow = const {
      'createManualReservation',
      'checkoutSelfBooking',
    }.contains(widget.workflow.operationId);
    if (isBookingWorkflow &&
        ((values['serviceId'] ?? '').isEmpty ||
            (values['resourceType'] ?? '').isEmpty)) {
      setState(() => error = 'بيانات المورد غير مكتملة؛ أعد اختيار المورد.');
      return;
    }
    if (isBookingWorkflow) {
      final type = values['resourceType'];
      if (type != 'COURT' && (values['sessionSlotId'] ?? '').isEmpty) {
        setState(() => error = 'اختر موعدًا متاحًا قبل تأكيد الحجز.');
        return;
      }
      if (type == 'CLASS' &&
          widget.workflow.operationId == 'createManualReservation') {
        final seats = int.tryParse(values['seats'] ?? '');
        if (seats == null || seats < 1) {
          setState(() => error = 'أدخل عدد مقاعد صحيحًا لا يقل عن مقعد واحد.');
          return;
        }
      }
      if (type == 'COURT') {
        final participants = int.tryParse(values['participantCount'] ?? '');
        final startText = values['startsAt'] ?? '';
        final endText = values['endsAt'] ?? '';
        final start = DateTime.tryParse(startText);
        final end = DateTime.tryParse(endText);
        if (participants == null || participants < 1 || participants > 100) {
          setState(() => error = 'أدخل عدد مشاركين صحيحًا من 1 إلى 100.');
          return;
        }
        if (start == null || end == null || !end.isAfter(start)) {
          setState(
            () => error = 'وقت نهاية الحجز يجب أن يكون بعد وقت البداية.',
          );
          return;
        }
        if (!start.isAfter(DateTime.now())) {
          setState(() => error = 'اختر موعد حجز في المستقبل.');
          return;
        }
        if (startText.substring(0, 10) != endText.substring(0, 10)) {
          setState(() => error = 'يجب أن يبدأ الحجز وينتهي في اليوم نفسه.');
          return;
        }
      }
      if (widget.workflow.operationId == 'createManualReservation' &&
          values['billingMode'] == 'INVOICE' &&
          !widget.controller.can('sales.checkout')) {
        setState(
          () => error =
              'لا تملك صلاحية إصدار فاتورة. اختر حجزًا تشغيليًا بلا مقابل.',
        );
        return;
      }
    }
    if (widget.workflow.operationId == 'recordSplitPayment' &&
        values['firstMethod'] == values['secondMethod']) {
      setState(() => error = 'اختر وسيلتي دفع مختلفتين للتحصيل المقسّم.');
      return;
    }
    if (widget.workflow.operationId == 'closeCashierShift' &&
        (values['reason'] ?? '').length < 3) {
      setState(() => error = 'اكتب ملاحظة إغلاق واضحة من 3 أحرف على الأقل.');
      return;
    }
    if (const {
      'createBookingAvailability',
      'createTrainerAvailability',
    }.contains(widget.workflow.operationId)) {
      final timePattern = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
      final start = values['startLocal'] ?? '';
      final end = values['endLocal'] ?? '';
      if (!timePattern.hasMatch(start) || !timePattern.hasMatch(end)) {
        setState(() => error = 'اكتب الوقت بصيغة 24 ساعة مثل 09:30.');
        return;
      }
      if (start.compareTo(end) >= 0) {
        setState(() => error = 'وقت النهاية يجب أن يكون بعد وقت البداية.');
        return;
      }
    }
    if (const {
      'createBookingBlackout',
      'createSessionSlot',
    }.contains(widget.workflow.operationId)) {
      final start = DateTime.tryParse(values['startsAt'] ?? '');
      final end = DateTime.tryParse(values['endsAt'] ?? '');
      if (start == null || end == null || !end.isAfter(start)) {
        setState(() => error = 'تاريخ ووقت النهاية يجب أن يكونا بعد البداية.');
        return;
      }
    }
    if (const {
          'scheduleServiceAvailability',
          'createBookingAvailability',
          'createTrainerAvailability',
          'assignEmployee',
          'assignTrainerToBranch',
          'assignMemberToTrainer',
        }.contains(widget.workflow.operationId) &&
        (values['validUntil'] ?? '').isNotEmpty) {
      final from = DateTime.tryParse(values['validFrom'] ?? '');
      final until = DateTime.tryParse(values['validUntil'] ?? '');
      if (from != null && until != null && until.isBefore(from)) {
        setState(() => error = 'تاريخ النهاية لا يمكن أن يسبق تاريخ البداية.');
        return;
      }
    }
    if (widget.workflow.operationId == 'rescheduleSubscriptionStart' &&
        (values['reason'] ?? '').length < 3) {
      setState(() => error = 'اكتب سببًا واضحًا من 3 أحرف على الأقل.');
      return;
    }
    if (widget.workflow.operationId == 'createWhatsAppCampaign') {
      setState(() {
        saving = true;
        error = null;
      });
      try {
        final data = await widget.controller.api.request(
          '/communications/capabilities',
        );
        final whatsapp = data is Map && data['whatsapp'] is Map
            ? data['whatsapp'] as Map
            : const <String, dynamic>{};
        if (whatsapp['enabled'] != true) {
          setState(
            () => error =
                whatsapp['message']?.toString() ??
                'قناة واتساب غير مهيأة على الخادم حاليًا.',
          );
          return;
        }
      } catch (exception) {
        setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    Map<String, dynamic>? audiencePreview;
    if (widget.workflow.operationId == 'createCommunicationCampaign') {
      setState(() {
        saving = true;
        error = null;
      });
      try {
        final campaign = widget.workflow.body(values, widget.controller);
        final data = await widget.controller.api.request(
          '/organizations/${widget.controller.organizationId}/communication-campaigns/audience-preview',
          method: 'POST',
          body: {
            if (campaign['branchId'] != null) 'branchId': campaign['branchId'],
            'audienceType': campaign['audienceType'],
            'audienceFilter': campaign['audienceFilter'],
          },
        );
        audiencePreview = data is Map
            ? Map<String, dynamic>.from(data)
            : <String, dynamic>{};
        if ((int.tryParse('${audiencePreview['total'] ?? 0}') ?? 0) == 0) {
          setState(() => error = 'لا يوجد مستلمون يطابقون الاستهداف الحالي.');
          return;
        }
        final channels = (campaign['channels'] as List?)?.cast<String>() ?? [];
        if (channels.contains('IN_APP') &&
            (int.tryParse('${audiencePreview['inAppEligible'] ?? 0}') ?? 0) ==
                0) {
          setState(
            () => error = 'المستلمون المحددون غير مرتبطين بحسابات دخول، لذلك لا يمكن إرسال إشعار داخل التطبيق لهم.',
          );
          return;
        }
      } catch (exception) {
        setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    Map<String, dynamic>? bookingQuote;
    if (const [
      'checkoutSelfBooking',
      'checkoutSelfService',
      'checkoutSelfMemberPackage',
    ].contains(widget.workflow.operationId)) {
      if (!_canRunWorkflow(widget.controller, widget.workflow)) {
        setState(
          () => error = 'ليس لديك صلاحية لتنفيذ هذا الطلب للعضو الحالي.',
        );
        return;
      }
      setState(() {
        saving = true;
        error = null;
      });
      try {
        final isPackage =
            widget.workflow.operationId == 'checkoutSelfMemberPackage';
        final quote = await widget.controller.api.request(
          '/self/organizations/${widget.controller.organizationId}/quotes',
          method: 'POST',
          body: {
            'branchId': widget.controller.branchId,
            'targetType': isPackage ? 'PACKAGE' : 'SERVICE',
            'targetId': values[isPackage ? 'packageId' : 'serviceId'],
            'quantity': 1,
            'memberId': widget.controller.selectedMemberId,
            if ((values['promoCode'] ?? '').isNotEmpty)
              'promoCode': values['promoCode'],
          },
        );
        if (quote is! Map || quote['grossMinor'] == null) {
          throw Exception('تعذر التحقق من السعر النهائي. حاول مرة أخرى.');
        }
        bookingQuote = Map<String, dynamic>.from(quote);
      } catch (exception) {
        if (mounted) setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    if (widget.workflow.operationId == 'createManualReservation') {
      setState(() {
        saving = true;
        error = null;
      });
      try {
        if (values['resourceType'] == 'COURT') {
          final availability = await widget.controller.api.request(
            '/organizations/${widget.controller.organizationId}/bookable-resources/${values['resourceId']}/availability-rules',
          );
          final rules = availability is List
              ? availability
              : availability is Map && availability['items'] is List
              ? availability['items'] as List
              : const <dynamic>[];
          if (rules.isEmpty) {
            setState(
              () => error = 'هذا المورد غير جاهز للحجز؛ أضف أيام وساعات الإتاحة أولًا من إعداد النظام.',
            );
            return;
          }
        }
        if (values['billingMode'] == 'INVOICE') {
          final quantity = values['resourceType'] == 'CLASS'
              ? int.tryParse(values['seats'] ?? '') ?? 1
              : 1;
          final quote = await widget.controller.api.request(
            '/organizations/${widget.controller.organizationId}/quotes',
            method: 'POST',
            body: {
              'branchId': widget.controller.branchId,
              'targetType': 'SERVICE',
              'targetId': values['serviceId'],
              'quantity': quantity,
              if (values['customerType'] == 'MEMBER')
                'memberId': values['memberId'],
            },
          );
          bookingQuote = quote is Map
              ? Map<String, dynamic>.from(quote)
              : <String, dynamic>{};
        }
      } catch (exception) {
        setState(() => error = _errorMessage(exception));
        return;
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.workflow.title),
        content: bookingQuote != null
            ? SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.selectionLabel != null)
                      Text(
                        widget.selectionLabel!,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    if (bookingQuote['netMinor'] != null)
                      Text(
                        'الصافي قبل الضريبة: ${_money(bookingQuote['netMinor'])}',
                      ),
                    if (bookingQuote['taxMinor'] != null)
                      Text('الضريبة: ${_money(bookingQuote['taxMinor'])}'),
                    const Divider(),
                    Text(
                      'الإجمالي: ${_money(bookingQuote['grossMinor'])}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'سيُنشأ الطلب والفاتورة. يرجى السداد في استقبال النادي لإتمام الاشتراك أو الخدمة أو تأكيد الموعد.',
                      style: TextStyle(height: 1.6),
                    ),
                  ],
                ),
              )
            : audiencePreview == null
            ? Text('راجع البيانات قبل إرسالها إلى نظام الإنتاج.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('نتيجة معاينة الجمهور قبل الإرسال:'),
                  const SizedBox(height: 12),
                  Text(
                    '${audiencePreview['total'] ?? 0} مستلم مطابق',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    '${audiencePreview['inAppEligible'] ?? 0} يمكنهم استقبال الإشعار داخل التطبيق',
                    style: const TextStyle(height: 1.6),
                  ),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      var path = _resolve(widget.workflow.path);
      var body = widget.workflow.body(values, widget.controller);
      if (widget.workflow.operationId == 'createManualReservation' &&
          values['billingMode'] == 'INVOICE') {
        final type = values['resourceType'];
        final quantity = type == 'CLASS'
            ? int.tryParse(values['seats'] ?? '') ?? 1
            : 1;
        path = '/organizations/${widget.controller.organizationId}/orders';
        body = {
          'sellingBranchId': widget.controller.branchId,
          if (values['customerType'] == 'MEMBER')
            'memberId': values['memberId'],
          'lines': [
            {
              'type': 'BOOKING',
              'targetId': values['serviceId'],
              'quantity': quantity,
              'booking': {
                'resourceId': values['resourceId'],
                'type': type,
                'seats': quantity,
                'participantCount': type == 'COURT'
                    ? int.tryParse(values['participantCount'] ?? '') ?? 1
                    : quantity,
                if (values['customerType'] == 'VISITOR') ...{
                  'guestName': values['guestName'],
                  'guestPhoneE164': values['guestPhoneE164']?.replaceAll(
                    RegExp(r'[\s()-]'),
                    '',
                  ),
                  if (values['guestEmail']?.isNotEmpty == true)
                    'guestEmail': values['guestEmail']?.toLowerCase(),
                },
                if (type == 'COURT') ...{
                  'startsAt': _asIso(values['startsAt']),
                  'endsAt': _asIso(values['endsAt']),
                } else
                  'sessionSlotId': values['sessionSlotId'],
              },
            },
          ],
        };
      }
      final result = await widget.controller.api.request(
        path,
        method: widget.workflow.method,
        body: body,
      );
      if ((widget.workflow.operationId == 'registerAccessDevice' ||
              widget.workflow.operationId.startsWith(
                'rotateAccessDeviceKey:',
              )) &&
          result is Map &&
          mounted) {
        final apiKey = result['apiKey']?.toString() ?? '';
        if (apiKey.isNotEmpty) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              icon: const Icon(Icons.vpn_key_rounded, color: Colors.orange),
              title: const Text('احفظ مفتاح اتصال اللوحة'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'لن يعرض النظام هذا المفتاح مرة أخرى. انسخه الآن وضعه في إعداد أداة ربط البوابة.',
                      textAlign: TextAlign.center,
                      style: TextStyle(height: 1.55),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(dialogContext)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectableText(
                        apiKey,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: apiKey));
                    if (!dialogContext.mounted) return;
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('تم نسخ مفتاح الاتصال.')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('نسخ المفتاح'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('حفظته'),
                ),
              ],
            ),
          );
        }
      }
      if (widget.workflow.operationId == 'issueAccessBarcode' &&
          result is Map &&
          mounted) {
        final issued = Map<String, dynamic>.from(result);
        final barcodeValue = issued['credentialValue']?.toString() ?? '';
        if (barcodeValue.isNotEmpty) {
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: const Text('بطاقة الدخول جاهزة'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/go-fitness-emblem.png',
                      width: 74,
                      height: 52,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      issued['subjectName']?.toString() ??
                          issued['name']?.toString() ??
                          'بطاقة GO Fitness',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(12),
                      child: barcode_ui.BarcodeWidget(
                        barcode: barcode_ui.Barcode.code39(),
                        data: barcodeValue,
                        width: 260,
                        height: 92,
                        drawText: false,
                        color: Colors.black,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      barcodeValue,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'احفظ البطاقة أو اعرضها مباشرة أمام قارئ البوابة.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton.icon(
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('تم'),
                ),
              ],
            ),
          );
        }
      }
      if (widget.workflow.operationId == 'createBarcodePrintBatch' &&
          result is Map &&
          result['items'] is List &&
          mounted) {
        final items = (result['items'] as List)
            .whereType<Map>()
            .map(Map<String, dynamic>.from)
            .toList();
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('دفعة الباركود جاهزة (${items.length})'),
            content: SizedBox(
              width: 420,
              height: MediaQuery.sizeOf(dialogContext).height * .6,
              child: ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const Divider(height: 28),
                itemBuilder: (_, index) {
                  final item = items[index];
                  final code =
                      item['credentialValue']?.toString() ??
                      item['barcodeValue']?.toString() ??
                      '';
                  return Column(
                    children: [
                      Text(
                        item['subjectName']?.toString() ??
                            item['memberName']?.toString() ??
                            'بطاقة ${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 10),
                      if (code.isNotEmpty)
                        Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(10),
                          child: barcode_ui.BarcodeWidget(
                            barcode: barcode_ui.Barcode.code39(),
                            data: code,
                            height: 72,
                            drawText: true,
                            color: Colors.black,
                            backgroundColor: Colors.white,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('تم'),
              ),
            ],
          ),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.workflow.title,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: Form(
      key: formKey,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: goYellow.withValues(alpha: .11),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(widget.workflow.icon, color: Colors.amber[800]),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.workflow.description,
                    style: const TextStyle(height: 1.6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (widget.selectionLabel != null) ...[
            Text(
              widget.selectionLabel!,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
          ],
          if (isReservation &&
              (controllers['resourceId']?.text.isNotEmpty ?? false))
            BookingAvailabilityCard(
              rules: bookingAvailability,
              loading: loadingAvailability,
              error: availabilityError,
              timezone: availabilityTimezone,
              onRetry: _loadBookingAvailability,
            ),
          if (loadingReferences)
            const LinearProgressIndicator()
          else
            ...widget.workflow.fields.where(_isVisible).map(_buildField),
          if (!loadingReferences &&
              widget.workflow.operationId == 'createManualReservation')
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: controllers['billingMode']?.text == 'INVOICE'
                    ? Colors.blue.withValues(alpha: .08)
                    : Colors.orange.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: controllers['billingMode']?.text == 'INVOICE'
                      ? Colors.blue.withValues(alpha: .25)
                      : Colors.orange.withValues(alpha: .3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    controllers['billingMode']?.text == 'INVOICE'
                        ? Icons.receipt_long_outlined
                        : Icons.info_outline_rounded,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      controllers['billingMode']?.text == 'INVOICE'
                          ? 'سيتم التحقق من سعر الخدمة وإنشاء فاتورة. يبقى الحجز بانتظار التحصيل حتى يتم الدفع.'
                          : 'حجز تشغيلي بلا مقابل: سيُؤكد مباشرة ولن تظهر له فاتورة أو مبلغ للتحصيل.',
                      style: const TextStyle(fontSize: 12, height: 1.55),
                    ),
                  ),
                ],
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                error!,
                style: const TextStyle(color: Colors.red, height: 1.5),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: saving || loadingReferences || loadingAvailability
                ? null
                : submit,
            icon: saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(widget.workflow.icon),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(widget.workflow.submitLabel),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildField(WorkflowField field) {
    final controller = controllers[field.name]!;
    if (field.type == WorkflowFieldType.checkbox) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: FormField<bool>(
          initialValue: controller.text == 'true',
          builder: (state) => SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(field.label),
            value: controller.text == 'true',
            onChanged: (value) => setState(() {
              controller.text = '$value';
              state.didChange(value);
            }),
          ),
        ),
      );
    }
    if (field.type == WorkflowFieldType.select) {
      final choices =
          widget.workflow.operationId == 'createManualReservation' &&
              field.name == 'billingMode' &&
              !widget.controller.can('sales.checkout')
          ? field.choices.where((choice) => choice.value != 'INVOICE').toList()
          : field.choices;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: controller.text.isEmpty ? null : controller.text,
          decoration: InputDecoration(labelText: field.label),
          items: choices
              .map(
                (choice) => DropdownMenuItem(
                  value: choice.value,
                  child: Text(choice.label),
                ),
              )
              .toList(),
          onChanged: (value) => setState(() => controller.text = value ?? ''),
          validator: (value) => field.required && (value?.isEmpty ?? true)
              ? 'هذا الحقل مطلوب.'
              : null,
        ),
      );
    }
    if (field.type == WorkflowFieldType.reference) {
      final rows = references[field.name] ?? [];
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          initialValue: rows.any((row) => _referenceId(row) == controller.text)
              ? controller.text
              : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: field.label,
            helperText: rows.isEmpty
                ? field.name == 'sessionSlotId'
                      ? 'لا توجد مواعيد مفتوحة خلال الثلاثين يومًا القادمة.'
                      : 'لا توجد عناصر متاحة في السياق الحالي.'
                : field.name == 'sessionSlotId' && controller.text.isNotEmpty
                ? rows
                      .where((row) => _referenceId(row) == controller.text)
                      .map((row) => _referenceLabel(row, field))
                      .firstOrNull
                : null,
            helperMaxLines: 3,
          ),
          items: rows
              .map(
                (row) => DropdownMenuItem(
                  value: _referenceId(row),
                  child: Text(
                    _referenceLabel(row, field),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (value) async {
            controller.text = value ?? '';
            final selected = rows
                .where((row) => _referenceId(row) == value)
                .firstOrNull;
            if (selected != null) {
              _copyReferenceValues(field, selected);
            }
            if (field.name == 'resourceId') await _loadBookingAvailability();
            for (final dependent in widget.workflow.fields.where(
              (item) => item.referencePath?.contains('{${field.name}}') == true,
            )) {
              controllers[dependent.name]?.clear();
              await _loadReference(dependent);
            }
            if (mounted) setState(() {});
          },
          validator: (value) => field.required && (value?.isEmpty ?? true)
              ? 'اختر ${field.label}.'
              : null,
        ),
      );
    }
    if (field.type == WorkflowFieldType.multiReference) {
      final rows = references[field.name] ?? [];
      final selected = controller.text
          .split(',')
          .where((value) => value.isNotEmpty)
          .toSet();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: FormField<String>(
          initialValue: controller.text,
          validator: (_) => field.required && selected.isEmpty
              ? 'اختر عنصرًا واحدًا على الأقل.'
              : null,
          builder: (state) => InputDecorator(
            decoration: InputDecoration(
              labelText: field.label,
              errorText: state.errorText,
              helperText: rows.isEmpty ? 'لا توجد عناصر متاحة.' : null,
            ),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: rows.map((row) {
                final id = _referenceId(row);
                return FilterChip(
                  label: Text(_referenceLabel(row, field)),
                  selected: selected.contains(id),
                  onSelected: (enabled) => setState(() {
                    if (enabled) {
                      selected.add(id);
                    } else {
                      selected.remove(id);
                    }
                    controller.text = selected.join(',');
                    state.didChange(controller.text);
                  }),
                );
              }).toList(),
            ),
          ),
        ),
      );
    }
    final keyboard = switch (field.type) {
      WorkflowFieldType.phone => TextInputType.phone,
      WorkflowFieldType.email => TextInputType.emailAddress,
      WorkflowFieldType.number => const TextInputType.numberWithOptions(
        decimal: true,
      ),
      WorkflowFieldType.dateTime => TextInputType.datetime,
      WorkflowFieldType.date => TextInputType.datetime,
      _ => TextInputType.text,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        obscureText: field.type == WorkflowFieldType.password,
        textDirection: field.type == WorkflowFieldType.textarea
            ? TextDirection.rtl
            : TextDirection.ltr,
        minLines: field.type == WorkflowFieldType.textarea ? 3 : 1,
        maxLines: field.type == WorkflowFieldType.textarea ? 5 : 1,
        decoration: InputDecoration(
          labelText: field.label,
          suffixIcon:
              field.type == WorkflowFieldType.date ||
                  field.type == WorkflowFieldType.dateTime
              ? const Icon(Icons.calendar_today_outlined)
              : null,
        ),
        validator: (value) {
          if (field.required && value?.trim().isEmpty == true) {
            return 'هذا الحقل مطلوب.';
          }
          if (field.type == WorkflowFieldType.number &&
              value?.trim().isNotEmpty == true &&
              (field.allowZero
                  ? (double.tryParse(value!) ?? -1) < 0
                  : (double.tryParse(value!) ?? 0) <= 0)) {
            return field.allowZero
                ? 'أدخل قيمة تساوي صفرًا أو أكبر.'
                : 'أدخل قيمة أكبر من صفر.';
          }
          if (field.type == WorkflowFieldType.email &&
              value?.trim().isNotEmpty == true &&
              !value!.contains('@')) {
            return 'أدخل بريدًا صحيحًا.';
          }
          return null;
        },
      ),
    );
  }
}

String _localDateTimeValue(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}T${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _nextBookingDateTime({int additionalHours = 0}) {
  final now = DateTime.now();
  final nextHour = DateTime(
    now.year,
    now.month,
    now.day,
    now.hour,
  ).add(Duration(hours: 1 + additionalHours));
  return _localDateTimeValue(nextHour);
}

String _referenceId(Map row) =>
    (row['id'] ??
            row['memberId'] ??
            row['invoiceId'] ??
            row['userAccountId'] ??
            row['code'] ??
            '')
        .toString();

String _referenceLabel(Map<String, dynamic> row, WorkflowField field) {
  if (field.name == 'sessionSlotId' && row['startsAt'] != null) {
    final available = row['availableCount'] ?? row['remainingCapacity'];
    return '${bookingSlotPeriodLabel(row, zone: row['timezone']?.toString() ?? 'Asia/Riyadh')}${available != null ? ' • متاح $available' : ''}';
  }
  String first(List<String> keys) => keys
      .map((key) => row[key]?.toString() ?? '')
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  final label = first(field.labelKeys);
  final subtitle = first(field.subtitleKeys);
  return subtitle.isEmpty
      ? (label.isEmpty ? _referenceId(row) : label)
      : '$label • $subtitle';
}

MobileWorkflow? _workflowForFeature(ResourceFeature feature) {
  final operation = switch (feature.path) {
    '/organizations/{organizationId}/subscriptions' => 'createSubscription',
    '/organizations/{organizationId}/invoices' => 'recordPayment',
    '/organizations/{organizationId}/expenses' => 'recordExpense',
    '/organizations/{organizationId}/crm/leads' => 'createCrmLead',
    '/organizations/{organizationId}/restaurant-orders' => 'checkoutOrder',
    '/organizations/{organizationId}/employee-shifts' =>
      'scheduleEmployeeShift',
    '/organizations/{organizationId}/employee-attendance' =>
      'recordEmployeeAttendance',
    '/organizations/{organizationId}/other-income' => 'recordOtherIncome',
    '/organizations/{organizationId}/reservations' => 'createManualReservation',
    '/organizations/{organizationId}/employees' => 'createEmployee',
    '/organizations/{organizationId}/measurement-sessions' =>
      'recordMeasurementSession',
    '/organizations/{organizationId}/branches' => 'createBranch',
    '/organizations/{organizationId}/activities' => 'createActivity',
    '/organizations/{organizationId}/service-categories' =>
      'createServiceCategory',
    '/organizations/{organizationId}/services' => 'createService',
    '/organizations/{organizationId}/packages' => 'createPackage',
    '/organizations/{organizationId}/prices' => 'createPrice',
    '/organizations/{organizationId}/promotions' => 'createPromotion',
    '/organizations/{organizationId}/commercial-policies' =>
      'createCommercialPolicy',
    '/organizations/{organizationId}/cash-points' => 'createCashPoint',
    '/organizations/{organizationId}/cashier-shifts' => 'openCashierShift',
    '/organizations/{organizationId}/lockers' => 'createLocker',
    '/organizations/{organizationId}/measurement-types' =>
      'createMeasurementType',
    '/organizations/{organizationId}/positions' => 'createPosition',
    '/organizations/{organizationId}/facilities' => 'createFacility',
    '/organizations/{organizationId}/bookable-resources' =>
      'createBookableResource',
    '/organizations/{organizationId}/roles' => 'createRole',
    '/organizations/{organizationId}/role-assignments' =>
      'createRoleAssignment',
    '/organizations/{organizationId}/notification-templates' =>
      'createNotificationTemplate',
    '/organizations/{organizationId}/retail/categories' =>
      'createRetailCategory',
    '/organizations/{organizationId}/retail/products' => 'createRetailProduct',
    '/organizations/{organizationId}/retail/prices' => 'createRetailPrice',
    '/organizations/{organizationId}/retail/inventory' => 'adjustRetailStock',
    '/organizations/{organizationId}/expense-categories' =>
      'createExpenseCategory',
    '/organizations/{organizationId}/restaurant/meal-categories' =>
      'createMealCategory',
    '/organizations/{organizationId}/restaurant/meals' =>
      'createRestaurantMeal',
    '/organizations/{organizationId}/restaurant/meal-prices' =>
      'createRestaurantMealPrice',
    '/organizations/{organizationId}/branches/{branchId}/daily-menus/{businessDate}' =>
      'createDailyMenu',
    '/organizations/{organizationId}/access-credentials' =>
      'issueAccessBarcode',
    '/organizations/{organizationId}/coaching-specialties' =>
      'createCoachingSpecialty',
    '/organizations/{organizationId}/trainers' => 'createTrainerProfile',
    '/organizations/{organizationId}/other-income-categories' =>
      'createOtherIncomeCategory',
    '/organizations/{organizationId}/communication-templates' =>
      'createCommunicationTemplate',
    '/organizations/{organizationId}/communication-campaigns' =>
      'createCommunicationCampaign',
    '/organizations/{organizationId}/whatsapp-campaigns' =>
      'createWhatsAppCampaign',
    '/organizations/{organizationId}/trainer-commission-plans' =>
      'createCommissionPlan',
    '/organizations/{organizationId}/trainer-commissions' =>
      'accrueTrainerCommission',
    '/organizations/{organizationId}/training-plan-templates' =>
      'createTrainingPlanTemplate',
    '/organizations/{organizationId}/member-training-plans' =>
      'createMemberTrainingPlan',
    '/organizations/{organizationId}/crm/lead-sources' => 'createCrmLeadSource',
    '/self/organizations/{organizationId}/packages' =>
      'checkoutSelfMemberPackage',
    '/self/organizations/{organizationId}/services' => 'checkoutSelfService',
    '/self/organizations/{organizationId}/bookable-resources' =>
      'checkoutSelfBooking',
    '/self/organizations/{organizationId}/members/{memberId}/feedback-cases' =>
      'createSelfMemberFeedback',
    _ => '',
  };
  return mobileWorkflows
      .where((workflow) => workflow.operationId == operation)
      .firstOrNull;
}

List<MobileWorkflow> _workflowsForFeature(ResourceFeature feature) {
  final primary = _workflowForFeature(feature);
  final additionalIds = switch (feature.path) {
    '/organizations/{organizationId}/services' => const [
      'scheduleServiceAvailability',
    ],
    '/organizations/{organizationId}/bookable-resources' => const [
      'createBookingAvailability',
      'createBookingBlackout',
      'createSessionSlot',
    ],
    '/organizations/{organizationId}/employees' => const ['assignEmployee'],
    '/organizations/{organizationId}/subscriptions' => const [
      'rescheduleSubscriptionStart',
    ],
    '/organizations/{organizationId}/trainers' => const [
      'assignTrainerToBranch',
      'createTrainerAvailability',
      'assignMemberToTrainer',
    ],
    '/organizations/{organizationId}/restaurant-orders' => const [
      'redeemMealPlan',
    ],
    '/organizations/{organizationId}/access-credentials' => const [
      'createBarcodePrintBatch',
      'assignFingerprintPin',
    ],
    _ => const <String>[],
  };
  return <MobileWorkflow>[?primary, ...additionalIds.map(_workflowById)];
}

MobileWorkflow? _editWorkflowForFeature(
  GoController controller,
  ResourceFeature feature,
  Map<String, dynamic> row,
) {
  final permission = <String, String>{
    '/organizations/{organizationId}/branches': 'branch.manage',
    '/organizations/{organizationId}/activities': 'catalog.manage',
    '/organizations/{organizationId}/service-categories': 'catalog.manage',
    '/organizations/{organizationId}/services': 'catalog.manage',
    '/organizations/{organizationId}/cash-points': 'finance.cash-points.manage',
    '/organizations/{organizationId}/measurement-types':
        'measurement-types.manage',
    '/organizations/{organizationId}/positions': 'workforce.manage',
    '/organizations/{organizationId}/facilities': 'bookings.facilities.manage',
    '/organizations/{organizationId}/bookable-resources':
        'bookings.facilities.manage',
    '/organizations/{organizationId}/trainers': 'coaching.manage',
    '/organizations/{organizationId}/employees': 'workforce.manage',
    '/organizations/{organizationId}/crm/lead-sources': 'crm.leads.manage',
    '/organizations/{organizationId}/crm/leads': 'crm.leads.manage',
    '/organizations/{organizationId}/crm/follow-ups': 'crm.follow-ups.manage',
    '/organizations/{organizationId}/communication-templates':
        'notification-templates.manage',
    '/organizations/{organizationId}/packages': 'commercial.manage',
    '/organizations/{organizationId}/promotions': 'promotions.manage',
    '/organizations/{organizationId}/prices': 'pricing.manage',
    '/organizations/{organizationId}/retail/prices': 'retail.pricing.manage',
    '/organizations/{organizationId}/roles': 'iam.roles.manage',
    '/organizations/{organizationId}/notification-templates':
        'notification-templates.manage',
    '/organizations/{organizationId}/retail/categories':
        'retail.catalog.manage',
    '/organizations/{organizationId}/retail/products': 'retail.catalog.manage',
    '/organizations/{organizationId}/expense-categories':
        'finance.expenses.manage',
    '/organizations/{organizationId}/restaurant/meal-categories':
        'restaurant.catalog.manage',
  }[feature.path];
  if (permission == null || !controller.can(permission)) return null;
  final id = _rowId(row, ['id']);
  if (id.isEmpty) return null;
  final version = int.tryParse('${row['version'] ?? 1}') ?? 1;
  String value(String key) => row[key]?.toString() ?? '';
  const statusChoices = [
    WorkflowChoice('ACTIVE', 'نشط'),
    WorkflowChoice('INACTIVE', 'غير نشط / مؤرشف'),
  ];
  WorkflowField statusField({List<WorkflowChoice> choices = statusChoices}) =>
      WorkflowField(
        name: 'status',
        label: 'الحالة',
        type: WorkflowFieldType.select,
        required: true,
        initialValue: value('status').isEmpty ? 'ACTIVE' : value('status'),
        choices: choices,
      );
  MobileWorkflow edit({
    required List<WorkflowField> fields,
    required WorkflowBodyBuilder body,
    String method = 'PATCH',
    String? path,
  }) => MobileWorkflow(
    operationId: 'edit:${feature.path}',
    title: 'تعديل ${feature.title}',
    description: 'راجع البيانات والحالة قبل حفظ التغييرات.',
    submitLabel: 'حفظ التغيرات',
    successMessage: 'تم حفظ التغيرات.',
    method: method,
    path: path ?? '${feature.path}/$id',
    icon: Icons.edit_outlined,
    fields: fields,
    body: body,
  );

  if ({
    '/organizations/{organizationId}/activities',
    '/organizations/{organizationId}/service-categories',
    '/organizations/{organizationId}/retail/categories',
    '/organizations/{organizationId}/restaurant/meal-categories',
  }.contains(feature.path)) {
    return edit(
      fields: [
        WorkflowField(
          name: 'name',
          label: 'الاسم',
          required: true,
          initialValue: value('name'),
        ),
        statusField(),
      ],
      body: (values, controller) => {
        'name': values['name']?.trim(),
        'status': values['status'],
        'expectedVersion': version,
      },
    );
  }
  switch (feature.path) {
    case '/organizations/{organizationId}/branches':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم الفرع',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'timezone',
            label: 'المنطقة الزمنية',
            initialValue: value('timezone'),
          ),
          WorkflowField(
            name: 'address',
            label: 'العنوان',
            type: WorkflowFieldType.textarea,
            initialValue: value('address'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          if (values['timezone']?.isNotEmpty == true)
            'timezone': values['timezone'],
          if (values['address']?.isNotEmpty == true)
            'address': values['address'],
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/cash-points':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم نقطة التحصيل',
            required: true,
            initialValue: value('name'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'branchId': row['branchId'] ?? controller.branchId,
          'name': values['name']?.trim(),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/measurement-types':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم القياس',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'unit',
            label: 'الوحدة',
            required: true,
            initialValue: value('unit'),
          ),
          WorkflowField(
            name: 'minimumValue',
            label: 'أقل قيمة',
            type: WorkflowFieldType.number,
            initialValue: value('minimumValue'),
          ),
          WorkflowField(
            name: 'maximumValue',
            label: 'أعلى قيمة',
            type: WorkflowFieldType.number,
            initialValue: value('maximumValue'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'unit': values['unit']?.trim(),
          if (values['minimumValue']?.isNotEmpty == true)
            'minimumValue': double.tryParse(values['minimumValue']!),
          if (values['maximumValue']?.isNotEmpty == true)
            'maximumValue': double.tryParse(values['maximumValue']!),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/positions':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'المسمى الوظيفي',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'permissions',
            label: 'صلاحيات المسمى',
            type: WorkflowFieldType.multiReference,
            required: true,
            initialValue: _initialIds(row['permissions']),
            referencePath: '/organizations/{organizationId}/permissions',
            labelKeys: ['description', 'code'],
            subtitleKeys: ['code', 'category'],
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'permissions': _selectedValues(values['permissions']),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/facilities':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم المرفق',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'type',
            label: 'نوع المرفق',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('type'),
            choices: const [
              WorkflowChoice('COURT', 'ملعب'),
              WorkflowChoice('ROOM', 'غرفة'),
              WorkflowChoice('POOL', 'مسبح'),
              WorkflowChoice('STUDIO', 'استوديو'),
              WorkflowChoice('TRAINING_AREA', 'منطقة تدريب'),
            ],
          ),
          WorkflowField(
            name: 'activityId',
            label: 'النشاط',
            type: WorkflowFieldType.reference,
            initialValue: value('activityId'),
            referencePath: '/organizations/{organizationId}/activities',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'branchId': row['branchId'] ?? controller.branchId,
          'name': values['name']?.trim(),
          'type': values['type'],
          'activityId': values['activityId']?.isEmpty == true
              ? null
              : values['activityId'],
          'status': values['status'],
        },
      );
    case '/organizations/{organizationId}/bookable-resources':
      return edit(
        fields: [
          WorkflowField(
            name: 'facilityId',
            label: 'المرفق',
            type: WorkflowFieldType.reference,
            required: true,
            initialValue: value('facilityId'),
            referencePath: '/organizations/{organizationId}/facilities',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          WorkflowField(
            name: 'serviceId',
            label: 'الخدمة',
            type: WorkflowFieldType.reference,
            required: true,
            initialValue: value('serviceId'),
            referencePath: '/organizations/{organizationId}/services',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          WorkflowField(
            name: 'cancellationPolicyVersionId',
            label: 'سياسة الإلغاء',
            type: WorkflowFieldType.reference,
            required: true,
            initialValue: value('cancellationPolicyVersionId'),
            referencePath:
                '/organizations/{organizationId}/commercial-policies',
            labelKeys: ['name'],
            subtitleKeys: ['policyType', 'versionNumber'],
          ),
          WorkflowField(
            name: 'name',
            label: 'اسم المورد',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'type',
            label: 'نوع الحجز',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('type'),
            choices: const [
              WorkflowChoice('COURT', 'ملعب'),
              WorkflowChoice('CLASS', 'حصة جماعية'),
              WorkflowChoice('PERSONAL_TRAINING', 'تدريب شخصي'),
              WorkflowChoice('APPOINTMENT', 'موعد فردي'),
            ],
          ),
          WorkflowField(
            name: 'capacity',
            label: 'السعة',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: value('capacity'),
          ),
          statusField(
            choices: const [
              WorkflowChoice('ACTIVE', 'نشط'),
              WorkflowChoice('MAINTENANCE', 'صيانة'),
              WorkflowChoice('INACTIVE', 'غير نشط'),
            ],
          ),
        ],
        body: (values, controller) => {
          'branchId': row['branchId'] ?? controller.branchId,
          'facilityId': values['facilityId'],
          'serviceId': values['serviceId'],
          'cancellationPolicyVersionId': values['cancellationPolicyVersionId'],
          'name': values['name']?.trim(),
          'type': values['type'],
          'capacity': values['type'] == 'CLASS'
              ? int.tryParse(values['capacity'] ?? '') ?? 1
              : 1,
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/roles':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم المجموعة',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'description',
            label: 'الوصف',
            type: WorkflowFieldType.textarea,
            initialValue: value('description'),
          ),
          WorkflowField(
            name: 'permissions',
            label: 'الصلاحيات',
            type: WorkflowFieldType.multiReference,
            initialValue: _initialIds(row['permissions']),
            referencePath: '/organizations/{organizationId}/permissions',
            labelKeys: ['description', 'code'],
            subtitleKeys: ['code'],
          ),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'description': values['description']?.trim().isEmpty == true
              ? null
              : values['description']?.trim(),
          'permissions': _selectedValues(values['permissions']),
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/services':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم الخدمة',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'categoryId',
            label: 'التصنيف',
            type: WorkflowFieldType.reference,
            initialValue: value('categoryId'),
            referencePath: '/organizations/{organizationId}/service-categories',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          WorkflowField(
            name: 'activityIds',
            label: 'الأنشطة',
            type: WorkflowFieldType.multiReference,
            initialValue: _initialIds(row['activityIds'] ?? row['activities']),
            referencePath: '/organizations/{organizationId}/activities',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          WorkflowField(
            name: 'description',
            label: 'الوصف',
            type: WorkflowFieldType.textarea,
            initialValue: value('description'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          if (values['categoryId']?.isNotEmpty == true)
            'categoryId': values['categoryId'],
          'activityIds': _selectedValues(values['activityIds']),
          if (values['description']?.isNotEmpty == true)
            'description': values['description'],
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/retail/products':
      return edit(
        fields: [
          WorkflowField(
            name: 'categoryId',
            label: 'التصنيف',
            type: WorkflowFieldType.reference,
            required: true,
            initialValue: value('categoryId'),
            referencePath: '/organizations/{organizationId}/retail/categories',
            labelKeys: ['name'],
            subtitleKeys: ['code'],
          ),
          WorkflowField(
            name: 'barcode',
            label: 'الباركود',
            initialValue: value('barcode'),
          ),
          WorkflowField(
            name: 'name',
            label: 'اسم المنتج',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'unit',
            label: 'وحدة البيع',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('unit'),
            choices: const [
              WorkflowChoice('UNIT', 'قطعة'),
              WorkflowChoice('PAIR', 'زوج'),
              WorkflowChoice('BOTTLE', 'زجاجة'),
              WorkflowChoice('CAN', 'علبة'),
              WorkflowChoice('PACK', 'عبوة'),
              WorkflowChoice('BOX', 'صندوق'),
              WorkflowChoice('KG', 'كيلوجرام'),
            ],
          ),
          WorkflowField(
            name: 'description',
            label: 'الوصف',
            type: WorkflowFieldType.textarea,
            initialValue: value('description'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'categoryId': values['categoryId'],
          if (values['barcode']?.isNotEmpty == true)
            'barcode': values['barcode'],
          'name': values['name']?.trim(),
          'unit': values['unit'],
          if (values['description']?.isNotEmpty == true)
            'description': values['description'],
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/expense-categories':
      final currentMinor =
          double.tryParse(
            '${row['approvalThresholdMinor'] ?? row['approvalLimitMinor'] ?? 0}',
          ) ??
          0;
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم التصنيف',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'approvalThreshold',
            label: 'حد طلب الاعتماد (ر.س)',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: (currentMinor / 100).toString(),
            allowZero: true,
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'approvalThresholdMinor': _moneyMinor(values['approvalThreshold']),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/promotions':
      final targets = row['targets'] is List
          ? (row['targets'] as List).whereType<Map>().toList()
          : const <Map>[];
      String targetIds(String type) => targets
          .where((item) => item['type']?.toString() == type)
          .map((item) => (item['id'] ?? item['targetId'] ?? '').toString())
          .where((item) => item.isNotEmpty)
          .join(',');
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم العرض',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'benefitType',
            label: 'نوع الفائدة',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('benefitType'),
            choices: const [
              WorkflowChoice('PERCENTAGE', 'خصم بالنسبة'),
              WorkflowChoice('FIXED_DISCOUNT', 'خصم مبلغ ثابت'),
              WorkflowChoice('FIXED_FINAL_PRICE', 'سعر نهائي ثابت'),
            ],
          ),
          WorkflowField(
            name: 'benefitValue',
            label: 'قيمة العرض',
            type: WorkflowFieldType.number,
            required: true,
            initialValue:
                ((num.tryParse('${row['benefitValue'] ?? 0}') ?? 0) / 100)
                    .toString(),
          ),
          WorkflowField(
            name: 'eligibility',
            label: 'طريقة التطبيق',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('eligibility'),
            choices: const [
              WorkflowChoice('EVERYONE', 'تلقائي للجميع'),
              WorkflowChoice('NEW_MEMBER', 'للأعضاء الجدد'),
              WorkflowChoice('FORMER_MEMBER', 'للأعضاء السابقين'),
              WorkflowChoice('PROMO_CODE', 'يدوي بكود الخصم'),
            ],
          ),
          WorkflowField(
            name: 'validFrom',
            label: 'يبدأ العرض',
            type: WorkflowFieldType.dateTime,
            required: true,
            initialValue: value('validFrom'),
          ),
          WorkflowField(
            name: 'validUntil',
            label: 'ينتهي العرض',
            type: WorkflowFieldType.dateTime,
            required: true,
            initialValue: value('validUntil'),
          ),
          WorkflowField(
            name: 'branchIds',
            label: 'الفروع المستهدفة',
            type: WorkflowFieldType.multiReference,
            initialValue: _initialIds(row['branchIds']),
            referencePath: '/organizations/{organizationId}/branches',
            labelKeys: const ['name', 'nameAr'],
            subtitleKeys: const ['code'],
          ),
          WorkflowField(
            name: 'packageIds',
            label: 'الباقات المشمولة',
            type: WorkflowFieldType.multiReference,
            initialValue: targetIds('PACKAGE'),
            referencePath: '/organizations/{organizationId}/packages',
            labelKeys: const ['name'],
            subtitleKeys: const ['code'],
          ),
          WorkflowField(
            name: 'serviceIds',
            label: 'الخدمات المشمولة',
            type: WorkflowFieldType.multiReference,
            initialValue: targetIds('SERVICE'),
            referencePath: '/organizations/{organizationId}/services',
            labelKeys: const ['name'],
            subtitleKeys: const ['code'],
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'benefitType': values['benefitType'],
          'benefitValue':
              ((double.tryParse(values['benefitValue'] ?? '') ?? 0) * 100)
                  .round(),
          'eligibility': values['eligibility'],
          'validFrom': _asIso(values['validFrom']),
          'validUntil': _asIso(values['validUntil']),
          'branchIds': _selectedValues(values['branchIds']),
          'targets': [
            ..._selectedValues(values['packageIds'])
                .map((id) => {'type': 'PACKAGE', 'id': id}),
            ..._selectedValues(values['serviceIds'])
                .map((id) => {'type': 'SERVICE', 'id': id}),
          ],
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/packages':
      final entitlements = row['entitlements'] is List
          ? (row['entitlements'] as List).whereType<Map>().toList()
          : const <Map>[];
      final currentMealAllowance = entitlements
          .map((item) => item['visitAllowance'])
          .where((item) => item != null)
          .map((item) => item.toString())
          .firstOrNull;
      final currentFrequency = value('visitLimitPeriod').isNotEmpty
          ? value('visitLimitPeriod')
          : row['visitAllowance'] != null
          ? 'TOTAL'
          : 'UNLIMITED';
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم الباقة',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'fulfillmentKind',
            label: 'نوع الباقة',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('fulfillmentKind'),
            choices: const [
              WorkflowChoice('FACILITY_ACCESS', 'دخول مرفق'),
              WorkflowChoice('SESSION', 'جلسات'),
              WorkflowChoice('MEAL_PLAN', 'خطة وجبات'),
            ],
          ),
          WorkflowField(
            name: 'durationDays',
            label: 'المدة الفعلية بالأيام',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: value('durationDays'),
          ),
          WorkflowField(
            name: 'mealAllowance',
            label: 'عدد الوجبات في الخطة',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: currentMealAllowance ?? value('visitAllowance'),
            visibleWhenField: 'fulfillmentKind',
            visibleWhenValues: const ['MEAL_PLAN'],
          ),
          WorkflowField(
            name: 'accessFrequency',
            label: 'نظام الحضور',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: currentFrequency,
            choices: const [
              WorkflowChoice('UNLIMITED', 'غير محدود'),
              WorkflowChoice('TOTAL', 'إجمالي طوال الباقة'),
              WorkflowChoice('WEEK', 'حد أسبوعي'),
              WorkflowChoice('MONTH', 'حد شهري'),
            ],
          ),
          WorkflowField(
            name: 'visitAllowance',
            label: 'إجمالي مرات الحضور',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: value('visitAllowance'),
            visibleWhenField: 'accessFrequency',
            visibleWhenValues: const ['TOTAL'],
          ),
          WorkflowField(
            name: 'visitsPerPeriod',
            label: 'مرات الحضور في الفترة',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: value('visitsPerPeriod'),
            visibleWhenField: 'accessFrequency',
            visibleWhenValues: const ['WEEK', 'MONTH'],
          ),
          WorkflowField(
            name: 'branchAccessPolicy',
            label: 'سياسة الوصول للفروع',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('branchAccessPolicy'),
            choices: const [
              WorkflowChoice('SINGLE_BRANCH', 'فرع البيع فقط'),
              WorkflowChoice('SELECTED_BRANCHES', 'فروع مختارة'),
              WorkflowChoice('ALL_ORGANIZATION_BRANCHES', 'كل الفروع'),
            ],
          ),
          WorkflowField(
            name: 'branchIds',
            label: 'الفروع المتاحة',
            type: WorkflowFieldType.multiReference,
            initialValue: _initialIds(row['branchIds']),
            referencePath: '/organizations/{organizationId}/branches',
            labelKeys: const ['name', 'nameAr'],
            subtitleKeys: const ['code'],
            visibleWhenField: 'branchAccessPolicy',
            visibleWhenValues: const ['SELECTED_BRANCHES'],
          ),
          WorkflowField(
            name: 'serviceIds',
            label: 'الخدمات المشمولة',
            type: WorkflowFieldType.multiReference,
            required: true,
            initialValue: _initialIds(row['entitlements']),
            referencePath: '/organizations/{organizationId}/services',
            labelKeys: const ['name'],
            subtitleKeys: const ['code'],
          ),
          WorkflowField(
            name: 'freezePolicyVersionId',
            label: 'سياسة التجميد',
            type: WorkflowFieldType.reference,
            initialValue: value('freezePolicyVersionId'),
            referencePath:
                '/organizations/{organizationId}/commercial-policies',
            labelKeys: const ['name'],
            subtitleKeys: const ['policyType', 'versionNumber'],
          ),
          WorkflowField(
            name: 'cancellationPolicyVersionId',
            label: 'سياسة إلغاء الاشتراك',
            type: WorkflowFieldType.reference,
            initialValue: value('cancellationPolicyVersionId'),
            referencePath:
                '/organizations/{organizationId}/commercial-policies',
            labelKeys: const ['name'],
            subtitleKeys: const ['policyType', 'versionNumber'],
          ),
          WorkflowField(
            name: 'renewalPolicyVersionId',
            label: 'سياسة التجديد',
            type: WorkflowFieldType.reference,
            initialValue: value('renewalPolicyVersionId'),
            referencePath:
                '/organizations/{organizationId}/commercial-policies',
            labelKeys: const ['name'],
            subtitleKeys: const ['policyType', 'versionNumber'],
          ),
          WorkflowField(
            name: 'description',
            label: 'الوصف',
            type: WorkflowFieldType.textarea,
            initialValue: value('description'),
          ),
          statusField(
            choices: const [
              WorkflowChoice('DRAFT', 'مسودة'),
              WorkflowChoice('PUBLISHED', 'منشورة'),
              WorkflowChoice('INACTIVE', 'مؤرشفة'),
            ],
          ),
        ],
        body: (values, controller) {
          final mealPlan = values['fulfillmentKind'] == 'MEAL_PLAN';
          final frequency = values['accessFrequency'];
          final allowance = mealPlan
              ? int.tryParse(values['mealAllowance'] ?? '')
              : frequency == 'TOTAL'
              ? int.tryParse(values['visitAllowance'] ?? '')
              : null;
          final periodic =
              !mealPlan && (frequency == 'WEEK' || frequency == 'MONTH');
          return {
            'name': values['name']?.trim(),
            if (values['description']?.isNotEmpty == true)
              'description': values['description']?.trim(),
            'contract': row['contract'],
            'durationDays': int.tryParse(values['durationDays'] ?? '') ?? 1,
            'visitAllowance': allowance,
            'visitLimitPeriod': periodic ? frequency : null,
            'visitsPerPeriod': periodic
                ? int.tryParse(values['visitsPerPeriod'] ?? '')
                : null,
            'fulfillmentKind': values['fulfillmentKind'],
            'branchAccessPolicy': values['branchAccessPolicy'],
            'branchIds': _selectedValues(values['branchIds']),
            'entitlements': _selectedValues(values['serviceIds'])
                .map(
                  (serviceId) => {
                    'serviceId': serviceId,
                    if (mealPlan && allowance != null)
                      'visitAllowance': allowance,
                  },
                )
                .toList(growable: false),
            if (values['freezePolicyVersionId']?.isNotEmpty == true)
              'freezePolicyVersionId': values['freezePolicyVersionId'],
            if (values['cancellationPolicyVersionId']?.isNotEmpty == true)
              'cancellationPolicyVersionId':
                  values['cancellationPolicyVersionId'],
            if (values['renewalPolicyVersionId']?.isNotEmpty == true)
              'renewalPolicyVersionId': values['renewalPolicyVersionId'],
            'status': values['status'],
            'expectedVersion': version,
          };
        },
      );
    case '/organizations/{organizationId}/trainers':
      return edit(
        fields: [
          WorkflowField(
            name: 'displayName',
            label: 'اسم المدرب الظاهر',
            required: true,
            initialValue: value('displayName'),
          ),
          WorkflowField(
            name: 'publicBio',
            label: 'نبذة تظهر للأعضاء',
            type: WorkflowFieldType.textarea,
            initialValue: value('publicBio'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'displayName': values['displayName']?.trim(),
          'publicBio': values['publicBio']?.trim().isEmpty == true
              ? null
              : values['publicBio']?.trim(),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/employees':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم الموظف',
            required: true,
            initialValue: value('name').isEmpty
                ? value('displayName')
                : value('name'),
          ),
          WorkflowField(
            name: 'phone',
            label: 'رقم الجوال',
            type: WorkflowFieldType.phone,
            initialValue: value('phoneE164').isEmpty
                ? value('phone')
                : value('phoneE164'),
          ),
          WorkflowField(
            name: 'email',
            label: 'البريد الإلكتروني',
            type: WorkflowFieldType.email,
            initialValue: value('email'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'name': values['name']?.trim(),
          'phone': values['phone']?.trim().isEmpty == true
              ? null
              : values['phone']?.trim(),
          'email': values['email']?.trim().isEmpty == true
              ? null
              : values['email']?.trim(),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/crm/lead-sources':
      return edit(
        fields: [
          WorkflowField(
            name: 'nameAr',
            label: 'الاسم العربي',
            required: true,
            initialValue: value('nameAr'),
          ),
          WorkflowField(
            name: 'nameEn',
            label: 'الاسم الإنجليزي',
            initialValue: value('nameEn'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'nameAr': values['nameAr']?.trim(),
          'nameEn': values['nameEn']?.trim().isEmpty == true
              ? null
              : values['nameEn']?.trim(),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/crm/leads':
      return edit(
        fields: [
          WorkflowField(
            name: 'fullName',
            label: 'اسم العميل المحتمل',
            required: true,
            initialValue: value('fullName'),
          ),
          WorkflowField(
            name: 'phone',
            label: 'رقم الجوال',
            type: WorkflowFieldType.phone,
            initialValue: value('phoneE164').isEmpty
                ? value('phone')
                : value('phoneE164'),
          ),
          WorkflowField(
            name: 'email',
            label: 'البريد الإلكتروني',
            type: WorkflowFieldType.email,
            initialValue: value('email'),
          ),
          WorkflowField(
            name: 'notes',
            label: 'ملاحظات',
            type: WorkflowFieldType.textarea,
            initialValue: value('notes'),
          ),
        ],
        body: (values, controller) => {
          'fullName': values['fullName']?.trim(),
          'phone': values['phone']?.trim().isEmpty == true
              ? null
              : values['phone']?.trim(),
          'email': values['email']?.trim().isEmpty == true
              ? null
              : values['email']?.trim(),
          'notes': values['notes']?.trim(),
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/crm/follow-ups':
      return edit(
        fields: [
          WorkflowField(
            name: 'assignedToUserAccountId',
            label: 'الموظف المسؤول',
            type: WorkflowFieldType.reference,
            required: true,
            initialValue: value('assignedToUserAccountId'),
            referencePath: '/organizations/{organizationId}/user-accounts',
            labelKeys: ['displayName', 'email'],
            subtitleKeys: ['status'],
          ),
          WorkflowField(
            name: 'channel',
            label: 'قناة المتابعة',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('channel'),
            choices: const [
              WorkflowChoice('CALL', 'مكالمة'),
              WorkflowChoice('WHATSAPP', 'واتساب'),
              WorkflowChoice('SMS', 'رسالة نصية'),
              WorkflowChoice('EMAIL', 'بريد إلكتروني'),
              WorkflowChoice('VISIT', 'زيارة'),
              WorkflowChoice('OTHER', 'أخرى'),
            ],
          ),
          WorkflowField(
            name: 'scheduledAt',
            label: 'موعد المتابعة',
            type: WorkflowFieldType.dateTime,
            required: true,
            initialValue: value('scheduledAt'),
          ),
          WorkflowField(
            name: 'subject',
            label: 'الموضوع',
            initialValue: value('subject'),
          ),
          WorkflowField(
            name: 'notes',
            label: 'ملاحظات',
            type: WorkflowFieldType.textarea,
            initialValue: value('notes'),
          ),
        ],
        body: (values, controller) => {
          'assignedToUserAccountId': values['assignedToUserAccountId'],
          'channel': values['channel'],
          'scheduledAt': _asIso(values['scheduledAt']),
          'subject': values['subject']?.trim().isEmpty == true
              ? null
              : values['subject']?.trim(),
          'notes': values['notes']?.trim(),
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/communication-templates':
      return edit(
        fields: [
          WorkflowField(
            name: 'name',
            label: 'اسم القالب',
            required: true,
            initialValue: value('name'),
          ),
          WorkflowField(
            name: 'purpose',
            label: 'الغرض',
            type: WorkflowFieldType.select,
            required: true,
            initialValue: value('purpose'),
            choices: const [
              WorkflowChoice('MARKETING', 'ترويج'),
              WorkflowChoice('RENEWAL', 'تجديد'),
              WorkflowChoice('REMINDER', 'تذكير'),
              WorkflowChoice('ANNOUNCEMENT', 'إعلان'),
              WorkflowChoice('FOLLOW_UP', 'متابعة'),
              WorkflowChoice('OTHER', 'أخرى'),
            ],
          ),
          WorkflowField(
            name: 'title',
            label: 'عنوان الرسالة',
            required: true,
            initialValue: value('title'),
          ),
          WorkflowField(
            name: 'body',
            label: 'نص الرسالة',
            type: WorkflowFieldType.textarea,
            required: true,
            initialValue: value('body'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          if (row['branchId'] != null) 'branchId': row['branchId'],
          'name': values['name']?.trim(),
          'purpose': values['purpose'],
          'title': values['title']?.trim(),
          'body': values['body']?.trim(),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/prices':
      final amount = row['amount'] is Map
          ? (row['amount'] as Map)['minorUnits']
          : row['amountMinor'];
      return edit(
        fields: [
          WorkflowField(
            name: 'amount',
            label: 'السعر بالريال',
            type: WorkflowFieldType.number,
            required: true,
            initialValue: ((num.tryParse('${amount ?? 0}') ?? 0) / 100)
                .toString(),
          ),
          WorkflowField(
            name: 'taxRate',
            label: 'نسبة الضريبة %',
            type: WorkflowFieldType.number,
            required: true,
            initialValue:
                ((num.tryParse('${row['taxRateBps'] ?? 0}') ?? 0) / 100)
                    .toString(),
            allowZero: true,
          ),
          WorkflowField(
            name: 'taxInclusive',
            label: 'السعر شامل الضريبة',
            type: WorkflowFieldType.checkbox,
            initialValue: '${row['taxInclusive'] == true}',
          ),
          WorkflowField(
            name: 'validFrom',
            label: 'بداية السريان',
            type: WorkflowFieldType.dateTime,
            required: true,
            initialValue: value('validFrom'),
          ),
          WorkflowField(
            name: 'validUntil',
            label: 'نهاية السريان (اختياري)',
            type: WorkflowFieldType.dateTime,
            autoFillDate: false,
            initialValue: value('validUntil'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'amountMinor': _moneyMinor(values['amount']),
          'taxRateBps': ((double.tryParse(values['taxRate'] ?? '') ?? 0) * 100)
              .round(),
          'taxInclusive': values['taxInclusive'] == 'true',
          'validFrom': _asIso(values['validFrom']),
          'validUntil': values['validUntil']?.isEmpty == true
              ? null
              : _asIso(values['validUntil']),
          'status': values['status'],
        },
      );
    case '/organizations/{organizationId}/retail/prices':
      return edit(
        fields: [
          WorkflowField(
            name: 'amount',
            label: 'سعر البيع بالريال',
            type: WorkflowFieldType.number,
            required: true,
            initialValue:
                ((num.tryParse('${row['amountMinor'] ?? 0}') ?? 0) / 100)
                    .toString(),
          ),
          WorkflowField(
            name: 'taxRate',
            label: 'نسبة الضريبة %',
            type: WorkflowFieldType.number,
            required: true,
            initialValue:
                ((num.tryParse('${row['taxRateBps'] ?? 0}') ?? 0) / 100)
                    .toString(),
            allowZero: true,
          ),
          WorkflowField(
            name: 'taxInclusive',
            label: 'السعر شامل الضريبة',
            type: WorkflowFieldType.checkbox,
            initialValue: '${row['taxInclusive'] == true}',
          ),
          WorkflowField(
            name: 'validUntil',
            label: 'نهاية السريان (اختياري)',
            type: WorkflowFieldType.dateTime,
            autoFillDate: false,
            initialValue: value('validUntil'),
          ),
          statusField(),
        ],
        body: (values, controller) => {
          'branchId': row['branchId'] ?? controller.branchId,
          'amountMinor': _moneyMinor(values['amount']),
          'taxRateBps': ((double.tryParse(values['taxRate'] ?? '') ?? 0) * 100)
              .round(),
          'taxInclusive': values['taxInclusive'] == 'true',
          if (values['validUntil']?.isNotEmpty == true)
            'validUntil': _asIso(values['validUntil']),
          'status': values['status'],
          'expectedVersion': version,
        },
      );
    case '/organizations/{organizationId}/notification-templates':
      return edit(
        method: 'POST',
        path: '/organizations/{organizationId}/notification-templates',
        fields: [
          WorkflowField(
            name: 'body',
            label: 'نص الرسالة',
            type: WorkflowFieldType.textarea,
            required: true,
            initialValue: value('body'),
          ),
          WorkflowField(
            name: 'variables',
            label: 'المتغيرات المسموحة',
            initialValue: _initialIds(row['allowedVariables']),
          ),
        ],
        body: (values, controller) => {
          'templateKey': row['templateKey'] ?? row['key'],
          'language': row['language'] ?? 'ar',
          'body': values['body'],
          'allowedVariables': _selectedValues(values['variables']),
        },
      );
  }
  return null;
}

String _initialIds(dynamic value) {
  if (value is! List) return value?.toString() ?? '';
  return value
      .map((item) {
        if (item is Map) {
          return (item['serviceId'] ??
                  item['id'] ??
                  item['mealId'] ??
                  item['activityId'] ??
                  item['code'] ??
                  item['permissionCode'] ??
                  '')
              .toString();
        }
        return item.toString();
      })
      .where((item) => item.isNotEmpty)
      .join(',');
}

MobileWorkflow _workflowById(String operationId) => mobileWorkflows
    .where((workflow) => workflow.operationId == operationId)
    .first;

bool _canRunWorkflow(GoController controller, MobileWorkflow workflow) {
  if (workflow.path.startsWith('/self/')) {
    if (workflow.operationId == 'checkoutSelfBooking') {
      return !controller.staffMode &&
          controller.selectedMemberId != null &&
          controller.selectedSelfMember?['canBook'] == true;
    }
    if (const [
      'checkoutSelfService',
      'checkoutSelfMemberPackage',
    ].contains(workflow.operationId)) {
      return !controller.staffMode &&
          controller.selectedMemberId != null &&
          controller.selectedSelfMember?['canManageMembership'] == true;
    }
    if (workflow.path.contains('/members/')) {
      return !controller.staffMode;
    }
    return controller.staffMode;
  }
  final permission = <String, String>{
    'createSubscription': 'sales.checkout',
    'rescheduleSubscriptionStart': 'subscriptions.adjustments.manage',
    'recordPayment': 'finance.payments.record',
    'recordSplitPayment': 'finance.payments.record',
    'createCrmLead': 'crm.leads.manage',
    'recordExpense': 'finance.expenses.manage',
    'recordOtherIncome': 'finance.other-income.manage',
    'scheduleEmployeeShift': 'workforce.shifts.manage',
    'recordEmployeeAttendance': 'workforce.attendance.record',
    'checkoutOrder': 'sales.checkout',
    'checkoutServiceAtPos': 'sales.checkout',
    'checkoutRetailAtPos': 'sales.checkout',
    'createManualReservation': 'bookings.create',
    'createEmployee': 'workforce.manage',
    'assignEmployee': 'workforce.assignments.manage',
    'recordMeasurementSession': 'measurements.manage',
    'requestReportingRebuild': 'reporting.rebuild',
    'createBranch': 'branch.manage',
    'createActivity': 'catalog.manage',
    'createServiceCategory': 'catalog.manage',
    'createService': 'catalog.manage',
    'scheduleServiceAvailability': 'catalog.manage',
    'createPackage': 'commercial.manage',
    'createPrice': 'pricing.manage',
    'createPromotion': 'promotions.manage',
    'createCommercialPolicy': 'policies.manage',
    'createCashPoint': 'finance.cash-points.manage',
    'openCashierShift': 'finance.cash-shifts.manage',
    'closeCashierShift': 'finance.cash-shifts.manage',
    'createLocker': 'lockers.manage',
    'createMeasurementType': 'measurement-types.manage',
    'createPosition': 'workforce.manage',
    'createFacility': 'bookings.facilities.manage',
    'createBookableResource': 'bookings.facilities.manage',
    'createBookingAvailability': 'bookings.facilities.manage',
    'createBookingBlackout': 'bookings.facilities.manage',
    'createSessionSlot': 'bookings.facilities.manage',
    'createRole': 'iam.roles.manage',
    'createRoleAssignment': 'iam.assignments.manage',
    'createNotificationTemplate': 'notification-templates.manage',
    'createRetailCategory': 'retail.catalog.manage',
    'createRetailProduct': 'retail.catalog.manage',
    'createRetailPrice': 'retail.pricing.manage',
    'adjustRetailStock': 'retail.inventory.manage',
    'createExpenseCategory': 'finance.expenses.manage',
    'createMealCategory': 'restaurant.catalog.manage',
    'createRestaurantMeal': 'restaurant.catalog.manage',
    'createRestaurantMealPrice': 'restaurant.pricing.manage',
    'createDailyMenu': 'restaurant.menu.manage',
    'issueAccessBarcode': 'access-credentials.manage',
    'createBarcodePrintBatch': 'access-credentials.manage',
    'assignFingerprintPin': 'access-credentials.manage',
    'registerAccessDevice': 'attendance.devices.manage',
    'createCoachingSpecialty': 'coaching.manage',
    'createTrainerProfile': 'coaching.manage',
    'assignTrainerToBranch': 'coaching.assignments.manage',
    'createTrainerAvailability': 'coaching.schedule.manage',
    'assignMemberToTrainer': 'coaching.assignments.manage',
    'redeemMealPlan': 'restaurant.meal-plans.redeem',
    'createOtherIncomeCategory': 'finance.other-income.manage',
    'createCommunicationTemplate': 'notification-templates.manage',
    'createCommunicationCampaign': 'notifications.send',
    'createWhatsAppCampaign': 'notifications.whatsapp.manage',
    'createCommissionPlan': 'coaching.commissions.manage',
    'accrueTrainerCommission': 'coaching.commissions.manage',
    'createTrainingPlanTemplate': 'coaching.training-plans.manage',
    'createMemberTrainingPlan': 'coaching.training-plans.manage',
    'createCrmLeadSource': 'crm.leads.manage',
  }[workflow.operationId];
  return permission == null || controller.can(permission);
}

String? _featurePermission(String path) {
  if (path.startsWith('/self/')) return null;
  if (path == '/organizations/{organizationId}') return 'organization.read';
  if (path.contains('/members')) return 'members.read';
  if (path.contains('/subscriptions')) return 'subscriptions.read';
  if (path.contains('/attendance-attempts')) return 'attendance.read';
  if (path.contains('/access-device')) return 'attendance.devices.read';
  if (path.contains('/access-credentials')) return 'access-credentials.read';
  if (path.contains('/reservations') ||
      path.contains('/facilities') ||
      path.contains('/bookable-resources')) {
    return 'bookings.read';
  }
  if (path.contains('/invoices')) return 'finance.invoices.read';
  if (path.contains('/restaurant-orders')) return 'restaurant.orders.read';
  if (path.endsWith('/orders')) return 'sales.read';
  if (path.contains('/payments') || path.contains('/refund')) {
    return 'finance.payments.read';
  }
  if (path.contains('/cash-points')) return 'finance.cash-points.read';
  if (path.contains('/expenses')) return 'finance.expenses.read';
  if (path.contains('/other-income')) return 'finance.other-income.read';
  if (path.contains('/crm/leads')) return 'crm.leads.read';
  if (path.contains('/crm/follow-ups')) return 'crm.follow-ups.read';
  if (path.contains('/daily-menus/')) return 'restaurant.menu.read';
  if (path.contains('/restaurant/')) return 'restaurant.catalog.read';
  if (path.contains('/retail/inventory')) return 'retail.inventory.read';
  if (path.contains('/retail/')) return 'retail.catalog.read';
  if (path.contains('/employees') || path.endsWith('/positions')) {
    return 'workforce.read';
  }
  if (path.contains('/employee-shifts') ||
      path.contains('/employee-attendance')) {
    return 'workforce.shifts.read';
  }
  if (path.contains('/trainer-commission')) return 'coaching.commissions.read';
  if (path.contains('/training-plan')) return 'coaching.training-plans.read';
  if (path.contains('/trainers') || path.contains('/coaching-specialties')) {
    return 'coaching.read';
  }
  if (path.contains('/measurement')) return 'measurements.read';
  if (path.contains('/files')) return 'files.read';
  if (path.contains('/feedback')) return 'feedback.read';
  if (path.contains('/online-requests')) return 'online-requests.read';
  if (path.contains('/lockers')) return 'lockers.read';
  if (path.contains('/notification-template')) {
    return 'notification-templates.read';
  }
  if (path.contains('/whatsapp')) return 'notifications.whatsapp.read';
  if (path.contains('/notification') || path.contains('/communication')) {
    return 'notifications.read';
  }
  if (path.contains('/audit')) return 'iam.audit.read';
  if (path.contains('/roles')) return 'iam.roles.read';
  if (path.contains('/permissions')) return 'iam.roles.read';
  if (path.contains('/user-accounts') || path.contains('/role-assignments')) {
    return 'iam.accounts.read';
  }
  if (path.contains('/branches')) return 'branch.read';
  if (path.contains('/activities') ||
      path.contains('/service-categories') ||
      path.contains('/services')) {
    return 'catalog.read';
  }
  if (path.contains('/prices') ||
      path.contains('/packages') ||
      path.contains('/promotions') ||
      path.contains('/commercial-policies')) {
    return 'commercial.read';
  }
  if (path.contains('/crm/lead-sources')) return 'crm.leads.read';
  return null;
}

bool _canViewFeature(GoController controller, ResourceFeature feature) {
  final path = feature.path;
  if (path.contains('/cashier-shifts')) {
    return controller.can('finance.cash-shifts.manage') ||
        controller.can('finance.cash-shifts.audit.read');
  }
  if (path.contains('/permissions')) {
    return controller.can('iam.roles.read') ||
        controller.can('workforce.manage');
  }
  final permission = _featurePermission(path);
  return permission == null || controller.can(permission);
}

Future<void> _openNewMemberSheet(
  BuildContext context,
  GoController controller,
) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _NewMemberSheet(controller: controller),
  );
  if (created != true || !context.mounted) return;
  await controller.refresh();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text('تم تسجيل العضو بنجاح.')));
}

class _NewMemberSheet extends StatefulWidget {
  const _NewMemberSheet({required this.controller});
  final GoController controller;

  @override
  State<_NewMemberSheet> createState() => _NewMemberSheetState();
}

class _NewMemberSheetState extends State<_NewMemberSheet> {
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final nationalId = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  final birthDate = TextEditingController();
  final notes = TextEditingController();
  String gender = 'UNSPECIFIED';
  bool loading = false;
  String? error;

  @override
  void dispose() {
    name.dispose();
    nationalId.dispose();
    phone.dispose();
    email.dispose();
    birthDate.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (formKey.currentState?.validate() != true) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.controller.api.configured) {
        await widget.controller.api.registerMember(
          widget.controller.organizationId,
          widget.controller.branchId,
          name: name.text.trim(),
          gender: gender,
          nationalId: nationalId.text.trim(),
          phone: phone.text.trim(),
          email: email.text.trim(),
          birthDate: birthDate.text.trim(),
          notes: notes.text.trim(),
        );
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        22,
        4,
        22,
        22 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'تسجيل عضو جديد',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'سيُسجل العضو في ${widget.controller.branchName}.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: name,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'الاسم الكامل *',
                prefixIcon: Icon(Icons.person_outline),
              ),
              validator: (value) =>
                  (value?.trim().length ?? 0) < 2 ? 'أدخل اسمًا صحيحًا.' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: nationalId,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'رقم الهوية *',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              validator: (value) => (value?.trim().length ?? 0) < 4
                  ? 'أدخل رقم هوية صحيحًا.'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: gender,
              decoration: const InputDecoration(
                labelText: 'الجنس',
                prefixIcon: Icon(Icons.wc_outlined),
              ),
              items: const [
                DropdownMenuItem(value: 'UNSPECIFIED', child: Text('غير محدد')),
                DropdownMenuItem(value: 'MALE', child: Text('ذكر')),
                DropdownMenuItem(value: 'FEMALE', child: Text('أنثى')),
              ],
              onChanged: loading
                  ? null
                  : (value) => setState(() => gender = value ?? gender),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'رقم الجوال',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
              validator: (value) =>
                  value?.trim().isNotEmpty == true &&
                      (value?.trim().length ?? 0) < 8
                  ? 'رقم الجوال قصير جدًا.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'البريد الإلكتروني',
                prefixIcon: Icon(Icons.email_outlined),
              ),
              validator: (value) =>
                  value?.trim().isNotEmpty == true && !value!.contains('@')
                  ? 'أدخل بريدًا إلكترونيًا صحيحًا.'
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: birthDate,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'تاريخ الميلاد (YYYY-MM-DD)',
                prefixIcon: Icon(Icons.cake_outlined),
              ),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.isEmpty) return null;
                return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)
                    ? null
                    : 'استخدم الصيغة YYYY-MM-DD.';
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: notes,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'ملاحظات',
                alignLabelWithHint: true,
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: loading ? null : submit,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.person_add_alt_1_rounded),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 13),
                child: Text('حفظ العضو'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _openCheckInSheet(
  BuildContext context,
  GoController controller,
) async {
  final rows = controller.api.configured
      ? controller.members
      : controller.demoMembers.cast<Map<String, dynamic>>();
  if (rows.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لا يوجد أعضاء متاحون لتسجيل الدخول.')),
    );
    return;
  }
  final completed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _CheckInSheet(controller: controller, members: rows),
  );
  if (completed != true || !context.mounted) return;
  await controller.refresh();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('تم إرسال محاولة الدخول بنجاح.')),
  );
}

class MemberBarcodeScannerPage extends StatefulWidget {
  const MemberBarcodeScannerPage({super.key});
  @override
  State<MemberBarcodeScannerPage> createState() =>
      _MemberBarcodeScannerPageState();
}

class _MemberBarcodeScannerPageState extends State<MemberBarcodeScannerPage> {
  bool handled = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text(
        'مسح بطاقة العضو',
        style: TextStyle(fontWeight: FontWeight.w900),
      ),
    ),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            if (handled) return;
            final value = capture.barcodes
                .map((barcode) => barcode.rawValue)
                .whereType<String>()
                .firstOrNull;
            if (value == null || value.isEmpty) return;
            handled = true;
            Navigator.of(context).pop(value);
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Container(
              margin: const EdgeInsets.all(20),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Text(
                'وجّه الكاميرا إلى باركود العضوية. لا تُرسل الصورة إلى الخادم؛ تتم قراءة الرمز على الجهاز.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, height: 1.5),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _CheckInSheet extends StatefulWidget {
  const _CheckInSheet({required this.controller, required this.members});
  final GoController controller;
  final List<Map<String, dynamic>> members;

  @override
  State<_CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends State<_CheckInSheet> {
  String? memberId;
  bool loading = false;
  String? error;

  String _id(Map<String, dynamic> row) =>
      (row['id'] ?? row['memberId'] ?? row['number']).toString();

  @override
  void initState() {
    super.initState();
    memberId = _id(widget.members.first);
  }

  Future<void> submit() async {
    if (memberId == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (widget.controller.api.configured) {
        await widget.controller.api.manualCheckIn(
          widget.controller.organizationId,
          widget.controller.branchId,
          memberId!,
        );
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (exception) {
      if (mounted) {
        setState(
          () => error = exception.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> scanMember() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => const MemberBarcodeScannerPage(),
      ),
    );
    if (value == null || !mounted) return;
    final code = value.trim().toLowerCase();
    final match = widget.members
        .where(
          (row) =>
              [
                row['id'],
                row['memberId'],
                row['memberNumber'],
                row['number'],
                row['credentialValue'],
              ].whereType<Object>().any(
                (item) => item.toString().toLowerCase() == code,
              ),
        )
        .firstOrNull;
    if (match == null) {
      setState(
        () => error = 'لم يتم العثور على هذا الرمز ضمن أعضاء الفرع الحالي.',
      );
      return;
    }
    setState(() {
      memberId = _id(match);
      error = null;
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'تسجيل دخول عضو',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(
            'اختر العضو لتسجيل محاولة دخول في ${widget.controller.branchName}.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
            initialValue: memberId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'العضو',
              prefixIcon: Icon(Icons.person_search_outlined),
            ),
            items: widget.members
                .map(
                  (row) => DropdownMenuItem(
                    value: _id(row),
                    child: Text(
                      '${row['name'] ?? 'عضو'}  •  ${row['memberNumber'] ?? row['number'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: loading
                ? null
                : (value) => setState(() => memberId = value),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: loading ? null : () => unawaited(scanMember()),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('مسح بطاقة العضو بالكاميرا'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: loading ? null : submit,
            icon: loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 13),
              child: Text('تأكيد الدخول'),
            ),
          ),
        ],
      ),
    ),
  );
}

String _money(dynamic minor) {
  final n = (num.tryParse(minor.toString()) ?? 0) / 100;
  return '${n.toStringAsFixed(0)} ر.س';
}

String _relativeTime(String? value) {
  final date = value == null ? null : DateTime.tryParse(value)?.toLocal();
  if (date == null) return '';
  final difference = DateTime.now().difference(date);
  if (difference.inMinutes < 1) return 'الآن';
  if (difference.inHours < 1) return 'منذ ${difference.inMinutes} دقيقة';
  if (difference.inDays < 1) return 'منذ ${difference.inHours} ساعة';
  if (difference.inDays < 7) return 'منذ ${difference.inDays} يوم';
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

Color _avatarColor(String value) {
  const palette = [
    Color(0xFF2F80ED),
    Color(0xFF9B51E0),
    Color(0xFF219653),
    Color(0xFFE59C16),
    Color(0xFFEB5757),
  ];
  return palette[value.codeUnits.fold<int>(0, (sum, code) => sum + code) %
      palette.length];
}
