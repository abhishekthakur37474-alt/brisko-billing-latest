import '../../../../core/money/money.dart';
import '../../../menu/domain/models/menu_item_option.dart';
import '../../../menu/domain/models/menu_option_type.dart';

/// A customisation as it was chosen on a cart line, with its price copied in.
///
/// ## Why this is not just a `MenuItemOption`
///
/// A `MenuItemOption` is a live menu row. Holding one on a cart line would mean the
/// line's price is really a pointer into the menu, and re-pricing Extra Cheese
/// mid-shift would silently change the amount already quoted to a customer standing
/// at the counter.
///
/// So the name and the price are copied here at the moment of selection.
/// [optionId] is kept as a back-reference for reporting only, never as the source of
/// the price. This mirrors how `OrderItemOption` stores a sold line, which is what
/// this becomes at checkout.
class CartLineOption {
  const CartLineOption({
    required this.optionId,
    required this.nameSnapshot,
    required this.optionType,
    required this.priceSnapshot,
  });

  /// Copies the values that matter from a menu row.
  ///
  /// The only supported way to build one, so a caller cannot construct a line
  /// option with a price it invented or read from a formatted string.
  factory CartLineOption.fromMenuOption(MenuItemOption option) {
    return CartLineOption(
      optionId: option.id,
      nameSnapshot: option.name,
      optionType: option.optionType,
      priceSnapshot: option.price,
    );
  }

  /// Reporting back-reference to the menu row this came from.
  final String optionId;

  /// Option name exactly as it appeared when chosen, for example `Extra Cheese`.
  /// Never carries a size; the size lives on the line's variant snapshot.
  final String nameSnapshot;

  /// Kept so the line can be grouped and displayed without asking the menu again.
  final MenuOptionType optionType;

  /// Amount this option adds to one unit of the line, as priced when chosen.
  final Money priceSnapshot;

  /// Value equality across every snapshot, including the price.
  ///
  /// Used to decide whether two cart lines are the same configuration. Comparing
  /// the price as well as the id means a line added before a price change never
  /// merges into one added after it.
  @override
  bool operator ==(Object other) {
    return other is CartLineOption &&
        other.optionId == optionId &&
        other.nameSnapshot == nameSnapshot &&
        other.optionType == optionType &&
        other.priceSnapshot == priceSnapshot;
  }

  @override
  int get hashCode =>
      Object.hash(optionId, nameSnapshot, optionType, priceSnapshot);

  @override
  String toString() =>
      'CartLineOption($nameSnapshot, ${priceSnapshot.toDecimalString()})';
}
