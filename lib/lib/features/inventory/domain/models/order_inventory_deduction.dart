import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import 'inventory_deduction_status.dart';

/// What happened when a settled bill's stock was taken off the shelf.
///
/// ## Why this record exists at all
///
/// Two reasons, and both are about honesty.
///
/// The first is idempotency. Deduction runs after the money is committed, so it can be
/// retried — by an operator clearing a shortfall, or by the same bill being processed
/// twice. One row per bill, enforced by a unique index on [orderId], is what makes a
/// retry safe: a bill already marked [InventoryDeductionStatus.deducted] cannot deduct
/// again, so three attempts take stock off once.
///
/// The second is that the alternative is silence. If deduction failed and nothing
/// recorded it, the inventory screen would show balances that quietly disagreed with
/// what had been sold, and nobody would know which figures to trust. A failure is
/// written down, named, and surfaced for the operator to resolve.
///
/// ## Why it is not part of the bill
///
/// A settled bill is a financial record and it is finished. This is a stock operation
/// that happens to be about that bill, may fail on its own, and may still be pending.
/// Merging the two would mean a bill's row changed state because a shelf was short,
/// and a bill that reads "incomplete" for a stock reason is a bill a cashier would
/// try to take payment for again.
class OrderInventoryDeduction implements SyncableEntity {
  const OrderInventoryDeduction({
    required this.id,
    required this.orderId,
    required this.orderNumberSnapshot,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.attemptCount = 0,
    this.movementCount = 0,
    this.unconfiguredItems = const <String>[],
    this.failureMessage,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory OrderInventoryDeduction.fromRow(Map<String, Object?> row) {
    return OrderInventoryDeduction(
      id: row.requireString(SyncColumns.id),
      orderId: row.requireString('orderId'),
      orderNumberSnapshot: row.requireString('orderNumberSnapshot'),
      status: row.requireEnum<InventoryDeductionStatus>(
        'status',
        InventoryDeductionStatus.values,
        // A row written by a newer build reads as unfinished rather than as done.
        // Claiming stock was deducted when this build cannot tell is the one
        // mistake worth avoiding here; an unnecessary retry is idempotent anyway.
        fallback: InventoryDeductionStatus.failed,
      ),
      attemptCount: row.optionalInt('attemptCount'),
      movementCount: row.optionalInt('movementCount'),
      unconfiguredItems: decodeItems(row.optionalString('unconfiguredItems')),
      failureMessage: row.optionalString('failureMessage'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  /// Separator for the stored list of unconfigured item names.
  ///
  /// A newline, because it cannot occur in a menu item name typed into a single-line
  /// field, so no name can split itself in two.
  static const String _itemSeparator = '\n';

  /// Reads the stored unconfigured-item list.
  static List<String> decodeItems(String? stored) {
    if (stored == null || stored.isEmpty) {
      return const <String>[];
    }
    return stored
        .split(_itemSeparator)
        .where((String name) => name.isNotEmpty)
        .toList(growable: false);
  }

  /// Writes the unconfigured-item list, or `null` when there is nothing to record.
  static String? encodeItems(List<String> names) =>
      names.isEmpty ? null : names.join(_itemSeparator);

  @override
  final String id;

  /// The settled bill this deduction is for. Unique across the table.
  final String orderId;

  /// The bill number as it was printed. A snapshot, so the operator-facing list of
  /// outstanding deductions names bills without joining the orders table.
  final String orderNumberSnapshot;

  final InventoryDeductionStatus status;

  /// How many times deduction has been attempted for this bill, successful attempt
  /// included. Shown to the operator, so a bill that keeps failing is visible as
  /// such rather than looking like a fresh problem each time.
  final int attemptCount;

  /// Stock movements written by the successful attempt.
  ///
  /// Zero with a [InventoryDeductionStatus.deducted] status is a real and common
  /// state: the bill was processed and no line on it had a recipe.
  final int movementCount;

  /// Display names of the sold lines that had no recipe, as they appeared on the
  /// bill.
  ///
  /// A snapshot rather than a live query, because it answers "what did this bill fail
  /// to account for", and that must not change retroactively when a recipe is
  /// configured next week.
  final List<String> unconfiguredItems;

  /// Why the attempt failed, in operator-facing language. `null` on success.
  final String? failureMessage;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  bool get isComplete => status.isComplete;

  bool get isFailed => status.isFailed;

  /// True when something was sold that inventory could not account for.
  bool get hasUnconfiguredItems => unconfiguredItems.isNotEmpty;

  /// True when nothing at all was deducted, whether because it failed or because no
  /// line had a recipe.
  bool get deductedNothing => movementCount == 0;

  /// The sentence shown to the operator, or `null` when there is nothing to report.
  ///
  /// Never phrased as a problem with the sale. By the time this can be read the money
  /// is collected, the bill is written and the kitchen has its slip; what is
  /// outstanding is a stock figure, and the wording says so.
  String? get operatorMessage {
    if (isFailed) {
      final String reason = failureMessage ?? 'The stock could not be updated.';
      return 'Bill $orderNumberSnapshot is settled. Stock was not deducted: '
          '$reason';
    }
    if (hasUnconfiguredItems) {
      return 'No recipe configured for ${unconfiguredItems.join(', ')}, so no '
          'stock was deducted for it.';
    }
    return null;
  }

  OrderInventoryDeduction copyWith({
    InventoryDeductionStatus? status,
    int? attemptCount,
    int? movementCount,
    List<String>? unconfiguredItems,
    String? failureMessage,
    DateTime? updatedAt,
    SyncState? syncState,
  }) {
    return OrderInventoryDeduction(
      id: id,
      orderId: orderId,
      orderNumberSnapshot: orderNumberSnapshot,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      movementCount: movementCount ?? this.movementCount,
      unconfiguredItems: unconfiguredItems ?? this.unconfiguredItems,
      failureMessage: failureMessage,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted,
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
      'orderId': orderId,
      'orderNumberSnapshot': orderNumberSnapshot,
      'status': status.name,
      'attemptCount': attemptCount,
      'movementCount': movementCount,
      'unconfiguredCount': unconfiguredItems.length,
      'unconfiguredItems': encodeItems(unconfiguredItems),
      'failureMessage': failureMessage,
    };
  }

  @override
  String toString() =>
      'OrderInventoryDeduction($orderNumberSnapshot, ${status.name}, '
      '$movementCount movements)';
}
