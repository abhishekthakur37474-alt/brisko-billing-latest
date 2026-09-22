import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import '../../../orders/domain/models/order_type.dart';
import 'cart.dart';
import 'cart_line.dart';
import 'held_bill_status.dart';

/// A bill put aside at the counter, with the cart it was put aside as.
///
/// ## What this is, and what it is not
///
/// It is a [Cart] that has been written down, plus the three things the cashier had
/// decided about it: how the order is being taken, whose number is on it, and any note.
/// It is not an order. There is no order number, no payment, no kitchen slip and no
/// customer record, because holding a bill commits to nothing.
///
/// ## The cart is the snapshot
///
/// [cart] is rebuilt from the stored line and option rows, never from the menu. Every
/// name and every price on it is the value that was showing when the bill was held, so
/// a bill resumed after a repricing restores what the cashier put aside rather than
/// what the item costs now, and a bill whose product has since been withdrawn resumes
/// exactly as it was held.
///
/// ## Money
///
/// [subtotal] is derived from the cart by the same [Money] arithmetic the live cart
/// uses, so a resumed bill and the bill that was held cannot disagree about the total.
/// The stored `subtotalPaise` column is written from this and read only by
/// `HeldBillSummary`, which renders the list without loading any lines.
class HeldBill implements SyncableEntity {
  HeldBill({
    required this.id,
    required this.cart,
    required this.orderType,
    required this.status,
    required this.heldAt,
    required this.updatedAt,
    this.customerPhone,
    this.notes,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  /// Rebuilds a held bill from its header row and the cart read from its lines.
  ///
  /// The cart is passed in rather than read here, because a header alone cannot
  /// describe a bill and this model will not pretend otherwise. Nothing in this factory
  /// reads an amount out of the header: the total comes from the cart.
  factory HeldBill.fromRow(Map<String, Object?> row, {required Cart cart}) {
    return HeldBill(
      id: row.requireString(SyncColumns.id),
      cart: cart,
      orderType: row.requireEnum<OrderType>(
        'orderType',
        OrderType.values,
        fallback: OrderType.takeaway,
      ),
      status: row.requireEnum<HeldBillStatus>(
        'status',
        HeldBillStatus.values,
        // A status written by a newer build reads as closed rather than as available.
        // Handing a cashier a bill this build cannot account for is the one outcome
        // worth avoiding; a held bill that cannot be resumed is merely inconvenient.
        fallback: HeldBillStatus.cancelled,
      ),
      customerPhone: row.optionalString('customerPhone'),
      notes: row.optionalString('notes'),
      heldAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// The cart exactly as it was held. Unmodifiable, like every cart.
  final Cart cart;

  /// How the order was being taken when it was put aside.
  final OrderType orderType;

  /// The customer's number as the cashier had it, or `null` for a walk-in.
  ///
  /// The digits, not a customer id, and deliberately so: holding a bill must not create
  /// a customer. Settlement resolves this into a record if and when the bill is paid
  /// for, in the same transaction as the money.
  final String? customerPhone;

  final String? notes;

  final HeldBillStatus status;

  /// When the bill was put aside. The `createdAt` of the row, named for what it means.
  final DateTime heldAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// Sum of the held lines, in exact integer paise. Derived, never re-read.
  Money get subtotal => cart.subtotal;

  /// Distinct configured lines on the held bill.
  int get lineCount => cart.lineCount;

  /// Total units across every held line.
  int get itemCount => cart.itemCount;

  bool get hasLines => cart.isNotEmpty;

  /// True when this bill is still there to be resumed or cancelled.
  bool get isAvailable => status.isAvailable && !isDeleted;

  /// True when a number was taken before the bill was put aside.
  bool get hasCustomerPhone =>
      customerPhone != null && customerPhone!.isNotEmpty;

  /// The lines, for a caller that wants them without reaching through the cart.
  List<CartLine> get lines => cart.lines;

  HeldBill copyWith({
    HeldBillStatus? status,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return HeldBill(
      id: id,
      cart: cart,
      orderType: orderType,
      customerPhone: customerPhone,
      notes: notes,
      status: status ?? this.status,
      heldAt: heldAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  /// The header row. The lines are written by the repository from [cart].
  ///
  /// `subtotalPaise`, `lineCount` and `itemCount` are copied off the cart so the
  /// held-bills list can be rendered from headers alone. They are written once, with
  /// the lines they describe, inside the same transaction.
  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      SyncColumns.id: id,
      SyncColumns.createdAt: SqliteValue.fromDateTime(heldAt),
      SyncColumns.updatedAt: SqliteValue.fromDateTime(updatedAt),
      SyncColumns.isDeleted: SqliteValue.fromBool(isDeleted),
      SyncColumns.syncState: syncState.name,
      'orderType': orderType.name,
      'customerPhone': customerPhone,
      'notes': notes,
      'status': status.name,
      'subtotalPaise': subtotal.paise,
      'lineCount': lineCount,
      'itemCount': itemCount,
    };
  }

  @override
  String toString() =>
      'HeldBill($id, ${status.name}, $lineCount lines, '
      '${subtotal.toDecimalString()})';
}
