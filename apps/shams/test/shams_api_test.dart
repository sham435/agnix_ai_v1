import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/models.dart';
import 'package:shams_app/src/api/shams_api.dart';

import 'fake_transport.dart';

void main() {
  group('ShamsApi', () {
    test('normalises the base URL and keeps the origin readable', () {
      final api = ShamsApi(
        baseUrl: 'https://app.shams.ai///',
        transport: FakeTransport(<String, List<TransportResponse>>{}),
      );
      expect(api.origin, 'https://app.shams.ai');
    });

    test('sends Accept/Content-Type and the CSRF token it fetched', () async {
      final transport = FakeTransport({
        'GET /api/v1/csrf': [json(200, '{"token":"tok-123"}')],
        'POST /api/v1/sessions': [json(200, '{"user":{"id":1}}')],
      });
      final api = apiWith(transport);

      await api.fetchCsrfToken();
      await api.login('dev@shams.ai', 'secret');

      final post = transport.sent.last;
      expect(post.headers['Accept'], 'application/json');
      expect(post.headers['Content-Type'], 'application/json');
      expect(post.headers['X-CSRF-Token'], 'tok-123');
      expect(post.body, '{"email":"dev@shams.ai","password":"secret"}');
      expect(post.uri.origin, 'http://localhost:3001');
    });

    test('replays both session cookies set by a successful login', () async {
      // Rails sets the stateless session cookie *and* a signed `user_id`
      // cookie whose Expires value contains a comma - the pair must survive
      // parsing as two cookies, not one mangled value.
      final transport = FakeTransport({
        'GET /api/v1/csrf': [json(200, '{"token":"tok"}')],
        'POST /api/v1/sessions': [
          json(
            200,
            '{"user":{"id":1}}',
            headers: <String, List<String>>{
              'set-cookie': const <String>[
                '_shams_session=abc123; path=/; HttpOnly; SameSite=Lax',
                'user_id=BAh7--sig; expires=Thu, 29 Oct 2036 10:00:00 GMT; '
                    'path=/; HttpOnly; SameSite=Lax',
              ],
            },
          ),
        ],
        'GET /api/v1/agents': [json(200, agentPayload)],
      });
      final api = apiWith(transport);

      await api.fetchCsrfToken();
      await api.login('dev@shams.ai', 'secret');
      final agents = await api.listAgents();

      expect(agents, hasLength(1));
      expect(agents.single.name, 'Shams AI');
      expect(agents.single.subtitle, 'openai · bonsai-227b');

      final cookie = transport.sent.last.headers['Cookie'] ?? '';
      expect(cookie, contains('_shams_session=abc123'));
      expect(cookie, contains('user_id=BAh7--sig'));
    });

    test('surfaces the server error message on 401', () async {
      final api = apiWith(FakeTransport(unauthenticatedRoutes));

      await expectLater(
        api.listAgents(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.unauthorized, 'unauthorized', true)
              .having(
                (e) => e.message,
                'message',
                'Please sign in to continue.',
              ),
        ),
      );
    });

    test('picks up a CSRF token rotated in a response header', () async {
      final transport = FakeTransport({
        'GET /api/v1/conversations': [
          json(
            200,
            conversationPayload,
            headers: <String, List<String>>{
              'x-csrf-token': const <String>['rotated-token'],
            },
          ),
        ],
        'DELETE /api/v1/sessions': [json(200, '{"message":"Signed out."}')],
      });
      final api = apiWith(transport);

      await api.listConversations();
      await api.logout();

      expect(transport.sent.last.headers['X-CSRF-Token'], 'rotated-token');
    });

    test('parses the embedded agent of a conversation', () async {
      final transport = FakeTransport({
        'GET /api/v1/conversations': [json(200, conversationPayload)],
      });
      final conversations = await apiWith(transport).listConversations();

      expect(conversations.single.title, 'Roadmap');
      expect(conversations.single.agent?.name, 'Shams AI');
      expect(conversations.single.updatedAt, isA<DateTime>());
      expect(conversations.single.displayName, 'Roadmap');
    });

    test('finds the agent on the messages of a single conversation', () async {
      // The two endpoints disagree about where the agent lives: the list uses
      // `include: :agent`, the detail read uses
      // `include: { messages: { include: :agent } }`. A client that only looked
      // at `conversation.agent` would open a thread with no model line.
      final transport = FakeTransport({
        'GET /api/v1/conversations/$conversationId': [
          json(200, conversationDetailPayload(streaming: false, reply: 'yes')),
        ],
      });
      final conversation = await apiWith(
        transport,
      ).conversation(conversationId);

      expect(conversation.agent, isNull);
      expect(conversation.effectiveAgent?.name, 'Shams AI');
      expect(conversation.effectiveAgent?.subtitle, 'openai · bonsai-227b');
      expect(conversation.messages.last.agent?.id, agentId);
    });

    test('falls back to the agent name when a conversation has no title', () {
      final conversation = Conversation.fromJson({
        'id': conversationId,
        'status': 'active',
        'agent': {'id': agentId, 'name': 'Shams AI'},
      });
      expect(conversation.displayName, 'Shams AI');
      expect(
        Conversation.fromJson(const <String, dynamic>{
          'id': conversationId,
        }).displayName,
        'Untitled conversation',
      );
    });

    test('keeps UUID ids as strings', () async {
      // The API's primary keys are UUIDs. Reading them as ints turned every id
      // into 0, which is how a client silently builds URLs that point nowhere.
      final transport = FakeTransport({
        'GET /api/v1/conversations': [json(200, conversationPayload)],
      });
      final conversation = (await apiWith(
        transport,
      ).listConversations()).single;

      expect(conversation.id, conversationId);
      expect(conversation.agentId, agentId);
      expect(conversation.agent?.id, agentId);
    });

    test('explains a non-JSON body by naming the endpoint', () async {
      final transport = FakeTransport({
        'GET /api/v1/agents': [
          TransportResponse(
            statusCode: 200,
            headers: const <String, List<String>>{
              'content-type': <String>['text/html'],
            },
            body: '<!DOCTYPE html><html>',
          ),
        ],
      });

      await expectLater(
        apiWith(transport).listAgents(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            contains('/api/v1/agents'),
          ),
        ),
      );
    });

    test('forgives a failing CSRF lookup', () async {
      final transport = FakeTransport({
        'GET /api/v1/csrf': [json(404, '<h1>Not Found</h1>')],
      });

      await expectLater(apiWith(transport).fetchCsrfToken(), completes);
    });

    group('chat', () {
      test(
        'createConversation posts the agent and omits blank content',
        () async {
          final transport = FakeTransport({
            'POST /api/v1/conversations': [
              json(201, createdConversationPayload),
            ],
          });
          final created = await apiWith(
            transport,
          ).createConversation(agentId: agentId);

          final request = transport.sent.single;
          expect(request.method, 'POST');
          expect(request.uri.path, '/api/v1/conversations');
          expect(request.body, '{"agent_id":"$agentId"}');
          expect(created.id, conversationId);
          expect(created.messages, isEmpty);
        },
      );

      test(
        'createConversation sends content when the caller has a first turn',
        () async {
          final transport = FakeTransport({
            'POST /api/v1/conversations': [
              json(201, createdConversationPayload),
            ],
          });

          await apiWith(
            transport,
          ).createConversation(agentId: agentId, content: 'hi there');

          expect(
            transport.sent.single.body,
            '{"agent_id":"$agentId","content":"hi there"}',
          );
        },
      );

      test(
        'conversation(id) reports whether a reply is still arriving',
        () async {
          final api = apiWith(
            FakeTransport({
              'GET /api/v1/conversations/$conversationId': [
                json(200, conversationDetailPayload(streaming: true)),
              ],
            }),
          );
          final pending = await api.conversation(conversationId);

          expect(pending.messages, hasLength(2));
          expect(pending.messages.first.role, 'user');
          expect(pending.messages.last.isAssistant, isTrue);
          expect(pending.messages.last.isStreaming, isTrue);
          expect(pending.messages.last.content, isEmpty);
          expect(pending.awaitingReply, isTrue);
        },
      );

      test(
        'awaitingReply clears once the job has written the answer',
        () async {
          final api = apiWith(
            FakeTransport({
              'GET /api/v1/conversations/$conversationId': [
                json(
                  200,
                  conversationDetailPayload(
                    streaming: false,
                    reply: 'Rails 8.2 is out.',
                  ),
                ),
              ],
            }),
          );
          final done = await api.conversation(conversationId);

          expect(done.awaitingReply, isFalse);
          expect(done.messages.last.content, 'Rails 8.2 is out.');
        },
      );

      test(
        'sendMessage posts the turn to the nested route and returns the row',
        () async {
          final transport = FakeTransport({
            'POST /api/v1/conversations/$conversationId/messages': [
              json(201, messageCreatedPayload),
            ],
          });
          final sent = await apiWith(
            transport,
          ).sendMessage(conversationId, 'hi');

          expect(
            transport.sent.single.uri.path,
            '/api/v1/conversations/$conversationId/messages',
          );
          expect(transport.sent.single.body, '{"content":"hi"}');
          expect(sent.id, userMessageId);
          expect(sent.isUser, isTrue);
          expect(sent.conversationId, conversationId);
        },
      );

      test('explains a response that is not a JSON object', () async {
        final api = apiWith(
          FakeTransport({
            'POST /api/v1/conversations': [json(201, '[]')],
          }),
        );

        await expectLater(
          api.createConversation(agentId: agentId),
          throwsA(
            isA<ApiException>().having(
              (e) => e.message,
              'message',
              contains('/api/v1/conversations'),
            ),
          ),
        );
      });
    });
  });
}
