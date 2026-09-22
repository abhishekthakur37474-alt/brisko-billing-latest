import 'dart:io';

import '../remote_store.dart';
import '../sync/syncable_entity.dart';
import 'firebase/firebase_auth_client.dart';
import 'firebase/firebase_auth_session.dart';
import 'firebase/firebase_config.dart';
import 'firebase/rtdb_remote_store.dart';
import 'firebase/rtdb_rest_client.dart';
import 'noop_remote_store.dart';

/// Builds a [RemoteStore] per collection.
///
/// Synchronisation is generic across entity types, but a `RemoteStore` is typed to
/// one. This factory is how the coordinator's bootstrap asks for the right store
/// for each table without naming the backend, so that whether the terminal is
/// configured for the cloud or running purely local is decided in exactly one
/// place.
abstract interface class RemoteStoreFactory {
  RemoteStore<T> create<T extends SyncableEntity>(
    String table,
    T Function(Map<String, Object?> row) fromRow,
  );

  /// Releases any shared transport. Safe to call when nothing was opened.
  Future<void> dispose();
}

/// The factory for a terminal with no usable cloud configuration.
///
/// Every store it makes reports the cloud as unreachable, which is the same
/// condition being offline produces, so nothing downstream has to special-case the
/// absence of a backend: local writes succeed and stay queued.
class NoopRemoteStoreFactory implements RemoteStoreFactory {
  const NoopRemoteStoreFactory();

  @override
  RemoteStore<T> create<T extends SyncableEntity>(
    String table,
    T Function(Map<String, Object?> row) fromRow,
  ) => NoopRemoteStore<T>();

  @override
  Future<void> dispose() async {}
}

/// The factory for a configured Firebase backend.
///
/// It owns the whole cloud transport for the terminal: one [HttpClient] shared across
/// every collection's store, and one [RtdbRestClient] that turns rows into Realtime
/// Database nodes scoped to the signed-in restaurant. Sharing them means all collections
/// reuse a single connection pool and a single session refresh.
///
/// The [RtdbRestClient] — and the [FirebaseAuthSession] inside it — are supplied
/// rather than built here, because the same session must also be reachable by the sign-in
/// flow: logging in adopts a session into it and signing out clears it, and both must be
/// seen by every store this factory hands out. See [FirebaseRemoteStoreFactory.new].
class FirebaseRemoteStoreFactory implements RemoteStoreFactory {
  /// Builds a factory over the whole Firebase transport for [config].
  ///
  /// One [HttpClient], one [FirebaseAuthSession], one [RtdbRestClient], all shared.
  /// The session is returned in [session] so the sign-in flow can adopt and clear it; the
  /// auth client is returned in [authClient] so the login screen can exchange an email and
  /// password for a session on the very same connection pool.
  factory FirebaseRemoteStoreFactory({required FirebaseConfig config}) {
    final HttpClient httpClient = HttpClient();
    final FirebaseAuthClient authClient = FirebaseAuthClient(
      config: config,
      httpClient: httpClient,
    );
    final FirebaseAuthSession session = FirebaseAuthSession(
      config: config,
      authClient: authClient,
    );
    return FirebaseRemoteStoreFactory._(
      httpClient: httpClient,
      authClient: authClient,
      session: session,
      client: RtdbRestClient(
        config: config,
        httpClient: httpClient,
        session: session,
      ),
    );
  }

  FirebaseRemoteStoreFactory._({
    required HttpClient httpClient,
    required this.authClient,
    required this.session,
    required RtdbRestClient client,
  }) : _httpClient = httpClient,
       _client = client;
  // The two private fields are assigned here rather than as initializing formals to keep
  // the four constructor arguments reading uniformly at the single call site above.
  // ignore_for_file: prefer_initializing_formals

  final HttpClient _httpClient;
  final RtdbRestClient _client;

  /// The auth client the sign-in screen uses to exchange an email and password for a
  /// session, on the same connection pool as the sync transport.
  final FirebaseAuthClient authClient;

  /// The session every store here signs its requests with. The sign-in flow adopts a new
  /// session into it on login and clears it on logout.
  final FirebaseAuthSession session;

  /// Shared REST client. The till wipe uses it to snapshot and empty the restaurant
  /// node; ordinary sync never sees it.
  RtdbRestClient get restClient => _client;

  @override
  RemoteStore<T> create<T extends SyncableEntity>(
    String table,
    T Function(Map<String, Object?> row) fromRow,
  ) => RtdbRemoteStore<T>(
    client: _client,
    collection: table,
    fromRow: fromRow,
  );

  @override
  Future<void> dispose() async => _httpClient.close(force: true);
}
