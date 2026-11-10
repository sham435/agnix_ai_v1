import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';
import 'package:shams_app/src/theme/app_theme.dart';
import 'package:shams_app/src/theme/theme_controller.dart';

import 'fake_transport.dart';

/// Tests for the redesign's new surfaces: the theme selector and its
/// persistence, the welcome surface's prompt cards, the desktop Enter-to-send
/// behaviour, the copy-response affordance, the phone drawer and the desktop
/// sidebar shell.
///
/// They reuse the main suite's fixture vocabulary so these test the same API
/// contract, not a parallel fake. The scaffolds the fixtures hang off are
/// re-declared here (not imported) because `widget_test.dart` keeps them
/// private to its own library.
final _roadmap = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: 'Earlier answer.',
);

/// The `AgentStreamJob` placeholder once the run has finished.
final _answered = conversationDetailPayload(
  title: 'Roadmap',
  streaming: false,
  reply: 'Rails 8.2 is out.',
);

/// The same thread mid-run: an empty streaming placeholder.
final _pending = conversationDetailPayload(title: 'Roadmap');

/// Just past the 1200 ms interval `ChatScreen` polls on.
const _pollTick = Duration(milliseconds: 1300);

/// A getter, not a `final`: FakeTransport drains the queues it is given.
/// Re-declared locally - the original lives private in `widget_test.dart`.
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
/// A store the tests own: no platform channels, and the choice is visibly
/// "written" so persistence can be asserted against the store itself.
class FakeThemeStore implements ThemeStore {
  ThemeMode? saved;

  @override
  Future<ThemeMode?> load() async => saved;

  @override
  Future<void> save(ThemeMode mode) async => saved = mode;
}

Widget appFor(HttpTransport transport) => ShamsApp(
  api: ShamsApi(baseUrl: 'http://localhost:3001', transport: transport),
);

/// Threads the chosen store into the app, so a theme switch can be asserted
/// both on screen and against the store.
Widget appWithTheme(ThemeStore store) => ShamsApp(
  api: ShamsApi(
    baseUrl: 'http://localhost:3001',
    transport: FakeTransport({...signedInRoutes}),
  ),
  themeStore: store,
);

Future<void> signInOf(WidgetTester tester) async {
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

Future<void> openRoadmap(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await signInOf(tester);
  await tester.tap(find.text('Roadmap'));
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------------------ theme switch
  testWidgets('the theme selector switches to dark and persists the choice', (
    tester,
  ) async {
    final store = FakeThemeStore();
    await tester.pumpWidget(appWithTheme(store));
    await tester.pumpAndSettle();

    // Login screen first: the selector is header-mounted there too.
    await tester.tap(find.byIcon(Icons.contrast));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();

    // The page background is now the spec's dark token...
    final context = tester.element(find.byType(Scaffold).first);
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      ShamsPalette.darkBackground,
    );
    // ...and the choice reached the store, so it will survive a relaunch.
    expect(store.saved, ThemeMode.dark);
  });

  testWidgets('the selector can pin light mode, overriding the OS choice', (
    tester,
  ) async {
    final store = FakeThemeStore();
    await tester.pumpWidget(appWithTheme(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.contrast));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      ShamsPalette.lightBackground,
    );
    expect(store.saved, ThemeMode.light);
  });

  // ------------------------------------------------------- welcome + cards
  testWidgets(
    'the first-use surface appears without conversations, and a prompt card '
    'starts a thread carrying the prompt',
    (tester) async {
      final transport = FakeTransport({
        // Startup (401), first load after sign-in ([]), and the refetch after
        // the new thread was created - `_chatWithAgent` refreshes the list.
        'GET /api/v1/conversations': [
          json(401, '{"error":"Please sign in to continue."}'),
          json(200, '[]'),
          json(200, '[]'),
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
        'POST /api/v1/conversations': [json(201, createdConversationPayload)],
        'GET /api/v1/conversations/$conversationId': [
          json(200, emptyConversationDetailPayload),
        ],
      });
      await tester.pumpWidget(appFor(transport));
      await tester.pumpAndSettle();
      await signInOf(tester);

      // The spec's welcome copy on an empty workspace.
      expect(find.text('How can I help you today?'), findsOneWidget);
      expect(
        find.textContaining(
          'Your intelligent workspace for thinking, creating and building.',
        ),
        findsOneWidget,
      );

      // A prompt card is the real "compose this" flow: pick the agent, then
      // the conversation is created *with the prompt as its first turn*.
      await tester.tap(find.text('Summarize this project'));
      await tester.pumpAndSettle();
      expect(find.text('Start a conversation'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pumpAndSettle();

      final create = transport.sent.firstWhere(
        (request) =>
            request.method == 'POST' &&
            request.uri.path == '/api/v1/conversations',
      );
      expect(
        create.body,
        '{"agent_id":"$agentId","content":"Summarize this project"}',
        reason: 'the prompt becomes the first turn via the real endpoint',
      );
      // The new (empty) thread is open in front of the composer.
      expect(find.text('Message shams ai…'), findsOneWidget);
    },
  );

  // --------------------------------------------------------- desktop Enter
  testWidgets('desktop Enter submits the composer; Shift+Enter keeps editing', (
    tester,
  ) async {
    final transport = FakeTransport({
      ...signedInRoutes,
      'POST /api/v1/conversations/$conversationId/messages': [
        json(201, messageCreatedPayload),
      ],
      // Same three-read lifecycle the send-button test uses.
      'GET /api/v1/conversations/$conversationId': [
        json(200, _roadmap),
        json(200, _pending),
        json(200, _answered),
      ],
    });
    await tester.pumpWidget(appFor(transport));
    await openRoadmap(tester);

    await tester.enterText(find.byType(TextField), 'Rails 8.2?');

    // Enter posts the turn through the same flow the send button taps.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();

    expect(
      transport.sent
          .lastWhere(
            (request) =>
                request.method == 'POST' &&
                request.uri.path.endsWith('/messages'),
          )
          .body,
      '{"content":"Rails 8.2?"}',
      reason: 'Enter submits exactly what was typed',
    );
    expect(find.textContaining('Agent is working'), findsOneWidget);

    // The reply lands through the ordinary polling lifecycle.
    await tester.pump(_pollTick);
    await tester.pump();
    expect(find.text('Rails 8.2 is out.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).enabled,
      isTrue,
      reason: 'the composer unlocks once the reply is in',
    );

    // Shift+Enter must never post: hold shift, tap Enter - the field keeps
    // editing and no second turn is created.
    final posted =
        transport.sent
            .where(
              (request) =>
                  request.method == 'POST' &&
                  request.uri.path.endsWith('/messages'),
            )
            .length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(
      transport.sent
          .where(
            (request) =>
                request.method == 'POST' &&
                request.uri.path.endsWith('/messages'),
          )
          .length,
      posted,
      reason: 'Shift+Enter is a newline, not a turn',
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  });

  // ------------------------------------------------------------ copy response
  testWidgets(
    "the assistant turn's copy action puts the source on the clipboard",
    (tester) async {
      // In tests the platform clipboard does not exist; back
      // `SystemChannels.platform` with this in-memory map.
      String? clipboardText;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            final arguments = (call.arguments as Map?)?.cast<String, Object?>();
            clipboardText = arguments?['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return {'text': clipboardText};
          default:
            return null;
        }
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final transport = FakeTransport({
        ...signedInRoutes,
        'GET /api/v1/conversations/$conversationId': [json(200, _roadmap)],
      });
      await tester.pumpWidget(appFor(transport));
      await openRoadmap(tester);

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();
      await tester.pump();

      // The flash to a checkmark confirms the action happened...
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(clipboardText, 'Earlier answer.');

      // ...and the flash is a one-shot: past its 1400 ms lifetime the control
      // (and its pending timer) is back to the resting icon.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.check), findsNothing);
    },
  );

  // ---------------------------------------------------------------- drawer
  testWidgets('the phone drawer opens from the app bar and offers the lists', (
    tester,
  ) async {
    final transport = FakeTransport(signedInRoutes);
    await tester.pumpWidget(appFor(transport));
    await tester.pumpAndSettle();
    await signInOf(tester);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    // The drawer carries the same sections the home list shows (both are in
    // the tree now).
    expect(find.text('CONVERSATIONS'), findsNWidgets(2));
    expect(find.text('AGENTS'), findsNWidgets(2));
    expect(find.text('Roadmap'), findsNWidgets(2));

    // Close via the drawer's close icon; the home list is unchanged behind it.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('CONVERSATIONS'), findsOneWidget);
  });

  // ------------------------------------------------------------ desktop shell
  testWidgets(
    'at desktop width a collapsible sidebar plus content pane '
    'carry the same lists',
    (tester) async {
      tester.view.devicePixelRatio = 3.0;
      tester.view.physicalSize = const Size(1200, 900) * 3.0;
      addTearDown(tester.view.reset);

      final transport = FakeTransport(signedInRoutes);
      await tester.pumpWidget(appFor(transport));
      await tester.pumpAndSettle();
      await signInOf(tester);

      // Sidebar and main pane both render the sections...
      expect(find.text('CONVERSATIONS'), findsNWidgets(2));
      // ...and the only New chat affordance on this shell is the sidebar's.
      expect(find.text('New chat'), findsOneWidget);

      // Collapse: the labelled button is replaced by the icon-only one, and
      // the content pane still shows the welcome hero.
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();

      expect(find.text('New chat'), findsNothing);
      expect(find.byIcon(Icons.add_comment_outlined), findsOneWidget);
      expect(find.textContaining('How can I help'), findsOneWidget);
      expect(find.text('CONVERSATIONS'), findsOneWidget);
    },
  );
}
