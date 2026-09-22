import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_option_type.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

/// Exercises the cart model on its own.
///
/// No database and no menu here: this file is about the arithmetic and the snapshot
/// guarantee, which have to hold for any values at all, including the sub-rupee
/// amounts the printed menu happens not to contain. The synthetic fixtures make it
/// obvious that no real product is being asserted about. The billing controller tests
/// cover the same rules against the actual seeded menu.
void main() {
  MenuItem itemPriced(String price) =>
      Fixtures.menuItem(categoryId: 'cat-test', basePrice: price);

  MenuItemVariant variantPriced(String menuItemId, String price) =>
      Fixtures.variant(menuItemId: menuItemId, price: price);

  MenuItemOption optionPriced(String name, String price) =>
      Fixtures.option(name: name, price: price);

  CartLine lineOf({
    required String id,
    required MenuItem item,
    MenuItemVariant? variant,
    List<MenuItemOption> options = const <MenuItemOption>[],
    int quantity = 1,
  }) {
    return CartLine.fromSelection(
      id: id,
      item: item,
      variant: variant,
      options: options,
      quantity: quantity,
    );
  }

  group('CartLine pricing', () {
    test('unit price is the base plus every chosen option', () {
      final MenuItem item = itemPriced('130.00');
      final MenuItemVariant medium = variantPriced(item.id, '250.00');

      final CartLine line = lineOf(
        id: 'line-1',
        item: item,
        variant: medium,
        options: <MenuItemOption>[
          optionPriced('Extra Cheese', '70.00'),
          optionPriced('Extra Toppings', '50.00'),
        ],
      );

      expect(line.basePriceSnapshot, Money.parse('250'));
      expect(line.optionsTotal, Money.parse('120'));
      expect(line.unitPrice, Money.parse('370'));
      expect(line.lineTotal, Money.parse('370'));
    });

    test(
      'a variant price replaces the base price rather than adding to it',
      () {
        final MenuItem item = itemPriced('130.00');
        final MenuItemVariant large = variantPriced(item.id, '400.00');

        final CartLine line = lineOf(id: 'line-1', item: item, variant: large);

        expect(line.unitPrice, Money.parse('400'));
      },
    );

    test('an item with no variant is priced from the item itself', () {
      final CartLine line = lineOf(id: 'line-1', item: itemPriced('70.00'));

      expect(line.hasVariant, isFalse);
      expect(line.variantId, isNull);
      expect(line.variantNameSnapshot, isNull);
      expect(line.unitPrice, Money.parse('70'));
    });

    test('the line total is exact at sub-rupee prices', () {
      // Nothing on the printed menu is priced in paise, but a discount or a future
      // price change can be, and the arithmetic must not drift.
      final MenuItem item = itemPriced('249.99');
      final CartLine line = lineOf(
        id: 'line-1',
        item: item,
        options: <MenuItemOption>[optionPriced('Dip', '0.01')],
        quantity: 3,
      );

      expect(line.unitPrice, Money.parse('250.00'));
      expect(line.unitPrice.paise, 25000);
      expect(line.lineTotal, Money.parse('750.00'));
      expect(line.lineTotal.paise, 75000);
    });

    test('a hundredth of a rupee is never lost across many units', () {
      final CartLine line = lineOf(
        id: 'line-1',
        item: itemPriced('0.01'),
        quantity: 99,
      );

      expect(line.lineTotal.paise, 99);
    });

    test('the display name includes the size when there is one', () {
      final MenuItem item = Fixtures.menuItem(
        categoryId: 'cat-test',
        name: 'Test Pizza',
      );
      final MenuItemVariant medium = Fixtures.variant(
        menuItemId: item.id,
        name: 'Medium',
      );

      expect(lineOf(id: 'l', item: item).displayName, 'Test Pizza');
      expect(
        lineOf(id: 'l', item: item, variant: medium).displayName,
        'Test Pizza (Medium)',
      );
    });

    test('a line cannot hold less than one unit', () {
      expect(
        () => CartLine(
          id: 'line-1',
          menuItemId: 'item-1',
          itemNameSnapshot: 'Test Pizza',
          basePriceSnapshot: Money.parse('100'),
          quantity: 0,
        ),
        throwsArgumentError,
      );
    });

    test('the option list cannot be modified after construction', () {
      final CartLine line = lineOf(
        id: 'line-1',
        item: itemPriced('100.00'),
        options: <MenuItemOption>[optionPriced('Ketchup', '10.00')],
      );

      expect(
        () => line.options.add(
          const CartLineOption(
            optionId: 'x',
            nameSnapshot: 'x',
            optionType: MenuOptionType.addOn,
            priceSnapshot: Money.zero,
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('CartLine snapshots', () {
    test('the line keeps the names and prices it was built with', () {
      final MenuItem item = Fixtures.menuItem(
        categoryId: 'cat-test',
        name: 'Test Pizza',
        basePrice: '130.00',
      );
      final MenuItemVariant medium = Fixtures.variant(
        menuItemId: item.id,
        name: 'Medium',
        price: '250.00',
      );
      final MenuItemOption extraCheese = optionPriced('Extra Cheese', '70.00');

      final CartLine line = lineOf(
        id: 'line-1',
        item: item,
        variant: medium,
        options: <MenuItemOption>[extraCheese],
      );

      expect(line.menuItemId, item.id);
      expect(line.variantId, medium.id);
      expect(line.itemNameSnapshot, 'Test Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.basePriceSnapshot, Money.parse('250'));
      expect(line.options.single.optionId, extraCheese.id);
      expect(line.options.single.nameSnapshot, 'Extra Cheese');
      expect(line.options.single.priceSnapshot, Money.parse('70'));
    });

    test('re-pricing the menu objects afterwards does not move the line', () {
      final MenuItem item = itemPriced('130.00');
      final MenuItemVariant medium = variantPriced(item.id, '250.00');
      final MenuItemOption extraCheese = optionPriced('Extra Cheese', '70.00');

      final CartLine line = lineOf(
        id: 'line-1',
        item: item,
        variant: medium,
        options: <MenuItemOption>[extraCheese],
      );

      // The menu changes underneath: a price rise and a rename.
      final MenuItem renamed = item.copyWith(name: 'Renamed Pizza');
      final MenuItemVariant repricedSize = medium.copyWith(
        name: 'Regular',
        price: Money.parse('999'),
      );
      final MenuItemOption repricedOption = extraCheese.copyWith(
        price: Money.parse('500'),
      );

      // The menu really did move.
      expect(renamed.name, 'Renamed Pizza');
      expect(repricedSize.price, Money.parse('999'));
      expect(repricedOption.price, Money.parse('500'));

      // The line did not.
      expect(line.itemNameSnapshot, 'Test Pizza');
      expect(line.variantNameSnapshot, 'Medium');
      expect(line.basePriceSnapshot, Money.parse('250'));
      expect(line.options.single.priceSnapshot, Money.parse('70'));
      expect(line.unitPrice, Money.parse('320'));
      expect(line.lineTotal, Money.parse('320'));
    });
  });

  group('Cart', () {
    test('an empty cart has no lines and a zero subtotal', () {
      const Cart cart = Cart.empty();

      expect(cart.isEmpty, isTrue);
      expect(cart.isNotEmpty, isFalse);
      expect(cart.lines, isEmpty);
      expect(cart.lineCount, 0);
      expect(cart.itemCount, 0);
      expect(cart.subtotal, Money.zero);
    });

    test('adding a line puts it in the cart', () {
      final Cart cart = const Cart.empty().addLine(
        lineOf(id: 'line-1', item: itemPriced('250.00')),
      );

      expect(cart.lineCount, 1);
      expect(cart.itemCount, 1);
      expect(cart.subtotal, Money.parse('250'));
    });

    test('the subtotal across several lines is exact', () {
      final Cart cart = const Cart.empty()
          .addLine(
            lineOf(id: 'line-1', item: itemPriced('250.00'), quantity: 2),
          )
          .addLine(lineOf(id: 'line-2', item: itemPriced('70.00')))
          .addLine(
            lineOf(id: 'line-3', item: itemPriced('99.99'), quantity: 3),
          );

      // 500.00 + 70.00 + 299.97
      expect(cart.subtotal, Money.parse('869.97'));
      expect(cart.subtotal.paise, 86997);
      expect(cart.itemCount, 6);
      expect(cart.lineCount, 3);
    });

    test('increasing the quantity from one to two doubles the line', () {
      final Cart cart = const Cart.empty().addLine(
        lineOf(id: 'line-1', item: itemPriced('320.00')),
      );

      final Cart increased = cart.increaseQuantity('line-1');

      expect(increased.lines.single.quantity, 2);
      expect(increased.lines.single.lineTotal, Money.parse('640'));
      expect(increased.subtotal, Money.parse('640'));
      // The original value is untouched, so no widget can see a half-applied edit.
      expect(cart.subtotal, Money.parse('320'));
    });

    test('decreasing the quantity reduces the line total', () {
      final Cart cart = const Cart.empty()
          .addLine(lineOf(id: 'line-1', item: itemPriced('320.00')))
          .increaseQuantity('line-1')
          .increaseQuantity('line-1');

      expect(cart.lines.single.quantity, 3);

      final Cart decreased = cart.decreaseQuantity('line-1');

      expect(decreased.lines.single.quantity, 2);
      expect(decreased.subtotal, Money.parse('640'));
    });

    test('the quantity floor is one, so a line is never silently lost', () {
      final Cart cart = const Cart.empty()
          .addLine(lineOf(id: 'line-1', item: itemPriced('320.00')))
          .decreaseQuantity('line-1')
          .decreaseQuantity('line-1');

      expect(cart.lineCount, 1);
      expect(cart.lines.single.quantity, 1);
    });

    test('the quantity ceiling guards against a stuck key', () {
      Cart cart = const Cart.empty().addLine(
        lineOf(id: 'line-1', item: itemPriced('10.00')),
      );

      for (int i = 0; i < Cart.maxLineQuantity + 20; i++) {
        cart = cart.increaseQuantity('line-1');
      }

      expect(cart.lines.single.quantity, Cart.maxLineQuantity);
    });

    test('setting a quantity directly is clamped to the allowed range', () {
      final Cart cart = const Cart.empty().addLine(
        lineOf(id: 'line-1', item: itemPriced('10.00')),
      );

      expect(cart.withQuantity('line-1', 0).lines.single.quantity, 1);
      expect(cart.withQuantity('line-1', -5).lines.single.quantity, 1);
      expect(cart.withQuantity('line-1', 4).lines.single.quantity, 4);
      expect(
        cart.withQuantity('line-1', 5000).lines.single.quantity,
        Cart.maxLineQuantity,
      );
    });

    test('removing a line leaves the others and their totals alone', () {
      final Cart cart = const Cart.empty()
          .addLine(lineOf(id: 'line-1', item: itemPriced('250.00')))
          .addLine(lineOf(id: 'line-2', item: itemPriced('70.00')));

      final Cart removed = cart.removeLine('line-1');

      expect(removed.lineCount, 1);
      expect(removed.lines.single.id, 'line-2');
      expect(removed.subtotal, Money.parse('70'));
    });

    test('clearing removes every line', () {
      final Cart cleared = const Cart.empty()
          .addLine(lineOf(id: 'line-1', item: itemPriced('250.00')))
          .addLine(lineOf(id: 'line-2', item: itemPriced('70.00')))
          .cleared();

      expect(cleared.isEmpty, isTrue);
      expect(cleared.lineCount, 0);
      expect(cleared.subtotal, Money.zero);
    });

    test('an unknown line id changes nothing', () {
      final Cart cart = const Cart.empty().addLine(
        lineOf(id: 'line-1', item: itemPriced('250.00')),
      );

      expect(cart.removeLine('nope').subtotal, Money.parse('250'));
      expect(cart.increaseQuantity('nope').lines.single.quantity, 1);
      expect(cart.decreaseQuantity('nope').lines.single.quantity, 1);
      expect(cart.lineById('nope'), isNull);
    });

    test('an identical configuration folds into the existing line', () {
      final MenuItem item = itemPriced('250.00');
      final MenuItemOption extraCheese = optionPriced('Extra Cheese', '70.00');

      final Cart cart = const Cart.empty()
          .addLine(
            lineOf(
              id: 'line-1',
              item: item,
              options: <MenuItemOption>[extraCheese],
            ),
          )
          .addLine(
            lineOf(
              id: 'line-2',
              item: item,
              options: <MenuItemOption>[extraCheese],
            ),
          );

      expect(cart.lineCount, 1);
      expect(cart.lines.single.quantity, 2);
      expect(cart.subtotal, Money.parse('640'));
    });

    test('a different set of options is a separate line', () {
      final MenuItem item = itemPriced('250.00');

      final Cart cart = const Cart.empty()
          .addLine(
            lineOf(
              id: 'line-1',
              item: item,
              options: <MenuItemOption>[optionPriced('Extra Cheese', '70.00')],
            ),
          )
          .addLine(lineOf(id: 'line-2', item: item));

      expect(cart.lineCount, 2);
      expect(cart.subtotal, Money.parse('570'));
    });

    test('a line added at the old price never merges into the new price', () {
      final MenuItem item = itemPriced('250.00');
      final MenuItem repriced = item.copyWith(basePrice: Money.parse('300'));

      final Cart cart = const Cart.empty()
          .addLine(lineOf(id: 'line-1', item: item))
          .addLine(lineOf(id: 'line-2', item: repriced));

      expect(cart.lineCount, 2);
      expect(cart.subtotal, Money.parse('550'));
    });
  });

  // The source-level assertion that no amount here touches a floating point number
  // now covers the checkout path as well, so it lives in
  // test/features/money_discipline_test.dart over a strictly larger file list.
}
