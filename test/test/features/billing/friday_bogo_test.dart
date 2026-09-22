import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CartLine createPizzaLine({
    required String id,
    required String size,
    required String price,
    int quantity = 1,
    String itemName = 'Test Pizza',
  }) {
    return CartLine(
      id: id,
      menuItemId: 'item-1',
      itemNameSnapshot: itemName,
      basePriceSnapshot: Money.parse(price),
      variantId: 'var-1',
      variantNameSnapshot: size,
      quantity: quantity,
    );
  }

  CartLine createNonPizzaLine({
    required String id,
    required String price,
    int quantity = 1,
  }) {
    return CartLine(
      id: id,
      menuItemId: 'item-2',
      itemNameSnapshot: 'Cold Drink',
      basePriceSnapshot: Money.parse(price),
      quantity: quantity,
    );
  }

  group('Friday BOGO Logic (Cart)', () {
    test('1 medium pizza: free = 0', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00'),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 1);
      expect(cart.fridayMediumPizzaUnitPrices.length ~/ 2, 0);
    });

    test('2 medium pizzas: free = 1', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', quantity: 2),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 2);
      expect(cart.fridayMediumPizzaUnitPrices.length ~/ 2, 1);
      
      final prices = cart.fridayMediumPizzaUnitPrices..sort();
      expect(prices.first, Money.parse('300.00'));
    });

    test('3 medium pizzas: free = 1', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', quantity: 3),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 3);
      expect(cart.fridayMediumPizzaUnitPrices.length ~/ 2, 1);
    });

    test('4 medium pizzas: free = 2', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', quantity: 4),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 4);
      expect(cart.fridayMediumPizzaUnitPrices.length ~/ 2, 2);
    });

    test('Small pizza does not qualify', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Small', price: '200.00'),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 0);
    });

    test('Large pizza does not qualify', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Large', price: '500.00'),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 0);
    });

    test('Mixed medium pizza prices: cheapest are free', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', itemName: 'Farmhouse'),
        createPizzaLine(id: '2', size: 'Medium', price: '220.00', itemName: 'Onion'),
        createPizzaLine(id: '3', size: 'Medium', price: '200.00', itemName: 'Corn'),
        createPizzaLine(id: '4', size: 'Medium', price: '180.00', itemName: 'Tomato'),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 4);
      
      final prices = cart.fridayMediumPizzaUnitPrices..sort();
      final int freeCount = prices.length ~/ 2;
      expect(freeCount, 2);
      
      Money discount = Money.zero;
      for (int i = 0; i < freeCount; i++) {
        discount += prices[i];
      }
      // Tomato (180) + Corn (200) = 380
      expect(discount, Money.parse('380.00'));
    });

    test('Three mixed-price medium pizzas: only cheapest one is free', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', itemName: 'Farmhouse'),
        createPizzaLine(id: '2', size: 'Medium', price: '220.00', itemName: 'Onion'),
        createPizzaLine(id: '3', size: 'Medium', price: '180.00', itemName: 'Tomato'),
      ]);
      expect(cart.fridayMediumPizzaUnitPrices.length, 3);
      
      final prices = cart.fridayMediumPizzaUnitPrices..sort();
      final int freeCount = prices.length ~/ 2;
      expect(freeCount, 1);
      
      Money discount = Money.zero;
      for (int i = 0; i < freeCount; i++) {
        discount += prices[i];
      }
      expect(discount, Money.parse('180.00'));
    });

    test('Mixed qualifying and non-qualifying products', () {
      final cart = Cart([
        createPizzaLine(id: '1', size: 'Medium', price: '300.00', itemName: 'Farmhouse'),
        createPizzaLine(id: '2', size: 'Medium', price: '220.00', itemName: 'Onion'),
        createPizzaLine(id: '3', size: 'Small', price: '200.00', itemName: 'Farmhouse'),
        createPizzaLine(id: '4', size: 'Large', price: '350.00', itemName: 'Farmhouse'),
        createNonPizzaLine(id: '5', price: '80.00'),
      ]);
      
      expect(cart.fridayMediumPizzaUnitPrices.length, 2);
      
      final prices = cart.fridayMediumPizzaUnitPrices..sort();
      final int freeCount = prices.length ~/ 2;
      expect(freeCount, 1);
      
      Money discount = Money.zero;
      for (int i = 0; i < freeCount; i++) {
        discount += prices[i];
      }
      expect(discount, Money.parse('220.00')); // Onion is free
    });
  });
}
