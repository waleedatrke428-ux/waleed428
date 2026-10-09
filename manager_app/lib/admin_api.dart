import 'dart:convert';

import 'package:http/http.dart' as http;

const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

class ManagerApiException implements Exception {
  const ManagerApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ManagerApi {
  ManagerApi(String baseUrl, {http.Client? httpClient})
      : _baseUri = Uri.parse(baseUrl),
        _client = httpClient ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  String? _token;

  Future<void> login(String email, String password) async {
    final result = await _send(
      'POST',
      '/api/auth/login',
      body: {'email': email, 'password': password},
      authenticated: false,
    );
    if (result['role'] != 'admin') {
      throw const ManagerApiException('هذا الحساب لا يملك صلاحية المدير.');
    }
    final token = result['accessToken'] ?? result['access_token'] ?? result['token'];
    if (token is! String || token.isEmpty) {
      throw const ManagerApiException('لم يُرجع الخادم رمز دخول صالحاً.');
    }
    _token = token;
  }

  Future<List<Map<String, dynamic>>> users() => _items('/api/admin/users');

  Future<List<Map<String, dynamic>>> signals() =>
      _items('/api/admin/signals');

  Future<Map<String, dynamic>> settings() =>
      _send('GET', '/api/admin/settings');

  Future<void> saveSettings({
    required int minimumSignalScore,
    required List<String> exchanges,
  }) async {
    await _send(
      'PUT',
      '/api/admin/settings',
      body: {
        'minSignalScore': minimumSignalScore,
        'activeExchanges': exchanges,
      },
    );
  }

  Future<Map<String, dynamic>> extendSubscription(String userId) {
    return _send(
      'POST',
      '/api/admin/users/${Uri.encodeComponent(userId)}/subscriptions',
      body: {'months': 1},
    );
  }

  Future<List<Map<String, dynamic>>> _items(String path) async {
    final result = await _send('GET', path);
    final items = result['items'];
    if (items is! List) {
      throw const ManagerApiException('استجابة الخادم لا تحتوي قائمة صالحة.');
    }
    return items.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (_supabaseAnonKey.isNotEmpty) headers['apikey'] = _supabaseAnonKey;
    if (body != null) headers['Content-Type'] = 'application/json';
    final token = _token;
    if (authenticated && token != null) {
      headers['Authorization'] = 'Bearer $token';
    }

    late http.Response response;
    try {
      final baseUri = _baseUri.path.endsWith('/')
          ? _baseUri
          : _baseUri.replace(path: '${_baseUri.path}/');
      final apiPath = _baseUri.path.contains('/functions/v1/api')
          ? path.replaceFirst(RegExp(r'^/api/'), '')
          : path;
      final request = http.Request(method, baseUri.resolve(apiPath))
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final stream = await _client.send(request).timeout(
            const Duration(seconds: 20),
          );
      response = await http.Response.fromStream(stream).timeout(
        const Duration(seconds: 20),
      );
    } on Exception {
      throw const ManagerApiException(
        'تعذّر الاتصال بخادم الإدارة. تحقق من عنوان الخادم والاتصال.',
      );
    }

    Object? decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          throw const ManagerApiException(
            'أعاد الخادم صفحة HTML بدلاً من بيانات API. تحقق من نشر الخادم.',
          );
        }
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = decoded is Map<String, dynamic> ? decoded : null;
      final detail = payload?['detail'] ?? payload?['message'];
      throw ManagerApiException(
        detail is String && detail.isNotEmpty
            ? detail
            : 'فشل الطلب (${response.statusCode}).',
      );
    }
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ManagerApiException('استجابة الخادم غير مكتملة.');
  }

  void logout() => _token = null;

  void close() => _client.close();
}
