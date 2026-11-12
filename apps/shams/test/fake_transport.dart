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

/// A second user turn, for the payloads that model "a turn has just been
/// posted into a thread that already has history".
const followUpMessageId = '1a2b3c4d-5e6f-4a0b-8c9d-0e1f2a3b4c5d';

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

/// The `GET /api/v1/conversations/:id` envelope around an already-rendered
/// list of message payloads.
String _conversationJson(String title, List<String> messages) =>
    '{"id":"$conversationId","user_id":"$userId","agent_id":"$agentId",'
    '"status":"active","title":${jsonEncode(title)},'
    '"created_at":"2026-10-06T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:01.000Z",'
    '"messages":[${messages.join(',')}]}';

/// One assistant row. `AgentStreamJob` writes the placeholder and the finished
/// answer to the same row, so the id stays put across the streaming transition.
String _assistantJson({
  bool streaming = true,
  String reply = '',
  String? error,
  int? tokens,
}) {
  final metadata = jsonEncode({
    if (streaming) 'streaming': true,
    if (streaming) 'request_id': 'b21d0c5f-3f0d-4d6d-9b1a-2f7e6a5b4c3d',
    if (error != null) 'error': error,
  });

  return '{"id":"$assistantMessageId","conversation_id":"$conversationId",'
      '"role":"assistant","content":${jsonEncode(reply)},'
      '"tokens":${tokens ?? 'null'},'
      '"tool_calls":[],"metadata":$metadata,'
      '"created_at":"2026-10-06T10:00:00.500Z",'
      '"updated_at":"2026-10-06T10:00:23.000Z",'
      '"agent":$_agentJson}';
}

/// `GET /api/v1/conversations/:id`. While `AgentStreamJob` is still working the
/// assistant row is an empty placeholder carrying `metadata.streaming`; the job
/// clears that flag when the answer lands, which is what the chat screen polls
/// for.
String conversationDetailPayload({
  bool streaming = true,
  String reply = '',
  String? error,
  int? tokens,
  String title = 'hi',
}) => _conversationJson(title, <String>[
  _userMessageJson,
  _assistantJson(
    streaming: streaming,
    reply: reply,
    error: error,
    tokens: tokens,
  ),
]);

/// The second user turn, i.e. the one a test posts through the composer.
const _followUpMessageJson =
    '{"id":"$followUpMessageId","conversation_id":"$conversationId",'
    '"role":"user","content":"Rails 8.2?","tokens":null,"tool_calls":[],'
    '"metadata":{},"created_at":"2026-10-06T10:01:00.000Z",'
    '"updated_at":"2026-10-06T10:01:00.000Z"}';

/// `GET /api/v1/conversations/:id` read in the gap right after
/// `messages#create` returns: the new user row is saved, the turns before it
/// are untouched, and `AgentStreamJob` has not created this turn's assistant
/// row yet - so nothing in the payload carries `metadata["streaming"]` even
/// though a reply is definitely still coming.
///
/// The chat screen used to read this state once, conclude nothing was pending,
/// and never look again; measured live on 2026-11-04, the reply landed ~20 s
/// later and the app never showed it.
final String turnPostedPayload = _conversationJson('Roadmap', <String>[
  _userMessageJson,
  _assistantJson(streaming: false, reply: 'Earlier answer.'),
  _followUpMessageJson,
]);

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

// ---------------------------------------------------------------------------
// Account & security panel
// ---------------------------------------------------------------------------

const currentDeviceId = '4a1f9c2e-7b3d-4e16-9a05-2c8d1e6f3b70';
const otherDeviceId = '6b2f0d31-8c4e-4f27-ab16-3d9e2f704c81';

/// One `devices` row, as `security_devices` builds it.
String deviceJson(
  String id,
  String name, {
  bool current = false,
  String? ip = '127.0.0.1',
}) =>
    '{"id":"$id","device":${jsonEncode(name)},'
    '"ip":${ip == null ? 'null' : jsonEncode(ip)},'
    '"signed_in_at":"2026-11-11T09:00:00.000Z",'
    '"last_seen_at":"2026-11-11T09:30:00.000Z",'
    '"current":$current}';

/// The `usage` block. An unmetered plan answers `metered:false` with a null
/// cap - "no ceiling", which the client must not read as "nothing left".
const _meteredUsage =
    '{"organization":"Shams","plan":"member","metered":true,'
    '"cap":20000,"used":1200,"remaining":18800}';
const _freeUsage =
    '{"organization":"Shams","plan":"free","metered":false,'
    '"cap":null,"used":1200,"remaining":null}';

/// `GET /api/v1/security`, and the snapshot the panel actions answer with.
///
/// The optional arguments are the parts that appear only in one response and
/// never in the next: [enrollment] (raw JSON, as only the call that minted it
/// carries it), [recoveryCodes], and the phone verifier's `status`/`message`/
/// [code] - the last of which a server with no SMS gateway sends in
/// development only.
String securityPayload({
  bool twoFactorEnabled = false,
  int recoveryCodesLeft = 0,
  int lockedMinutesLeft = 0,
  String? phone,
  bool phoneVerified = false,
  bool meteredUsage = true,
  List<String> devices = const [],
  String? enrollment,
  List<String> recoveryCodes = const [],
  String? status,
  String? message,
  String? code,
  int? retryIn,
  bool signedOut = false,
}) =>
    '{'
    '"two_factor":{"enabled":$twoFactorEnabled,'
    '"recovery_codes_left":$recoveryCodesLeft,'
    '"locked_minutes_left":$lockedMinutesLeft},'
    '"phone":{"number":${phone == null ? 'null' : jsonEncode(phone)},'
    '"verified":$phoneVerified,'
    '"verified_at":${phoneVerified ? '"2026-11-11T09:00:00.000Z"' : 'null'}},'
    '"devices":[${devices.join(',')}],'
    '"usage":${meteredUsage ? _meteredUsage : _freeUsage}'
    '${enrollment == null ? '' : ',"enrollment":$enrollment'}'
    '${recoveryCodes.isEmpty ? '' : ',"recovery_codes":${jsonEncode(recoveryCodes)}'}'
    '${status == null ? '' : ',"status":${jsonEncode(status)}'}'
    '${message == null ? '' : ',"message":${jsonEncode(message)}'}'
    '${code == null ? '' : ',"code":${jsonEncode(code)}'}'
    '${retryIn == null ? '' : ',"retry_in":$retryIn'}'
    '${signedOut ? ',"signed_out":true' : ''}'
    '}';

/// The key the server mints during enrollment: base32, and never stored.
const pendingSecret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';
const pendingEnrollmentJson =
    '{"secret":"$pendingSecret",'
    '"provisioning_uri":"otpauth://totp/Shams%20AI:dev%40shams.ai'
    '?secret=$pendingSecret&issuer=Shams%20AI","expires_in":600}';

ShamsApi apiWith(HttpTransport transport) =>
    ShamsApi(baseUrl: 'http://localhost:3001/', transport: transport);
