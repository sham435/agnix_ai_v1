import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';
import 'package:shams_app/src/widgets/transcript.dart';

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

/// The same thread with the new answer in place, its cost, and enough of a gap
/// between the placeholder's `created_at` and this final write's `updated_at`
/// that the transcript can show "took 22s".
final _answered = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: 'Rails 8.2 is out.',
  tokens: 210,
);

/// The same thread when the run failed. `content` holds only the fixed
/// sentence; the reason lives in `metadata["error"]`, which is the difference
/// between "something broke" and "the agent has no Anthropic key".
final _failed = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: genericFailure,
  error: providerErrorDetail,
);

/// The same thread while `AgentStreamJob` is still working and has written
/// nothing yet. The assistant row is an empty placeholder.
final _pending = conversationDetailPayload(title: 'Roadmap');

/// The same thread with the answer only partly arrived: the placeholder is
/// still flagged streaming, but now carries the words produced so far. This is
/// the state that lets the reply appear as it is generated rather than all at
/// once at the end.
final _partial = conversationDetailPayload(
  title: 'Roadmap',
  streaming: true,
  reply: 'Rails 8.2 is',
);

/// A finished answer whose text is Markdown, so rendering can be checked
/// against the source: the headings/lists/bold markers must disappear and the
/// words they wrapped must survive.
final _markdown = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply:
      '# Release plan\n\n'
      'Two steps, in order:\n\n'
      '1. build the image\n'
      '2. sign it\n\n'
      'The important part is **not to skip signing**.',
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
    expect(
      find.text('Message shams ai…'),
      findsOneWidget,
    ); // the empty composer hint
    // The agent and its model, which is how the model choice stays visible.
    expect(find.text('Shams AI · openai · bonsai-227b'), findsOneWidget);
    // The workspace is behind this route now.
    expect(find.text('CONVERSATIONS'), findsNothing);
    // The whole transcript is selectable as one surface, not per-bubble.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('a finished turn names the time it was asked and completed', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'GET /api/v1/conversations/$conversationId': [json(200, _answered)],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    // The two numbers the request asked for - when the turn was made and when
    // the answer landed - plus how long it took and what it cost. The clock
    // strings are shown in the viewer's zone, so the tests check the labels and
    // the computed parts that are zone-independent, not the exact digits.
    expect(find.textContaining('Asked '), findsOneWidget);
    expect(find.textContaining('Finished '), findsOneWidget);
    expect(find.textContaining('took 22s'), findsOneWidget);
    expect(find.textContaining('210 tokens'), findsOneWidget);
  });

  testWidgets('the reply is rendered as Markdown, not literal source', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'GET /api/v1/conversations/$conversationId': [json(200, _markdown)],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    // The words the markers wrapped all survive...
    expect(find.textContaining('Release plan'), findsWidgets);
    expect(find.textContaining('build the image'), findsOneWidget);
    expect(find.textContaining('sign it'), findsOneWidget);
    expect(find.textContaining('not to skip signing'), findsOneWidget);
    // ...and the Markdown syntax that produced them is gone.
    expect(find.textContaining('# Release plan'), findsNothing);
    expect(find.textContaining('**not to skip signing**'), findsNothing);
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
        json(200, _pending),
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
    expect(find.text('Message shams ai…'), findsOneWidget); // the field cleared
    expect(find.textContaining('Agent is working'), findsOneWidget);

    // Step the clock past one poll interval. pumpAndSettle would never return
    // while that periodic timer is alive.
    await tester.pump(_pollTick);
    await tester.pump();

    expect(find.textContaining('Agent is working'), findsNothing);
    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    // The thread shows both the question and its answer, not just the newest.
    expect(find.text('hi'), findsOneWidget);

    // No further polls once the placeholder is closed.
    final polls = transport.sent.where(
      (request) => request.uri.path == '/api/v1/conversations/$conversationId',
    );
    expect(polls, hasLength(3));
  });

  testWidgets('the answer appears while it is still being written', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      // The read after the send already carries a partial answer in the
      // streaming row, so the user sees words before the turn is over.
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, _partial),
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

    // The partial text is on screen and the composer stays locked - the words
    // are the progress, so the separate "working" line is suppressed rather
    // than shown alongside a half-written sentence.
    expect(find.textContaining('Rails 8.2 is'), findsOneWidget);
    expect(find.textContaining('Agent is working'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await tester.pump(_pollTick);
    await tester.pump();

    // Grown to the full answer, the streaming flag cleared, composer released.
    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('a second turn cannot be posted while the agent is writing', (
    tester,
  ) async {
    int postedTurns(FakeTransport t) => t.sent
        .where(
          (request) =>
              request.method == 'POST' &&
              request.uri.path.endsWith('/messages'),
        )
        .length;

    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      // Open the thread, post a turn, then sit in the job's mid-run state for a
      // poll before the answer finally lands.
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, _pending),
        json(200, _pending),
        json(200, _answered),
      ],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);
    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'and a second turn?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Agent is working'), findsOneWidget);
    // This is the whole point: the composer used to reopen seconds after the
    // POST, while the reply still needed a minute, and a second tap started a
    // second AgentStreamJob on the same conversation.
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    // Still waiting a poll tick later - and still exactly one turn posted.
    await tester.pump(_pollTick);
    await tester.pump();
    expect(postedTurns(transport), 1);

    await tester.pump(_pollTick);
    await tester.pump();

    expect(find.textContaining('Agent is working'), findsNothing);
    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(postedTurns(transport), 1);
  });

  testWidgets('the waiting line is a labelled indicator, not a bare spinner', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, _pending),
        json(200, _pending),
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

    // The complaint this replaces: "only Agent is thinking and a rotation
    // arrow in a round". The wait is a TypingIndicator - a labelled row with an
    // elapsed counter - not an anonymous spinner.
    expect(find.byType(TypingIndicator), findsOneWidget);
    expect(find.textContaining('Agent is working'), findsOneWidget);
  });

  testWidgets('a reply is still followed up when the placeholder was not '
      'visible in the read after the send', (tester) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      // The sequence that used to lose an answer: the thread, then a read taken
      // while `AgentStreamJob` has not written this turn's row yet, then the
      // placeholder, then the finished reply.
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, turnPostedPayload),
        json(200, _pending),
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
    await tester.pump();

    // `turnPostedPayload` flags nothing as streaming. Treating that as "no
    // answer is coming" is the bug - the job had simply not written the row
    // yet, and the reply landed seconds later into a screen that had stopped
    // looking.
    expect(
      find.textContaining('Agent is working'),
      findsOneWidget,
      reason:
          'a turn this client just posted is waited on even before the '
          'server creates the placeholder',
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    // Keep polling: the placeholder shows up on the next read.
    await tester.pump(_pollTick);
    await tester.pump();
    expect(find.textContaining('Agent is working'), findsOneWidget);

    await tester.pump(_pollTick);
    await tester.pump();

    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    expect(find.textContaining('Agent is working'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);

    final polls = transport.sent.where(
      (request) => request.uri.path == '/api/v1/conversations/$conversationId',
    );
    expect(polls, hasLength(4));
  });

  testWidgets('a failed turn shows the reason the server recorded', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'GET /api/v1/conversations/$conversationId': [json(200, _failed)],
    });
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Roadmap'));
    await tester.pumpAndSettle();

    expect(find.textContaining(genericFailure), findsOneWidget);
    // The sentence on its own was the whole complaint. This is the part that
    // says what to fix - and it arrives in the payload today.
    expect(find.textContaining('x-api-key header is required'), findsOneWidget);
    // A failed turn is not a completed task, so its cost line is suppressed.
    expect(find.textContaining('Finished'), findsNothing);
    // Everything still lives under one selectable surface, so the exact
    // provider error can be copied out of the app.
    expect(find.byType(SelectionArea), findsOneWidget);
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
    expect(find.text('Message shams ai…'), findsOneWidget);
    // The empty payload carries no agent, so this line can only come from the
    // agent that was picked - which is the model choice staying visible.
    expect(find.text('Shams AI · openai · bonsai-227b'), findsOneWidget);
  });
}
