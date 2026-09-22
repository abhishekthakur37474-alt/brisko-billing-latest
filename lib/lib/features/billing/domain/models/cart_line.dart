import '../../../../core/money/money.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_option.dart';
import '../../../menu/domain/models/menu_item_variant.dart';
import 'cart_line_option.dart';

/// One configured line on the bill being built.
///
/// ## Snapshots, not references
///
/// Everything needed to price and print this line is copied onto it: the item name,
/// the size name, the base price and every chosen option's price. After
/// construction the line never reads the menu again.
///
/// That is the whole point. A cart line is a promise made to the customer at the
/// counter. If the line held only ids, then an owner editing the menu on another
/// terminal, or a sync arriving from the cloud, would change the amount the customer
/// was just quoted. Because the values are captured, the quote is stable, and the
/// line converts to an `OrderItem` at checkout without recalculating anything.
///
/// [menuItemId] and [variantId] are retained purely as reporting back-references.
///
/// ## Money
///
/// Every amount is a [Money], so the arithmetic is exact integer paise. There is no
/// `double` anywhere in the pricing path and no total is ever derived from a
/// formatted string.
class CartLine {
  CartLine({
    required this.id,
    required this.menuItemId,
    required this.itemNameSnapshot,
    required this.basePriceSnapshot,
    required this.quantity,
    this.variantId,
    this.variantNameSnapshot,
    List<CartLineOption> options = const <CartLineOption>[],
  }) : options = List<CartLineOption>.unmodifiable(options) {
    if (quantity < 1) {
      throw ArgumentError.value(
        quantity,
        'quantity',
        'A cart line must hold at least one unit',
      );
    }
  }

  /// Builds a line by copying the snapshots out of the menu entities chosen.
  ///
  /// This is the only construction path the billing layer uses, so a line can never
  /// be assembled with a price the caller made up. When [variant] is supplied its
  /// price is the base, because a variant price is absolute rather than a
  /// difference; otherwise the item's own price applies.
  factory CartLine.fromSelection({
    required String id,
    required MenuItem item,
    MenuItemVariant? variant,
    Iterable<MenuItemOption> options = const <MenuItemOption>[],
    int quantity = 1,
  }) {
    return CartLine(
      id: id,
      menuItemId: item.id,
      itemNameSnapshot: item.name,
      variantId: variant?.id,
      variantNameSnapshot: variant?.name,
      basePriceSnapshot: variant?.price ?? item.basePrice,
      options: options.map(CartLineOption.fromMenuOption).toList(),
      quantity: quantity,
    );
  }

  /// Identifies this line for the lifetime of the cart.
  ///
  /// Needed because the same product at the same size can legitimately appear twice
  /// with different customisations, so nothing else on the line is unique.
  final String id;

  /// Reporting back-reference. Never the source of the name or price.
  final String menuItemId;

  /// Reporting back-reference to the size chosen, or `null` for a single-price item.
  final String? variantId;

  /// Product name exactly as it appeared when added.
  final String itemNameSnapshot;

  /// Size name exactly as it appeared when added, or `null` if not size-priced.
  final String? variantNameSnapshot;

  /// Price of one unit before options, as it stood when the line was added.
  final Money basePriceSnapshot;

  /// Chosen customisations with their prices copied in. Unmodifiable.
  final List<CartLineOption> options;

  final int quantity;

  /// True when a size was chosen for this line.
  bool get hasVariant => variantId != null;

  /// What the options add to one unit. Exact.
  Money get optionsTotal =>
      Money.sum(options.map((CartLineOption option) => option.priceSnapshot));

  /// Amount charged for one unit, base plus every chosen option.
  Money get unitPrice => basePriceSnapshot + optionsTotal;

  /// Amount charged for the whole line. Integer multiplication, so doubling the
  /// quantity doubles the total to the paisa.
  Money get lineTotal => unitPrice * quantity;

  /// Name as it should appear on the cart panel and the receipt, for example
  /// `Cheese Pizza (Medium)`.
  String get displayName => variantNameSnapshot == null
      ? itemNameSnapshot
      : '$itemNameSnapshot ($variantNameSnapshot)';

  /// The chosen options as a single line of text, or `null` when there are none.
  String? get optionsSummary => options.isEmpty
      ? null
      : options
            .map((CartLineOption option) => option.nameSnapshot)
            .join(' \u00b7 ');

  CartLine copyWith({int? quantity}) {
    return CartLine(
      id: id,
      menuItemId: menuItemId,
      itemNameSnapshot: itemNameSnapshot,
      variantId: variantId,
      variantNameSnapshot: variantNameSnapshot,
      basePriceSnapshot: basePriceSnapshot,
      options: options,
      quantity: quantity ?? this.quantity,
    );
  }

  /// True when [other] is the same product, size, price and set of options.
  ///
  /// Used to fold a repeat of an identical configuration into the existing line's
  /// quantity, which is what a cashier expects when the same thing is rung up
  /// twice. The prices are part of the comparison, so a line added before a menu
  /// price change stays separate from one added after it rather than being merged
  /// at the wrong amount.
  ///
  /// Option order is ignored, because the two selections are the same order however
  /// the repository happened to sort them.
  bool hasSameConfiguration(CartLine other) {
    return other.menuItemId == menuItemId &&
        other.variantId == variantId &&
        other.basePriceSnapshot == basePriceSnapshot &&
        other.options.length == options.length &&
        other.options.toSet().containsAll(options);
  }

  @override
  String toString() =>
      'CartLine($displayName x$quantity = ${lineTotal.toDecimalString()})';
}
