import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/main.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';

import 'fake_transport.dart';

/// The Coding Workspace screen, opened the way a user opens it: signed in, from
/// a conversation.
///
/// What this screen may say is bounded by the API's answers. A sandbox that was
/// never created is named as such, an unreachable manager is reported instead
/// of drawn as an empty project, a refusal is repeated in the manager's own
/// words, and the only preview link shown is the gateway route the server
/// issued. Nothing here is filled in by the client.
final _answeredThread = conversationDetailPayload(
  streaming: false,
  reply: 'Earlier answer.',
);

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
      'POST /api/v1/sessions': [
        json(
          200,
          '{"user":{"id":1,"name":"Dev","email":"dev@shams.ai"}}',
          headers: <String, List<String>>{
            'set-cookie': <String>['_shams_session=abc123; path=/; HttpOnly'],
          },
        ),
      ],
      'GET /api/v1/conversations/$conversationId': [
        json(200, _answeredThread),
      ],
    };

/// The screen as the app reaches it: sign in, open the thread, tap the header's
/// workspace entry. Every route the walk needs is on [transport]'s table, so a
/// missing fixture fails loudly instead of silently showing a spinner.
Future<FakeTransport> _openWorkspace(
  WidgetTester tester,
  Map<String, List<TransportResponse>> workspaceRoutes,
) async {
  final transport = FakeTransport({..._loginRoutes, ...workspaceRoutes});
  await tester.pumpWidget(
    ShamsApp(
      api: ShamsApi(baseUrl: 'http://localhost:3001/', transport: transport),
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(
    find.widgetWithText(TextField, 'Email'),
    'dev@shams.ai',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Password'),
    'password1234',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Roadmap'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.code_outlined));
  await tester.pumpAndSettle();
  return transport;
}

/// The five sections, so a test says which one it is about.
Future<void> _showTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

/// The snapshot the screen draws by default: a ready sandbox, the manager
/// answering, two files and one recorded command.
String get _snapshot => workspaceDetailPayload(runs: [workspaceRunJson()]);

void main() {
  group('workspace screen', () {
    testWidgets('shows the sandbox this conversation ran in', (tester) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
        },
      );

      expect(find.text('Flask landing page'), findsWidgets);
      // The container's state is the manager's answer, not the row's column.
      expect(find.text('Running'), findsOneWidget);
      expect(
        find.text('Runtime python3 · shams-ws-$workspaceId'),
        findsOneWidget,
      );
      expect(find.text('app.py'), findsOneWidget);
      expect(find.text('338 B'), findsOneWidget);
    });

    testWidgets('names a conversation that has never run code', (
      tester,
    ) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [
            json(200, workspacesListPayload(empty: true)),
          ],
        },
      );

      expect(find.text('This conversation has not run any code yet.'),
          findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('reads a file when it is tapped', (tester) async {
      final transport = await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
          'GET /api/v1/workspaces/$workspaceId/file': [
            json(200, workspaceFilePayload()),
          ],
        },
      );

      await tester.tap(find.text('app.py'));
      await tester.pumpAndSettle();

      expect(find.textContaining('app = Flask(__name__)'), findsOneWidget);
      expect(
        transport.sent.last.uri.query,
        'path=${Uri.encodeComponent('app.py')}',
      );

      await tester.tap(find.byIcon(Icons.folder_outlined));
      await tester.pumpAndSettle();
      expect(find.text('templates/index.html'), findsOneWidget);
    });

    testWidgets('runs a typed line and shows the container\'s verdict', (
      tester,
    ) async {
      final transport = await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
          'POST /api/v1/workspaces/$workspaceId/exec': [
            json(200, workspaceExecPayload(stdout: 'Python 3.12.7')),
          ],
        },
      );
      await _showTab(tester, 'Terminal');

      await tester.enterText(
        find.widgetWithText(TextField, 'Command'),
        'python3 -V',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Run'));
      await tester.pumpAndSettle();

      // One line, sent as one field: the server splits it, and no shell runs.
      final exec = transport.sent.lastWhere(
        (request) => request.method == 'POST',
      );
      expect(exec.uri.path, '/api/v1/workspaces/$workspaceId/exec');
      expect(exec.body, '{"command":"python3 -V"}');
      expect(find.text('Exit 0 in 0.1s.'), findsOneWidget);
      expect(find.textContaining('Python 3.12.7'), findsWidgets);
    });

    testWidgets('repeats the manager\'s refusal in its own words', (
      tester,
    ) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
          'POST /api/v1/workspaces/$workspaceId/exec': [
            workspaceRefusal(
              503,
              'execution_unavailable',
              'workspace manager is not answering',
            ),
          ],
        },
      );
      await _showTab(tester, 'Terminal');

      await tester.enterText(
        find.widgetWithText(TextField, 'Command'),
        'python3 -V',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Run'));
      await tester.pumpAndSettle();

      // No invented "command failed", and no output presented as if it ran.
      expect(find.text('workspace manager is not answering'), findsWidgets);
      expect(
        find.textContaining('execution_unavailable'),
        findsWidgets,
      );
      expect(find.text('Exit 0 in 0.1s.'), findsNothing);
    });

    testWidgets('runs the provider\'s test command', (tester) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
          'POST /api/v1/workspaces/$workspaceId/tests': [
            json(200, workspaceTestsPayload()),
          ],
        },
      );
      await _showTab(tester, 'Tests');

      await tester.tap(find.widgetWithText(FilledButton, 'Run tests'));
      await tester.pumpAndSettle();

      expect(find.text('2 passed in 1.14s'), findsWidgets);
    });

    testWidgets('shows only the preview link the server issued', (
      tester,
    ) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [
            json(
              200,
              workspaceDetailPayload(
                previewLink: true,
                runs: [workspaceRunJson()],
              ),
            ),
          ],
        },
      );
      await _showTab(tester, 'Preview');

      // The gateway route, made absolute with this installation's origin, plus
      // the lifetime the server said it has.
      expect(
        find.textContaining(
          'http://localhost:3001/workspaces/$workspaceId/preview/8000'
          '?session=$previewToken',
        ),
        findsOneWidget,
      );
      expect(find.text('Port 8000 · 10 min left'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Stop preview'),
        findsOneWidget,
      );
    });

    testWidgets('asks before stopping, and does not stop when told to keep', (
      tester,
    ) async {
      final transport = await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [json(200, _snapshot)],
        },
      );

      await tester.tap(find.byIcon(Icons.stop_circle_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Stop "Flask landing page"?'), findsOneWidget);

      await tester.tap(find.text('Keep it running'));
      await tester.pumpAndSettle();

      expect(
        transport.sent.where((request) => request.method == 'DELETE'),
        isEmpty,
      );
    });

    testWidgets('a confirmed stop re-reads the workspace as stopped', (
      tester,
    ) async {
      final transport = await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [
            json(200, workspacesListPayload()),
            json(200, workspacesListPayload(state: 'destroyed')),
          ],
          'GET /api/v1/workspaces/$workspaceId': [
            json(200, _snapshot),
            json(
              200,
              workspaceDetailPayload(
                state: 'destroyed',
                runtimeStatus: 'absent',
                files: '[]',
              ),
            ),
          ],
          'DELETE /api/v1/workspaces/$workspaceId': [
            json(200, workspaceDestroyPayload()),
          ],
        },
      );

      await tester.tap(find.byIcon(Icons.stop_circle_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Stop workspace'));
      await tester.pumpAndSettle();

      expect(
        transport.sent.where((request) => request.method == 'DELETE').length,
        1,
      );
      expect(find.text('Stopped'), findsOneWidget);
      // A stopped sandbox is still readable, and says why it cannot run code.
      expect(
        find.textContaining('start a new turn in the chat'),
        findsOneWidget,
      );
      // The affordance to stop it again is gone.
      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    });

    testWidgets('reports an unreachable manager instead of an empty project', (
      tester,
    ) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [
            json(
              200,
              workspaceDetailPayload(
                statusError: 'workspace manager is not answering',
                files: 'null',
                filesError: 'workspace manager is not answering',
              ),
            ),
          ],
        },
      );

      expect(find.text('Manager unavailable'), findsOneWidget);
      expect(
        find.text(
          'The files could not be listed: workspace manager is not answering',
        ),
        findsOneWidget,
      );
    });

    testWidgets('lists what has run in the sandbox', (tester) async {
      await _openWorkspace(
        tester,
        {
          'GET /api/v1/workspaces': [json(200, workspacesListPayload())],
          'GET /api/v1/workspaces/$workspaceId': [
            json(
              200,
              workspaceDetailPayload(
                runs: [
                  workspaceRunJson(),
                  workspaceRunJson(
                    id: testRunId,
                    kind: 'test',
                    argv: const ['python3', '-m', 'pytest', '-q'],
                    stdout: '2 passed in 1.14s',
                  ),
                ],
              ),
            ),
          ],
        },
      );
      await _showTab(tester, 'Logs');

      expect(find.text('python3 -V'), findsWidgets);
      expect(find.text('python3 -m pytest -q'), findsOneWidget);
      expect(find.text('0.1s'), findsWidgets);
    });
  });
}
