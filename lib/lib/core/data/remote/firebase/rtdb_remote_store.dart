import '../../../utils/result.dart';
import '../../remote_store.dart';
import '../../sync/syncable_entity.dart';
import 'rtdb_rest_client.dart';

/// [RemoteStore] backed by one Realtime Database node under the signed-in
/// restaurant.
///
/// The cloud node mirrors the local row: the entity's own `toMap` is the payload
/// in both directions — it is what is written to SQLite and what is written to
/// RTDB — and [fromRow] turns a downloaded node back into an entity the same way
/// it turns a SQLite row into one. That symmetry is why there is no separate
/// cloud DTO to keep in step.
///
/// This is the one class that is specific to the backend. Everything above it
/// works through [RemoteStore], so the choice of RTDB reaches no further than
/// the bootstrap that constructs it.
class RtdbRemoteStore<T extends SyncableEntity> implements RemoteStore<T> {
  const RtdbRemoteStore({
    required this.client,
    required this.collection,
    required this.fromRow,
  });

  final RtdbRestClient client;

  /// Local table name for this collection. The client maps it to the RTDB node
  /// under the restaurant.
  final String collection;

  /// Rebuilds an entity from a downloaded node, the same function the local
  /// store uses for a SQLite row.
  final T Function(Map<String, Object?> row) fromRow;

  @override
  Future<Result<void>> push(T entity) =>
      client.upsert(collection, <Map<String, dynamic>>[entity.toMap()]);

  @override
  Future<Result<void>> pushAll(Iterable<T> entities) {
    final List<Map<String, dynamic>> rows = entities
        .map((T entity) => entity.toMap())
        .toList(growable: false);
    return client.upsert(collection, rows);
  }

  @override
  Future<Result<void>> pushDelete(String id) =>
      client.markDeleted(collection, id);

  @override
  Future<Result<List<T>>> pullChangedSince(DateTime? since) async {
    final Result<List<Map<String, Object?>>> result = await client
        .selectChangedSince(collection, since?.toUtc().millisecondsSinceEpoch);
    return result.map(
      (List<Map<String, Object?>> rows) =>
          rows.map(fromRow).toList(growable: false),
    );
  }
}
