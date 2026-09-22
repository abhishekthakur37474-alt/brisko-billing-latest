import 'package:brisko_billing/core/money/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Money', () {
    test('stores rupees as exact paise', () {
      expect(const Money.fromRupees(249).paise, 24900);
      expect(Money.parse('249.50').paise, 24950);
      expect(Money.parse('249.5').paise, 24950);
      expect(Money.parse('249.05').paise, 24905);
      expect(Money.parse('0.01').paise, 1);
    });

    test('rejects a value with more precision than a paisa', () {
      // Silently dropping a third decimal would hide a data-entry error.
      expect(() => Money.parse('10.001'), throwsFormatException);
      expect(() => Money.parse('abc'), throwsFormatException);
      expect(() => Money.parse(''), throwsFormatException);
    });

    test('adds without the drift a double would introduce', () {
      // 0.1 + 0.2 != 0.3 in binary floating point. In paise it is exact.
      final Money total = Money.parse('0.10') + Money.parse('0.20');
      expect(total, Money.parse('0.30'));
      expect(total.paise, 30);
    });

    test('summing many lines stays exact', () {
      final List<Money> lines = List<Money>.filled(1000, Money.parse('0.01'));
      expect(Money.sum(lines), Money.parse('10.00'));
    });

    test('multiplies by a quantity exactly', () {
      expect(Money.parse('249.50') * 3, Money.parse('748.50'));
      expect(Money.parse('0.01') * 7, Money.parse('0.07'));
    });

    test(
      'applies a tax rate in basis points, rounding half away from zero',
      () {
        // 5% of 249.50 is 12.475, which rounds to 12.48.
        expect(Money.parse('249.50').applyRate(500), Money.parse('12.48'));
        // 18% of 100 is exactly 18.
        expect(Money.parse('100.00').applyRate(1800), Money.parse('18.00'));
        // Exactly half a paisa rounds up.
        expect(Money.parse('0.10').applyRate(500), Money.parse('0.01'));
      },
    );

    test('rounds a negative amount away from zero too', () {
      expect(-Money.parse('249.50').applyRate(500), Money.parse('-12.48'));
      expect(Money.parse('-249.50').applyRate(500), Money.parse('-12.48'));
    });

    test('allocates a split so the parts sum back to the whole', () {
      // 100.00 into three cannot divide evenly; nothing may be created or lost.
      final List<Money> parts = Money.parse('100.00').allocate(3);
      expect(parts.length, 3);
      expect(Money.sum(parts), Money.parse('100.00'));
      expect(parts, <Money>[
        Money.parse('33.34'),
        Money.parse('33.33'),
        Money.parse('33.33'),
      ]);
    });

    test('rejects a nonsensical split', () {
      expect(() => Money.parse('10.00').allocate(0), throwsArgumentError);
    });

    test('formats with two decimals', () {
      expect(Money.parse('249.5').toDecimalString(), '249.50');
      expect(Money.parse('0.05').toDecimalString(), '0.05');
      expect(Money.zero.toDecimalString(), '0.00');
      expect(Money.parse('-12.40').toDecimalString(), '-12.40');
    });

    test('compares and equates by value', () {
      expect(Money.parse('10.00'), Money.parse('10.00'));
      expect(Money.parse('10.00').hashCode, Money.parse('10.00').hashCode);
      expect(Money.parse('10.00') < Money.parse('10.01'), isTrue);
      expect(Money.parse('10.01') > Money.parse('10.00'), isTrue);
      expect(Money.parse('10.00') <= Money.parse('10.00'), isTrue);
      expect(Money.parse('10.00') >= Money.parse('10.00'), isTrue);
    });

    test('reports sign correctly', () {
      expect(Money.zero.isZero, isTrue);
      expect(Money.parse('1.00').isPositive, isTrue);
      expect(Money.parse('-1.00').isNegative, isTrue);
    });
  });
}
