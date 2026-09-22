/// Observable summary of synchronisation health.
///
/// Exists so the shell can show an honest indicator, for example "12 bills
/// waiting to upload", without any widget reaching into the outbox or the cloud
/// client itself.
class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.isOnline,
    required this.isSyncing,
    required this.pendingCount,
    this.lastSyncedAt,
    this.lastError,
    this.lastDiagnostic,
  });

  /// State before anything has been observed.
  const SyncStatusSnapshot.initial()
    : isOnline = false,
    isSyncing = false,
    pendingCount = 0,
    lastSyncedAt = null,
    lastError = null,
    lastDiagnostic = null;

  final bool isOnline;

  final bool isSyncing;

  /// Writes still queued in the outbox.
  final int pendingCount;

  /// When the outbox was last fully drained.
  final DateTime? lastSyncedAt;

  /// Message from the most recent failed attempt.
  final String? lastError;

  /// Detailed diagnostic JSON of the most recent failed attempt.
  final String? lastDiagnostic;

  /// True when every local change has reached the cloud.
  bool get isFullySynced => pendingCount == 0 && lastError == null;
}
