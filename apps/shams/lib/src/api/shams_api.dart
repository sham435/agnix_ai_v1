import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';

import 'http_transport.dart';
import 'models.dart';

/// A request that the Shams API rejected, or that could not be completed.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// `authenticate_user!` answers 401 with JSON for API requests, which is how
  /// the client knows it has to show the login screen again.
  bool get unauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException(${statusCode ?? '-'}): $message';
}

/// Client for the Rails `/api/v1` JSON API.
///
/// Mirrors `mobile/src/api/client.ts`: session state lives in cookies that this
/// class owns (there is no bearer token), and mutating requests must replay the
/// CSRF token the server handed out.
class ShamsApi {
  ShamsApi({
    required String baseUrl,
    HttpTransport? transport,
    CookieJar? cookieJar,
  }) : baseUrl = _normalise(baseUrl),
       _transport = transport ?? IoHttpTransport(),
       _cookieJar = cookieJar ?? CookieJar();

  /// Origin only - no trailing slash, no path.
  final String baseUrl;

  final HttpTransport _transport;
  final CookieJar _cookieJar;

  String? _csrfToken;

  /// Exposed for tests and for surfacing the resolved origin in the UI.
  String get origin => baseUrl;

  /// `GET /api/v1/csrf` - `{ token }`. Failures are swallowed exactly like the
  /// Expo client does: a missing token only matters once a POST is attempted.
  Future<void> fetchCsrfToken() async {
    try {
      final response = await _send('GET', '/api/v1/csrf');
      final body = _decode(response, '/api/v1/csrf') as Map<String, dynamic>?;
      final token = body?['token'];
      if (token is String && token.isNotEmpty) _csrfToken = token;
    } on ApiException {
      // Leave the token unset; the caller retries through login().
    }
  }

  /// `POST /api/v1/sessions` with `{ email, password }`.
  ///
  /// A successful response carries the session cookies, which `_storeCookies`
  /// has already kept - clearing the jar here would sign the user back out.
  Future<void> login(String email, String password) async {
    await _send(
      'POST',
      '/api/v1/sessions',
      body: jsonEncode({'email': email, 'password': password}),
    );
  }

  /// `DELETE /api/v1/sessions`.
  Future<void> logout() async {
    await _send('DELETE', '/api/v1/sessions');
    _csrfToken = null;
    await _cookieJar.deleteAll();
  }

  /// `GET /api/v1/agents` - agents of the active organization.
  Future<List<Agent>> listAgents() async {
    final response = await _send('GET', '/api/v1/agents');
    final body = _decode(response, '/api/v1/agents');
    return _listOfMaps(body).map(Agent.fromJson).toList(growable: false);
  }

  /// `GET /api/v1/conversations` - active conversations, newest first, each
  /// with its agent embedded.
  Future<List<Conversation>> listConversations() async {
    final response = await _send('GET', '/api/v1/conversations');
    final body = _decode(response, '/api/v1/conversations');
    return _listOfMaps(body).map(Conversation.fromJson).toList(growable: false);
  }

  void close() => _transport.close();

  Future<TransportResponse> _send(
    String method,
    String path, {
    String? body,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (_csrfToken != null) 'X-CSRF-Token': _csrfToken!,
    };

    final cookies = await _cookieJar.loadForRequest(uri);
    if (cookies.isNotEmpty) {
      headers['Cookie'] = cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    }

    final response = await _transport.send(
      TransportRequest(method: method, uri: uri, headers: headers, body: body),
    );

    await _storeCookies(uri, response);

    final rotated = response.valueFor('x-csrf-token');
    if (rotated != null && rotated.isNotEmpty) _csrfToken = rotated;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        _errorMessage(response),
        statusCode: response.statusCode,
      );
    }

    return response;
  }

  Future<void> _storeCookies(Uri uri, TransportResponse response) async {
    final raw = response.valuesFor('set-cookie');
    if (raw.isEmpty) return;

    final cookies = <Cookie>[];
    for (final value in raw) {
      try {
        cookies.add(Cookie.fromSetCookieValue(value));
      } on FormatException {
        // Skip a cookie this platform cannot parse rather than failing the call.
      }
    }
    if (cookies.isNotEmpty) await _cookieJar.saveFromResponse(uri, cookies);
  }

  Object? _decode(TransportResponse response, String path) {
    if (response.statusCode == 204 || response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw ApiException(
        'Expected JSON from $path but got a ${response.statusCode} '
        '${_contentType(response)} body.',
        statusCode: response.statusCode,
      );
    }
  }

  List<Map<String, dynamic>> _listOfMaps(Object? body) {
    if (body is! List) {
      throw ApiException(
        'Expected a JSON array, received ${body.runtimeType}.',
      );
    }
    return body.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  String _errorMessage(TransportResponse response) {
    if (response.body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final error = decoded['error'];
          if (error is String && error.isNotEmpty) return error;
        }
      } on FormatException {
        // Fall through to the generic message.
      }
    }
    return 'Request failed with status ${response.statusCode}';
  }

  String _contentType(TransportResponse response) =>
      response.valueFor('content-type') ?? 'unknown';

  static String _normalise(String baseUrl) {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
