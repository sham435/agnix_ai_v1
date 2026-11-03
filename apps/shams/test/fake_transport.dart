import 'dart:convert';
import 'dart:io';

import 'package:shams_app/src/api/http_transport.dart';
import 'package:shams_app/src/api/shams_api.dart';

/// A transport that answers from a scripted table instead of a network.
///
/// Routes are keyed `'METHOD /path'`. A route with one queued response repeats
/// it; a longer queue is consumed in order, which lets a test model "first 401,
/// then 200 after signing in".
class FakeTransport implements HttpTransport {
  FakeTransport(this.routes);

  final Map<String, List<TransportResponse>> routes;
  final List<TransportRequest> sent = <TransportRequest>[];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    sent.add(request);
    final key = '${request.method} ${request.uri.path}';
    final queue = routes[key];
    if (queue == null || queue.isEmpty) {
      throw ApiException('FakeTransport has no route for $key');
    }
    return queue.length == 1 ? queue.single : queue.removeAt(0);
  }

  @override
  void close() {}
}

/// A transport that behaves like a server that is not listening.
class UnreachableTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest request) async =>
      throw SocketException('Connection refused');

  @override
  void close() {}
}

TransportResponse json(
  int status,
  String body, {
  Map<String, List<String>> headers = const <String, List<String>>{},
}) => TransportResponse(
  statusCode: status,
  headers: {
    'content-type': const <String>['application/json; charset=utf-8'],
    ...headers,
  },
  body: body,
);

/// The server's primary keys are UUIDs (`create_table "agents", id: :uuid`),
/// so fixtures use them too rather than the integers the Expo types assumed.
const agentId = '9672f201-b166-4b51-8d27-1b803c37fc15';
const conversationId = '5e720437-b8ed-403c-994d-e5800855c6d0';
const userId = '2e98fc38-25f6-4161-a55f-cf39d720080f';
const userMessageId = '3e4670af-eb59-4dca-969d-a52b6725700d';
const assistantMessageId = '7c1f4f6e-2b41-4d1a-9f0c-1c2e5a7b8d90';

const _agentJson =
    '{"id":"$agentId","name":"Shams AI","slug":"shams-ai","description":null,'
    '"system_prompt":"be helpful","model":"bonsai-227b","provider":"openai",'
    '"is_active":true,"created_at":"2026-10-01T09:00:00.000Z",'
    '"updated_at":"2026-10-02T09:00:00.000Z"}';

const agentPayload = '[$_agentJson]';

const conversationPayload =
    '[{"id":"$conversationId","user_id":"$userId","agent_id":"$agentId",'
    '"status":"active","title":"Roadmap",'
    '"created_at":"2026-10-05T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:00.000Z",'
    '"agent":$_agentJson}]';

/// `POST /api/v1/conversations` - the created row, without messages.
const createdConversationPayload =
    '{"id":"$conversationId","user_id":"$userId","agent_id":"$agentId",'
    '"status":"active","title":null,'
    '"created_at":"2026-10-06T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:00.000Z"}';

const _userMessageJson =
    '{"id":"$userMessageId","conversation_id":"$conversationId",'
    '"role":"user","content":"hi","tokens":null,"tool_calls":[],'
    '"metadata":{},"created_at":"2026-10-06T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:00.000Z"}';

/// `GET /api/v1/conversations/:id`. While `AgentStreamJob` is still working the
/// assistant row is an empty placeholder carrying `metadata.streaming`; the job
/// clears that flag when the answer lands, which is what the chat screen polls
/// for.
String conversationDetailPayload({
  bool streaming = true,
  String reply = '',
  String? error,
  String title = 'hi',
}) {
  final metadata = jsonEncode({
    if (streaming) 'streaming': true,
    if (streaming) 'request_id': 'b21d0c5f-3f0d-4d6d-9b1a-2f7e6a5b4c3d',
    if (error != null) 'error': error,
  });

  return '{"id":"$conversationId","user_id":"$userId","agent_id":"$agentId",'
      '"status":"active","title":${jsonEncode(title)},'
      '"created_at":"2026-10-06T10:00:00.000Z",'
      '"updated_at":"2026-10-06T10:00:01.000Z",'
      '"messages":[$_userMessageJson,'
      '{"id":"$assistantMessageId","conversation_id":"$conversationId",'
      '"role":"assistant","content":${jsonEncode(reply)},"tokens":null,'
      '"tool_calls":[],"metadata":$metadata,'
      '"created_at":"2026-10-06T10:00:00.500Z",'
      '"updated_at":"2026-10-06T10:00:02.000Z",'
      '"agent":$_agentJson}]}';
}

/// `POST /api/v1/conversations/:id/messages` - the saved user row plus the
/// server's own note that the reply is still being generated.
const messageCreatedPayload =
    '{"message":$_userMessageJson,"status":"processing"}';

/// The sentence `AgentRunner` stores in `content` for *any* failed run. It is
/// deliberately uninformative, which is why the cause travels separately.
const genericFailure = 'I encountered an error while processing your request.';

/// A `metadata["error"]` value copied from a live failed turn - an agent with
/// no Anthropic key. Captured from `GET /api/v1/conversations/:id`, so the
/// fixtures describe what the API really sends rather than what it was assumed
/// to send.
const providerErrorDetail =
    'Anthropic API error: HTTP 401 - {"type":"error","error":{"type":'
    '"authentication_error","message":"x-api-key header is required"},'
    '"request_id":"req_011CggQjuTVXAGryYZaFcpyN"}';

/// A conversation with no messages yet: what `POST /api/v1/conversations`
/// without content produces, read back through the detail endpoint. No agent is
/// embedded - `include: { messages: { include: :agent } }` puts it on the
/// messages, and there are none here.
const emptyConversationDetailPayload =
    '{"id":"$conversationId","user_id":"$userId","agent_id":"$agentId",'
    '"status":"active","title":null,'
    '"created_at":"2026-10-06T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:00.000Z",'
    '"messages":[]}';

/// The two 401 answers `authenticate_user!` returns for an anonymous API call.
Map<String, List<TransportResponse>> get unauthenticatedRoutes =>
    <String, List<TransportResponse>>{
      'GET /api/v1/conversations': [
        json(401, '{"error":"Please sign in to continue."}'),
      ],
      'GET /api/v1/agents': [
        json(401, '{"error":"Please sign in to continue."}'),
      ],
    };

ShamsApi apiWith(HttpTransport transport) =>
    ShamsApi(baseUrl: 'http://localhost:3001/', transport: transport);
