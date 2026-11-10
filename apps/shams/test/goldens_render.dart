import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';
import 'package:shams_app/src/theme/theme_controller.dart';

import 'fake_transport.dart';

/// Renders the redesigned surfaces to PNG goldens (run with
/// `flutter test --update-goldens test/goldens_render.dart`). These are
/// test-renderer pixels - the real Cocoa/Gradle runtime may differ in font
/// metrics - but layout, tokens and composition are exact.
///
/// One surface per test: each needs a fresh app scaffold, so the flows mirror
/// the proven helpers in `ui_spec_test.dart` rather than re-pumping apps.
class _Store implements ThemeStore {
  ThemeMode? saved;

  @override
  Future<ThemeMode?> load() async => saved;

  @override
  Future<void> save(ThemeMode mode) async => saved = mode;
}

Widget appFor(HttpTransport transport, {ThemeStore? themeStore}) => ShamsApp(
      api: ShamsApi(baseUrl: 'http://localhost:3001', transport: transport),
      themeStore: themeStore,
    );

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

/// The sign-in queues plus a thread whose answer carries markdown, so code
/// blocks render with their copy row.
Map<String, List<TransportResponse>> get markdownRoutes {
  final detail = conversationDetailPayload(
    title: 'Roadmap',
    streaming: false,
    reply: '**Design tokens** live in `app_theme.dart`.\n\n'
        '```dart\nconst brandGradient = LinearGradient(...);\n```\n',
  );
  return {
    ...signedInRoutes,
    'GET /api/v1/conversations/$conversationId': [json(200, detail)],
  };
}

/// Home routes with no threads: the spec's first-use welcome surface.
Map<String, List<TransportResponse>> get emptyHomeRoutes => {
      'GET /api/v1/conversations': [
        json(401, '{"error":"Please sign in to continue."}'),
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
      'DELETE /api/v1/sessions': [json(200, '{"message":"Signed out."}')],
    };

Future<void> signInOf(WidgetTester tester) async {
  await tester.pumpAndSettle();
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

/// Theme choice is pinned on the sign-in screen first - the selector is
/// header-mounted there, and this is the flow `ui_spec_test.dart` proves.
Future<void> moveToDark(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.contrast));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Dark').last);
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------- 01 home, dark, phone
  testWidgets('01 home dark', (tester) async {
    await tester.pumpWidget(appFor(FakeTransport(signedInRoutes)));
    // Theme is pinned at the DEFAULT test surface first - that is where the
    // proven (and only reliably hit-testable) popup flow lives; the surface
    // is resized afterwards purely for the capture.
    await moveToDark(tester);
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await signInOf(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/01_home_dark.png'),
    );
  });

  // ------------------------------------------------- 02 drawer, dark, phone
  testWidgets('02 drawer dark', (tester) async {
    await tester.pumpWidget(appFor(FakeTransport(signedInRoutes)));
    await moveToDark(tester);
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await signInOf(tester);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/02_drawer_dark.png'),
    );
  });

  // --------------------------------------- 03 thread with markdown, dark
  testWidgets('03 thread markdown dark', (tester) async {
    await tester.pumpWidget(appFor(FakeTransport(markdownRoutes)));
    await moveToDark(tester);
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();
    await signInOf(tester);
    await tester.tap(find.text('Roadmap').first);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/03_thread_markdown_dark.png'),
    );
  });

  // --------------------------------- 04 welcome surface, light, phone
  testWidgets('04 welcome light', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      appFor(FakeTransport(emptyHomeRoutes), themeStore: _Store()),
    );
    await signInOf(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/04_welcome_light.png'),
    );
  });

  // --------------------------------- 05 desktop shell expanded, light
  testWidgets('05 desktop light', (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      appFor(FakeTransport(emptyHomeRoutes), themeStore: _Store()),
    );
    await signInOf(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/05_desktop_light.png'),
    );
  });

  // ------------------------------- 06 desktop shell collapsed, light
  testWidgets('06 desktop collapsed light', (tester) async {
    tester.view.physicalSize = const Size(1280, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      appFor(FakeTransport(emptyHomeRoutes), themeStore: _Store()),
    );
    await signInOf(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens_redesign/06_desktop_collapsed_light.png'),
    );
  });
}
