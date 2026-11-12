import 'package:flutter_test/flutter_test.dart';
import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/models.dart';
import 'package:shams_app/src/api/shams_api.dart';

import 'fake_transport.dart';

/// Runs a call the server is expected to refuse, and hands back the refusal.
///
/// A sign-in that *succeeds* here would be the bug: it would mean the client
/// got in without the second factor the account asks for.
Future<ApiException> refused(Future<void> Function() call) async {
  try {
    await call();
  } on ApiException catch (error) {
    return error;
  }
  throw StateError('expected the request to be refused');
}

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

    group('security panel', () {
      test('reads the snapshot the panel is drawn from', () async {
        final transport = FakeTransport({
          'GET /api/v1/security': [
            json(
              200,
              securityPayload(
                devices: [
                  deviceJson(currentDeviceId, 'Chrome · macOS', current: true),
                  deviceJson(otherDeviceId, 'Safari · iPhone'),
                ],
              ),
            ),
          ],
        });
        final panel = await apiWith(transport).security();

        expect(transport.sent.single.uri.path, '/api/v1/security');
        expect(panel.twoFactorEnabled, isFalse);
        expect(panel.recoveryCodesLeft, 0);
        expect(panel.phone.number, '');
        expect(panel.phone.verified, isFalse);
        expect(panel.devices.map((d) => d.label), [
          'Chrome · macOS',
          'Safari · iPhone',
        ]);
        expect(
          panel.devices.map((d) => d.isCurrent),
          [true, false],
          reason: 'exactly the row this request came from is "this device"',
        );
        expect(panel.usage.plan, 'member');
        expect(panel.usage.cap, 20000);
        expect(panel.usage.remaining, 18800);
      });

      test('reads an unmetered plan as no ceiling, not as none left', () async {
        final panel = await apiWith(
          FakeTransport({
            'GET /api/v1/security': [
              json(200, securityPayload(meteredUsage: false)),
            ],
          }),
        ).security();

        expect(panel.usage.metered, isFalse);
        expect(panel.usage.cap, isNull);
        expect(panel.usage.remaining, isNull);
        expect(
          panel.usage.fractionUsed,
          isNull,
          reason: 'a bar drawn from a null cap would read as 0 % used',
        );
      });

      test('treats a missing or malformed flag as protection off', () async {
        // The defensive default for `is_active` on an agent is "live"; for
        // whether an account is protected, the only safe default is the one
        // that does not claim a guard the server never confirmed.
        final panel = await apiWith(
          FakeTransport({
            'GET /api/v1/security': [
              json(200, '{"two_factor":{"enabled":null}}'),
            ],
          }),
        ).security();

        expect(panel.twoFactorEnabled, isFalse);
        expect(panel.devices, isEmpty);
      });

      test('sends the code the user typed for a second factor', () async {
        final transport = FakeTransport({
          'POST /api/v1/sessions': [json(200, '{"user":{"id":1}}')],
        });

        await apiWith(
          transport,
        ).login('dev@shams.ai', 'secret', code: '429117');

        expect(
          transport.sent.single.body,
          '{"email":"dev@shams.ai","password":"secret","code":"429117"}',
        );
      });

      test(
        'reports that a sign-in needs a code, and that the code was wrong',
        () async {
          final transport = FakeTransport({
            'POST /api/v1/sessions': [
              json(
                401,
                '{"error":"Two-factor authentication required.",'
                '"two_factor_required":true}',
              ),
              json(
                403,
                '{"error":"Invalid two-factor code.",'
                '"two_factor_required":true}',
              ),
              json(
                429,
                '{"error":"Too many attempts. Sign-ins are paused for '
                '15 minutes.","two_factor_required":true}',
              ),
            ],
          });
          final api = apiWith(transport);

          for (var i = 0; i < 3; i++) {
            final error = await refused(
              () => api.login('dev@shams.ai', 'secret', code: '111111'),
            );
            expect(error.twoFactorRequired, isTrue, reason: error.message);
          }
          expect(transport.sent.map((r) => r.body).toSet(), {
            '{"email":"dev@shams.ai","password":"secret","code":"111111"}',
          });
        },
      );

      test('never calls a plain bad password a request for a code', () async {
        final api = apiWith(
          FakeTransport({
            'POST /api/v1/sessions': [
              json(401, '{"error":"Invalid email or password."}'),
            ],
          }),
        );

        await expectLater(
          api.login('dev@shams.ai', 'wrong'),
          throwsA(
            isA<ApiException>()
                .having(
                  (e) => e.twoFactorRequired,
                  'twoFactorRequired',
                  isFalse,
                )
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
      });

      test(
        'starts an enrollment and shows the key only from that response',
        () async {
          final transport = FakeTransport({
            'POST /api/v1/security/two_factor': [
              json(200, securityPayload(enrollment: pendingEnrollmentJson)),
            ],
          });
          final panel = await apiWith(transport).startTwoFactor();

          expect(transport.sent.single.body, '{}');
          expect(panel.twoFactorEnabled, isFalse);
          expect(panel.enrollment?.secret, pendingSecret);
          expect(
            panel.enrollment?.provisioningUri,
            startsWith('otpauth://totp/'),
          );
          expect(panel.enrollment?.expiresInSeconds, 600);
        },
      );

      test(
        'activates on a confirmed code and returns the backup codes once',
        () async {
          final codes = ['2K4QX7ZR9T', 'ABCD2EFGHJ'];
          final panel = await apiWith(
            FakeTransport({
              'POST /api/v1/security/two_factor/confirm': [
                json(
                  200,
                  securityPayload(
                    twoFactorEnabled: true,
                    recoveryCodesLeft: codes.length,
                    recoveryCodes: codes,
                  ),
                ),
              ],
            }),
          ).confirmTwoFactor('429117');

          expect(panel.twoFactorEnabled, isTrue);
          expect(panel.recoveryCodes, codes);
        },
      );

      test('turns two-factor off only with the password', () async {
        final transport = FakeTransport({
          'DELETE /api/v1/security/two_factor': [json(200, securityPayload())],
        });
        await apiWith(transport).disableTwoFactor('secret');

        expect(transport.sent.single.method, 'DELETE');
        expect(transport.sent.single.body, '{"password":"secret"}');
      });

      test('asks the server for the code instead of inventing one', () async {
        final transport = FakeTransport({
          'DELETE /api/v1/security/two_factor': [
            json(422, '{"error":"That password is not right."}'),
          ],
        });

        await expectLater(
          apiWith(transport).disableTwoFactor('nope'),
          throwsA(
            isA<ApiException>()
                .having(
                  (e) => e.message,
                  'message',
                  'That password is not right.',
                )
                .having((e) => e.statusCode, 'statusCode', 422),
          ),
        );
      });

      test('regenerates backup codes with the password', () async {
        final transport = FakeTransport({
          'POST /api/v1/security/recovery_codes': [
            json(
              200,
              securityPayload(
                twoFactorEnabled: true,
                recoveryCodesLeft: 10,
                recoveryCodes: ['2K4QX7ZR9T'],
              ),
            ),
          ],
        });
        final panel = await apiWith(
          transport,
        ).regenerateRecoveryCodes('secret');

        expect(transport.sent.single.body, '{"password":"secret"}');
        expect(panel.recoveryCodes, ['2K4QX7ZR9T']);
      });

      test('a phone cooldown keeps the server message and the wait', () async {
        // A refusal sends no snapshot, only `status`/`message`/`retry_in`, so
        // the client must surface those words rather than its own summary of
        // the status code.
        final refusal = await refused(
          () => apiWith(
            FakeTransport({
              'POST /api/v1/security/phone': [
                json(
                  429,
                  '{"status":"cooldown",'
                  '"message":"That code is still valid. Wait before asking '
                  'for another.","retry_in":42}',
                ),
              ],
            }),
          ).requestPhoneCode('+94771234567'),
        );

        expect(refusal.statusCode, 429);
        expect(
          refusal.message,
          'That code is still valid. Wait before asking for another.',
        );
        expect(refusal.retryInSeconds, 42);
        expect(
          refusal.twoFactorRequired,
          isFalse,
          reason: 'a cooldown is not a request for a code',
        );
      });

      test(
        'a sent code answers with the snapshot and the resend window',
        () async {
          final panel = await apiWith(
            FakeTransport({
              'POST /api/v1/security/phone': [
                json(
                  200,
                  securityPayload(
                    phone: '+94771234567',
                    status: 'sent',
                    message: 'We sent a 6-digit code to +94771234567.',
                    retryIn: 30,
                    code: '429117',
                  ),
                ),
              ],
            }),
          ).requestPhoneCode('+94771234567');

          expect(panel.outcome, 'sent');
          expect(panel.retryInSeconds, 30);
          expect(panel.phone.verified, isFalse);
          expect(
            panel.developmentPhoneCode,
            '429117',
            reason: 'only a server with no SMS gateway sends this',
          );
        },
      );

      test('verifies the number from the texted code', () async {
        final transport = FakeTransport({
          'POST /api/v1/security/phone/confirm': [
            json(
              200,
              securityPayload(
                phone: '+94771234567',
                phoneVerified: true,
                status: 'verified',
                message: 'Number verified.',
              ),
            ),
          ],
        });
        final panel = await apiWith(transport).confirmPhoneCode('429117');

        expect(transport.sent.single.body, '{"code":"429117"}');
        expect(panel.phone.verified, isTrue);
        expect(panel.phone.number, '+94771234567');
        expect(panel.developmentPhoneCode, isNull);
      });

      test('revokes one device by id', () async {
        final transport = FakeTransport({
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
        });
        final panel = await apiWith(transport).revokeDevice(otherDeviceId);

        expect(transport.sent.single.method, 'DELETE');
        expect(panel.devices, hasLength(1));
        expect(panel.message, 'Safari · iPhone was signed out.');
      });

      test('knows a revoke ended this session', () async {
        // The real answer for one's own row is a message and nothing else; the
        // screen must read `signed_out` from it rather than a snapshot.
        final panel = await apiWith(
          FakeTransport({
            'DELETE /api/v1/security/devices/$currentDeviceId': [
              json(
                200,
                '{"message":"This device was signed out.",'
                '"signed_out":true}',
              ),
            ],
          }),
        ).revokeDevice(currentDeviceId);

        expect(panel.signedOut, isTrue);
        expect(
          panel.devices,
          isEmpty,
          reason: 'no state was sent, so none may be claimed',
        );
        expect(panel.twoFactorEnabled, isFalse);
      });

      test('signs out everywhere on the collection route', () async {
        final transport = FakeTransport({
          'DELETE /api/v1/security/devices': [
            json(
              200,
              '{"message":"Signed out everywhere.",'
              '"signed_out":true}',
            ),
          ],
        });

        await expectLater(apiWith(transport).signOutEverywhere(), completes);
        expect(transport.sent.single.uri.path, '/api/v1/security/devices');
      });

      test('answers 404 for a device that is not this account\'s', () async {
        final api = apiWith(
          FakeTransport({
            'DELETE /api/v1/security/devices/$otherDeviceId': [
              json(404, '{"error":"That device is not signed in."}'),
            ],
          }),
        );

        await expectLater(
          api.revokeDevice(otherDeviceId),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 404)
                .having(
                  (e) => e.message,
                  'message',
                  'That device is not signed in.',
                ),
          ),
        );
      });
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
        'a failed turn keeps the cause the server recorded in metadata',
        () async {
          final api = apiWith(
            FakeTransport({
              'GET /api/v1/conversations/$conversationId': [
                json(
                  200,
                  conversationDetailPayload(
                    streaming: false,
                    reply: genericFailure,
                    error: providerErrorDetail,
                  ),
                ),
              ],
            }),
          );
          final failed = await api.conversation(conversationId);

          expect(failed.awaitingReply, isFalse);
          expect(failed.messages.last.content, genericFailure);
          expect(
            failed.messages.last.errorDetail,
            contains('x-api-key header is required'),
            reason:
                'the generic sentence alone is what made a failure '
                'unreadable in the thread',
          );
          expect(
            failed.messages.first.errorDetail,
            isNull,
            reason: 'a turn that did not fail reports no cause',
          );
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
