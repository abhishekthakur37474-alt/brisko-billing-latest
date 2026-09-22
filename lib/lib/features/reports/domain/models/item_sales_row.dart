import '../../../../core/money/money.dart';

/// One line of the item-wise sales report: what was sold, how much of it, and for how
/// much.
///
/// ## Where the name comes from
///
/// The `itemNameSnapshot` and `variantNameSnapshot` written on the bill line, not the
/// menu. This is the whole reason the report is trustworthy: renaming "Farmhouse" to
/// "Farmhouse Special" today does not retitle last month's sales, and a product deleted
/// from the menu still appears in the month it was sold in. A report that joined back to
/// `menu_items` would lose both.
///
/// ## Why the size is part of the identity
///
/// Rows are grouped by name *and* size, so a pizza sold in three sizes is three lines.
/// The size is what was priced, so grouping it away would produce a single "Farmhouse"
/// line whose amount divided by its quantity is a price that was never charged for
/// anything.
class ItemSalesRow {
  const ItemSalesRow({
    required this.itemName,
    required this.quantitySold,
    required this.salesAmount,
    this.variantName,
  });

  /// Product name as it was when sold.
  final String itemName;

  /// Size name as it was when sold, or `null` for a product with a single price.
  final String? variantName;

  /// Units sold across the range, summed from the stored line quantities.
  final int quantitySold;

  /// What those units were charged, summed from the stored line totals.
  ///
  /// A line total includes anything its customisations added, because that is what the
  /// customer paid for the line. See `BillSettlement`.
  final Money salesAmount;

  /// Name as it appeared on the bill, for example `Farmhouse (Medium)`.
  ///
  /// Built the same way as `OrderItem.displayName`, so an item reads identically on a
  /// report and on the bill it came from.
  String get displayName =>
      variantName == null ? itemName : '$itemName ($variantName)';

  @override
  String toString() =>
      'ItemSalesRow($displayName x$quantitySold, '
      '${salesAmount.toDecimalString()})';
}
