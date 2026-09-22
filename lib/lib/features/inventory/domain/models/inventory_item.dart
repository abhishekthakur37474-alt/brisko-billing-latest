import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import 'stock_quantity.dart';
import 'stock_unit.dart';

/// A tracked stock item, such as flour or cheese.
///
/// ## Quantity representation
///
/// Quantities are exact integer thousandths of [unit], held in
/// [currentQuantityMilli]. `2.5 kg` is `2500`. See [StockQuantity] for why.
///
/// ## The balance is a cache
///
/// [currentQuantityMilli] is a running total maintained by the repository alongside
/// the `stock_movements` ledger, in the same transaction. The ledger is the record of
/// what happened; this field exists so the inventory screen does not have to sum a
/// year of movements to show a number. Nothing outside the repository may write it,
/// which is why saving an item cannot change it — a balance moves only by recording a
/// movement.
class InventoryItem implements SyncableEntity {
  const InventoryItem({
    required this.id,
    required this.name,
    required this.unit,
    required this.createdAt,
    required this.updatedAt,
    this.currentQuantityMilli = 0,
    this.minimumQuantityMilli = 0,
    this.isActive = true,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory InventoryItem.fromRow(Map<String, Object?> row) {
    return InventoryItem(
      id: row.requireString(SyncColumns.id),
      name: row.requireString('name'),
      unit: StockUnit.read(row.requireString('unit')),
      currentQuantityMilli: row.optionalInt('currentQuantityMilli'),
      minimumQuantityMilli: row.optionalInt('minimumQuantityMilli'),
      isActive: row.requireBool('isActive'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  /// Converts a display quantity such as `2.5` into thousandths.
  ///
  /// Delegates to [StockQuantity.parse], which recipes and movements also use, so
  /// there is one quantity representation across the feature rather than one per
  /// model. Throws [FormatException] on a value with more than three decimals.
  static int parseQuantity(String value) => StockQuantity.parse(value);

  /// Renders thousandths as a trimmed decimal string, for example `2.5`.
  static String formatQuantity(int milli) => StockQuantity.format(milli);

  @override
  final String id;

  final String name;

  /// Unit of measure. A closed set, so a recipe written against this item is
  /// measured in the same thing the shelf is counted in.
  final StockUnit unit;

  /// Running balance, in thousandths of [unit]. Maintained by the repository.
  final int currentQuantityMilli;

  /// Threshold at or below which the item is reported as low, in thousandths.
  /// Zero means the item is not monitored.
  final int minimumQuantityMilli;

  final bool isActive;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// True when the balance has fallen to or below the reorder threshold.
  ///
  /// A threshold of zero means the item is not monitored, rather than meaning
  /// everything with an empty shelf is urgent. Without that, every item the operator
  /// has not set a threshold for would sit permanently in the low-stock list and the
  /// list would stop being read.
  bool get isLow =>
      minimumQuantityMilli > 0 && currentQuantityMilli <= minimumQuantityMilli;

  /// True when the balance is monitored at all.
  bool get isMonitored => minimumQuantityMilli > 0;

  String get currentQuantityDisplay =>
      StockQuantity.format(currentQuantityMilli);

  String get minimumQuantityDisplay =>
      StockQuantity.format(minimumQuantityMilli);

  /// Balance with its unit, for example `2.5 kg`.
  String get currentQuantityWithUnit => unit.describe(currentQuantityDisplay);

  /// Threshold with its unit, for example `1 kg`.
  String get minimumQuantityWithUnit => unit.describe(minimumQuantityDisplay);

  /// True when [milli] can be taken off this item's balance without going negative.
  bool canRemove(int milli) => currentQuantityMilli - milli.abs() >= 0;

  InventoryItem copyWith({
    String? name,
    StockUnit? unit,
    int? currentQuantityMilli,
    int? minimumQuantityMilli,
    bool? isActive,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return InventoryItem(
      id: id,
      name: name ?? this.name,
      unit: unit ?? this.unit,
      currentQuantityMilli: currentQuantityMilli ?? this.currentQuantityMilli,
      minimumQuantityMilli: minimumQuantityMilli ?? this.minimumQuantityMilli,
      isActive: isActive ?? this.isActive,
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
      'name': name,
      'unit': unit.name,
      'currentQuantityMilli': currentQuantityMilli,
      'minimumQuantityMilli': minimumQuantityMilli,
      'isActive': SqliteValue.fromBool(isActive),
    };
  }
}
