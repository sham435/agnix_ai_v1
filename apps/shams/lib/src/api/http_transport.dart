import 'dart:convert';
import 'dart:io' as io;

/// A single outgoing request, already resolved to a [uri].
class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

/// A raw response. Header values are kept as a *list* because HTTP allows
/// repeated headers, and `Set-Cookie` is exactly such a header.
class TransportResponse {
  const TransportResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, List<String>> headers;
  final String body;

  /// All values sent for [name], compared case-insensitively.
  List<String> valuesFor(String name) {
    final wanted = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return const <String>[];
  }

  /// The first value sent for [name], or `null`.
  String? valueFor(String name) {
    final values = valuesFor(name);
    return values.isEmpty ? null : values.first;
  }
}

/// The only network seam the API client uses.
///
/// Keeping this narrow means [ShamsApi] can be tested with an in-memory fake
/// instead of a live Rails server.
abstract interface class HttpTransport {
  Future<TransportResponse> send(TransportRequest request);

  /// Releases any sockets held by the transport.
  void close();
}

/// [HttpTransport] backed by `dart:io`.
///
/// `dart:io` is used directly rather than through a wrapper package because the
/// login response sets two cookies (`_shams_session` and the signed `user_id`,
/// the latter with an `Expires` date containing commas). Wrapper packages that
/// flatten repeated headers into one comma-joined string make that pair
/// ambiguous to parse; `HttpHeaders[name]` returns each value separately.
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({io.HttpClient? client})
    : _client = client ?? io.HttpClient();

  final io.HttpClient _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final ioReq = await _client.openUrl(request.method, request.uri);
    request.headers.forEach(ioReq.headers.set);

    final body = request.body;
    if (body != null) ioReq.write(body);

    final ioRes = await ioReq.close();
    final text = await utf8.decoder.bind(ioRes).join();

    final headers = <String, List<String>>{};
    ioRes.headers.forEach((name, _) {
      headers[name] = ioRes.headers[name] ?? const <String>[];
    });

    return TransportResponse(
      statusCode: ioRes.statusCode,
      headers: headers,
      body: text,
    );
  }

  @override
  void close() => _client.close(force: true);
}
