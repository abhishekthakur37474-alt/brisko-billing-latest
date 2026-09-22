import 'dart:convert';

import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../helpers/recording_http_server.dart';

/// The auth client is the only thing that turns a stored session into a usable
/// credential, so its two calls — sign-in and refresh — must parse the real response
/// shapes and classify failures the way the sync engine depends on.
void main() {
  late RecordingHttpServer server;

  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-pos',
    apiKey: 'web-api-key',
    refreshToken: 'stored-refresh',
  );

  FirebaseAuthClient clientFor(RecordingHttpServer server) {
    return FirebaseAuthClient(
      config: config,
      identityBaseUrl: '${server.baseUrl}/identity/v1',
      secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
    );
  }

  setUp(() async {
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  test('refresh exchanges a refresh token for an ID token and uid', () async {
    server.responder = (RecordedRequest request) async {
      expect(request.path, endsWith('/securetoken/v1/token'));
      expect(request.query['key'], 'web-api-key');
      final Map<String, dynamic> body = request.json! as Map<String, dynamic>;
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'stored-refresh');
      return HttpResponseSpec(
        200,
        jsonEncode(<String, dynamic>{
          'id_token': 'id-token-1',
          'refresh_token': 'rotated-refresh',
          'user_id': 'restaurant-abc',
          'expires_in': '3600',
        }),
      );
    };

    final Result<FirebaseAuthTokens> result = await clientFor(server)
        .refresh('stored-refresh');

    final FirebaseAuthTokens tokens = result.valueOrNull!;
    expect(tokens.idToken, 'id-token-1');
    expect(tokens.refreshToken, 'rotated-refresh');
    expect(tokens.uid, 'restaurant-abc');
    expect(tokens.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
  });

  test('sign-in returns the session for a valid email and password', () async {
    server.responder = (RecordedRequest request) async {
      expect(request.path, endsWith('/accounts:signInWithPassword'));
      return HttpResponseSpec(
        200,
        jsonEncode(<String, dynamic>{
          'idToken': 'id-token-2',
          'refreshToken': 'refresh-2',
          'localId': 'restaurant-xyz',
          'expiresIn': '3600',
        }),
      );
    };

    final Result<FirebaseAuthTokens> result = await clientFor(server)
        .signInWithPassword('till@brisko.test', 'secret');

    expect(result.valueOrNull!.uid, 'restaurant-xyz');
    expect(result.valueOrNull!.idToken, 'id-token-2');
  });

  test(
    'a rejected refresh is a RemoteFailure, not a lost-data condition',
    () async {
      server.responder = (RecordedRequest request) async => HttpResponseSpec(
        400,
        jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{'message': 'INVALID_REFRESH_TOKEN'},
        }),
      );

      final Result<FirebaseAuthTokens> result = await clientFor(server)
          .refresh('stored-refresh');

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<RemoteFailure>());
    },
  );

  test('an unreachable identity service is a NetworkFailure', () async {
    // Bind then immediately close so the port is guaranteed to refuse.
    final RecordingHttpServer dead = await RecordingHttpServer.start();
    final String base = dead.baseUrl;
    await dead.close();

    final FirebaseAuthClient client = FirebaseAuthClient(
      config: config,
      secureTokenBaseUrl: '$base/securetoken/v1',
    );

    final Result<FirebaseAuthTokens> result = await client.refresh(
      'stored-refresh',
    );

    expect(result.isErr, isTrue);
    expect(result.failureOrNull, isA<NetworkFailure>());
  });
}
