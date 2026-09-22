import 'dart:convert';

import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../helpers/recording_http_server.dart';

/// Sign-out and expiry behaviour of the shared session.
///
/// Signing out must genuinely cut the terminal off from the cloud — including not quietly
/// reusing a refresh token that still sits in the configuration — and an expired or
/// rejected session must surface as a server refusal rather than silently pass.
void main() {
  late RecordingHttpServer server;

  int tokenRequests() => server.requests
      .where((RecordedRequest r) => r.path.contains('/securetoken/'))
      .length;

  FirebaseAuthSession sessionFor(FirebaseConfig config) {
    return FirebaseAuthSession(
      config: config,
      authClient: FirebaseAuthClient(
        config: config,
        secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
      ),
    );
  }

  setUp(() async {
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  test('clear() cuts off an adopted session without a network call', () async {
    const FirebaseConfig config = FirebaseConfig(
      projectId: 'brisko-pos',
      apiKey: 'web-api-key',
    );
    final FirebaseAuthSession session = sessionFor(config);
    session.adopt(
      FirebaseAuthTokens(
        idToken: 'id',
        refreshToken: 'r',
        uid: 'restaurant-abc',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );
    expect(session.hasSession, isTrue);

    session.clear();

    expect(session.hasSession, isFalse);
    final Result<FirebaseAuthContext> result = await session.current();
    expect(result.failureOrNull, isA<RemoteFailure>());
    // Signed out means signed out: no attempt to refresh anything.
    expect(tokenRequests(), 0);
  });

  test(
    'after sign-out the configured refresh token is not silently reused',
    () async {
      // Even though the config still carries a refresh token, a signed-out session must
      // not fall back to it — otherwise logging out would not actually stop cloud access.
      const FirebaseConfig configured = FirebaseConfig(
        projectId: 'brisko-pos',
        apiKey: 'web-api-key',
        refreshToken: 'left-in-config',
      );
      final FirebaseAuthSession session = sessionFor(configured);

      session.clear();

      final Result<FirebaseAuthContext> result = await session.current();
      expect(result.failureOrNull, isA<RemoteFailure>());
      expect(tokenRequests(), 0);
    },
  );

  test('a rejected refresh (expired session) is a RemoteFailure', () async {
    const FirebaseConfig config = FirebaseConfig(
      projectId: 'brisko-pos',
      apiKey: 'web-api-key',
      refreshToken: 'stale-refresh',
    );
    server.responder = (RecordedRequest request) async => HttpResponseSpec(
      400,
      jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{'message': 'TOKEN_EXPIRED'},
      }),
    );

    final Result<FirebaseAuthContext> result = await sessionFor(config)
        .current();

    expect(result.isErr, isTrue);
    expect(result.failureOrNull, isA<RemoteFailure>());
  });

  test('signing back in after sign-out restores the session', () async {
    const FirebaseConfig config = FirebaseConfig(
      projectId: 'brisko-pos',
      apiKey: 'web-api-key',
    );
    final FirebaseAuthSession session = sessionFor(config);
    session.clear();
    expect(session.hasSession, isFalse);

    session.adopt(
      FirebaseAuthTokens(
        idToken: 'id-2',
        refreshToken: 'r-2',
        uid: 'restaurant-xyz',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );

    expect(session.hasSession, isTrue);
    final Result<FirebaseAuthContext> result = await session.current();
    expect(result.valueOrNull!.restaurantId, 'restaurant-xyz');
    expect(tokenRequests(), 0);
  });
}
