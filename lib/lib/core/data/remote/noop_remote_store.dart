import '../../error/app_failure.dart';
import '../../utils/result.dart';
import '../remote_store.dart';
import '../sync/syncable_entity.dart';

/// A [RemoteStore] that always reports the cloud as unreachable.
///
/// There is no backend yet, and this is the honest representation of that: it
/// answers every call with a `NetworkFailure`, which is precisely the condition
/// the offline design already handles. Local writes succeed, changes stay queued,
/// and nothing in the application has to special-case the absence of a backend.
///
/// Returning success instead would be a lie that marks records as synced when
/// nothing was uploaded. Throwing would force callers to guard against a state the
/// architecture already treats as normal.
///
/// Replaced wholesale when a real backend is implemented. No caller changes.
class NoopRemoteStore<T extends SyncableEntity> implements RemoteStore<T> {
  const NoopRemoteStore();

  static const AppFailure _unavailable = NetworkFailure(
    'No cloud backend is configured. Data is saved on this device.',
  );

  @override
  Future<Result<void>> push(T entity) async => const Err<void>(_unavailable);

  @override
  Future<Result<void>> pushAll(Iterable<T> entities) async =>
      const Err<void>(_unavailable);

  @override
  Future<Result<void>> pushDelete(String id) async =>
      const Err<void>(_unavailable);

  // Not const: the type argument mentions the class's own type parameter, which a
  // constant expression cannot do.
  @override
  Future<Result<List<T>>> pullChangedSince(DateTime? since) async =>
      Err<List<T>>(_unavailable);
}
