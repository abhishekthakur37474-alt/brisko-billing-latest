import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import 'stock_movement_type.dart';
import 'stock_quantity.dart';

/// One entry in the stock ledger.
///
/// Movements are append-only history. The running balance on [InventoryItem] is a
/// cached total kept in step by the repository, so the ledger remains the record of
/// what happened and the balance can always be rebuilt from it.
class StockMovement implements SyncableEntity {
  const StockMovement({
    required this.id,
    required this.inventoryItemId,
    required this.movementType,
    required this.quantityMilli,
    required this.createdAt,
    required this.updatedAt,
    this.reason,
    this.referenceId,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory StockMovement.fromRow(Map<String, Object?> row) {
    return StockMovement(
      id: row.requireString(SyncColumns.id),
      inventoryItemId: row.requireString('inventoryItemId'),
      movementType: row.requireEnum<StockMovementType>(
        'movementType',
        StockMovementType.values,
        fallback: StockMovementType.adjustment,
      ),
      quantityMilli: row.requireInt('quantityMilli'),
      reason: row.optionalString('reason'),
      referenceId: row.optionalString('referenceId'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  final String inventoryItemId;

  final StockMovementType movementType;

  /// Magnitude in thousandths of the item's unit.
  ///
  /// For purchase, sale and wastage this is unsigned and the direction comes from
  /// [movementType]. For an adjustment it is signed, because a physical count can
  /// correct in either direction.
  final int quantityMilli;

  /// Free-text note, for example `spilled` or `monthly count`.
  final String? reason;

  /// What caused the movement, usually an order id for a sale.
  ///
  /// Untyped and without a foreign key, because a purchase or a manual count
  /// references nothing at all.
  final String? referenceId;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// The signed effect this movement has on the running balance, in thousandths.
  int get signedQuantityMilli {
    final int direction = movementType.direction;
    // An adjustment already carries its own sign.
    return direction == 0 ? quantityMilli : quantityMilli.abs() * direction;
  }

  /// True when settlement wrote this row from a configured recipe. Its
  /// [referenceId] is the settled order id.
  bool get isSale => movementType == StockMovementType.sale;

  /// The effect on the balance, always signed, for example `-0.15` or `+10`.
  ///
  /// Explicitly signed even when positive, because a stock ledger read down a column
  /// is only legible if every row states its direction.
  String get signedQuantityDisplay {
    final int signed = signedQuantityMilli;
    final String rendered = StockQuantity.format(signed);
    return signed < 0 ? rendered : '+$rendered';
  }

  StockMovement copyWith({
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return StockMovement(
      id: id,
      inventoryItemId: inventoryItemId,
      movementType: movementType,
      quantityMilli: quantityMilli,
      reason: reason,
      referenceId: referenceId,
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
      'inventoryItemId': inventoryItemId,
      'movementType': movementType.name,
      'quantityMilli': quantityMilli,
      'reason': reason,
      'referenceId': referenceId,
    };
  }
}
