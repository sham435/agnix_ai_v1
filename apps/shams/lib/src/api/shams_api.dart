import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';

import 'http_transport.dart';
import 'models.dart';

/// A request that the Shams API rejected, or that could not be completed.
class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.twoFactorRequired = false,
    this.retryInSeconds,
    this.payload,
  });

  final String message;
  final int? statusCode;

  /// The refusal's own JSON body, when it had one. A workspace action answers a
  /// rejection with `{ ok:false, error_code, error }` - the reason and its code
  /// are the data the screen has to show, not a transport failure, so the
  /// action methods read them back from here instead of only the message.
  final Map<String, dynamic>? payload;

  /// `authenticate_user!` answers 401 with JSON for API requests, which is how
  /// the client knows it has to show the login screen again.
  bool get unauthorized => statusCode == 401;

  /// The server's own word that the password was right and a second factor is
  /// still owed — 401 when no code was sent, 403 when the one sent was refused.
  /// Nothing here is inferred client-side: an account without two-factor never
  /// sets it, so the code step only appears when the server asks for it.
  final bool twoFactorRequired;

  /// How long to wait before the request may work, when the refusal said so
  /// (`retry_in` on a send that is still cooling down). A client repeats the
  /// server's number instead of guessing its own.
  final int? retryInSeconds;

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

  /// `POST /api/v1/sessions` with `{ email, password }` and, for an account
  /// with a second factor, the `{ code }` the server asked for.
  ///
  /// A successful response carries the session cookies, which `_storeCookies`
  /// has already kept - clearing the jar here would sign the user back out.
  /// [code] doubles as a backup recovery code, which the server spends and
  /// reports in `two_factor.recovery_codes_left`.
  Future<void> login(String email, String password, {String? code}) async {
    await _send(
      'POST',
      '/api/v1/sessions',
      body: jsonEncode({
        'email': email,
        'password': password,
        if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
      }),
    );
  }

  /// `DELETE /api/v1/sessions`.
  Future<void> logout() async {
    await _send('DELETE', '/api/v1/sessions');
    _csrfToken = null;
    await _cookieJar.deleteAll();
  }

  /// `GET /api/v1/security` — two-factor state, phone state, the devices this
  /// account is signed in on, and today's usage.
  Future<SecurityPanel> security() => _getSecurity('/api/v1/security');

  /// `POST /api/v1/security/two_factor` — start an enrollment.
  ///
  /// The key comes back in [SecurityPanel.enrollment] and changes nothing on
  /// the account: only [confirmTwoFactor] activates it, and only after a code
  /// built from that key arrives. The manual key is what a phone's authenticator
  /// app is given — there is no second camera to scan a QR with.
  Future<SecurityPanel> startTwoFactor() =>
      _postSecurity('/api/v1/security/two_factor', {});

  /// Activate the pending enrollment. On success the response carries the
  /// backup codes; they are never shown again by any later call.
  Future<SecurityPanel> confirmTwoFactor(String code) =>
      _postSecurity('/api/v1/security/two_factor/confirm', {'code': code});

  /// Turn the factor off using the current password and an authenticator or
  /// single-use recovery [code]. The server verifies both and retires the codes.
  Future<SecurityPanel> disableTwoFactor(
    String password, {
    required String code,
  }) => _sendSecurity('DELETE', '/api/v1/security/two_factor', {
    'password': password,
    'code': code,
  });

  /// A fresh set of backup codes, retiring the old set. Requires the current
  /// password and an authenticator or single-use recovery [code].
  Future<SecurityPanel> regenerateRecoveryCodes(
    String password, {
    required String code,
  }) => _postSecurity('/api/v1/security/recovery_codes', {
    'password': password,
    'code': code,
  });

  /// Ask for an SMS code. Refusals come back as [ApiException] carrying the
  /// server's own reason; a cooldown also reports how long to wait.
  Future<SecurityPanel> requestPhoneCode(String phone) =>
      _postSecurity('/api/v1/security/phone', {'phone': phone});

  /// Prove the number by the code it received. This is a different claim from a
  /// sign-in code and the server never accepts one as the other.
  Future<SecurityPanel> confirmPhoneCode(String code) =>
      _postSecurity('/api/v1/security/phone/confirm', {'code': code});

  /// Revoke one device. Revoking the device this client is on ends its session,
  /// which [SecurityPanel.signedOut] reports.
  Future<SecurityPanel> revokeDevice(String id) =>
      _sendSecurity('DELETE', '/api/v1/security/devices/$id', null);

  /// Revoke every device and refuse every session issued before now, this one
  /// included. There is no panel to read afterwards.
  Future<void> signOutEverywhere() async {
    await _send('DELETE', '/api/v1/security/devices');
    _csrfToken = null;
    await _cookieJar.deleteAll();
  }

  Future<SecurityPanel> _getSecurity(String path) async {
    final response = await _send('GET', path);
    return SecurityPanel.fromJson(_map(response, path));
  }

  Future<SecurityPanel> _postSecurity(
    String path,
    Map<String, Object?> fields,
  ) => _sendSecurity('POST', path, fields);

  /// The panel's writes all answer the same way: the refreshed state, with the
  /// result of the call merged into it.
  Future<SecurityPanel> _sendSecurity(
    String method,
    String path,
    Map<String, Object?>? fields,
  ) async {
    final response = await _send(
      method,
      path,
      body: fields == null ? null : jsonEncode(fields),
    );
    return SecurityPanel.fromJson(_map(response, path));
  }

  Future<ModelCatalogue> modelCatalogue(String conversationId) async {
    final path =
        '/api/v1/models?conversation_id=${Uri.encodeComponent(conversationId)}';
    return ModelCatalogue.fromJson(_map(await _send('GET', path), path));
  }

  Future<ModelCatalogue> refreshModels(String conversationId) async {
    const path = '/api/v1/models/refresh';
    return ModelCatalogue.fromJson(
      _map(
        await _send(
          'POST',
          path,
          body: jsonEncode({'conversation_id': conversationId}),
        ),
        path,
      ),
    );
  }

  /// A null selection resets only this conversation to its organization default.
  Future<ModelCatalogue> selectConversationModel(
    String conversationId,
    ModelReference? selection,
  ) async {
    final path =
        '/api/v1/conversations/${Uri.encodeComponent(conversationId)}/model';
    return ModelCatalogue.fromJson(
      _map(
        await _send(
          'PATCH',
          path,
          body: jsonEncode(
            selection == null
                ? {'use_organization_default': true}
                : {
                    'provider_id': selection.providerId,
                    'model_id': selection.modelId,
                  },
          ),
        ),
        path,
      ),
    );
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

  /// `POST /api/v1/conversations` - start a chat with [agentId].
  ///
  /// [content] is optional: with it the server runs the whole startup path
  /// (user message, streaming assistant placeholder, `AgentStreamJob`), without
  /// it the conversation is simply empty and the first turn goes through
  /// [sendMessage].
  Future<Conversation> createConversation({
    required String agentId,
    String? content,
  }) async {
    final response = await _send(
      'POST',
      '/api/v1/conversations',
      body: jsonEncode({
        'agent_id': agentId,
        if (content != null && content.isNotEmpty) 'content': content,
      }),
    );
    final body = _map(response, '/api/v1/conversations');
    return Conversation.fromJson(body);
  }

  /// `GET /api/v1/conversations/:id` - one conversation with its messages.
  Future<Conversation> conversation(String id) async {
    final path = '/api/v1/conversations/$id';
    final response = await _send('GET', path);
    return Conversation.fromJson(_map(response, path));
  }

  /// `POST /api/v1/conversations/:id/messages` - one turn.
  ///
  /// The server answers 201 as soon as the user row is saved and queues
  /// `AgentStreamJob`, so the reply is *not* in this response: callers poll
  /// [conversation] until `awaitingReply` goes false.
  Future<Message> sendMessage(String conversationId, String content) async {
    final path = '/api/v1/conversations/$conversationId/messages';
    final response = await _send(
      'POST',
      path,
      body: jsonEncode({'content': content}),
    );
    final body = _map(response, path);
    final message = body['message'];
    if (message is! Map<String, dynamic>) {
      throw ApiException('Expected a "message" object from $path.');
    }
    return Message.fromJson(message);
  }

  /// `GET /api/v1/workspaces` — the sandboxes this account owns, newest first.
  ///
  /// [conversationId] asks for the one that chat runs in, which is how the
  /// screen opened from a conversation finds its own workspace. A conversation
  /// this account does not own simply lists nothing.
  Future<List<Workspace>> listWorkspaces({String? conversationId}) async {
    var path = '/api/v1/workspaces';
    if (conversationId != null) {
      path += '?conversation_id=${Uri.encodeComponent(conversationId)}';
    }
    final response = await _send('GET', path);
    final body = _map(response, path);
    return (body['workspaces'] is List)
        ? (body['workspaces'] as List)
              .whereType<Map<String, dynamic>>()
              .map(Workspace.fromJson)
              .toList(growable: false)
        : const [];
  }

  /// `GET /api/v1/workspaces/:id` — everything the screen draws in one read:
  /// the row, the manager's word about the container, the files and the runs.
  Future<Workspace> workspace(String id) async {
    final path = '/api/v1/workspaces/$id';
    final response = await _send('GET', path);
    final body = _map(response, path);
    final row = body['workspace'];
    if (row is! Map<String, dynamic>) {
      throw ApiException('Expected a "workspace" object from $path.');
    }
    // The row carries the preview *link*; the envelope's `preview` is the
    // container's state, a different fact with the same name, so the halves are
    // merged by key instead of one spreading over the other.
    return Workspace.fromJson(<String, dynamic>{
      ...row,
      'status': body['status'],
      'files': body['files'],
      'files_truncated': body['files_truncated'],
      'files_error': body['files_error'],
      'runs': body['runs'],
    });
  }

  /// `GET /api/v1/workspaces/:id/file` — one project file, by its relative path.
  Future<WorkspaceFileContent> readWorkspaceFile(
    String workspaceId,
    String filePath,
  ) async {
    final path =
        '/api/v1/workspaces/$workspaceId/file'
        '?path=${Uri.encodeComponent(filePath)}';
    final response = await _send('GET', path);
    return WorkspaceFileContent.fromJson(_map(response, path));
  }

  /// `POST /api/v1/workspaces/:id/exec`.
  ///
  /// [argv] runs the tokens as given; [command] is one typed line, which the
  /// *server* splits into argv tokens. Both mean "no shell ever parses this",
  /// and the splitting rule lives in one place rather than being guessed at
  /// here.
  Future<WorkspaceActionResult> runWorkspaceCommand(
    String workspaceId, {
    List<String>? argv,
    String? command,
    int? timeout,
  }) => _workspaceAction(
    'POST',
    '/api/v1/workspaces/$workspaceId/exec',
    body: {
      if (argv != null) 'argv': argv else 'command': command ?? '',
      if (timeout != null) 'timeout': timeout,
    },
  );

  /// `POST /api/v1/workspaces/:id/tests` — the test command the provider chose.
  Future<WorkspaceActionResult> runWorkspaceTests(String workspaceId) =>
      _workspaceAction(
        'POST',
        '/api/v1/workspaces/$workspaceId/tests',
        body: const {},
      );

  /// `POST /api/v1/workspaces/:id/preview` — start the preview server and get
  /// the gateway link this session was issued.
  Future<WorkspaceActionResult> startWorkspacePreview(
    String workspaceId, {
    int? port,
    String? command,
  }) => _workspaceAction(
    'POST',
    '/api/v1/workspaces/$workspaceId/preview',
    body: {
      if (port != null) 'port': port,
      if (command != null && command.isNotEmpty) 'command': command,
    },
  );

  Future<WorkspaceActionResult> stopWorkspacePreview(String workspaceId) =>
      _workspaceAction(
        'DELETE',
        '/api/v1/workspaces/$workspaceId/preview',
        body: null,
      );

  /// `DELETE /api/v1/workspaces/:id` — stop the sandbox. The files stay in the
  /// volume until the manager says otherwise; what it removed is its answer.
  Future<WorkspaceActionResult> stopWorkspace(String workspaceId) =>
      _workspaceAction('DELETE', '/api/v1/workspaces/$workspaceId', body: null);

  /// A workspace action, whether the server ran it or refused it.
  ///
  /// A refusal arrives as a 4xx/5xx with `{ ok:false, error_code, error }`, so
  /// the record caught from the exception is the same shape as a success: the
  /// screen shows the manager's own reason either way and never invents one.
  Future<WorkspaceActionResult> _workspaceAction(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    try {
      final response = await _send(
        method,
        path,
        body: body == null ? null : jsonEncode(body),
      );
      return WorkspaceActionResult.fromJson(_map(response, path));
    } on ApiException catch (error) {
      final payload = error.payload;
      if (payload != null && payload.containsKey('ok')) {
        return WorkspaceActionResult.fromJson(payload);
      }
      rethrow;
    }
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
      final failure = _failure(response);
      throw ApiException(
        failure.message,
        statusCode: response.statusCode,
        twoFactorRequired: failure.twoFactorRequired,
        retryInSeconds: failure.retryInSeconds,
        payload: failure.payload,
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

  Map<String, dynamic> _map(TransportResponse response, String path) {
    final body = _decode(response, path);
    if (body is! Map<String, dynamic>) {
      throw ApiException(
        'Expected a JSON object from $path, received ${body.runtimeType}.',
        statusCode: response.statusCode,
      );
    }
    return body;
  }

  /// What a rejection actually said, read once from its body.
  ///
  /// `authenticate_user!` and the security endpoints write `{ "error": ... }`;
  /// the phone verifier writes `{ "status", "message", "retry_in" }`; a refused
  /// workspace action writes `{ "ok": false, "error_code", "error" }`. All are
  /// the server's own words, and answering a cooldown with "Request failed
  /// with status 429" would hide the one number the user can act on.
  ({
    String message,
    bool twoFactorRequired,
    int? retryInSeconds,
    Map<String, dynamic>? payload,
  }) _failure(TransportResponse response) {
    Map<String, dynamic>? body;
    if (response.body.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } on FormatException {
        body = null;
      }
    }

    // Only sign-in sets `two_factor_required`, and only once the password has
    // been proved, so a 401 from anywhere else never means "ask for a code".
    return (
      message:
          _said(body?['error']) ??
          _said(body?['message']) ??
          'Request failed with status ${response.statusCode}',
      twoFactorRequired: body?['two_factor_required'] == true,
      retryInSeconds: body?['retry_in'] is int
          ? body!['retry_in'] as int
          : null,
      payload: body,
    );
  }

  static String? _said(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

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
