import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';

import 'fake_transport.dart';

/// A getter, not a `final`: FakeTransport drains the queues it is given.
Map<String, List<TransportResponse>> get signedInRoutes =>
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
      'POST /api/v1/sessions': [
        json(
          200,
          '{"user":{"id":1,"name":"Dev","email":"dev@shams.ai"}}',
          headers: <String, List<String>>{
            'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
          },
        ),
      ],
      'DELETE /api/v1/sessions': [json(200, '{"message":"Signed out."}')],
    };

Widget appFor(HttpTransport transport) => ShamsApp(
  api: ShamsApi(baseUrl: 'http://localhost:3001', transport: transport),
);

Future<void> signIn(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'dev@shams.ai',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    'password',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a 401 from the API lands on the login screen', (tester) async {
    final transport = FakeTransport(unauthenticatedRoutes);
    await tester.pumpWidget(appFor(transport));

    // The first frame is the connecting state, then the 401 routes to login.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
    // A bare 401 means "not signed in yet", not an error to shout about.
    expect(find.text('Please sign in to continue.'), findsNothing);
  });

  testWidgets('signing in reveals conversations and agents', (tester) async {
    final transport = FakeTransport(signedInRoutes);
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();

    await signIn(tester);

    expect(find.text('Roadmap'), findsWidgets);
    expect(find.text('Shams AI'), findsWidgets);
    expect(find.text('CONVERSATIONS'), findsOneWidget);
    expect(find.text('AGENTS'), findsOneWidget);

    // The client must replay the cookie the login response set.
    final agentsCall = transport.sent.lastWhere(
      (request) => request.uri.path == '/api/v1/agents',
    );
    expect(agentsCall.headers['Cookie'], contains('_shams_session=abc123'));
  });

  testWidgets('shows the server message when credentials are wrong', (
    tester,
  ) async {
    final transport = FakeTransport(<String, List<TransportResponse>>{
      ...unauthenticatedRoutes,
      'GET /api/v1/csrf': [json(200, '{"token":"tok"}')],
      'POST /api/v1/sessions': [
        json(401, '{"error":"Invalid email or password."}'),
      ],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();

    await signIn(tester);

    expect(find.text('Invalid email or password.'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('an unreachable server is reported, not silently retried', (
    tester,
  ) async {
    await tester.pumpWidget(appFor(UnreachableTransport()));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Cannot reach http://localhost:3001'),
      findsOneWidget,
    );
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('signing out returns to the login screen', (tester) async {
    final transport = FakeTransport(signedInRoutes);
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(
      transport.sent.any(
        (request) =>
            request.method == 'DELETE' &&
            request.uri.path == '/api/v1/sessions',
      ),
      isTrue,
    );
  });
}
