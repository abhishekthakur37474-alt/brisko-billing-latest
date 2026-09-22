import 'dart:convert';
import 'dart:io';

/// One request the [RecordingHttpServer] received, captured for assertions.
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.authorization,
    required this.body,
  });

  final String method;
  final String path;
  final Map<String, String> query;

  /// The `Authorization` header value, or `null` when none was sent.
  final String? authorization;

  /// The raw request body.
  final String body;

  /// The body parsed as JSON, for convenience in assertions.
  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// How the fake server should answer one request.
class HttpResponseSpec {
  const HttpResponseSpec(this.status, this.body);

  final int status;
  final String body;
}

/// A loopback HTTP server that records every request and answers each through a
/// caller-supplied [responder].
///
/// It exists so the Firebase REST clients can be exercised end to end — real HTTP,
/// real JSON, real status codes — without a live Firebase project. The client's base
/// URLs are pointed at [baseUrl]; the [responder] decides what each path returns.
class RecordingHttpServer {
  RecordingHttpServer._(this._server);

  final HttpServer _server;

  /// Every request the server received, in order.
  final List<RecordedRequest> requests = <RecordedRequest>[];

  /// Answers a request. Set by the test before making calls.
  Future<HttpResponseSpec> Function(RecordedRequest request) responder = (
    RecordedRequest request,
  ) async => const HttpResponseSpec(200, '{}');

  static Future<RecordingHttpServer> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final RecordingHttpServer recorder = RecordingHttpServer._(server);
    server.listen((HttpRequest request) async {
      final String body = await utf8.decoder.bind(request).join();
      final RecordedRequest recorded = RecordedRequest(
        method: request.method,
        path: request.uri.path,
        query: request.uri.queryParameters,
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
        body: body,
      );
      recorder.requests.add(recorded);

      final HttpResponseSpec spec = await recorder.responder(recorded);
      request.response.statusCode = spec.status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(spec.body);
      await request.response.close();
    });
    return recorder;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}
