import 'dart:convert';

import 'package:brisko_billing/core/data/remote/remote_store_factory.dart';
import 'package:brisko_billing/core/data/remote_store.dart';
import 'package:brisko_billing/core/data/sync/syncable_entity.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';

/// How the fake cloud responds, so a test can put the backend in each of the
/// three states the offline design cares about.
enum FakeCloudMode {
  /// Reachable and accepting.
  online,

  /// The link is down: every call fails with a [NetworkFailure], the ordinary
  /// offline condition that leaves work queued.
  offline,

  /// Reachable but refusing: every call fails with a [RemoteFailure], the
  /// server-side condition that is retried with backoff.
  unavailable,
}

/// An in-memory stand-in for the Firebase/RTDB backend, shared across every
/// collection's store.
///
/// It stores rows exactly as the real backend would — the entity's `toMap`, keyed
/// by id — so a push followed by a pull round-trips through the same JSON the wire
/// uses, and a record seeded here is indistinguishable from one another terminal
/// uploaded. That is what lets the download and restore paths be tested without a
/// network. It is backend-agnostic on purpose: it exercises the sync engine through
/// the same `RemoteStore` seam the real RTDB store implements.
class FakeCloud {
  FakeCloud({this.mode = FakeCloudMode.online});

  FakeCloudMode mode;

  /// collection -> id -> stored row.
  final Map<String, Map<String, Map<String, dynamic>>> _rows =
      <String, Map<String, Map<String, dynamic>>>{};

  /// Records what was pushed, per collection, for assertions about batching.
  int pushCount = 0;

  /// Seeds a row directly, as though another terminal had uploaded it.
  void seed(String collection, Map<String, dynamic> row) {
    _store(collection, row);
  }

  List<Map<String, dynamic>> rowsIn(String collection) =>
      _rows[collection]?.values.toList(growable: false) ??
      const <Map<String, dynamic>>[];

  Map<String, dynamic>? row(String collection, String id) =>
      _rows[collection]?[id];

  int count(String collection) => _rows[collection]?.length ?? 0;

  AppFailure? _failure() {
    return switch (mode) {
      FakeCloudMode.online => null,
      FakeCloudMode.offline => const NetworkFailure('offline (test)'),
      FakeCloudMode.unavailable => const RemoteFailure('unavailable (test)'),
    };
  }

  void _store(String collection, Map<String, dynamic> row) {
    // Round-trip through JSON so stored rows carry only wire-safe primitives,
    // exactly like a real backend, and cannot alias the caller's map.
    final Map<String, dynamic> copy =
        jsonDecode(jsonEncode(row)) as Map<String, dynamic>;
    _rows.putIfAbsent(
      collection,
      () => <String, Map<String, dynamic>>{},
    )[copy['id'] as String] = copy;
  }

  Result<void> push(String collection, Iterable<Map<String, dynamic>> rows) {
    final AppFailure? failure = _failure();
    if (failure != null) {
      return Err<void>(failure);
    }
    for (final Map<String, dynamic> row in rows) {
      _store(collection, row);
      pushCount++;
    }
    return const Ok<void>(null);
  }

  Result<void> markDeleted(String collection, String id) {
    final AppFailure? failure = _failure();
    if (failure != null) {
      return Err<void>(failure);
    }
    final Map<String, dynamic>? existing = _rows[collection]?[id];
    if (existing != null) {
      existing['isDeleted'] = 1;
      existing['updatedAt'] = DateTime.now().toUtc().millisecondsSinceEpoch;
    }
    return const Ok<void>(null);
  }

  Result<List<Map<String, dynamic>>> pull(String collection, int? sinceMillis) {
    final AppFailure? failure = _failure();
    if (failure != null) {
      return Err<List<Map<String, dynamic>>>(failure);
    }
    final List<Map<String, dynamic>> all = rowsIn(collection);
    final List<Map<String, dynamic>> changed =
        all
            .where(
              (Map<String, dynamic> row) =>
                  sinceMillis == null ||
                  (row['updatedAt'] as int) > sinceMillis,
            )
            .toList()
          ..sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                (a['updatedAt'] as int).compareTo(b['updatedAt'] as int),
          );
    // Hand back copies so the caller cannot mutate the cloud's rows.
    return Ok<List<Map<String, dynamic>>>(
      changed
          .map(
            (Map<String, dynamic> row) =>
                jsonDecode(jsonEncode(row)) as Map<String, dynamic>,
          )
          .toList(growable: false),
    );
  }
}

/// A [RemoteStore] backed by a [FakeCloud] for one collection.
class FakeRemoteStore<T extends SyncableEntity> implements RemoteStore<T> {
  FakeRemoteStore({
    required this.cloud,
    required this.collection,
    required this.fromRow,
  });

  final FakeCloud cloud;
  final String collection;
  final T Function(Map<String, Object?> row) fromRow;

  @override
  Future<Result<void>> push(T entity) async =>
      cloud.push(collection, <Map<String, dynamic>>[entity.toMap()]);

  @override
  Future<Result<void>> pushAll(Iterable<T> entities) async => cloud.push(
    collection,
    entities.map((T e) => e.toMap()).toList(growable: false),
  );

  @override
  Future<Result<void>> pushDelete(String id) async =>
      cloud.markDeleted(collection, id);

  @override
  Future<Result<List<T>>> pullChangedSince(DateTime? since) async {
    final Result<List<Map<String, dynamic>>> rows = cloud.pull(
      collection,
      since?.toUtc().millisecondsSinceEpoch,
    );
    return rows.map(
      (List<Map<String, dynamic>> list) =>
          list.map(fromRow).toList(growable: false),
    );
  }
}

/// A [RemoteStoreFactory] that hands out [FakeRemoteStore]s over one [FakeCloud].
class FakeRemoteStoreFactory implements RemoteStoreFactory {
  FakeRemoteStoreFactory(this.cloud);

  final FakeCloud cloud;

  @override
  RemoteStore<T> create<T extends SyncableEntity>(
    String table,
    T Function(Map<String, Object?> row) fromRow,
  ) => FakeRemoteStore<T>(cloud: cloud, collection: table, fromRow: fromRow);

  @override
  Future<void> dispose() async {}
}

/// Convenience for asserting on stored sync state names.
const String syncedName = 'synced';
const String pendingName = 'pending';
