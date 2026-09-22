import '../../../../core/money/money.dart';
import 'order_item.dart';
import 'order_item_option.dart';

/// One line of a stored bill, together with the customisations on it.
///
/// ## Why the pairing is a type
///
/// Lines and their options are two tables, and every reader of a historical bill needs
/// them joined the same way. Doing that assembly in each screen invites one of them to
/// forget an option row, which would show the customer a line total that does not match
/// what they were charged.
///
/// ## What it is not
///
/// It is not a cart line and it cannot become one. Every value here came out of the
/// `order_items` and `order_item_options` tables, where it was written at the moment of
/// sale. Nothing in this file or its callers consults the menu, so renaming a dish or
/// repricing it tomorrow cannot alter what a bill printed months ago says it sold.
class BillLineSnapshot {
  BillLineSnapshot({
    required this.item,
    List<OrderItemOption> options = const <OrderItemOption>[],
  }) : options = List<OrderItemOption>.unmodifiable(options);

  /// The stored line: name, size, quantity and price as charged.
  final OrderItem item;

  /// The stored customisations, in the order they were added. Unmodifiable.
  final List<OrderItemOption> options;

  /// Name as it appeared on the bill, for example `Farmhouse (Medium)`.
  String get displayName => item.displayName;

  int get quantity => item.quantity;

  /// Price of one unit as charged, including the size.
  Money get unitPrice => item.unitPrice;

  /// Line total as charged. The persisted figure, never recomputed.
  Money get lineTotal => item.totalAmount;

  bool get hasOptions => options.isNotEmpty;

  /// What the customisations added to this line. Exact integer maths.
  Money get optionsTotal =>
      Money.sum(options.map((OrderItemOption option) => option.totalAmount));

  @override
  String toString() =>
      'BillLineSnapshot($displayName x$quantity, ${lineTotal.toDecimalString()})';
}
