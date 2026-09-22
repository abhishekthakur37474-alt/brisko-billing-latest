import 'dart:io';

import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/reports/domain/models/payment_mix.dart';
import 'package:brisko_billing/features/reports/domain/models/sales_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_source.dart';

/// Rules about the reporting code, checked by reading it.
///
/// ## Why a source test
///
/// A report is a number somebody writes down and files. Two of the ways it could quietly
/// stop being true are not visible in any single arithmetic test: a `double` introduced on a
/// path this suite happens not to cover, and a menu lookup introduced behind a historical
/// figure. Both would pass every behavioural test written today and be discovered in a GST
/// return, so they are asserted as rules about the files.
///
/// ## The rules
///
/// 1. No floating point anywhere a report amount travels.
/// 2. No amount recovered from text — a figure parsed back out of a rendered string is a
///    figure nobody charged.
/// 3. No menu access behind a historical figure.
/// 4. No tender the outlet does not accept.
void main() {
  /// Every file a reported amount is calculated in, from the query to the controller.
  ///
  /// These carry no floating point at all, in any form.
  const List<String> calculationPath = <String>[
    // Domain
    'lib/features/reports/domain/models/date_range.dart',
    'lib/features/reports/domain/models/report_period.dart',
    'lib/features/reports/domain/models/sales_summary.dart',
    'lib/features/reports/domain/models/payment_mix.dart',
    'lib/features/reports/domain/models/item_sales_row.dart',
    'lib/features/reports/domain/models/sales_bill.dart',
    'lib/features/reports/domain/models/bill_search_query.dart',
    'lib/features/reports/domain/repositories/sales_report_repository.dart',
    // Data
    'lib/features/reports/data/repositories/sqlite_sales_report_repository.dart',
    // Controllers
    'lib/features/reports/presentation/controllers/sales_report_controller.dart',
    'lib/features/reports/presentation/controllers/order_history_controller.dart',
  ];

  /// The files that render a report.
  ///
  /// A widget cannot be held to "no `double` anywhere": a column width and a padding are
  /// genuinely fractional pixels, and pretending otherwise would only teach whoever hits the
  /// failure to add the file to an exemption list. So these are held to the rule that
  /// actually matters — no amount is ever calculated, constructed or parsed here, and a
  /// `double` never appears on a line that touches money.
  const List<String> viewPath = <String>[
    'lib/features/reports/presentation/screens/reports_screen.dart',
    'lib/features/reports/presentation/screens/order_history_screen.dart',
    'lib/features/reports/presentation/report_section.dart',
    'lib/features/reports/presentation/widgets/report_filter_bar.dart',
    'lib/features/reports/presentation/widgets/report_notices.dart',
    'lib/features/reports/presentation/widgets/sales_summary_view.dart',
    'lib/features/reports/presentation/widgets/sales_bills_view.dart',
    'lib/features/reports/presentation/widgets/item_sales_view.dart',
    'lib/features/reports/presentation/widgets/payment_breakdown_view.dart',
  ];

  /// Everything in the feature.
  final List<String> reportPath = <String>[...calculationPath, ...viewPath];

  /// The one file allowed to turn an integer column into an amount.
  ///
  /// A `SUM(...Paise)` comes back as an `int`, and something has to wrap it. That is exactly
  /// the construction being insisted on everywhere else — integer paise, straight from
  /// storage — which is why it is the exemption and why it is one named file rather than a
  /// rule of thumb.
  const String paiseFromStorage =
      'lib/features/reports/data/repositories/sqlite_sales_report_repository.dart';

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

  /// Ways an amount could be conjured rather than carried out of storage.
  const Map<String, String> amountConstruction = <String, String>{
    'Money.parse': r'Money\.parse',
    'Money.fromPaise': r'Money\.fromPaise',
    'Money.fromRupees': r'Money\.fromRupees',
  };

  /// Anything that would make a historical figure depend on the current menu.
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

  group('no floating point in a report', () {
    test('every file on the reporting path is listed', () {
      // A file added to the feature without being added above would escape every check
      // below, so the list is held against the directory itself.
      final List<String> onDisk =
          Directory('lib/features/reports')
              .listSync(recursive: true)
              .whereType<File>()
              .map((File file) => file.path.replaceAll(r'\', '/'))
              .where((String path) => path.endsWith('.dart'))
              .toList()
            ..sort();

      expect(onDisk, hasLength(reportPath.length));
      for (final String path in onDisk) {
        expect(
          reportPath,
          contains(path),
          reason: '$path is in the reports feature but is not checked here.',
        );
      }
    });

    test('nothing that calculates an amount names a floating point type', () {
      for (final String path in calculationPath) {
        expectAbsent(
          path,
          floatingPoint,
          because:
              'A reported amount is the same integer paise that is in the '
              'database, or it is a figure nobody charged.',
        );
      }
    });

    test('nothing that renders an amount converts one to floating point', () {
      for (final String path in viewPath) {
        expectAbsent(path, const <String, String>{
          'a conversion to double': r'toDouble\s*\(',
          'a num': r'\bnum\b',
        }, because: 'A rendered amount is a Money formatted for display.');
      }
    });

    test('no view mixes a floating point number with an amount', () {
      // A layout `double` is fine; a `double` on the same line as money is the beginning of
      // a total that drifts. Checked line by line so the two cannot be confused.
      for (final String path in viewPath) {
        final List<String> lines = DartSource.codeOf(path).split('\n');
        for (final String line in lines) {
          if (!RegExp(r'\bdouble\b').hasMatch(line)) {
            continue;
          }
          expect(
            RegExp(r'Money|amount|Paise|total|Total').hasMatch(line),
            isFalse,
            reason:
                '$path mixes a double with an amount:\n$line\n'
                'Amounts stay in integer paise inside Money.',
          );
        }
      }
    });

    test('nothing on the reporting path reads an amount out of text', () {
      for (final String path in reportPath) {
        expectAbsent(
          path,
          textToAmount,
          because:
              'Formatting an amount for a report is one way. A total on screen '
              'is never parsed back into a number.',
        );
      }
    });

    test('only the aggregate query turns stored paise into an amount', () {
      for (final String path in reportPath) {
        if (path == paiseFromStorage) {
          continue;
        }
        expectAbsent(
          path,
          amountConstruction,
          because:
              'Amounts are summed by the database and carried as Money; '
              'nothing above the data layer invents one.',
        );
      }
    });

    test('the aggregate query builds amounts from integer columns only', () {
      final String code = DartSource.codeOf(paiseFromStorage);

      // The exemption is narrow: integer paise construction, and nothing else.
      expect(code, contains('Money.fromPaise'));
      expect(code, isNot(matches(RegExp(r'\bdouble\b'))));
      expect(code, isNot(matches(RegExp(r'Money\.parse'))));
      // And the sums are done in SQL over the paise columns rather than in Dart over rows.
      expect(code, contains('SUM(totalAmountPaise)'));
      expect(code, contains('SUM(p.amountPaise)'));
      expect(code, contains('SUM(i.totalAmountPaise)'));
    });

    test('an amount reaches the screen only through the display extension', () {
      // The one-way conversion at the edge of the UI. Nothing reads it back.
      for (final String path in <String>[
        'lib/features/reports/presentation/widgets/sales_summary_view.dart',
        'lib/features/reports/presentation/widgets/sales_bills_view.dart',
        'lib/features/reports/presentation/widgets/item_sales_view.dart',
        'lib/features/reports/presentation/widgets/payment_breakdown_view.dart',
      ]) {
        final String code = DartSource.codeOf(path);
        expect(
          code,
          contains('.formatted'),
          reason: '$path should render amounts through MoneyDisplay.',
        );
        expect(code, isNot(matches(RegExp(r'toDecimalString'))));
      }
    });

    test('the average is integer division inside Money', () {
      // The only division of an amount in the application, and it happens in Money rather
      // than on a bare number that could have been a double.
      final String summary = DartSource.codeOf(
        'lib/features/reports/domain/models/sales_summary.dart',
      );
      expect(summary, contains('grossSales ~/ billCount'));
      expect(summary, isNot(matches(RegExp(r'\.paise'))));

      final String money = DartSource.codeOf('lib/core/money/money.dart');
      expect(money, contains('Money operator ~/(int divisor)'));
      expect(money, contains('Money.fromPaise(paise ~/ divisor)'));
      expect(money, isNot(matches(RegExp(r'\bdouble\b'))));
    });
  });

  group('history does not depend on the menu', () {
    test('nothing in the reports feature reaches for the menu', () {
      for (final String path in reportPath) {
        expectAbsent(
          path,
          menuAccess,
          because:
              'A historical figure comes from the snapshot written when the '
              'bill was settled. Reading the menu would make last month change '
              'when this month is repriced.',
        );
      }
    });

    test('the aggregate query reads only the persisted sale tables', () {
      final String code = DartSource.codeOf(paiseFromStorage);

      expect(code, contains('SqliteTables.orders'));
      expect(code, contains('SqliteTables.orderItems'));
      expect(code, contains('SqliteTables.payments'));
      expect(code, contains('SqliteTables.kotRecords'));
      expect(code, contains('SqliteTables.customers'));
      // The item report groups on the snapshot columns, not on a menu id.
      expect(code, contains('i.itemNameSnapshot'));
      expect(code, contains('i.variantNameSnapshot'));
    });

    test('the reports screen holds no SQL', () {
      // SQL belongs in the data layer. A controller or a widget that grew a query would be
      // a controller or a widget nobody could change the schema underneath.
      const List<String> aboveTheDataLayer = <String>[
        'lib/features/reports/presentation/controllers/sales_report_controller.dart',
        'lib/features/reports/presentation/screens/reports_screen.dart',
        'lib/features/reports/presentation/widgets/report_filter_bar.dart',
        'lib/features/reports/presentation/widgets/sales_summary_view.dart',
        'lib/features/reports/presentation/widgets/sales_bills_view.dart',
        'lib/features/reports/presentation/widgets/item_sales_view.dart',
        'lib/features/reports/presentation/widgets/payment_breakdown_view.dart',
      ];

      for (final String path in aboveTheDataLayer) {
        expectAbsent(path, const <String, String>{
          'a SELECT': r'\bSELECT\b',
          'a table name constant': r'SqliteTables',
          'a sqflite import': r'package:sqflite',
        }, because: 'Queries live in the SQLite repositories.');
      }
    });
  });

  group('the tenders reported are the tenders accepted', () {
    test('there are four payment methods and no more', () {
      expect(PaymentMethod.values, hasLength(4));
      expect(PaymentMethod.values.map((PaymentMethod m) => m.name), <String>[
        'cash',
        'upi',
        'card',
        'other',
      ]);
    });

    test('all four are handled by the payment report', () {
      final PaymentMix empty = PaymentMix.empty();

      expect(PaymentMix.methods, PaymentMethod.values);
      for (final PaymentMethod method in PaymentMethod.values) {
        // Answers for every method rather than only the ones money came in on.
        expect(empty.amountFor(method), Money.zero);
        expect(empty.countFor(method), 0);
        expect(method.label, isNotEmpty);
      }
    });

    test('no wallet or loyalty tender has been introduced', () {
      // Not a tender this outlet takes. A bucket for one would be a heading on a report
      // that no payment can ever land in.
      for (final String path in <String>[
        ...reportPath,
        'lib/features/payments/domain/models/payment_method.dart',
      ]) {
        expectAbsent(path, const <String, String>{
          'a wallet': r'[Ww]allet',
          'a loyalty tender': r'[Ll]oyalty',
        }, because: 'The accepted tenders are cash, UPI, card and other.');
      }
    });
  });

  group('an empty report is a value, not an absence', () {
    test('the empty summary is all zeroes and says so', () {
      expect(SalesSummary.empty.isEmpty, isTrue);
      expect(SalesSummary.empty.billCount, 0);
      expect(SalesSummary.empty.grossSales, Money.zero);
      // Not a division by zero, and not a misleading figure either.
      expect(SalesSummary.empty.averageBillValue, Money.zero);
    });

    test('dividing an amount by zero is refused rather than guessed at', () {
      expect(() => const Money.fromPaise(100) ~/ 0, throwsArgumentError);
    });

    test('integer division truncates towards zero exactly', () {
      expect(const Money.fromPaise(10000) ~/ 3, const Money.fromPaise(3333));
      expect(const Money.fromPaise(-10000) ~/ 3, const Money.fromPaise(-3333));
      expect(const Money.fromPaise(999) ~/ 1, const Money.fromPaise(999));
    });
  });
}
