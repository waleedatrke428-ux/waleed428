import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(String baseUrl)
      : _baseUri = Uri.parse(baseUrl),
        _client = http.Client();

  final Uri _baseUri;
  final http.Client _client;
  String? accessToken;

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) {
    return _send(
      'POST',
      '/api/auth/login',
      body: {'email': email, 'password': password},
    );
  }

  Future<Map<String, dynamic>> register({
    required String phone,
    required String email,
    required String password,
  }) {
    return _send(
      'POST',
      '/api/auth/register',
      body: {'phone': phone, 'email': email, 'password': password},
    );
  }

  Future<Map<String, dynamic>> getEntitlement() =>
      _send('GET', '/api/me/entitlement');

  Future<List<Map<String, dynamic>>> getSignals() =>
      _getItems('/api/signals');

  Future<List<Map<String, dynamic>>> getMarkets({String query = ''}) async {
    final items = await _getItems(
      '/api/markets',
      query: query.isEmpty ? null : {'query': query},
    );
    return items;
  }

  Future<List<Map<String, dynamic>>> getNews() => _getItems('/api/news');

  Future<void> markEntered(String signalId) async {
    await _send('POST', '/api/me/signals/${Uri.encodeComponent(signalId)}/entered');
  }

  Future<List<Map<String, dynamic>>> _getItems(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await _send('GET', path, query: query);
    final items = response['items'];
    if (items is! List) {
      throw const ApiException('استجابة الخادم لا تحتوي قائمة عناصر صالحة.');
    }
    return items.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final uri = _baseUri.resolve(path).replace(queryParameters: query);
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    final token = accessToken;
    if (token != null) headers['Authorization'] = 'Bearer $token';

    late http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 20),
          );
      response = await http.Response.fromStream(streamed).timeout(
        const Duration(seconds: 20),
      );
    } on Exception {
      throw const ApiException(
        'تعذّر الاتصال بالخادم. تحقق من الاتصال وحاول مجدداً.',
      );
    }

    Object? decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw const ApiException('استجابة الخادم غير صالحة.');
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final payload = decoded is Map<String, dynamic> ? decoded : null;
      final message = payload?['message'] ?? payload?['detail'];
      throw ApiException(
        message is String && message.isNotEmpty
            ? message
            : 'تعذّر تنفيذ الطلب (${response.statusCode}).',
      );
    }
    if (decoded is Map<String, dynamic>) return decoded;
    throw const ApiException('استجابة الخادم غير مكتملة.');
  }

  void close() => _client.close();
}
