import '../../../../core/money/money.dart';
import 'cart_line.dart';

/// The bill being built at the counter: an ordered, immutable list of lines.
///
/// ## Why it is immutable
///
/// Every operation returns a new cart rather than mutating this one. The controller
/// swaps the whole value and notifies once, so a widget can never observe a cart
/// half-way through an edit, and the arithmetic below has no order-of-mutation to
/// reason about.
///
/// The cart holds no repository and no menu row. It is pure data plus exact
/// [Money] arithmetic, which is why it can be tested without a database and why a
/// menu change cannot reach back into it.
///
/// Tax, discounts and settlement are deliberately absent: this type stops at the
/// subtotal.
class Cart {
  Cart(List<CartLine> lines) : lines = List<CartLine>.unmodifiable(lines);

  /// A cart with no lines. The state the screen starts and ends a bill in.
  const Cart.empty() : lines = const <CartLine>[];

  /// Ceiling on a single line's quantity.
  ///
  /// A guard against a held keyboard key or a stuck touch turning one pizza into a
  /// four-figure bill. Well above any real counter order.
  static const int maxLineQuantity = 99;

  /// Lines in the order they were added. Unmodifiable.
  final List<CartLine> lines;

  bool get isEmpty => lines.isEmpty;

  bool get isNotEmpty => lines.isNotEmpty;

  /// Number of distinct configured lines.
  int get lineCount => lines.length;

  /// Total units across every line, for the "3 items" style counter.
  int get itemCount =>
      lines.fold(0, (int total, CartLine line) => total + line.quantity);

  /// Sum of every line total, before discounts and tax. Exact integer paise.
  Money get subtotal => Money.sum(lines.map((CartLine line) => line.lineTotal));

  /// List of individual unit prices for all qualifying medium pizzas.
  /// Explodes lines by quantity so 2 Medium pizzas on one line result in two prices.
  List<Money> get fridayMediumPizzaUnitPrices {
    final List<Money> prices = <Money>[];
    for (final CartLine line in lines) {
      if (line.variantNameSnapshot == 'Medium') {
        for (int i = 0; i < line.quantity; i++) {
          prices.add(line.unitPrice);
        }
      }
    }
    return prices;
  }

  CartLine? lineById(String lineId) {
    for (final CartLine line in lines) {
      if (line.id == lineId) {
        return line;
      }
    }
    return null;
  }

  /// Adds [line], folding it into an existing line of the identical
  /// configuration instead of appending a duplicate.
  ///
  /// Merging is what a cashier expects when the same thing is rung up twice, and it
  /// keeps the printed bill short. `CartLine.hasSameConfiguration` compares the
  /// price snapshots too, so a line added at the old price is never merged into one
  /// added at a new price.
  Cart addLine(CartLine line) {
    final int existing = lines.indexWhere(
      (CartLine candidate) => candidate.hasSameConfiguration(line),
    );

    if (existing == -1) {
      return Cart(<CartLine>[...lines, line]);
    }

    final CartLine merged = lines[existing];
    return _replaceAt(
      existing,
      merged.copyWith(
        quantity: _clampQuantity(merged.quantity + line.quantity),
      ),
    );
  }

  /// Sets the quantity of one line, clamped to 1..[maxLineQuantity].
  ///
  /// Clamping rather than removing at zero: dropping a line the cashier was only
  /// adjusting would be a surprising way to lose it, so removal stays an explicit
  /// action through [removeLine].
  ///
  /// An unknown [lineId] returns this cart unchanged, so a stale tap from a widget
  /// rebuilt mid-edit is harmless.
  Cart withQuantity(String lineId, int quantity) {
    final int index = lines.indexWhere((CartLine line) => line.id == lineId);
    if (index == -1) {
      return this;
    }

    final int clamped = _clampQuantity(quantity);
    if (clamped == lines[index].quantity) {
      return this;
    }
    return _replaceAt(index, lines[index].copyWith(quantity: clamped));
  }

  Cart increaseQuantity(String lineId) {
    final CartLine? line = lineById(lineId);
    return line == null ? this : withQuantity(lineId, line.quantity + 1);
  }

  Cart decreaseQuantity(String lineId) {
    final CartLine? line = lineById(lineId);
    return line == null ? this : withQuantity(lineId, line.quantity - 1);
  }

  Cart removeLine(String lineId) {
    if (lineById(lineId) == null) {
      return this;
    }
    return Cart(lines.where((CartLine line) => line.id != lineId).toList());
  }

  /// Abandons the bill. Returns the empty cart rather than clearing in place.
  Cart cleared() => const Cart.empty();

  Cart _replaceAt(int index, CartLine line) {
    final List<CartLine> updated = List<CartLine>.of(lines);
    updated[index] = line;
    return Cart(updated);
  }

  static int _clampQuantity(int quantity) =>
      quantity.clamp(1, maxLineQuantity).toInt();

  @override
  String toString() =>
      'Cart($lineCount lines, subtotal ${subtotal.toDecimalString()})';
}
