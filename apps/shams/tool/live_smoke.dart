// End-to-end check of the client against a *running* Rails server.
//
// Start the app first (port 3001, per Procfile.dev), then:
//
//   env -u DATABASE_URL bin/rails server -p 3001      # repository root
//   dart run tool/live_smoke.dart
//
// Override the target if needed:
//
//   dart run tool/live_smoke.dart http://10.0.2.2:3001
//
// It uses the same ShamsApi - and therefore the same dart:io transport and
// cookie jar - that the app ships with, so passing means the real cookie and
// CSRF handshake works on this platform, not just under the FakeTransport used
// by the unit tests.
import 'dart:io';

import 'package:shams_app/src/api/shams_api.dart';

Future<void> main(List<String> args) async {
  final baseUrl = args.isEmpty ? 'http://127.0.0.1:3001' : args.first;
  final email = Platform.environment['SHAMS_SMOKE_EMAIL'] ?? 'shams@shams.ai';
  final password =
      Platform.environment['SHAMS_SMOKE_PASSWORD'] ?? 'password123';

  print('target: $baseUrl  user: $email');

  await _rawCookieProbe(baseUrl, email: email, password: password);

  final api = ShamsApi(baseUrl: baseUrl);
  try {
    _step('anonymous GET /api/v1/conversations is rejected');
    try {
      await api.listConversations();
      _fail('expected an ApiException for an anonymous request');
    } on ApiException catch (error) {
      _check(error.unauthorized, 'expected 401, got ${error.statusCode}');
      print('  server said: ${error.message}');
    }

    _step('GET /api/v1/csrf');
    await api.fetchCsrfToken();

    _step('POST /api/v1/sessions');
    await api.login(email, password);
    print('  signed in');

    _step('GET /api/v1/conversations (authenticated)');
    final conversations = await api.listConversations();
    print('  ${conversations.length} active conversation(s)');
    for (final conversation in conversations.take(3)) {
      print(
        '    - ${conversation.displayName} '
        '[agent: ${conversation.agent?.name ?? "none"}]',
      );
    }

    _step('GET /api/v1/agents (authenticated)');
    final agents = await api.listAgents();
    print('  ${agents.length} agent(s)');
    for (final agent in agents.take(3)) {
      print('    - ${agent.name} (${agent.subtitle})');
    }

    _step('DELETE /api/v1/sessions');
    await api.logout();

    _step('anonymous again after logout');
    try {
      await api.listAgents();
      _fail('expected the session to be gone after logout');
    } on ApiException catch (error) {
      _check(error.unauthorized, 'expected 401 after logout');
    }
  } finally {
    api.close();
  }

  print('\nlive smoke test passed');
}

/// Read the login response with `dart:io` directly to confirm how many
/// `Set-Cookie` values Rails actually sends - the case that folded-header
/// clients get wrong.
Future<void> _rawCookieProbe(
  String baseUrl, {
  required String email,
  required String password,
}) async {
  _step('raw POST /api/v1/sessions to inspect Set-Cookie');
  final client = HttpClient();
  try {
    final uri = Uri.parse('$baseUrl/api/v1/sessions');
    final request = await client.openUrl('POST', uri);
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Accept', 'application/json');
    request.write('{"email":"$email","password":"$password"}');
    final response = await request.close();
    await response.drain<void>();

    final cookies = response.headers['set-cookie'] ?? const <String>[];
    final names = cookies.map((value) => value.split('=').first).toList();
    print('  status: ${response.statusCode}, cookies: $names');
    _check(names.length >= 2, 'login response lost the second cookie');
  } finally {
    client.close();
  }
}

void _step(String label) => print('\n==> $label');

void _check(bool condition, String failure) {
  if (!condition) _fail(failure);
}

Never _fail(String message) {
  stderr.writeln('FAILED: $message');
  exit(1);
}
