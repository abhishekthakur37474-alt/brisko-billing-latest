import 'sync_state.dart';

/// Contract every persisted domain entity implements so that it can round-trip
/// between local storage and the cloud.
///
/// The four members below are the minimum the synchronisation engine needs to
/// work generically, without knowing anything about bills, orders, menu items or
/// customers:
///
/// * [id] is generated on the device, so a record created offline keeps the same
///   identity forever.
/// * [updatedAt] is the conflict-resolution key. The policy is last-write-wins
///   by `updatedAt`; with a single billing terminal, genuine conflicts are only
///   possible between this terminal and an administrative edit made in the
///   cloud console.
/// * [syncState] tracks cloud acknowledgement only. It never affects whether a
///   bill can be created, printed or paid.
/// * [isDeleted] makes deletion a soft, syncable operation. A record removed
///   while offline must still be able to tell the cloud it was removed, which is
///   impossible if the row is physically gone.
abstract interface class SyncableEntity {
  String get id;

  DateTime get updatedAt;

  SyncState get syncState;

  bool get isDeleted;

  /// Serialises the entity for storage and for transport to the cloud.
  Map<String, dynamic> toMap();
}
