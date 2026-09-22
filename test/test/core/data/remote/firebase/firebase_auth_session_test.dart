import 'dart:convert';

import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../helpers/recording_http_server.dart';

/// The session is what keeps a valid credential to hand without asking the caller to
/// think about token lifetimes. It must cache a good token, refresh a stale one, share
/// one refresh across concurrent callers, and fail cleanly when there is no session or
/// no network.
void main() {
  late RecordingHttpServer server;

  int tokenRequests() => server.requests
      .where((RecordedRequest r) => r.path.contains('/securetoken/'))
      .length;

  FirebaseAuthSession sessionFor(
    RecordingHttpServer server,
    FirebaseConfig config, {
    Duration refreshMargin = const Duration(minutes: 1),
  }) {
    return FirebaseAuthSession(
      config: config,
      refreshMargin: refreshMargin,
      authClient: FirebaseAuthClient(
        config: config,
        secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
      ),
    );
  }

  void respondWithExpiry(String expiresIn) {
    server.responder = (RecordedRequest request) async => HttpResponseSpec(
      200,
      jsonEncode(<String, dynamic>{
        'id_token': 'id-token',
        'refresh_token': 'rotated',
        'user_id': 'restaurant-abc',
        'expires_in': expiresIn,
      }),
    );
  }

  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-pos',
    apiKey: 'web-api-key',
    refreshToken: 'stored-refresh',
  );

  setUp(() async {
    server = await RecordingHttpServer.start();
  });

  tearDown(() async {
    await server.close();
  });

  test('current() exposes the restaurant id as the signed-in uid', () async {
    respondWithExpiry('3600');
    final Result<FirebaseAuthContext> result = await sessionFor(
      server,
      config,
    ).current();
    expect(result.valueOrNull!.restaurantId, 'restaurant-abc');
    expect(result.valueOrNull!.idToken, 'id-token');
  });

  test('a valid token is cached, not refreshed on every call', () async {
    respondWithExpiry('3600');
    final FirebaseAuthSession session = sessionFor(server, config);
    await session.current();
    await session.current();
    expect(tokenRequests(), 1);
  });

  test('a near-expiry token is refreshed before use', () async {
    // expires_in 0 means the token is already inside the refresh margin.
    respondWithExpiry('0');
    final FirebaseAuthSession session = sessionFor(server, config);
    await session.current();
    await session.current();
    expect(tokenRequests(), 2);
  });

  test('concurrent callers share a single refresh', () async {
    respondWithExpiry('3600');
    final FirebaseAuthSession session = sessionFor(server, config);
    await Future.wait(<Future<Result<FirebaseAuthContext>>>[
      session.current(),
      session.current(),
      session.current(),
    ]);
    expect(tokenRequests(), 1);
  });

  test(
    'a terminal with no session reports not signed in, without a call',
    () async {
      respondWithExpiry('3600');
      const FirebaseConfig noSession = FirebaseConfig(
        projectId: 'brisko-pos',
        apiKey: 'web-api-key',
      );
      final Result<FirebaseAuthContext> result = await sessionFor(
        server,
        noSession,
      ).current();
      expect(result.failureOrNull, isA<RemoteFailure>());
      expect(tokenRequests(), 0);
    },
  );

  test('adopting a session avoids a refresh entirely', () async {
    respondWithExpiry('3600');
    final FirebaseAuthSession session = sessionFor(server, config);
    session.adopt(
      FirebaseAuthTokens(
        idToken: 'adopted-token',
        refreshToken: 'r',
        uid: 'restaurant-zzz',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      ),
    );
    final Result<FirebaseAuthContext> result = await session.current();
    expect(result.valueOrNull!.restaurantId, 'restaurant-zzz');
    expect(tokenRequests(), 0);
  });

  test('an offline refresh is a NetworkFailure, leaving work queued', () async {
    final RecordingHttpServer dead = await RecordingHttpServer.start();
    final String base = dead.baseUrl;
    await dead.close();

    final FirebaseAuthSession session = FirebaseAuthSession(
      config: config,
      authClient: FirebaseAuthClient(
        config: config,
        secureTokenBaseUrl: '$base/securetoken/v1',
      ),
    );
    final Result<FirebaseAuthContext> result = await session.current();
    expect(result.failureOrNull, isA<NetworkFailure>());
  });
}
