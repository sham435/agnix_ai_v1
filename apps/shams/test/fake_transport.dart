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

const agentPayload =
    '[{"id":7,"name":"Shams AI","slug":"shams-ai","description":null,'
    '"system_prompt":"be helpful","model":"bonsai-227b","provider":"openai",'
    '"is_active":true,"created_at":"2026-10-01T09:00:00.000Z",'
    '"updated_at":"2026-10-02T09:00:00.000Z"}]';

const conversationPayload =
    '[{"id":3,"user_id":1,"agent_id":7,"status":"active","title":"Roadmap",'
    '"created_at":"2026-10-05T10:00:00.000Z",'
    '"updated_at":"2026-10-06T10:00:00.000Z",'
    '"agent":{"id":7,"name":"Shams AI","slug":"shams-ai","description":null,'
    '"system_prompt":null,"model":"bonsai-227b","provider":"openai",'
    '"is_active":true,"created_at":"2026-10-01T09:00:00.000Z",'
    '"updated_at":"2026-10-02T09:00:00.000Z"}}]';

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
