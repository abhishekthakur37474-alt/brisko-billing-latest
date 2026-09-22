import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_discount.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_totals.dart';
import 'package:brisko_billing/features/billing/domain/models/cart.dart';
import 'package:brisko_billing/features/billing/domain/models/cart_line.dart';
import 'package:brisko_billing/features/billing/domain/models/gst_rate.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';

/// The bill arithmetic: what a discount takes off, what GST adds, and in which order.
///
/// ## Why this is where the figures are pinned
///
/// Every amount a customer is charged comes out of `BillTotals`, and every other part of
/// the application reads that one result: the cart panel, the checkout review, the cash
/// keypad, the persisted order, the printed receipt and the sales report. So the figures
/// are asserted here, once, against worked examples rather than against whatever the code
/// happens to produce.
///
/// Amounts are synthetic. These tests are about exactness at any value — including the
/// sub-rupee ones the printed menu does not contain and the odd-paisa ones where rounding
/// actually decides something — so the prices are chosen to make the arithmetic checkable
/// by hand. Settlement against the real seeded menu is covered by the checkout tests.
void main() {
  MenuItem itemPriced(String price) =>
      Fixtures.menuItem(categoryId: 'cat-test', basePrice: price);

  /// A one-line cart at [price], which makes the subtotal that price.
  Cart cartAt(String price) => Cart(<CartLine>[
    CartLine.fromSelection(id: 'l1', item: itemPriced(price)),
  ]);

  /// The canonical worked example from the requirement: a ₹1,000 bill.
  Cart thousandRupeeBill() => cartAt('1000.00');

  const GstRate noGst = GstRate.zero;
  const GstRate fivePercent = GstRate.ofBasisPoints(500);
  const GstRate twelvePercent = GstRate.ofBasisPoints(1200);
  const GstRate eighteenPercent = GstRate.ofBasisPoints(1800);

  // ------------------------------------------------------------------ discounts ---

  group('discounts', () {
    test('no discount leaves the subtotal alone', () {
      final BillTotals totals = BillTotals.forCart(cart: thousandRupeeBill());

      expect(totals.subtotal, Money.parse('1000.00'));
      expect(totals.discount, Money.zero);
      expect(totals.taxableAmount, Money.parse('1000.00'));
      expect(totals.total, Money.parse('1000.00'));
      expect(totals.hasDiscount, isFalse);
      expect(totals.discountRule.isNone, isTrue);
    });

    test('a percentage discount comes off the subtotal', () {
      // 10% of 1000 is 100, leaving 900.
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: const BillDiscount.percentage(1000),
      );

      expect(totals.discount, Money.parse('100.00'));
      expect(totals.taxableAmount, Money.parse('900.00'));
      expect(totals.total, Money.parse('900.00'));
      expect(totals.discountRule.label, '10%');
    });

    test('a fixed discount comes off the subtotal', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: BillDiscount.amount(Money.parse('100.00')),
      );

      expect(totals.discount, Money.parse('100.00'));
      expect(totals.taxableAmount, Money.parse('900.00'));
      expect(totals.total, Money.parse('900.00'));
      expect(totals.discountRule.label, '\u20B9100.00');
    });

    test('a percentage and a fixed discount worth the same agree exactly', () {
      // The requirement's two worked examples. They must land on the same paise, or the
      // two ways of entering the same discount would charge two different amounts.
      final BillTotals byPercent = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: const BillDiscount.percentage(1000),
        taxRate: eighteenPercent,
      );
      final BillTotals byAmount = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: BillDiscount.amount(Money.parse('100.00')),
        taxRate: eighteenPercent,
      );

      expect(byPercent.discount, byAmount.discount);
      expect(byPercent.taxableAmount, byAmount.taxableAmount);
      expect(byPercent.tax, byAmount.tax);
      expect(byPercent.total, byAmount.total);
    });

    test('a 100% discount takes the bill to zero, and no further', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: const BillDiscount.percentage(BillDiscount.maxBasisPoints),
        taxRate: eighteenPercent,
      );

      expect(totals.discount, Money.parse('1000.00'));
      expect(totals.taxableAmount, Money.zero);
      // Nothing is charged on nothing, so there is no tax either.
      expect(totals.tax, Money.zero);
      expect(totals.total, Money.zero);
      expect(totals.total.isNegative, isFalse);
      // And a bill of zero is not settleable, which is the existing rule.
      expect(totals.isPayable, isFalse);
    });

    test('a fixed discount larger than the subtotal is refused', () {
      final BillDiscount tooBig = BillDiscount.amount(Money.parse('1500.00'));

      // Refused with a message that says what the ceiling is, rather than just "invalid".
      final String? problem = tooBig.problemOn(Money.parse('1000.00'));
      expect(problem, isNotNull);
      expect(problem, contains('1000.00'));
    });

    test(
      'a discount larger than the subtotal cannot produce a negative bill',
      () {
        // The second guard. Even if a caller never asks `problemOn`, the amount is clamped, so
        // there is no route through the calculation that pays the customer.
        final BillTotals totals = BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: BillDiscount.amount(Money.parse('1500.00')),
          taxRate: eighteenPercent,
        );

        expect(totals.discount, Money.parse('1000.00'));
        expect(totals.taxableAmount, Money.zero);
        expect(totals.total, Money.zero);
        expect(totals.total.isNegative, isFalse);
      },
    );

    test('a negative discount is refused, both ways of expressing it', () {
      expect(const BillDiscount.percentage(-1).isWellFormed, isFalse);
      expect(
        const BillDiscount.percentage(-1).problemOn(Money.parse('1000.00')),
        contains('negative'),
      );

      final BillDiscount negativeAmount = BillDiscount.amount(
        Money.parse('-50.00'),
      );
      expect(negativeAmount.isWellFormed, isFalse);
      expect(
        negativeAmount.problemOn(Money.parse('1000.00')),
        contains('negative'),
      );

      // And it cannot add to a bill even if it got past the refusal.
      expect(
        BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: negativeAmount,
        ).total,
        Money.parse('1000.00'),
      );
      expect(
        BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: const BillDiscount.percentage(-1000),
        ).total,
        Money.parse('1000.00'),
      );
    });

    test('a percentage above 100 is refused', () {
      const BillDiscount tooMuch = BillDiscount.percentage(10001);

      expect(tooMuch.isWellFormed, isFalse);
      expect(
        tooMuch.problemOn(Money.parse('1000.00')),
        contains('more than 100%'),
      );
      // Clamped in the calculation as well, so the worst it can do is take the whole bill.
      expect(tooMuch.amountOn(Money.parse('1000.00')), Money.parse('1000.00'));
    });

    test('a discount on an empty bill takes off nothing', () {
      expect(
        const BillDiscount.percentage(5000).amountOn(Money.zero),
        Money.zero,
      );
      expect(
        BillDiscount.amount(Money.parse('100.00')).amountOn(Money.zero),
        Money.zero,
      );
    });
  });

  // ------------------------------------------------------------- discount entry ---

  group('what the operator can type', () {
    BillDiscount? parsePercent(String value) =>
        BillDiscount.tryParse(type: BillDiscountType.percentage, value: value);

    BillDiscount? parseAmount(String value) =>
        BillDiscount.tryParse(type: BillDiscountType.amount, value: value);

    test('a whole percentage reads as basis points', () {
      expect(parsePercent('10')!.basisPoints, 1000);
      expect(parsePercent('5')!.basisPoints, 500);
      expect(parsePercent('100')!.basisPoints, 10000);
    });

    test('a fractional percentage is exact, with no double in between', () {
      // 12.5% is 1250 basis points. Through a double this is where 1250.0000000000002
      // would come from, and the rate charged would be one nobody entered.
      expect(parsePercent('12.5')!.basisPoints, 1250);
      expect(parsePercent('12.50')!.basisPoints, 1250);
      expect(parsePercent('0.01')!.basisPoints, 1);
      expect(parsePercent('7.25')!.basisPoints, 725);
    });

    test('an amount reads as exact paise', () {
      expect(parseAmount('100')!.fixedAmount, Money.parse('100.00'));
      expect(parseAmount('99.50')!.fixedAmount, Money.parse('99.50'));
      expect(parseAmount('0.01')!.fixedAmount, const Money.fromPaise(1));
    });

    test('an empty field is no discount, not an error', () {
      // Clearing the field is how a discount is removed, so blank has to be a value.
      expect(parsePercent(''), BillDiscount.none);
      expect(parsePercent('   '), BillDiscount.none);
      expect(parseAmount(''), BillDiscount.none);
    });

    test('anything that is not a plain decimal is refused', () {
      for (final String rubbish in <String>[
        'abc',
        '10a',
        'a10',
        '1 0',
        '10..5',
        '10.5.2',
        '.5',
        '1,000',
        '1e3',
        '0x10',
        'Infinity',
        '-Infinity',
        'NaN',
        '+10',
        '-10',
        '10%',
        '\u20B9100',
      ]) {
        expect(
          parsePercent(rubbish),
          isNull,
          reason: '"$rubbish" is not a percentage',
        );
        expect(
          parseAmount(rubbish),
          isNull,
          reason: '"$rubbish" is not an amount',
        );
      }
    });

    test('a third decimal place is refused rather than dropped', () {
      // Silently discarding it would hide a typing mistake, and the discount given would
      // not be the discount entered.
      expect(parsePercent('12.555'), isNull);
      expect(parseAmount('99.999'), isNull);
    });

    test('a percentage over 100 is refused at the point of entry', () {
      expect(parsePercent('101'), isNull);
      expect(parsePercent('100.01'), isNull);
      expect(parsePercent('1000'), isNull);
    });

    test('an amount beyond what the till accepts is refused', () {
      // The same ceiling the cash keypad has, for the same reason: a held key must not
      // become a six-figure discount.
      expect(parseAmount('99999.99')!.fixedAmount.paise, 9999999);
      expect(parseAmount('100000'), isNull);
    });
  });

  // ------------------------------------------------------------------------ GST ---

  group('GST', () {
    test('no rate configured means no tax line at all', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: noGst,
      );

      expect(totals.tax, Money.zero);
      expect(totals.cgst, Money.zero);
      expect(totals.sgst, Money.zero);
      expect(totals.total, Money.parse('1000.00'));
      expect(totals.hasTax, isFalse);
      expect(totals.hasAdjustments, isFalse);
    });

    test('5% is charged exactly', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: fivePercent,
      );

      expect(totals.tax, Money.parse('50.00'));
      expect(totals.total, Money.parse('1050.00'));
      expect(totals.taxRate, fivePercent);
    });

    test('12% is charged exactly', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: twelvePercent,
      );

      expect(totals.tax, Money.parse('120.00'));
      expect(totals.total, Money.parse('1120.00'));
    });

    test('18% is charged exactly', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: eighteenPercent,
      );

      expect(totals.tax, Money.parse('180.00'));
      expect(totals.total, Money.parse('1180.00'));
    });

    test('tax is charged on the subtotal, not on the total', () {
      // The mistake this rules out is compounding: taxing a figure that already includes
      // tax. 18% of 1000 is 180, and the total is 1180 — not 18% of 1180.
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: eighteenPercent,
      );

      expect(totals.tax, totals.taxableAmount.applyRate(1800));
      expect(totals.total, totals.taxableAmount + totals.tax);
    });

    test('rounding is half away from zero, once', () {
      // 5% of 249.50 is 12.475. Rounded half away from zero that is 12.48, which is the
      // convention an Indian invoice uses. Rounded down it would be 12.47 and the bill
      // would be a paisa short of the tax due.
      final BillTotals totals = BillTotals.forCart(
        cart: cartAt('249.50'),
        taxRate: fivePercent,
      );

      expect(totals.tax, Money.parse('12.48'));
      expect(totals.total, Money.parse('261.98'));
    });

    test('a long bill of odd prices does not drift', () {
      // Twenty lines at 99.99. A double would be visibly out by now; integer paise cannot
      // be.
      final Cart cart = Cart(<CartLine>[
        for (int index = 0; index < 20; index++)
          CartLine.fromSelection(id: 'l$index', item: itemPriced('99.99')),
      ]);

      final BillTotals totals = BillTotals.forCart(
        cart: cart,
        taxRate: eighteenPercent,
      );

      // 20 x 9999 = 199980 paise.
      expect(totals.subtotal.paise, 199980);
      // 18% of 199980 is 35996.4, which rounds to 35996.
      expect(totals.tax.paise, 35996);
      expect(totals.total.paise, 235976);
      expect(totals.isConsistent, isTrue);
    });

    test('CGST and SGST are halves that add back to the tax exactly', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: eighteenPercent,
      );

      expect(totals.tax, Money.parse('180.00'));
      expect(totals.cgst, Money.parse('90.00'));
      expect(totals.sgst, Money.parse('90.00'));
      expect(totals.cgst + totals.sgst, totals.tax);
    });

    test('an odd paisa of tax is allocated, never created or lost', () {
      // 12.48 does not halve into whole paise. One side takes the extra paisa, and the two
      // still come to exactly the tax charged — which is what makes the two printed lines
      // defensible.
      final BillTotals totals = BillTotals.forCart(
        cart: cartAt('249.50'),
        taxRate: fivePercent,
      );

      expect(totals.tax.paise, 1248);
      expect(totals.cgst.paise, 624);
      expect(totals.sgst.paise, 624);
      expect(totals.cgst + totals.sgst, totals.tax);

      // And a genuinely odd figure. 5% of 100.10 is 5.005, which rounds to 5.01.
      final BillTotals odd = BillTotals.forCart(
        cart: cartAt('100.10'),
        taxRate: fivePercent,
      );
      expect(odd.tax.paise, 501);
      expect(odd.cgst.paise, 251);
      expect(odd.sgst.paise, 250);
      expect(odd.cgst + odd.sgst, odd.tax);
    });

    test('the rate halves for a label only when it halves exactly', () {
      expect(eighteenPercent.halfLabel, '9%');
      expect(twelvePercent.halfLabel, '6%');
      expect(fivePercent.halfLabel, '2.5%');
      // An odd number of basis points cannot be stated as half a rate without rounding it,
      // so no label is offered rather than a wrong one.
      expect(const GstRate.ofBasisPoints(501).halfLabel, isNull);
    });

    test('a rate outside 0 to 100% is not one a bill may carry', () {
      expect(const GstRate.ofBasisPoints(-1).isAcceptable, isFalse);
      expect(const GstRate.ofBasisPoints(10001).isAcceptable, isFalse);
      expect(const GstRate.ofBasisPoints(10000).isAcceptable, isTrue);
      expect(noGst.isAcceptable, isTrue);

      // A corrupt stored rate reads as zero, so the bill opens and shows its stored amounts
      // rather than becoming unopenable.
      expect(GstRate.fromStoredBasisPoints(-5), noGst);
      expect(GstRate.fromStoredBasisPoints(99999), noGst);
      expect(GstRate.fromStoredBasisPoints(1800), eighteenPercent);
    });

    test('the selectable rates are the standard slabs, starting at none', () {
      expect(GstRate.selectable.first, noGst);
      expect(
        GstRate.selectable.map((GstRate rate) => rate.label).toList(),
        <String>['0%', '5%', '12%', '18%'],
      );
      // Every one of them is a rate a bill may be settled at.
      for (final GstRate rate in GstRate.selectable) {
        expect(rate.isAcceptable, isTrue);
      }
    });

    test('a stored rate round-trips through text', () {
      for (final GstRate rate in GstRate.selectable) {
        expect(GstRate.tryParseStored(rate.toStored()), rate);
      }
      // And nothing that is not a rate becomes one.
      for (final String rubbish in <String>[
        '',
        'eighteen',
        '18%',
        '1.8',
        '-500',
        '10001',
      ]) {
        expect(
          GstRate.tryParseStored(rubbish),
          isNull,
          reason: '"$rubbish" is not a stored rate',
        );
      }
      expect(GstRate.tryParseStored(null), isNull);
    });
  });

  // --------------------------------------------------------------- combinations ---

  group('a discount and GST together', () {
    test('the requirement worked example: 1000 less 100, GST 18%', () {
      // Subtotal 1000, discount 100, taxable 900, GST 162, total 1062.
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: const BillDiscount.percentage(1000),
        taxRate: eighteenPercent,
      );

      expect(totals.subtotal, Money.parse('1000.00'));
      expect(totals.discount, Money.parse('100.00'));
      expect(totals.taxableAmount, Money.parse('900.00'));
      expect(totals.tax, Money.parse('162.00'));
      expect(totals.total, Money.parse('1062.00'));
      expect(totals.cgst, Money.parse('81.00'));
      expect(totals.sgst, Money.parse('81.00'));
    });

    test('GST is charged after the discount, not before it', () {
      // The whole point of the order of operations. Taxing the full 1000 would collect 180
      // and total 1080, which is tax on ₹100 the customer was never charged.
      final BillTotals discounted = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: const BillDiscount.percentage(1000),
        taxRate: eighteenPercent,
      );
      final BillTotals undiscounted = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: eighteenPercent,
      );

      expect(undiscounted.tax, Money.parse('180.00'));
      expect(discounted.tax, Money.parse('162.00'));
      expect(discounted.tax < undiscounted.tax, isTrue);
      expect(discounted.total, Money.parse('1062.00'));
    });

    test('a fixed discount with GST', () {
      final BillTotals totals = BillTotals.forCart(
        cart: thousandRupeeBill(),
        discount: BillDiscount.amount(Money.parse('250.00')),
        taxRate: fivePercent,
      );

      expect(totals.taxableAmount, Money.parse('750.00'));
      expect(totals.tax, Money.parse('37.50'));
      expect(totals.total, Money.parse('787.50'));
      expect(totals.showsTaxableAmount, isTrue);
    });

    test('a percentage discount with GST at each slab', () {
      // 20% off 1000 leaves 800 taxable at every rate.
      const Map<int, String> expected = <int, String>{
        0: '800.00',
        500: '840.00',
        1200: '896.00',
        1800: '944.00',
      };

      expected.forEach((int basisPoints, String total) {
        final BillTotals totals = BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: const BillDiscount.percentage(2000),
          taxRate: GstRate.ofBasisPoints(basisPoints),
        );

        expect(totals.taxableAmount, Money.parse('800.00'));
        expect(totals.total, Money.parse(total), reason: 'at $basisPoints bp');
        expect(totals.isConsistent, isTrue);
      });
    });

    test('every combination adds up, and none goes negative', () {
      // A sweep rather than a worked example: the invariants have to hold for all of it.
      final List<BillDiscount> discounts = <BillDiscount>[
        BillDiscount.none,
        const BillDiscount.percentage(1),
        const BillDiscount.percentage(1000),
        const BillDiscount.percentage(3333),
        const BillDiscount.percentage(10000),
        BillDiscount.amount(const Money.fromPaise(1)),
        BillDiscount.amount(Money.parse('99.99')),
        BillDiscount.amount(Money.parse('1000.00')),
      ];

      for (final String price in <String>[
        '0.01',
        '99.99',
        '249.50',
        '1000.00',
      ]) {
        for (final BillDiscount discount in discounts) {
          for (final GstRate rate in GstRate.selectable) {
            final BillTotals totals = BillTotals.forCart(
              cart: cartAt(price),
              discount: discount,
              taxRate: rate,
            );
            final String at = '$price, ${discount.label}, ${rate.label}';

            expect(totals.isConsistent, isTrue, reason: 'adds up at $at');
            expect(totals.discount.isNegative, isFalse, reason: at);
            expect(totals.tax.isNegative, isFalse, reason: at);
            expect(
              totals.taxableAmount.isNegative,
              isFalse,
              reason: 'taxable at $at',
            );
            expect(totals.total.isNegative, isFalse, reason: 'total at $at');
            expect(
              totals.discount <= totals.subtotal,
              isTrue,
              reason: 'discount within subtotal at $at',
            );
            expect(
              totals.cgst + totals.sgst,
              totals.tax,
              reason: 'halves add back at $at',
            );
          }
        }
      }
    });

    test('changing the discount recalculates the tax with it', () {
      final BillTotals plain = BillTotals.forCart(
        cart: thousandRupeeBill(),
        taxRate: eighteenPercent,
      );

      final BillTotals discounted = plain.withDiscount(
        const BillDiscount.percentage(1000),
      );

      // The rate is kept and the tax follows the new taxable amount.
      expect(discounted.taxRate, eighteenPercent);
      expect(discounted.tax, Money.parse('162.00'));
      expect(discounted.total, Money.parse('1062.00'));

      // And removing it goes back to exactly where it started.
      expect(discounted.withDiscount(BillDiscount.none), plain);
    });

    test('the taxable line is only worth showing when it says something', () {
      // No discount: the taxable amount is the subtotal, so repeating it says nothing.
      expect(
        BillTotals.forCart(
          cart: thousandRupeeBill(),
          taxRate: eighteenPercent,
        ).showsTaxableAmount,
        isFalse,
      );
      // A discount but no tax: there is no tax to explain.
      expect(
        BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: const BillDiscount.percentage(1000),
        ).showsTaxableAmount,
        isFalse,
      );
      // Both: the figure the tax was charged on is not on the bill anywhere else.
      expect(
        BillTotals.forCart(
          cart: thousandRupeeBill(),
          discount: const BillDiscount.percentage(1000),
          taxRate: eighteenPercent,
        ).showsTaxableAmount,
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------- one calculation ---

  group('there is one calculation', () {
    test('the plain factory and the full one agree on an untaxed bill', () {
      // `BillTotals.fromCart` is what a cart alone can answer and is still used where no
      // discount or rate exists. It must not be a second implementation.
      final Cart cart = thousandRupeeBill();

      expect(BillTotals.fromCart(cart), BillTotals.forCart(cart: cart));
    });

    test('a subtotal and a cart of that subtotal give the same answer', () {
      final Cart cart = thousandRupeeBill();

      expect(
        BillTotals.forCart(
          cart: cart,
          discount: const BillDiscount.percentage(1000),
          taxRate: eighteenPercent,
        ),
        BillTotals.of(
          subtotal: Money.parse('1000.00'),
          discount: const BillDiscount.percentage(1000),
          taxRate: eighteenPercent,
        ),
      );
    });

    test('the same inputs always give the same figures', () {
      // Deterministic: no clock, no locale, no floating point, so two runs cannot differ.
      for (int attempt = 0; attempt < 5; attempt++) {
        final BillTotals totals = BillTotals.of(
          subtotal: Money.parse('249.50'),
          discount: const BillDiscount.percentage(1250),
          taxRate: fivePercent,
        );

        expect(totals.discount.paise, 3119);
        expect(totals.taxableAmount.paise, 21831);
        expect(totals.tax.paise, 1092);
        expect(totals.total.paise, 22923);
      }
    });
  });
}
