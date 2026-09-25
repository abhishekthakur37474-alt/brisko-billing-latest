import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import 'order_status.dart';
import 'order_type.dart';

/// The header of a bill.
///
/// The monetary fields are stored, not derived. They are computed once when the
/// bill is settled and then persisted, so a reprint or a report reproduces the
/// original document exactly even if tax rates or menu prices change afterwards.
/// Nothing recalculates a historical total from the menu tables.
///
/// ## Why the rate and the discount rule are here too
///
/// [taxAmount] alone cannot say what rate produced it, and [discountAmount] alone cannot
/// say whether the customer was given ten percent or a hundred rupees. Both facts are
/// printed on the bill the customer keeps, so both are stored beside the amounts they
/// explain: [taxRateBasisPoints] is the rate in force at settlement, copied in, and
/// [discountType] with [discountValue] is the rule that was applied.
///
/// Copied, not looked up. The GST rate lives in Settings and settings change; a bill that
/// read today's rate would restate itself the day the outlet moved slab, and the reprint
/// would disagree with the paper in the customer's hand. See `M009BillTaxAndDiscount`.
///
/// A bill written before either column existed reads back as zero rate and no discount
/// rule, which is exactly what those bills charged.
///
/// There is no table or seat reference. The outlet serves dine-in customers but
/// does not run digital table management, so there is nothing to point at.
class Order implements SyncableEntity {
  const Order({
    required this.id,
    required this.orderNumber,
    required this.orderType,
    required this.status,
    required this.subtotal,
    required this.discountAmount,
    required this.taxAmount,
    required this.totalAmount,
    required this.createdAt,
    required this.updatedAt,
    this.taxRateBasisPoints = 0,
    this.discountType,
    this.discountValue = 0,
    this.customerId,
    this.customerName,
    this.customerAddress,
    this.notes,
    this.cancelledAt,
    this.cancellationReason,
    this.authorizedBy,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory Order.fromRow(Map<String, Object?> row) {
    return Order(
      id: row.requireString(SyncColumns.id),
      orderNumber: row.requireString('orderNumber'),
      orderType: row.requireEnum<OrderType>(
        'orderType',
        OrderType.values,
        fallback: OrderType.takeaway,
      ),
      status: row.requireEnum<OrderStatus>(
        'status',
        OrderStatus.values,
        fallback: OrderStatus.draft,
      ),
      customerId: row.optionalString('customerId'),
      customerName: row.optionalString('customerName'),
      customerAddress: row.optionalString('customerAddress'),
      subtotal: Money.fromPaise(row.requireInt('subtotalPaise')),
      discountAmount: Money.fromPaise(row.requireInt('discountAmountPaise')),
      taxAmount: Money.fromPaise(row.requireInt('taxAmountPaise')),
      totalAmount: Money.fromPaise(row.requireInt('totalAmountPaise')),
      // Optional reads, falling back to zero and null. A bill settled before
      // `M009BillTaxAndDiscount` has no rate and no rule to read, and it charged neither,
      // so the fallback states the truth about it rather than standing in for an unknown.
      taxRateBasisPoints: row.optionalInt('taxRateBasisPoints'),
      discountType: row.optionalString('discountType'),
      discountValue: row.optionalInt('discountValue'),
      notes: row.optionalString('notes'),
      cancelledAt: row.optionalDateTime('cancelledAt'),
      cancellationReason: row.optionalString('cancellationReason'),
      authorizedBy: row.optionalString('authorizedBy'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// Human-readable number printed on the bill. Unique on this terminal.
  final String orderNumber;

  final OrderType orderType;

  final OrderStatus status;

  /// `null` for a walk-in who did not give a phone number.
  final String? customerId;

  /// The name taken with this bill, or `null` when none was given.
  ///
  /// Stored on the order rather than only on a customer record, because a name can
  /// be taken without a phone and a customer record is keyed by phone. A blank or
  /// missing value is a walk-in; a stored value is what the cashier typed, for any
  /// order type.
  final String? customerName;

  /// Delivery address taken with this bill, or `null` when none was given.
  ///
  /// Stored on the order rather than on a customer record, because an address is a
  /// fact about *this* sale (where this pizza went), not a standing profile. Required
  /// at checkout for [OrderType.delivery]; optional for every other type. A reprint
  /// and a cloud restore both read this snapshot.
  final String? customerAddress;

  /// Sum of line totals before bill-level discount and tax.
  final Money subtotal;

  final Money discountAmount;

  final Money taxAmount;

  /// Amount payable. Persisted as calculated at settlement time.
  final Money totalAmount;

  /// The combined GST rate this bill was charged at, in basis points where 10000 is 100%.
  ///
  /// Zero on a bill that charged no GST, including every bill settled before a rate could
  /// be configured. Never read from Settings — this is the rate that was in force when the
  /// money was taken.
  final int taxRateBasisPoints;

  /// The `BillDiscountType` name of the rule that produced [discountAmount], or `null`
  /// when no bill-level discount rule was recorded.
  final String? discountType;

  /// The rule's magnitude in hundredths: basis points for a percentage, paise for a flat
  /// amount. Meaningless without [discountType].
  final int discountValue;

  final String? notes;

  /// When this bill was cancelled, if its status is [OrderStatus.cancelled].
  final DateTime? cancelledAt;

  /// The reason provided for cancellation, if any.
  final String? cancellationReason;

  /// The identifier of the manager who authorized the cancellation.
  final String? authorizedBy;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// What GST was charged on: [subtotal] less [discountAmount], as it was settled.
  ///
  /// Derived from two stored figures rather than stored itself, so it cannot disagree with
  /// them.
  Money get taxableAmount => subtotal - discountAmount;

  /// True when this bill was given a bill-level discount.
  bool get hasDiscount => !discountAmount.isZero;

  /// True when this bill carries a tax line.
  bool get hasTax => !taxAmount.isZero;

  Order copyWith({
    String? orderNumber,
    OrderType? orderType,
    OrderStatus? status,
    String? customerId,
    String? customerName,
    String? customerAddress,
    Money? subtotal,
    Money? discountAmount,
    Money? taxAmount,
    Money? totalAmount,
    int? taxRateBasisPoints,
    String? discountType,
    int? discountValue,
    String? notes,
    DateTime? cancelledAt,
    String? cancellationReason,
    String? authorizedBy,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return Order(
      id: id,
      orderNumber: orderNumber ?? this.orderNumber,
      orderType: orderType ?? this.orderType,
      status: status ?? this.status,
      customerId: customerId ?? this.customerId,
      customerName: customerName ?? this.customerName,
      customerAddress: customerAddress ?? this.customerAddress,
      subtotal: subtotal ?? this.subtotal,
      discountAmount: discountAmount ?? this.discountAmount,
      taxAmount: taxAmount ?? this.taxAmount,
      totalAmount: totalAmount ?? this.totalAmount,
      taxRateBasisPoints: taxRateBasisPoints ?? this.taxRateBasisPoints,
      discountType: discountType ?? this.discountType,
      discountValue: discountValue ?? this.discountValue,
      notes: notes ?? this.notes,
      cancelledAt: cancelledAt ?? this.cancelledAt,
      cancellationReason: cancellationReason ?? this.cancellationReason,
      authorizedBy: authorizedBy ?? this.authorizedBy,
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
      'orderNumber': orderNumber,
      'orderType': orderType.name,
      'status': status.name,
      'customerId': customerId,
      'customerName': customerName,
      'customerAddress': customerAddress,
      'subtotalPaise': subtotal.paise,
      'discountAmountPaise': discountAmount.paise,
      'taxAmountPaise': taxAmount.paise,
      'totalAmountPaise': totalAmount.paise,
      'taxRateBasisPoints': taxRateBasisPoints,
      'discountType': discountType,
      'discountValue': discountValue,
      'notes': notes,
      'cancelledAt': cancelledAt == null ? null : SqliteValue.fromDateTime(cancelledAt!),
      'cancellationReason': cancellationReason,
      'authorizedBy': authorizedBy,
    };
  }
}
