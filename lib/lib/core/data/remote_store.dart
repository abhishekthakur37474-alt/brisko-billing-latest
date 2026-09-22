import '../utils/result.dart';
import 'sync/syncable_entity.dart';

/// Cloud persistence for one collection of entities.
///
/// Every method here is allowed to fail with a `NetworkFailure`, and that failure
/// is a normal operating condition rather than an error to surface to the
/// cashier. Callers respond by leaving the work in the outbox and retrying later.
///
/// Firebase will implement this interface. Keeping it abstract is what allows the
/// billing module to be written and tested before the backend exists, and what
/// keeps Firebase types out of the domain and presentation layers.
abstract interface class RemoteStore<T extends SyncableEntity> {
  /// Uploads one record, overwriting the cloud copy.
  Future<Result<void>> push(T entity);

  /// Uploads many records as a single batch where the backend supports it.
  Future<Result<void>> pushAll(Iterable<T> entities);

  /// Propagates a soft delete.
  Future<Result<void>> pushDelete(String id);

  /// Downloads records changed strictly after [since]. A `null` [since] requests
  /// everything, which is what a freshly provisioned terminal needs.
  Future<Result<List<T>>> pullChangedSince(DateTime? since);
}
