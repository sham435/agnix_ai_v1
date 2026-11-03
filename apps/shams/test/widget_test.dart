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

/// The "Roadmap" thread as `GET /api/v1/conversations/:id` returns it once the
/// agent has answered: the stored `hi` turn plus its reply.
final _roadmap = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: 'Earlier answer.',
);

/// The same thread with the new answer in place.
final _answered = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: 'Rails 8.2 is out.',
);

/// Just past the 1200 ms interval `ChatScreen` polls on.
const _pollTick = Duration(milliseconds: 1300);

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

  testWidgets('opening a conversation shows its thread and a composer', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'GET /api/v1/conversations/$conversationId': [json(200, _roadmap)],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    expect(find.text('hi'), findsOneWidget); // the stored user turn
    expect(find.text('Earlier answer.'), findsOneWidget); // the agent's turn
    expect(find.text('Message'), findsOneWidget); // the empty composer hint
    // The agent and its model, which is how the model choice stays visible.
    expect(find.text('Shams AI · openai · bonsai-227b'), findsOneWidget);
    // The workspace is behind this route now.
    expect(find.text('CONVERSATIONS'), findsNothing);
  });

  testWidgets('sending a turn waits on the job, then shows its reply', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      // First read: finished. Second: `AgentStreamJob` is mid-run. Third: the
      // answer landed, which is what stops the polling.
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, conversationDetailPayload(title: 'Roadmap')),
        json(200, _answered),
      ],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Rails 8.2?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(
      transport.sent
          .lastWhere(
            (request) =>
                request.method == 'POST' &&
                request.uri.path ==
                    '/api/v1/conversations/$conversationId/messages',
          )
          .body,
      '{"content":"Rails 8.2?"}',
      reason: 'the composer posts exactly what was typed',
    );
    expect(find.text('Message'), findsOneWidget); // the field cleared
    expect(find.text('Agent is thinking'), findsOneWidget);

    // Step the clock past one poll interval. pumpAndSettle would never return
    // while that periodic timer is alive.
    await tester.pump(_pollTick);
    await tester.pump();

    expect(find.text('Agent is thinking'), findsNothing);
    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    // The thread is the whole conversation, not just the newest turn.
    expect(find.byType(SelectableText), findsNWidgets(2));

    // No further polls once the placeholder is closed.
    final polls = transport.sent.where(
      (request) => request.uri.path == '/api/v1/conversations/$conversationId',
    );
    expect(polls, hasLength(3));
  });

  testWidgets('New chat asks which agent, then opens an empty thread', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations': [json(201, createdConversationPayload)],
      'GET /api/v1/conversations/$conversationId': [
        json(200, emptyConversationDetailPayload),
      ],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('New chat'));
    await tester.pumpAndSettle();

    expect(find.text('Start a conversation'), findsOneWidget);
    expect(
      transport.sent.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path == '/api/v1/conversations',
      ),
      isEmpty,
      reason: 'nothing is created until an agent is chosen',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      transport.sent
          .firstWhere(
            (request) =>
                request.method == 'POST' &&
                request.uri.path == '/api/v1/conversations',
          )
          .body,
      '{"agent_id":"$agentId"}',
    );
    expect(
      find.textContaining('No messages yet. Say something.'),
      findsOneWidget,
    );
    expect(find.text('Message'), findsOneWidget);
    // The empty payload carries no agent, so this line can only come from the
    // agent that was picked - which is the model choice staying visible.
    expect(find.text('Shams AI · openai · bonsai-227b'), findsOneWidget);
  });
}
