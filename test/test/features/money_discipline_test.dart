import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Asserts, by reading the source, that no amount anywhere between a menu price and a
/// persisted payment touches a floating point number or a string.
///
/// This is a rule about the code rather than about a value, so it is checked as one. A
/// passing arithmetic test would not notice a `double` introduced on a path the test
/// happened not to cover, and by the time it did the drift would be in a GST return.
///
/// The patterns are regular expressions with word boundaries rather than plain
/// substrings, because `enum` contains `num` and `toDouble` contains `double`. A check
/// that cries wolf gets deleted.
void main() {
  /// Every file a price passes through, from the cart to the committed row.
  const List<String> paymentPath = <String>[
    // Cart
    'lib/features/billing/domain/models/cart.dart',
    'lib/features/billing/domain/models/cart_line.dart',
    'lib/features/billing/domain/models/cart_line_option.dart',
    'lib/features/billing/presentation/controllers/billing_controller.dart',
    // Discount and tax, which are inputs to the total rather than amounts of their own
    'lib/features/billing/domain/models/bill_discount.dart',
    'lib/features/billing/domain/models/gst_rate.dart',
    // Checkout
    'lib/features/billing/domain/models/bill_totals.dart',
    'lib/features/billing/domain/models/cash_tender.dart',
    'lib/features/billing/domain/models/bill_settlement.dart',
    'lib/features/billing/presentation/controllers/checkout_controller.dart',
    'lib/features/billing/data/repositories/sqlite_checkout_repository.dart',
  ];

  /// The two files allowed to build an amount out of nothing, and why each is.
  ///
  /// Keypad entry is inherently "these digits, as paise", so [CashTender] constructs
  /// through `Money.fromPaise` with integer arithmetic. A typed discount is the same
  /// problem — characters the operator entered, which have to become an exact figure — so
  /// `BillDiscount` parses in the same way, splitting on the decimal point and combining two
  /// integers rather than going anywhere near `double.parse`.
  ///
  /// That is exactly the construction being insisted on everywhere else, which is why these
  /// are the exemptions, and why they are two named files rather than a rule of thumb. The
  /// rule is not "some files may construct amounts"; it is "the two places that turn operator
  /// input into an amount do it with integer arithmetic, and nothing else constructs one at
  /// all".
  const List<String> operatorEntry = <String>[
    'lib/features/billing/domain/models/cash_tender.dart',
    'lib/features/billing/domain/models/bill_discount.dart',
  ];

  /// The one file that parses an integer which is not an amount.
  ///
  /// A GST rate is basis points — 18% is `1800` — and it is read back out of the settings
  /// table, which stores text. So `GstRate` parses an integer, and the blanket ban on
  /// `int.parse` across the payment path would otherwise catch it.
  ///
  /// It is exempted from that one pattern and from nothing else. It still may not name
  /// `Money`, a paise field or a `double`, which is asserted separately and is the check that
  /// matters: a rate that cannot hold an amount cannot become one by accident. The same
  /// distinction the settings module already draws between a count and an amount.
  const String rateEntry = 'lib/features/billing/domain/models/gst_rate.dart';

  /// Floating point, in any of the ways it could appear.
  const Map<String, String> floatingPoint = <String, String>{
    'a double': r'\bdouble\b',
    'a conversion to double': r'toDouble\s*\(',
    'a num': r'\bnum\b',
  };

  /// Ways an amount could be read out of text.
  const Map<String, String> textToAmount = <String, String>{
    'Money.parse': r'Money\.parse',
    'double.parse': r'double\.(try)?[pP]arse',
  };

  /// Ways an amount could be conjured rather than carried.
  const Map<String, String> amountConstruction = <String, String>{
    'Money.parse': r'Money\.parse',
    'Money.fromPaise': r'Money\.fromPaise',
    'Money.fromRupees': r'Money\.fromRupees',
    'an integer parse': r'int\.(try)?[pP]arse',
  };

  void expectAbsent(
    String path,
    Map<String, String> patterns, {
    required String because,
  }) {
    final String code = _codeOf(path);

    patterns.forEach((String label, String pattern) {
      expect(
        code,
        isNot(matches(RegExp(pattern))),
        reason: '$path contains $label. $because',
      );
    });
  }

  group('no floating point', () {
    test('nothing on the payment path names a floating point type', () {
      for (final String path in paymentPath) {
        expectAbsent(
          path,
          floatingPoint,
          because: 'Amounts must stay in integer paise inside Money.',
        );
      }
    });

    test('nothing on the payment path reads an amount out of text', () {
      for (final String path in paymentPath) {
        expectAbsent(
          path,
          textToAmount,
          because:
              'An amount recovered from a formatted string is an amount '
              'nobody typed.',
        );
      }
    });

    test('only operator entry constructs an amount', () {
      for (final String path in paymentPath) {
        if (operatorEntry.contains(path)) {
          continue;
        }

        // The rate file parses an integer that is not an amount. Every other way of
        // conjuring one still applies to it.
        final Map<String, String> patterns = path == rateEntry
            ? (Map<String, String>.of(amountConstruction)
                ..remove('an integer parse'))
            : amountConstruction;

        expectAbsent(
          path,
          patterns,
          because:
              'Prices come from the menu and totals come from Money '
              'arithmetic; nothing here invents one.',
        );
      }
    });

    test('the only integer parsed on the payment path is a rate', () {
      // The exemption above is narrow, and this is what holds it narrow: no other file on
      // the path parses an integer at all, so the exemption cannot quietly become a habit.
      for (final String path in paymentPath) {
        if (path == rateEntry || operatorEntry.contains(path)) {
          continue;
        }
        expectAbsent(
          path,
          const <String, String>{'an integer parse': r'int\.(try)?[pP]arse'},
          because:
              'Characters become numbers in the two entry files and in '
              'GstRate, and nowhere else on this path.',
        );
      }
    });

    test('cash entry builds paise by integer arithmetic', () {
      final String code = _codeOf(
        'lib/features/billing/domain/models/cash_tender.dart',
      );

      // The exemption is narrow: integer paise construction, and nothing else.
      expect(code, contains('Money.fromPaise'));
      expect(code, contains('paise * 10 + digit'));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      expect(code, isNot(matches(RegExp(r'Money\.parse'))));
    });

    test('discount entry builds hundredths by integer arithmetic', () {
      final String code = _codeOf(
        'lib/features/billing/domain/models/bill_discount.dart',
      );

      // The same narrow exemption. A decimal the operator typed is split on the point and
      // recombined as `whole * 100 + hundredths`, which is exact; `double.parse('12.5') * 100`
      // is not, and the rate that came out would be one nobody entered.
      expect(code, contains('Money.fromPaise'));
      expect(code, contains('whole * 100 + hundredths'));
      expect(code, contains('int.parse'));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      expect(code, isNot(matches(RegExp(r'toDouble\s*\('))));
      expect(code, isNot(matches(RegExp(r'Money\.parse'))));
    });

    test('the tax rate is an integer and holds no amount', () {
      final String code = _codeOf(
        'lib/features/billing/domain/models/gst_rate.dart',
      );

      // A rate is basis points, so 18% is 1800. It is not money and never becomes money:
      // applying it is `Money.applyRate`, which lives on Money.
      expect(code, contains('basisPoints'));
      expect(code, isNot(matches(RegExp(r'\bMoney\b'))));
      expect(code, isNot(matches(RegExp(r'Paise\b'))));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
    });

    test('a rate is applied in one place, and it rounds once', () {
      // The only multiplication of an amount by a rate in the application. Both the discount
      // and the GST go through it, so there is one rounding rule rather than two that could
      // disagree.
      final String money = _codeOf('lib/core/money/money.dart');
      expect(money, contains('Money applyRate(int basisPoints)'));
      expect(money, contains('_divideRoundingHalfAway'));

      final String totals = _codeOf(
        'lib/features/billing/domain/models/bill_totals.dart',
      );
      final String discount = _codeOf(
        'lib/features/billing/domain/models/bill_discount.dart',
      );

      // Tax on the taxable amount, and a percentage discount on the subtotal. Neither
      // divides, multiplies or rounds on its own.
      expect(totals, contains('taxable.applyRate(taxRate.basisPoints)'));
      expect(discount, contains('subtotal.applyRate('));
      for (final String code in <String>[totals, discount]) {
        expect(code, isNot(matches(RegExp(r'\bround\b|\bceil\b|\bfloor\b'))));
        expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      }
    });

    test('the two halves of the tax are allocated, not recalculated', () {
      // CGST and SGST are shares of one figure. Applying half the rate twice would round
      // twice, and the halves could then fail to add up to the tax charged.
      final String totals = _codeOf(
        'lib/features/billing/domain/models/bill_totals.dart',
      );

      expect(totals, contains('tax.allocate(2)'));

      final String money = _codeOf('lib/core/money/money.dart');
      expect(money, contains('List<Money> allocate(int parts)'));
      expect(money, contains('paise.remainder(parts)'));
    });
  });

  /// Every file an amount passes through on its way to paper.
  ///
  /// The printing path is checked for the same reasons as the payment path, and one
  /// more: a receipt is the customer's record and a tax document. An amount that
  /// drifted by a paisa on its way to the paper would be a bill that does not match
  /// the till, and a formatted amount read back into a number would be an amount
  /// nobody ever charged.
  const List<String> printPath = <String>[
    // Documents
    'lib/features/printing/domain/models/print_document.dart',
    'lib/features/printing/domain/models/print_job.dart',
    'lib/features/printing/domain/models/print_profile.dart',
    'lib/features/printing/domain/models/upi_payment_request.dart',
    // Encoding
    'lib/features/printing/data/escpos/escpos_builder.dart',
    'lib/features/printing/data/escpos/escpos_commands.dart',
    'lib/features/printing/data/escpos/escpos_encoding.dart',
    'lib/features/printing/data/escpos/escpos_text_layout.dart',
    'lib/features/printing/data/escpos/escpos_document_formatter.dart',
    // Building and sending
    'lib/features/printing/domain/services/print_job_factory.dart',
    'lib/features/printing/data/repository_sale_print_document_source.dart',
    'lib/features/printing/data/default_print_service.dart',
  ];

  group('no floating point on the way to paper', () {
    test('nothing in the printing path names a floating point type', () {
      for (final String path in printPath) {
        expectAbsent(
          path,
          floatingPoint,
          because:
              'A printed amount is the same integer paise that is in the '
              'database, or it is wrong.',
        );
      }
    });

    test('nothing in the printing path reads an amount out of text', () {
      for (final String path in printPath) {
        expectAbsent(
          path,
          textToAmount,
          because:
              'Formatting an amount for paper is one way. A receipt line is '
              'never parsed back into a number.',
        );
      }
    });

    test('the printing path invents no amount of its own', () {
      for (final String path in printPath) {
        expectAbsent(
          path,
          amountConstruction,
          because:
              'Every figure on a receipt was carried from the committed '
              'order, not constructed while printing.',
        );
      }
    });

    test('an amount reaches the paper only through Money', () {
      // The single place a figure is rendered, and it takes a Money.
      final String builder = _codeOf(
        'lib/features/printing/data/escpos/escpos_builder.dart',
      );

      expect(builder, contains('void amountRow(String label, Money amount'));
      expect(builder, contains('amount.toDecimalString()'));

      // And the QR carries the same exact figure rather than a re-typed one.
      final String upi = _codeOf(
        'lib/features/printing/domain/models/upi_payment_request.dart',
      );
      expect(upi, contains('amount.toDecimalString()'));
    });
  });

  /// Every file a stock quantity passes through, from a recipe to a moved balance.
  ///
  /// Quantities get the same treatment as money, and for the same reason. A balance is a
  /// running total updated hundreds of times a week, so a `double` would drift, and a
  /// drifting balance is a figure that no longer matches the shelf. The check is a rule
  /// about the code because that is what it is: an arithmetic test would pass while a
  /// `double` sat on a path it did not happen to cover.
  ///
  /// Inventory introduces no money at all. There is no cost, no valuation and no price
  /// on a stock item or a recipe line, because the client asked for basic stock tracking
  /// and inventing a cost model would have meant inventing the costs to go in it. The
  /// last test in this group is what holds that.
  const List<String> quantityPath = <String>[
    // Representation
    'lib/features/inventory/domain/models/stock_quantity.dart',
    'lib/features/inventory/domain/models/stock_unit.dart',
    'lib/features/inventory/domain/models/inventory_item.dart',
    'lib/features/inventory/domain/models/stock_movement.dart',
    'lib/features/inventory/domain/models/stock_movement_type.dart',
    // Recipes
    'lib/features/inventory/domain/models/recipe.dart',
    'lib/features/inventory/domain/models/recipe_ingredient.dart',
    'lib/features/inventory/domain/models/recipe_scope.dart',
    // Deduction
    'lib/features/inventory/domain/models/order_inventory_deduction.dart',
    'lib/features/inventory/data/stock_ledger.dart',
    'lib/features/inventory/data/repositories/sqlite_inventory_repository.dart',
    'lib/features/inventory/data/repositories/sqlite_recipe_repository.dart',
    'lib/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart',
    // Controllers and forms
    'lib/features/inventory/presentation/controllers/inventory_controller.dart',
    'lib/features/inventory/presentation/controllers/recipe_controller.dart',
    'lib/features/inventory/presentation/widgets/inventory_item_editor.dart',
    'lib/features/inventory/presentation/widgets/stock_movement_editor.dart',
    'lib/features/inventory/presentation/widgets/recipe_ingredient_editor.dart',
  ];

  /// The one file allowed to build a quantity out of text.
  ///
  /// A typed quantity is inherently "these characters, as thousandths", so
  /// [StockQuantity] parses straight from a string to an `int` with no `double` in
  /// between. That is exactly the construction being insisted on everywhere else, which
  /// is why it is the exemption, and why it is one named file rather than a rule of
  /// thumb.
  const String quantityEntry =
      'lib/features/inventory/domain/models/stock_quantity.dart';

  /// Ways characters could become a number outside the one type allowed to do it.
  ///
  /// Calling `StockQuantity.parse` is the good behaviour and is deliberately not
  /// matched, including the delegation on `InventoryItem`. What is banned is any other
  /// route from text to a number, because that is where a `double` gets in.
  const Map<String, String> quantityConstruction = <String, String>{
    'an integer parse': r'int\.(try)?[pP]arse',
    'a double parse': r'double\.(try)?[pP]arse',
  };

  /// Anything that would put a price on stock.
  const Map<String, String> money = <String, String>{
    'Money': r'\bMoney\b',
    'a paise column': r'Paise',
  };

  group('no floating point in stock quantities', () {
    test('nothing on the quantity path names a floating point type', () {
      for (final String path in quantityPath) {
        expectAbsent(
          path,
          floatingPoint,
          because:
              'A balance must stay an exact integer count of thousandths, or it '
              'stops matching the shelf.',
        );
      }
    });

    test('only the quantity type constructs a quantity from text', () {
      for (final String path in quantityPath) {
        if (path == quantityEntry) {
          continue;
        }
        expectAbsent(
          path,
          quantityConstruction,
          because:
              'Quantities are carried as integers from StockQuantity.parse, '
              'never re-read out of a rendered figure.',
        );
      }
    });

    test('the quantity type builds thousandths by integer arithmetic', () {
      final String code = _codeOf(quantityEntry);

      // The exemption is narrow: integer construction, and nothing else.
      expect(code, contains('whole * perUnit'));
      expect(code, contains('int.parse'));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      expect(code, isNot(matches(RegExp(r'toDouble\s*\('))));
    });

    test('scaling a recipe to a bill line is integer multiplication', () {
      final String code = _codeOf(quantityEntry);

      // The whole of turning "100 g per pizza" into "300 g for three".
      expect(code, contains('perUnitMilli * soldQuantity'));
    });
  });

  group('stock carries no money', () {
    test('nothing on the quantity path mentions an amount', () {
      // Inventory tracks quantities, not valuations. A cost field would have needed
      // costs to put in it, and the client's costs are not ours to invent.
      for (final String path in quantityPath) {
        expectAbsent(
          path,
          money,
          because:
              'Basic stock tracking has no cost model. Adding one means adding '
              'integer paise through Money, and extending this list.',
        );
      }
    });
  });

  group('display is one way', () {
    test('formatting lives behind the MoneyDisplay extension', () {
      // The currency symbol is written once, next to Money, rather than into every
      // widget that shows an amount. And nothing converts the text back.
      final String code = _codeOf('lib/core/money/money_display.dart');

      expect(code, contains('AppConstants.currencySymbol'));
      expect(code, contains('toDecimalString'));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      expect(code, isNot(matches(RegExp(r'[pP]arse'))));
    });
  });
}

/// The Dart source at [path] with its comments removed.
///
/// The doc comments in these files discuss `double` in order to explain why it is
/// absent, so a search over the whole file would report the very rule it is checking.
/// Trailing comments count too: the ESC/POS encoder names the characters it substitutes,
/// one of which is a double quotation mark.
String _codeOf(String path) {
  final String source = File(path).readAsStringSync();
  final String withoutBlocks = source.replaceAll(
    RegExp(r'/\*.*?\*/', dotAll: true),
    '',
  );
  return withoutBlocks.split('\n').map(_withoutLineComment).join('\n');
}

/// [line] up to a `//` that is not inside a string literal.
///
/// The string check matters: a URL in a string contains `//`, and cutting the line
/// there would hide real code from the search rather than a comment.
String _withoutLineComment(String line) {
  String? quote;

  for (int index = 0; index < line.length; index++) {
    final String character = line[index];

    if (quote != null) {
      if (character == r'\') {
        index++;
      } else if (character == quote) {
        quote = null;
      }
      continue;
    }

    if (character == "'" || character == '"') {
      quote = character;
      continue;
    }
    if (character == '/' && index + 1 < line.length && line[index + 1] == '/') {
      return line.substring(0, index);
    }
  }

  return line;
}
