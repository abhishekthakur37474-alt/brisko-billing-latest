import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';

/// One customisation on a kitchen slip line, for example `Extra Cheese`.
///
/// Carries the name exactly as it was sold. The slip is the instruction the kitchen
/// worked from, so renaming the option on the menu next week must not change what
/// this slip says was asked for.
///
/// No price. The kitchen needs to know what to put on the pizza, not what it added
/// to the bill; the priced record of the same choice is the order item option.
class KotItemOption implements SyncableEntity {
  const KotItemOption({
    required this.id,
    required this.kotItemId,
    required this.optionNameSnapshot,
    required this.createdAt,
    required this.updatedAt,
    this.quantity = 1,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory KotItemOption.fromRow(Map<String, Object?> row) {
    return KotItemOption(
      id: row.requireString(SyncColumns.id),
      kotItemId: row.requireString('kotItemId'),
      optionNameSnapshot: row.requireString('optionNameSnapshot'),
      quantity: row.optionalInt('quantity', fallback: 1),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// The slip line this customisation belongs to.
  final String kotItemId;

  final String optionNameSnapshot;

  /// Portions asked for, carried across from the priced order row so the slip and
  /// the bill cannot disagree about how much extra cheese was sold.
  final int quantity;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  KotItemOption copyWith({
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return KotItemOption(
      id: id,
      kotItemId: kotItemId,
      optionNameSnapshot: optionNameSnapshot,
      quantity: quantity,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      SyncColumns.id: id,
      SyncColumns.createdAt: SqliteValue.fromDateTime(createdAt),
      SyncColumns.updatedAt: SqliteValue.fromDateTime(updatedAt),
      SyncColumns.isDeleted: SqliteValue.fromBool(isDeleted),
      SyncColumns.syncState: syncState.name,
      'kotItemId': kotItemId,
      'optionNameSnapshot': optionNameSnapshot,
      'quantity': quantity,
    };
  }
}
