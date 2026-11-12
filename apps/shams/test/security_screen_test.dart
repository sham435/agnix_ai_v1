import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';
import 'package:shams_app/src/screens/security_screen.dart';

import 'fake_transport.dart';

/// The account & security screen and the two-factor sign-in step.
///
/// These tests hold the screen to the rule the whole feature is built on:
/// nothing about protection is decided here. The code field appears because
/// `POST /api/v1/sessions` asked for a code, the setup key is shown while the
/// account is still unprotected, and 'On' only ever follows the server saying
/// it activated.
final _offSnapshot = securityPayload(
  devices: [
    deviceJson(currentDeviceId, 'Chrome · macOS', current: true),
    deviceJson(otherDeviceId, 'Safari · iPhone'),
  ],
);

final _onSnapshot = securityPayload(
  twoFactorEnabled: true,
  recoveryCodesLeft: 10,
  phone: '+94771234567',
  phoneVerified: true,
  devices: [deviceJson(currentDeviceId, 'Chrome · macOS', current: true)],
);

/// Anonymous until signed in, then the thread list.
Map<String, List<TransportResponse>> get _loginRoutes =>
    <String, List<TransportResponse>>{
      'GET /api/v1/conversations': [
        json(401, '{"error":"Please sign in to continue."}'),
        json(200, conversationPayload),
      ],
      'GET /api/v1/agents': [
        json(401, '{"error":"Please sign in to continue."}'),
        json(200, agentPayload),
      ],
      'GET /api/v1/csrf': [json(200, '{"token":"tok"}')],
    };

/// The same, with a sign-in that comes back asking for a second factor before
/// it accepts one.
Map<String, List<TransportResponse>> get _twoFactorLoginRoutes => {
  ..._loginRoutes,
  'POST /api/v1/sessions': [
    json(
      401,
      '{"error":"Two-factor authentication required.",'
      '"two_factor_required":true}',
    ),
    json(
      200,
      '{"user":{"id":1},"two_factor":{"enabled":true,'
      '"recovery_codes_left":9}}',
      headers: <String, List<String>>{
        'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
      },
    ),
  ],
};

ShamsApi _api(HttpTransport transport) =>
    ShamsApi(baseUrl: 'http://localhost:3001', transport: transport);

Future<void> _signIn(
  WidgetTester tester, {
  String? code,
  String password = 'password',
}) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'dev@shams.ai',
  );
  await tester.enterText(find.widgetWithText(TextField, 'Password'), password);
  if (code != null) {
    await tester.enterText(
      find.widgetWithText(TextField, 'Authentication code'),
      code,
    );
  }
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

/// Scrolls the security screen until [target] is on screen. Its sections are
/// stacked taller than the test surface, and a `ListView` only builds what is
/// near the viewport.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  // Built is not tappable: the list lays out past its viewport, so the row the
  // drag found can still sit below the fold.
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Signed-in home with the security snapshot on offer.
Future<FakeTransport> _openPanel(WidgetTester tester) async {
  final transport = FakeTransport({
    ..._loginRoutes,
    'POST /api/v1/sessions': [
      json(
        200,
        '{"user":{"id":1}}',
        headers: <String, List<String>>{
          'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
        },
      ),
    ],
    'GET /api/v1/security': [json(200, _offSnapshot)],
    'DELETE /api/v1/security/devices/$otherDeviceId': [
      json(
        200,
        securityPayload(
          devices: [
            deviceJson(currentDeviceId, 'Chrome · macOS', current: true),
          ],
          message: 'Safari · iPhone was signed out.',
        ),
      ),
    ],
    'DELETE /api/v1/security/devices': [
      json(
        200,
        '{"message":"Signed out everywhere. Sign in again to continue.",'
        '"signed_out":true}',
      ),
    ],
  });
  await tester.pumpWidget(ShamsApp(api: _api(transport)));
  await tester.pumpAndSettle();
  await _signIn(tester);

  await tester.tap(find.byIcon(Icons.menu));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Account & security'));
  await tester.pumpAndSettle();
  return transport;
}

void main() {
  group('two-factor sign-in', () {
    testWidgets('shows no code field until the server asks for a code', (
      tester,
    ) async {
      final transport = FakeTransport(_twoFactorLoginRoutes);
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Authentication code'),
        findsNothing,
        reason: 'this account may not have a second factor at all',
      );

      await _signIn(tester);

      // The refusal said what is owed; the form now offers exactly that, and
      // repeats the credentials already on screen rather than starting over.
      expect(
        find.widgetWithText(TextField, 'Authentication code'),
        findsOneWidget,
      );
      expect(find.text('Two-factor authentication required.'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Email'),
        findsOneWidget,
        reason: 'the email stays filled; only the code was missing',
      );

      await _signIn(tester, code: '429117');

      expect(find.text('Roadmap'), findsWidgets);

      final codes = transport.sent
          .where((r) => r.uri.path == '/api/v1/sessions')
          .map((r) => r.body)
          .toList();
      expect(codes.first, isNot(contains('code')));
      expect(codes.last, contains('"code":"429117"'));
    });

    testWidgets('a wrong code keeps the step open and the account locked out', (
      tester,
    ) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(
            401,
            '{"error":"Two-factor authentication required.",'
            '"two_factor_required":true}',
          ),
          json(
            403,
            '{"error":"Invalid two-factor code.","two_factor_required":true}',
          ),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester);
      await _signIn(tester, code: '111111');

      expect(find.text('Invalid two-factor code.'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Authentication code'),
        findsOneWidget,
        reason: 'the server still owes a sign-in; the step must stay open',
      );
      expect(find.text('Roadmap'), findsNothing);
    });

    testWidgets('a wrong password never becomes a request for a code', (
      tester,
    ) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(401, '{"error":"Invalid email or password."}'),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester, password: 'nope');

      expect(find.text('Invalid email or password.'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Authentication code'),
        findsNothing,
      );
    });
  });

  group('account & security screen', () {
    testWidgets('opens from the drawer and draws the server state', (
      tester,
    ) async {
      final transport = await _openPanel(tester);

      expect(find.byType(SecurityScreen), findsOneWidget);
      expect(find.text('Account & security'), findsWidgets);
      expect(find.text('Two-factor authentication'), findsOneWidget);
      // Read from the payload, not assumed: off is what the snapshot said.
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Set up two-factor authentication'), findsOneWidget);

      await _scrollTo(tester, find.text('Usage & membership'));
      expect(find.text('Usage & membership'), findsOneWidget);
      expect(find.text('Signed-in devices'), findsOneWidget);
      expect(
        transport.sent.any((r) => r.uri.path == '/api/v1/security'),
        isTrue,
      );
    });

    testWidgets('an enrollment shows the key while two-factor is still off', (
      tester,
    ) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(
            200,
            '{"user":{"id":1}}',
            headers: <String, List<String>>{
              'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
            },
          ),
        ],
        'GET /api/v1/security': [json(200, _offSnapshot)],
        'POST /api/v1/security/two_factor': [
          json(200, securityPayload(enrollment: pendingEnrollmentJson)),
        ],
        'POST /api/v1/security/two_factor/confirm': [
          json(
            200,
            securityPayload(
              twoFactorEnabled: true,
              recoveryCodesLeft: 2,
              recoveryCodes: const ['2K4QX7ZR9T', 'ABCD2EFGHJ'],
            ),
          ),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account & security'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Set up two-factor authentication'));
      await tester.pumpAndSettle();

      expect(find.text('Setup key'), findsOneWidget);
      expect(find.text(pendingSecret), findsOneWidget);
      expect(find.text('Six-digit code'), findsOneWidget);
      expect(
        find.text('Off'),
        findsOneWidget,
        reason: 'opening the enrollment must not turn anything on',
      );
      expect(find.text('Backup codes'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Six-digit code'),
        '429117',
      );
      await tester.tap(find.text('Activate two-factor'));
      await tester.pumpAndSettle();

      expect(find.text('On'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(find.text('Setup key'), findsNothing);
      // Shown once, from the response that minted them.
      expect(find.text('Backup codes'), findsOneWidget);
      expect(find.textContaining('2K4QX7ZR9T'), findsOneWidget);

      await tester.tap(find.text('I have saved them'));
      await tester.pumpAndSettle();
      expect(find.text('Backup codes'), findsNothing);

      final confirm = transport.sent.lastWhere(
        (r) => r.uri.path.endsWith('/two_factor/confirm'),
      );
      expect(confirm.body, contains('"code":"429117"'));
    });

    testWidgets('turning two-factor off costs the password', (tester) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(
            200,
            '{"user":{"id":1}}',
            headers: <String, List<String>>{
              'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
            },
          ),
        ],
        'GET /api/v1/security': [json(200, _onSnapshot)],
        'DELETE /api/v1/security/two_factor': [
          json(422, '{"error":"Wrong password. Nothing was changed."}'),
          json(200, securityPayload()),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account & security'));
      await tester.pumpAndSettle();

      // On, and the only way off is through the current password.
      expect(find.text('On'), findsOneWidget);
      expect(find.text('Set up two-factor authentication'), findsNothing);

      await tester.tap(find.text('Turn two-factor off'));
      await tester.pumpAndSettle();

      expect(find.text('Wrong password. Nothing was changed.'), findsOneWidget);
      expect(find.text('On'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Current password'),
        'password',
      );
      await tester.tap(find.text('Turn two-factor off'));
      await tester.pumpAndSettle();

      expect(find.text('Off'), findsOneWidget);
      final call = transport.sent.lastWhere(
        (r) => r.uri.path == '/api/v1/security/two_factor',
      );
      expect(call.method, 'DELETE');
      expect(call.body, contains('"password":"password"'));
    });

    testWidgets('lists this device without a button and offers the other one', (
      tester,
    ) async {
      final transport = await _openPanel(tester);

      await _scrollTo(tester, find.text('Signed-in devices'));
      expect(find.textContaining('this device'), findsOneWidget);
      expect(find.text('Revoke'), findsOneWidget);
      await _scrollTo(tester, find.widgetWithText(TextButton, 'Revoke'));
      expect(
        find.widgetWithText(TextButton, 'Revoke'),
        findsOneWidget,
        reason: 'this row is signed in on - signing out here is the control',
      );

      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();

      final revoke = transport.sent.lastWhere(
        (r) => r.uri.path.startsWith('/api/v1/security/devices/'),
      );
      expect(revoke.method, 'DELETE');
      expect(revoke.uri.path, '/api/v1/security/devices/$otherDeviceId');
      // The list the server answered with, not the one still on screen.
      expect(find.text('Revoke'), findsNothing);
    });

    testWidgets('signing out everywhere leaves the screen', (tester) async {
      final transport = await _openPanel(tester);

      await _scrollTo(tester, find.text('Sign out everywhere'));
      await tester.tap(find.text('Sign out everywhere'));
      await tester.pumpAndSettle();

      expect(find.byType(SecurityScreen), findsNothing);
      expect(
        transport.sent.lastWhere((r) => r.method == 'DELETE').uri.path,
        '/api/v1/security/devices',
      );
    });

    testWidgets('an expired setup request is shown as the server words it', (
      tester,
    ) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(
            200,
            '{"user":{"id":1}}',
            headers: <String, List<String>>{
              'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
            },
          ),
        ],
        'GET /api/v1/security': [json(200, _offSnapshot)],
        'POST /api/v1/security/two_factor': [
          json(200, securityPayload(enrollment: pendingEnrollmentJson)),
        ],
        'POST /api/v1/security/two_factor/confirm': [
          json(410, '{"error":"That setup request expired. Start again."}'),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account & security'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up two-factor authentication'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Six-digit code'),
        '429117',
      );
      await tester.tap(find.text('Activate two-factor'));
      await tester.pumpAndSettle();

      expect(
        find.text('That setup request expired. Start again.'),
        findsOneWidget,
      );
      expect(
        find.text('Off'),
        findsOneWidget,
        reason: 'a refused confirmation cannot claim the factor is on',
      );
    });

    testWidgets('a phone cooldown repeats the wait the server reported', (
      tester,
    ) async {
      final transport = FakeTransport({
        ..._loginRoutes,
        'POST /api/v1/sessions': [
          json(
            200,
            '{"user":{"id":1}}',
            headers: <String, List<String>>{
              'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
            },
          ),
        ],
        'GET /api/v1/security': [json(200, _offSnapshot)],
        'POST /api/v1/security/phone': [
          json(
            429,
            '{"status":"cooldown","message":"That code is still valid. Wait '
            'before asking for another.","retry_in":42}',
          ),
        ],
      });
      await tester.pumpWidget(ShamsApp(api: _api(transport)));
      await tester.pumpAndSettle();
      await _signIn(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account & security'));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Send code'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Mobile number'),
        '+94771234567',
      );
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Try again in 42 seconds.'),
        findsOneWidget,
        reason: 'the number is the server answer, not a client countdown',
      );
      expect(
        find.widgetWithText(TextField, 'Code from the text message'),
        findsNothing,
        reason: 'no code went out, so there is nothing to ask for',
      );
    });
  });
}
