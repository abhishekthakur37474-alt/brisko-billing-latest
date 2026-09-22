import '../../error/app_failure.dart';
import '../../utils/result.dart';
import 'sync_endpoint.dart';
import 'sync_metadata_store.dart';

/// What the one-time bootstrap decided.
enum InitialSyncOutcome {
  /// The terminal had already bootstrapped, so nothing was done. A restore never
  /// runs twice.
  alreadyBootstrapped,

  /// This terminal already holds operational data, so the cloud was not pulled
  /// over it. Its data stands, and ordinary synchronisation reconciles the two.
  keptExistingLocal,

  /// The local database held no operational data and the cloud had records, which
  /// were downloaded to seed it.
  restoredFromCloud,

  /// The local database was empty and so was the cloud. A genuinely fresh outlet.
  cloudEmpty,
}

/// Runs the safe, one-time bootstrap when a terminal first connects to the cloud.
///
/// ## The one rule
///
/// A restore must never overwrite a database that is already in use. Getting this
/// wrong duplicates or destroys real bills, so the service refuses to restore the
/// moment it sees operational data on the terminal, and it records that the
/// bootstrap has run so it cannot fire a second time.
///
/// ## The two paths
///
/// A fresh install with an empty local database pulls the cloud down to seed
/// itself: authenticate, download, populate, ready. A terminal that already holds
/// bills keeps them and lets ordinary synchronisation merge the two sides by
/// `updatedAt`; nothing is pulled on top of it here.
///
/// ## Why this cannot duplicate records
///
/// The download is the same conflict-aware merge ordinary pulls use: every record
/// is keyed by its device-generated id and upserted, so running the restore twice,
/// or restoring records this terminal already has, updates in place rather than
/// inserting a second copy. Stable ids are what make that true.
///
/// ## Seeded reference data does not count as "in use"
///
/// A brand-new install already has the seeded menu from the migrations. That is
/// not operational data, so [hasOperationalData] must report only the records a
/// working terminal accumulates — bills, payments, customers and the like — or a
/// fresh install would wrongly look "in use" and never restore.
class InitialSyncService {
  const InitialSyncService({
    required this._endpoints,
    required this._metadata,
    required this._hasOperationalData,
  });

  final List<SyncEndpointBase> _endpoints;
  final SyncMetadataStore _metadata;
  final Future<bool> Function() _hasOperationalData;

  Future<Result<InitialSyncOutcome>> run() async {
    final bool bootstrapped =
        (await _metadata.isBootstrapped()).valueOrNull ?? false;
    if (bootstrapped) {
      return const Ok<InitialSyncOutcome>(
        InitialSyncOutcome.alreadyBootstrapped,
      );
    }

    if (await _hasOperationalData()) {
      // The terminal is already in use. Protect it: mark the bootstrap done so no
      // restore is ever attempted over these bills, and let ordinary sync merge.
      await _metadata.markBootstrapped();
      return const Ok<InitialSyncOutcome>(InitialSyncOutcome.keptExistingLocal);
    }

    // Empty of operational data: safe to seed from the cloud.
    int applied = 0;
    DateTime? newest;
    for (final SyncEndpointBase endpoint in _endpoints) {
      final Result<PullOutcome> result = await endpoint.pull(null);
      final PullOutcome? outcome = result.valueOrNull;
      if (outcome == null) {
        // Cloud unreachable or refused. Do not mark bootstrapped, so a later run
        // once the link is up can still restore. Nothing local was changed.
        return Err<InitialSyncOutcome>(result.failureOrNull!);
      }
      applied += outcome.report.applied;
      final DateTime? collectionNewest = outcome.newestUpdatedAt;
      if (collectionNewest != null &&
          (newest == null || collectionNewest.isAfter(newest))) {
        newest = collectionNewest;
      }
    }

    if (newest != null) {
      await _metadata.setPullHighWaterMark(newest);
    }
    await _metadata.markBootstrapped();

    return Ok<InitialSyncOutcome>(
      applied > 0
          ? InitialSyncOutcome.restoredFromCloud
          : InitialSyncOutcome.cloudEmpty,
    );
  }
}

/// A concern that could not complete the bootstrap. Exposed so callers can tell a
/// deferred restore (offline) from a genuine fault.
extension InitialSyncFailure on AppFailure {
  bool get isDeferrableConnectivity => this is NetworkFailure;
}
