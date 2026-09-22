import 'dart:io';

import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_status.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_source.dart';

/// Asserts, by reading the source, that no amount on the refund path touches a floating point
/// number or a string.
///
/// This is a rule about the code rather than about a value, so it is checked as one. A passing
/// arithmetic test would not notice a `double` introduced on a path the test happened not to
/// cover, and by the time it did the drift would be in money that had already been handed
/// over a counter.
///
/// Refunds get this treatment for a reason the sale itself does not have: a sale that is a
/// paisa wrong is a bill somebody queries at the counter, but a refund that is a paisa wrong
/// is money out of the till that nobody asked for.
///
/// The patterns are regular expressions with word boundaries rather than plain substrings,
/// because `enum` contains `num` and `toDouble` contains `double`. A check that cries wolf gets
/// deleted.
void main() {
  /// Every file a refund amount passes through, from reading the tender to the committed row.
  const List<String> refundPath = <String>[
    // Domain
    'lib/features/payments/domain/models/refund.dart',
    'lib/features/payments/domain/models/refund_policy.dart',
    'lib/features/payments/domain/models/refund_request.dart',
    'lib/features/payments/domain/models/refundable_bill.dart',
    'lib/features/payments/domain/repositories/refund_repository.dart',
    // Data
    'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
    // Controller
    'lib/features/orders/presentation/controllers/bill_detail_controller.dart',
  ];

  /// The files allowed to turn a stored integer column into an amount.
  ///
  /// A `SUM(...Paise)` and an `amountPaise` column come back as an `int`, and something has to
  /// wrap them. That is exactly the construction being insisted on everywhere else — integer
  /// paise, straight from storage — which is why these are the exemptions and why they are two
  /// named files rather than a rule of thumb.
  const List<String> paiseFromStorage = <String>[
    'lib/features/payments/domain/models/refund.dart',
    'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
  ];

  /// The view that renders the refund figures.
  ///
  /// A widget cannot be held to "no `double` anywhere": a padding and an icon size are
  /// genuinely fractional pixels. So it is held to the rule that matters — no amount is
  /// calculated, constructed or parsed here, and a `double` never appears on a line that
  /// touches money.
  const String refundView =
      'lib/features/orders/presentation/widgets/bill_detail_view.dart';

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
    'an integer parse': r'int\.(try)?[pP]arse',
  };

  /// Ways an amount could be conjured rather than carried out of storage.
  const Map<String, String> amountConstruction = <String, String>{
    'Money.parse': r'Money\.parse',
    'Money.fromPaise': r'Money\.fromPaise',
    'Money.fromRupees': r'Money\.fromRupees',
  };

  /// Anything that would make a refunded amount depend on the current menu.
  const Map<String, String> menuAccess = <String, String>{
    'the menu repository': r'MenuRepository',
    'a menu table': r'SqliteTables\.menu',
    'a menu item model': r'\bMenuItem\b',
  };

  void expectAbsent(
    String path,
    Map<String, String> patterns, {
    required String because,
  }) {
    final String code = DartSource.codeOf(path);

    patterns.forEach((String label, String pattern) {
      expect(
        code,
        isNot(matches(RegExp(pattern))),
        reason: '$path contains $label. $because',
      );
    });
  }

  group('no floating point in a refund', () {
    test('every file on the refund path is listed', () {
      // A file added to the feature without being added above would escape every check below,
      // so the list is held against the directory itself.
      final List<String> onDisk =
          Directory('lib/features/payments')
              .listSync(recursive: true)
              .whereType<File>()
              .map((File file) => file.path.replaceAll(r'\', '/'))
              .where((String path) => path.endsWith('.dart'))
              .where((String path) => path.contains('refund'))
              .toList()
            ..sort();

      for (final String path in onDisk) {
        expect(
          refundPath,
          contains(path),
          reason: '$path handles refunds but is not checked here.',
        );
      }
      // And every listed refund file in the payments feature actually exists.
      for (final String path in refundPath) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: '$path is checked here but is not on disk.',
        );
      }
    });

    test('nothing on the refund path names a floating point type', () {
      for (final String path in refundPath) {
        expectAbsent(
          path,
          floatingPoint,
          because:
              'A refunded amount is the same integer paise that is in the '
              'database, or it is money nobody agreed to hand back.',
        );
      }
    });

    test('nothing on the refund path reads an amount out of text', () {
      for (final String path in refundPath) {
        expectAbsent(
          path,
          textToAmount,
          because:
              'An amount recovered from a formatted string is an amount '
              'nobody typed.',
        );
      }
    });

    test('only storage turns paise into an amount', () {
      for (final String path in refundPath) {
        if (paiseFromStorage.contains(path)) {
          continue;
        }
        expectAbsent(
          path,
          amountConstruction,
          because:
              'A refund amount comes from the persisted tender and is carried '
              'as Money; nothing above the data layer invents one.',
        );
      }
    });

    test('the exemptions build amounts from integer columns only', () {
      for (final String path in paiseFromStorage) {
        final String code = DartSource.codeOf(path);

        // The exemption is narrow: integer paise construction, and nothing else.
        expect(code, contains('Money.fromPaise'));
        expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
        expect(code, isNot(matches(RegExp(r'Money\.parse'))));
        expect(code, isNot(matches(RegExp(r'Money\.fromRupees'))));
      }
    });

    test('the repository reads the amount out of the paise columns', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
      );

      // The tender's amount and the refund's amount both come from an INTEGER column.
      expect(code, contains("row.requireInt('amountPaise')"));
      expect(code, contains('Money.fromPaise'));
      // And the totals are added by Money rather than by bare integers that could have been
      // anything.
      expect(code, contains('Money.sum'));
    });

    test('the refund row writes an integer, not a formatted figure', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/domain/models/refund.dart',
      );

      expect(code, contains("'amountPaise': amount.paise"));
      // Nothing on the way into the database is a rendered string.
      expect(code, isNot(matches(RegExp(r'toDecimalString\(\)\s*,'))));
    });

    test('the remainder is integer subtraction inside Money', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/domain/models/refundable_bill.dart',
      );

      // The one piece of arithmetic in the read model, and it happens in Money rather than on
      // a bare number that could have been a double.
      expect(code, contains('paidAmount - refundedAmount'));
      expect(code, isNot(matches(RegExp(r'\.paise'))));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
    });

    test('net figures are integer subtraction inside Money', () {
      final String summary = DartSource.codeOf(
        'lib/features/reports/domain/models/sales_summary.dart',
      );
      expect(summary, contains('grossSales - refundTotal'));
      expect(summary, isNot(matches(RegExp(r'\.paise'))));

      final String mix = DartSource.codeOf(
        'lib/features/reports/domain/models/payment_mix.dart',
      );
      expect(mix, contains('total - refundTotal'));
      expect(mix, isNot(matches(RegExp(r'\bdouble\b'))));

      final String customer = DartSource.codeOf(
        'lib/features/customers/domain/models/customer_summary.dart',
      );
      expect(customer, contains('totalSpent - refundedTotal'));
      expect(customer, isNot(matches(RegExp(r'\bdouble\b'))));
    });
  });

  group('the refund view only renders', () {
    test('it converts no amount to floating point', () {
      expectAbsent(refundView, const <String, String>{
        'a conversion to double': r'toDouble\s*\(',
        'a num': r'\bnum\b',
      }, because: 'A rendered amount is a Money formatted for display.');
    });

    test('no line mixes a floating point number with an amount', () {
      // A layout `double` is fine; a `double` on the same line as money is the beginning of a
      // figure that drifts. Checked line by line so the two cannot be confused.
      final List<String> lines = DartSource.codeOf(refundView).split('\n');
      for (final String line in lines) {
        if (!RegExp(r'\bdouble\b').hasMatch(line)) {
          continue;
        }
        expect(
          RegExp(r'Money|amount|Paise|total|Total').hasMatch(line),
          isFalse,
          reason:
              '$refundView mixes a double with an amount:\n$line\n'
              'Amounts stay in integer paise inside Money.',
        );
      }
    });

    test('it invents no amount and parses none', () {
      expectAbsent(
        refundView,
        amountConstruction,
        because:
            'Every figure on this screen was carried from a committed row, '
            'not constructed while drawing it.',
      );
      expectAbsent(
        refundView,
        textToAmount,
        because:
            'Formatting an amount for a screen is one way. A figure on screen '
            'is never parsed back into a number.',
      );
    });

    test('amounts reach the screen only through the display extension', () {
      final String code = DartSource.codeOf(refundView);

      expect(code, contains('.formatted'));
      expect(code, isNot(matches(RegExp(r'toDecimalString'))));
    });

    test('the view holds no SQL', () {
      // SQL belongs in the data layer. A widget that grew a query would be a widget nobody
      // could change the schema underneath.
      for (final String path in <String>[
        refundView,
        'lib/features/orders/presentation/controllers/bill_detail_controller.dart',
      ]) {
        expectAbsent(path, const <String, String>{
          'a SELECT': r'\bSELECT\b',
          'a table name constant': r'SqliteTables',
          'a sqflite import': r'package:sqflite',
        }, because: 'Queries live in the SQLite repositories.');
      }
    });
  });

  group('a refunded amount does not depend on the menu', () {
    test('nothing on the refund path reaches for the menu', () {
      for (final String path in <String>[...refundPath, refundView]) {
        expectAbsent(
          path,
          menuAccess,
          because:
              'What is refundable comes from the tender that was taken. '
              'Reading the menu would make a refund change when a price does.',
        );
      }
    });

    test('the repository reads only the persisted sale tables', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
      );

      expect(code, contains('SqliteTables.orders'));
      expect(code, contains('SqliteTables.payments'));
      expect(code, contains('SqliteTables.refunds'));
      // And nothing else. In particular no stock ledger write dressed as a reversal.
      expect(code, isNot(matches(RegExp(r'SqliteTables\.stockMovements'))));
      expect(code, isNot(matches(RegExp(r'StockMovementType'))));
      expect(code, isNot(matches(RegExp(r'adjustment'))));
      expect(code, isNot(matches(RegExp(r'SqliteTables\.kot'))));
    });

    test('the repository writes to exactly one table', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
      );

      // One upsert, into the refunds table. The tender and the order are read only.
      expect(code, contains('SqliteUpsert.run(txn, SqliteTables.refunds'));
      expect(
        RegExp(r'SqliteUpsert\.run').allMatches(code).length,
        1,
        reason: 'A refund is one write. A second would be a second fact.',
      );
      // And no UPDATE or DELETE anywhere: the original sale is never rewritten.
      expect(code, isNot(matches(RegExp(r'txn\.update'))));
      expect(code, isNot(matches(RegExp(r'txn\.delete'))));
      expect(code, isNot(matches(RegExp(r'\bUPDATE\b'))));
      expect(code, isNot(matches(RegExp(r'\bDELETE\b'))));
    });

    test('the notification happens after the transaction, not inside it', () {
      final String code = DartSource.codeOf(
        'lib/features/payments/data/repositories/sqlite_refund_repository.dart',
      );

      final int transactionEnd = code.indexOf('});');
      final int notify = code.indexOf('notifyTablesChanged');

      expect(notify, greaterThan(transactionEnd));
    });
  });

  group('refunds introduced no new tender', () {
    test('there are still four payment methods and no more', () {
      // A "refund" tender would be a heading on the payment report that no sale can land in,
      // and it would make a reversal look like a way of paying.
      expect(PaymentMethod.values, hasLength(4));
      expect(PaymentMethod.values.map((PaymentMethod m) => m.name), <String>[
        'cash',
        'upi',
        'card',
        'other',
      ]);
    });

    test('the refund status vocabulary is the tender status vocabulary', () {
      expect(PaymentStatus.values.map((PaymentStatus s) => s.name), <String>[
        'pending',
        'completed',
        'failed',
        'refunded',
      ]);
      // Only `completed` counts as money that has moved, for a tender and for a reversal.
      expect(PaymentStatus.completed.isSettled, isTrue);
      expect(PaymentStatus.pending.isSettled, isFalse);
      expect(PaymentStatus.failed.isSettled, isFalse);
    });

    test('no wallet or loyalty refund has been introduced', () {
      for (final String path in <String>[...refundPath, refundView]) {
        expectAbsent(path, const <String, String>{
          'a wallet': r'[Ww]allet',
          'a loyalty tender': r'[Ll]oyalty',
        }, because: 'Money goes back the way it came in.');
      }
    });
  });

  group('the net figures are values, not absences', () {
    test('a summary with no refunds nets to its gross', () {
      const SalesSummary summary = SalesSummary(
        billCount: 2,
        itemCount: 3,
        subtotal: Money.fromPaise(40000),
        discountTotal: Money.zero,
        taxTotal: Money.fromPaise(2000),
        grossSales: Money.fromPaise(42000),
      );

      expect(summary.refundTotal, Money.zero);
      expect(summary.hasRefunds, isFalse);
      expect(summary.netSales, const Money.fromPaise(42000));
    });

    test('an empty summary nets to zero rather than throwing', () {
      expect(SalesSummary.empty.refundTotal, Money.zero);
      expect(SalesSummary.empty.netSales, Money.zero);
      expect(SalesSummary.empty.hasRefunds, isFalse);
    });

    test('a fully refunded range nets to zero, exactly', () {
      const SalesSummary summary = SalesSummary(
        billCount: 1,
        itemCount: 2,
        subtotal: Money.fromPaise(20000),
        discountTotal: Money.zero,
        taxTotal: Money.fromPaise(1000),
        grossSales: Money.fromPaise(21000),
        refundTotal: Money.fromPaise(21000),
      );

      expect(summary.netSales, Money.zero);
      // Still a bill that happened, so still not an empty range.
      expect(summary.isEmpty, isFalse);
    });

    test('net sales may legitimately be negative and is reported so', () {
      // A quiet morning in which yesterday's large bill was refunded really did take less
      // than nothing. Clamping at zero would hide money that left the till.
      const SalesSummary summary = SalesSummary(
        billCount: 1,
        itemCount: 1,
        subtotal: Money.fromPaise(10000),
        discountTotal: Money.zero,
        taxTotal: Money.zero,
        grossSales: Money.fromPaise(10000),
        refundTotal: Money.fromPaise(30000),
      );

      expect(summary.netSales, const Money.fromPaise(-20000));
      expect(summary.netSales.isNegative, isTrue);
    });

    test('an empty mix answers zero for every method, in and out', () {
      final PaymentMix empty = PaymentMix.empty();

      for (final PaymentMethod method in PaymentMethod.values) {
        expect(empty.amountFor(method), Money.zero);
        expect(empty.refundedFor(method), Money.zero);
        expect(empty.netFor(method), Money.zero);
        expect(empty.countFor(method), 0);
        expect(empty.refundCountFor(method), 0);
      }
      expect(empty.refundTotal, Money.zero);
      expect(empty.netTotal, Money.zero);
      expect(empty.hasRefunds, isFalse);
    });

    test('the mix nets each method exactly', () {
      final PaymentMix mix = PaymentMix(
        amounts: const <PaymentMethod, Money>{
          PaymentMethod.cash: Money.fromPaise(21000),
          PaymentMethod.upi: Money.fromPaise(15000),
        },
        counts: const <PaymentMethod, int>{
          PaymentMethod.cash: 1,
          PaymentMethod.upi: 1,
        },
        refunds: const <PaymentMethod, Money>{
          PaymentMethod.cash: Money.fromPaise(21000),
        },
        refundCounts: const <PaymentMethod, int>{PaymentMethod.cash: 1},
      );

      expect(mix.netFor(PaymentMethod.cash), Money.zero);
      expect(mix.netFor(PaymentMethod.upi), const Money.fromPaise(15000));
      expect(mix.total, const Money.fromPaise(36000));
      expect(mix.refundTotal, const Money.fromPaise(21000));
      expect(mix.netTotal, const Money.fromPaise(15000));
      expect(mix.refundCount, 1);
      expect(mix.tenderCount, 2);
    });
  });
}
