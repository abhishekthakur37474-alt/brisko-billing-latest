/// Where a locally stored record stands relative to the cloud copy.
///
/// Local storage is always the source of truth for writes. A bill is saved
/// locally and considered complete the moment it is created, whether or not the
/// internet is available. This enum only records how far the cloud has caught
/// up, so it must never gate billing behaviour.
enum SyncState {
  /// Written locally, not yet accepted by the cloud. The record is queued in the
  /// outbox.
  pending,

  /// The cloud has acknowledged this exact version of the record.
  synced,

  /// Pushing failed repeatedly. Needs attention but the local record is intact
  /// and still valid.
  failed;

  bool get needsPush => this != SyncState.synced;
}
