import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/money/money.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/domain/models/order_type.dart';
import 'held_bill_status.dart';

/// One entry in the held-bills list: enough to tell two held bills apart, and no lines.
///
/// ## Why the lines are absent
///
/// The list answers "which bill do I want back", and a cashier answers that from the
/// time, the total, the number of items and whose number is on it. Loading every line
/// and every option of every held bill to render a list would be two extra queries for
/// information that is not on screen. The lines are read when a bill is actually
/// resumed, and then they are read whole.
///
/// ## Money
///
/// [subtotal] comes straight out of the `INTEGER` paise column that was written from the
/// held cart's own total. It is the same figure the resumed cart will compute for itself
/// from its lines, because that is where the column's value came from. Nothing here
/// parses a decimal.
class HeldBillSummary {
  const HeldBillSummary({
    required this.id,
    required this.orderType,
    required this.status,
    required this.heldAt,
    required this.lineCount,
    required this.itemCount,
    required this.subtotal,
    this.customerPhone,
    this.notes,
  });

  factory HeldBillSummary.fromRow(Map<String, Object?> row) {
    return HeldBillSummary(
      id: row.requireString(SyncColumns.id),
      orderType: row.requireEnum<OrderType>(
        'orderType',
        OrderType.values,
        fallback: OrderType.takeaway,
      ),
      status: row.requireEnum<HeldBillStatus>(
        'status',
        HeldBillStatus.values,
        fallback: HeldBillStatus.cancelled,
      ),
      customerPhone: row.optionalString('customerPhone'),
      notes: row.optionalString('notes'),
      heldAt: row.requireDateTime(SyncColumns.createdAt),
      lineCount: row.optionalInt('lineCount'),
      itemCount: row.optionalInt('itemCount'),
      // Out of an INTEGER column as an integer. No rounding, no parsing, no double.
      subtotal: Money.fromPaise(row.optionalInt('subtotalPaise')),
    );
  }

  final String id;

  final OrderType orderType;

  final HeldBillStatus status;

  /// The stored digits, or `null` for a walk-in.
  final String? customerPhone;

  final String? notes;

  /// When the bill was put aside. Stored UTC; the list renders it local.
  final DateTime heldAt;

  final int lineCount;

  final int itemCount;

  /// Total of the held lines, as it was when the bill was put aside.
  final Money subtotal;

  bool get hasCustomerPhone =>
      customerPhone != null && customerPhone!.isNotEmpty;

  /// The number grouped for reading off the screen, or `null` for a walk-in.
  String? get customerPhoneDisplay =>
      hasCustomerPhone ? CustomerPhone.forDisplay(customerPhone!) : null;

  bool get isAvailable => status.isAvailable;

  /// `2 lines · 3 items`, the counts a cashier scans the list by.
  String get countsLabel {
    final String lines = lineCount == 1 ? 'line' : 'lines';
    final String items = itemCount == 1 ? 'item' : 'items';
    return '$lineCount $lines \u00b7 $itemCount $items';
  }

  @override
  String toString() =>
      'HeldBillSummary($id, ${status.name}, $countsLabel, '
      '${subtotal.toDecimalString()})';
}
