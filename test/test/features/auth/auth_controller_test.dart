import 'dart:convert';

import 'package:brisko_billing/app/sync/cloud_sync_activation.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_client.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_auth_session.dart';
import 'package:brisko_billing/core/data/remote/firebase/firebase_config.dart';
import 'package:brisko_billing/core/data/sync/outbox_entry.dart';
import 'package:brisko_billing/core/utils/entity_id.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/auth/presentation/controllers/auth_controller.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/recording_http_server.dart';
import '../../helpers/test_database.dart';

/// Records whether synchronisation was switched on or off, so the controller's effect on
/// the sync engine can be checked without a real coordinator, timer or network.
class _RecordingActivation implements CloudSyncActivation {
  int enableCalls = 0;
  int disableCalls = 0;

  @override
  Future<void> enable() async => enableCalls++;

  @override
  Future<void> disable() async => disableCalls++;
}

/// The AuthController is the single place sign-in and sign-out happen. These prove it does
/// the four things Step 18 asks of it: exchange credentials for a session, persist that
/// session, hand it to the shared session the sync transport uses, and — on the way out —
/// forget it and stop syncing while leaving every local record and queued change in place.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late RecordingHttpServer server;
  late SqliteSettingsRepository settings;
  late AuthSessionStore sessionStore;
  late FirebaseAuthSession session;
  late FirebaseAuthClient authClient;
  late _RecordingActivation activation;

  const FirebaseConfig config = FirebaseConfig(
    projectId: 'brisko-pos',
    apiKey: 'web-api-key',
  );

  setUp(() async {
    database = await TestDatabase.openInMemory();
    server = await RecordingHttpServer.start();
    settings = SqliteSettingsRepository(database: database);
    sessionStore = AuthSessionStore(settings: settings);
    authClient = FirebaseAuthClient(
      config: config,
      identityBaseUrl: '${server.baseUrl}/identity/v1',
      secureTokenBaseUrl: '${server.baseUrl}/securetoken/v1',
    );
    session = FirebaseAuthSession(config: config, authClient: authClient);
    activation = _RecordingActivation();
  });

  tearDown(() async {
    await server.close();
    await database.close();
  });

  AuthController controller({
    bool initiallyAuthenticated = false,
    String? initialEmail,
  }) {
    return AuthController(
      isCloudEnabled: true,
      initiallyAuthenticated: initiallyAuthenticated,
      initialEmail: initialEmail,
      authClient: authClient,
      session: session,
      sessionStore: sessionStore,
      syncActivation: activation,
    );
  }

  void respondSignInOk() {
    server.responder = (RecordedRequest request) async => HttpResponseSpec(
      200,
      jsonEncode(<String, dynamic>{
        'idToken': 'id-token-1',
        'refreshToken': 'refresh-token-1',
        'localId': 'restaurant-abc',
        'expiresIn': '3600',
      }),
    );
  }

  void respondSignInRejected() {
    server.responder = (RecordedRequest request) async => HttpResponseSpec(
      400,
      jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{'message': 'INVALID_LOGIN_CREDENTIALS'},
      }),
    );
  }

  group('sign in', () {
    test('a valid email and password authenticates the terminal', () async {
      respondSignInOk();
      final AuthController auth = controller();
      addTearDown(auth.dispose);

      final bool ok = await auth.signIn(
        email: 'till@brisko.test',
        password: 'correct horse',
      );

      expect(ok, isTrue);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.signedInEmail, 'till@brisko.test');
      expect(auth.errorMessage, isNull);
      // The session was handed to the shared object the sync transport signs with, and
      // synchronisation was switched on.
      expect(session.hasSession, isTrue);
      expect(activation.enableCalls, 1);
    });

    test('wrong credentials fail without authenticating', () async {
      respondSignInRejected();
      final AuthController auth = controller();
      addTearDown(auth.dispose);

      final bool ok = await auth.signIn(
        email: 'till@brisko.test',
        password: 'wrong',
      );

      expect(ok, isFalse);
      expect(auth.isAuthenticated, isFalse);
      expect(auth.status, SignInStatus.failed);
      expect(auth.errorMessage, contains('did not match'));
      expect(activation.enableCalls, 0);
      // No credential from the server ever reaches the message.
      expect(auth.errorMessage, isNot(contains('INVALID')));
    });

    test(
      'an unreachable cloud reports a network problem, not bad login',
      () async {
        final RecordingHttpServer dead = await RecordingHttpServer.start();
        final String base = dead.baseUrl;
        await dead.close();
        final FirebaseAuthClient offlineClient = FirebaseAuthClient(
          config: config,
          identityBaseUrl: '$base/identity/v1',
          secureTokenBaseUrl: '$base/securetoken/v1',
        );
        final AuthController auth = AuthController(
          isCloudEnabled: true,
          initiallyAuthenticated: false,
          authClient: offlineClient,
          session: session,
          sessionStore: sessionStore,
          syncActivation: activation,
        );
        addTearDown(auth.dispose);

        final bool ok = await auth.signIn(
          email: 'till@brisko.test',
          password: 'secret',
        );

        expect(ok, isFalse);
        expect(auth.isAuthenticated, isFalse);
        expect(auth.errorMessage, contains('reach the cloud'));
      },
    );

    test('empty fields are refused before any network call', () async {
      final AuthController auth = controller();
      addTearDown(auth.dispose);

      final bool ok = await auth.signIn(email: '  ', password: '');

      expect(ok, isFalse);
      expect(auth.errorMessage, contains('Enter your email and password'));
      expect(server.requests, isEmpty);
    });
  });

  group('session persistence', () {
    test(
      'the refresh token and email are persisted; the password is not',
      () async {
        respondSignInOk();
        final AuthController auth = controller();
        addTearDown(auth.dispose);

        await auth.signIn(email: 'till@brisko.test', password: 'super-secret');

        final Map<String, String?> stored =
            (await settings.readAll()).valueOrNull!;

        // The session is on disk, so the next launch skips the login screen.
        final PersistedSession? persisted = sessionStore.fromStored(stored);
        expect(persisted, isNotNull);
        expect(persisted!.refreshToken, 'refresh-token-1');
        expect(persisted.email, 'till@brisko.test');

        // The password appears nowhere in storage.
        expect(
          stored.values.whereType<String>(),
          isNot(contains('super-secret')),
        );
      },
    );
  });

  group('startup gate', () {
    test('an unauthenticated cloud build starts signed out', () {
      final AuthController auth = controller();
      addTearDown(auth.dispose);
      expect(auth.isAuthenticated, isFalse);
    });

    test('a persisted session starts authenticated even with no network', () {
      // No responder is ever hit: presence of a session is enough, so the till opens
      // offline and sync resumes later on its own.
      final AuthController auth = controller(
        initiallyAuthenticated: true,
        initialEmail: 'till@brisko.test',
      );
      addTearDown(auth.dispose);
      expect(auth.isAuthenticated, isTrue);
      expect(auth.signedInEmail, 'till@brisko.test');
      expect(server.requests, isEmpty);
    });

    test('a local-only build is always "authenticated" so the till opens', () {
      final AuthController local = AuthController(
        isCloudEnabled: false,
        initiallyAuthenticated: false,
        sessionStore: sessionStore,
      );
      addTearDown(local.dispose);
      expect(local.isAuthenticated, isTrue);
    });
  });

  group('sign out', () {
    test('forgets the session and stops syncing', () async {
      respondSignInOk();
      final AuthController auth = controller();
      addTearDown(auth.dispose);
      await auth.signIn(email: 'till@brisko.test', password: 'secret');
      expect(session.hasSession, isTrue);

      await auth.signOut();

      expect(auth.isAuthenticated, isFalse);
      expect(auth.signedInEmail, isNull);
      // The in-memory session is cleared, so cloud access requires signing in again.
      expect(session.hasSession, isFalse);
      expect(activation.disableCalls, 1);
      // The persisted session is gone too.
      final PersistedSession? persisted = sessionStore.fromStored(
        (await settings.readAll()).valueOrNull!,
      );
      expect(persisted, isNull);
    });

    test('does not discard other settings or the outbox', () async {
      // A real setting and a queued change stand for "local data" and "pending cloud
      // work". Neither may be lost on sign-out.
      await settings.writeString(SettingKeys.businessName, 'Brisko Pizza');
      final SqliteOutboxStore outbox = SqliteOutboxStore(database: database);
      addTearDown(outbox.dispose);
      await outbox.enqueue(
        OutboxEntry(
          id: EntityId.generate(prefix: 'obx'),
          collection: 'orders',
          entityId: 'order-1',
          operation: OutboxOperation.upsert,
          payload: const <String, Object?>{'id': 'order-1'},
          queuedAt: DateTime.now().toUtc(),
        ),
      );
      final int pendingBefore = (await outbox.pendingCount()).valueOrNull!;
      expect(pendingBefore, 1);

      respondSignInOk();
      final AuthController auth = controller();
      addTearDown(auth.dispose);
      await auth.signIn(email: 'till@brisko.test', password: 'secret');
      await auth.signOut();

      // The business name is untouched, and the queued change is still there.
      expect(
        (await settings.readString(SettingKeys.businessName)).valueOrNull,
        'Brisko Pizza',
      );
      expect((await outbox.pendingCount()).valueOrNull, 1);
    });
  });
}
