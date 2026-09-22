import 'dart:typed_data';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/configurable_escpos_encoder.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_commands.dart';
import 'package:brisko_billing/features/printing/domain/models/print_document.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/print_settings.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/active_pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:brisko_billing/features/settings/presentation/controllers/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// What the configured settings do to a printed document, and what they must never do to
/// a bill.
///
/// ## Why this is settled through the real checkout
///
/// A receipt assembled by hand would prove nothing about where its business details came
/// from. Every bill here is settled through [CheckoutController] against the real
/// repositories, then read back off the printer as the transcript a customer would hold —
/// so "the receipt uses the stored GSTIN" is a statement about the application, not about
/// a constructor argument.
///
/// ## No printer is required
///
/// [FakeEscPosPrinter] records the bytes handed to a transport. Nothing here opens a
/// device, a socket or a port, and no test in this file needs hardware to run.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteSettingsRepository settings;
  late ConfigurableEscPosEncoder encoder;
  late FakeEscPosPrinter printer;
  late PrintService printing;
  late BillingController billing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    settings = SqliteSettingsRepository(database: database);
    printer = FakeEscPosPrinter();
    // The encoder the application exposes as its active profile, shared with the print
    // service exactly as the bootstrap shares it.
    encoder = ConfigurableEscPosEncoder.forPrinter(printer);
    printing = TestPrinting.serviceOver(
      database,
      printer: printer,
      encoder: encoder,
    );
    billing = await SeededCart.controller(menu);
  });

  tearDown(() async {
    billing.dispose();
    await printer.dispose();
    if (database.isOpen) {
      await database.close();
    }
  });

  /// Saves [values] through the Settings screen's own controller.
  ///
  /// Deliberately not written straight into the table: what is under test is that the
  /// screen's save is what the printer ends up reading.
  Future<void> saveSettings(
    void Function(SettingsController controller) edit,
  ) async {
    final SettingsController controller = SettingsController(
      settings: settings,
      printProfile: encoder,
      activeSettings: ActivePosSettings(),
    );
    await controller.load();
    edit(controller);
    expect(await controller.save(), isTrue);
    controller.dispose();
  }

  /// Settles one Medium Cheese Pizza with Extra Cheese, in cash, and prints it.
  Future<String> settleOneBill() async {
    await SeededCart.add(
      billing,
      category: 'SIMPLY VEG',
      item: 'Cheese Pizza',
      size: 'Medium',
      options: <String>['Extra Cheese'],
    );

    final CheckoutController controller = CheckoutController(
      cart: billing.cart,
      checkoutRepository: SqliteCheckoutRepository(database: database),
      customerRepository: SqliteCustomerRepository(database: database),
      inventoryDeductionRepository: SqliteInventoryDeductionRepository(
        database: database,
      ),
      printService: printing,
      onSettled: billing.clearCart,
    );
    addTearDown(controller.dispose);

    controller.setCustomerName('Test Customer');
    controller.setCustomerPhone('9000000001');
    controller.goToPayment();
    controller.selectPaymentMethod(PaymentMethod.cash);
    controller.tenderExact();
    controller.goToConfirm();
    await controller.submit();

    expect(controller.isSettled, isTrue);
    expect(controller.hasPrintFailure, isFalse);
    return controller.settledOrder!.id;
  }

  /// The customer receipt from the last sale printed.
  EscPosTranscript receipt() {
    final List<PrintJob> jobs = printer.jobsOf(PrintJobKind.customerReceipt);
    expect(jobs, isNotEmpty, reason: 'no customer receipt was printed');
    return EscPosTranscript.of(jobs.last.bytes);
  }

  /// The kitchen slip from the last sale printed.
  EscPosTranscript kot() {
    final List<PrintJob> jobs = printer.jobsOf(PrintJobKind.kitchenKot);
    expect(jobs, isNotEmpty, reason: 'no kitchen slip was printed');
    return EscPosTranscript.of(jobs.last.bytes);
  }

  // ------------------------------------------------------------- the receipt ---

  group('the receipt reads the stored settings', () {
    test(
      'an unconfigured terminal claims nothing it has not been told',
      () async {
        await settleOneBill();
        final EscPosTranscript printed = receipt();

        // The build's own name, because a bill with no name is not identifiable as a bill.
        expect(printed.hasLineContaining('Brisko Pizza'), isTrue);
        // And nothing else. No invented address, telephone number, GSTIN or QR.
        expect(printed.hasLineContaining('GSTIN'), isFalse);
        expect(printed.hasLineContaining('Phone'), isFalse);
        expect(printed.hasLineContaining('Scan to pay'), isFalse);
        expect(printed.qrPayloads, isEmpty);
      },
    );

    test('every configured business field appears on the bill', () async {
      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Kothrud');
        controller.editBusinessAddress('12 Paud Road, Kothrud, Pune 411038');
        controller.editBusinessPhone('020 2545 1234');
        controller.editGstin('27AAPFU0939F1ZV');
        controller.editReceiptHeader('Wood-fired since 2019');
        controller.editReceiptFooter('Thank you, come again');
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      expect(printed.hasLineContaining('Brisko Pizza Kothrud'), isTrue);
      expect(printed.hasLineContaining('12 Paud Road'), isTrue);
      expect(printed.hasLineContaining('Phone 020 2545 1234'), isTrue);
      expect(printed.hasLineContaining('GSTIN 27AAPFU0939F1ZV'), isTrue);
      expect(printed.hasLineContaining('Wood-fired since 2019'), isTrue);
      expect(printed.hasLineContaining('Thank you, come again'), isTrue);
    });

    test('the outlet address prints on one line and never overflows', () async {
      // The current, shortened Brisko Pizza address. The previous long-form address
      // (Delhi Haridwar Highway, NH-58 …) is deliberately gone: this is the exact line
      // the outlet's terminal is configured with, and it fits an 80mm line unwrapped.
      const String address = 'Near: RMP(PG) College, Gurukul Narsan, Haridwar';
      await saveSettings((SettingsController controller) {
        controller.editBusinessName('BRISKO PIZZA');
        controller.editBusinessAddress(address);
        controller.editBusinessPhone('+91 9058582158');
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      expect(printed.hasLineContaining('BRISKO PIZZA'), isTrue);
      expect(
        printed.hasLineContaining(
          'Near: RMP(PG) College, Gurukul Narsan, Haridwar',
        ),
        isTrue,
      );
      expect(printed.hasLineContaining('Phone +91 9058582158'), isTrue);
      // The retired long-form address must never come back onto the paper.
      expect(printed.hasLineContaining('Delhi Haridwar Highway'), isFalse);
      // Nothing runs off the 48-column paper.
      expect(printed.widestLine, lessThanOrEqualTo(48));
    });

    test('a configured feedback URL puts a review QR on the bill', () async {
      await saveSettings((SettingsController controller) {
        controller.editFeedbackUrl('https://g.page/r/brisko/review');
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      // The paid bill invites a review, and never asks to be paid again.
      expect(printed.hasLineContaining('RATE US'), isTrue);
      expect(printed.hasLineContaining('Scan to share your feedback'), isTrue);
      expect(printed.hasLineContaining('Scan to pay'), isFalse);
      expect(printed.qrPayloads, hasLength(1));
      // The QR carries exactly the configured review URL.
      expect(printed.qrPayloads.single, 'https://g.page/r/brisko/review');
    });

    test('turning the QR off leaves the feedback block off entirely', () async {
      await saveSettings((SettingsController controller) {
        controller.editFeedbackUrl('https://g.page/r/brisko/review');
        controller.setQrEnabled(isEnabled: false);
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      // Not a heading with nothing under it, which would read as a fault.
      expect(printed.qrPayloads, isEmpty);
      expect(printed.hasLineContaining('RATE US'), isFalse);
    });

    test('changing a business setting changes the next bill', () async {
      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Kothrud');
        controller.editReceiptFooter('Thank you, come again');
      });
      await settleOneBill();
      final EscPosTranscript before = receipt();

      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Baner');
        controller.editReceiptFooter('No returns on cut pizza');
      });
      await settleOneBill();
      final EscPosTranscript after = receipt();

      expect(before.hasLineContaining('Brisko Pizza Kothrud'), isTrue);
      expect(before.hasLineContaining('Thank you, come again'), isTrue);

      expect(after.hasLineContaining('Brisko Pizza Baner'), isTrue);
      expect(after.hasLineContaining('No returns on cut pizza'), isTrue);
      expect(after.hasLineContaining('Kothrud'), isFalse);
    });

    test('a reprint picks up the settings as they stand now', () async {
      final String orderId = await settleOneBill();

      await saveSettings((SettingsController controller) {
        controller.editGstin('27AAPFU0939F1ZV');
      });

      printer.clearRecording();
      await printing.reprintSale(orderId);

      // Presentation follows the current configuration, because the GSTIN of the outlet
      // is a fact about the outlet rather than about that sale.
      expect(receipt().hasLineContaining('GSTIN 27AAPFU0939F1ZV'), isTrue);
    });
  });

  // ------------------------------------------------- the figures are untouched ---

  group('settings cannot change what a bill charges', () {
    test(
      'the stored order is identical before and after a settings change',
      () async {
        final String orderId = await settleOneBill();
        final SqliteOrderRepository orders = SqliteOrderRepository(
          database: database,
        );

        final Order before = (await orders.findOrder(orderId)).valueOrNull!;
        final List<OrderItem> linesBefore = (await orders.loadItems(orderId))
            .valueOrNull!;

        await saveSettings((SettingsController controller) {
          controller.editBusinessName('Brisko Pizza Baner');
          controller.editGstin('27AAPFU0939F1ZV');
          controller.editReceiptFooter('Different footer');
          controller.selectFont(PrinterFont.fontB);
          controller.editColumnOverride('40');
        });

        final Order after = (await orders.findOrder(orderId)).valueOrNull!;
        final List<OrderItem> linesAfter = (await orders.loadItems(orderId))
            .valueOrNull!;

        // Money, to the paise.
        expect(after.subtotal, before.subtotal);
        expect(after.discountAmount, before.discountAmount);
        expect(after.taxAmount, before.taxAmount);
        expect(after.totalAmount, before.totalAmount);
        expect(after.orderNumber, before.orderNumber);
        expect(after.orderType, before.orderType);

        // And the item snapshots, which are what a reprint reproduces.
        expect(linesAfter, hasLength(linesBefore.length));
        for (int index = 0; index < linesBefore.length; index++) {
          expect(
            linesAfter[index].itemNameSnapshot,
            linesBefore[index].itemNameSnapshot,
          );
          expect(
            linesAfter[index].variantNameSnapshot,
            linesBefore[index].variantNameSnapshot,
          );
          expect(linesAfter[index].unitPrice, linesBefore[index].unitPrice);
          expect(linesAfter[index].totalAmount, linesBefore[index].totalAmount);
          expect(linesAfter[index].quantity, linesBefore[index].quantity);
        }
      },
    );

    test('a reprint after a settings change prints the same figures', () async {
      final String orderId = await settleOneBill();
      final String totalBefore = receipt().lineContaining('TOTAL INR')!.trim();

      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Baner');
        controller.editReceiptFooter('Different footer');
      });

      printer.clearRecording();
      await printing.reprintSale(orderId);

      expect(receipt().lineContaining('TOTAL INR')!.trim(), totalBefore);
      expect(receipt().hasLineContaining('Paid by Cash'), isTrue);
    });

    test('no settings key names an amount or a discount', () async {
      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Kothrud');
      });

      final Map<String, String?> stored =
          (await settings.readAll()).valueOrNull!;

      // The screen writes business, receipt, behaviour, printer and GST-rate keys.
      //
      // `tax.gstRateBasisPoints` was added in step 14 and is the one key here that a bill's
      // arithmetic reads. It is admitted deliberately, and it is still not an amount: it
      // holds an integer count of basis points, it reaches a bill only through
      // `BillTotals`, and settlement copies it onto the order so changing it cannot move a
      // bill already issued — which is what the test above this one proves.
      //
      // The rule this test protects is otherwise unchanged. No key holds paise, and no key
      // sets a discount: a discount is a decision about one bill taken at the counter, not a
      // configured default, so there is nothing for Settings to store.
      for (final String key in stored.keys) {
        expect(
          key,
          anyOf(
            startsWith('business.'),
            startsWith('receipt.'),
            startsWith('payment.upi'),
            startsWith('printer.'),
            startsWith('pos.'),
            equals('tax.gstin'),
            equals('tax.gstRateBasisPoints'),
          ),
          reason: '$key is not a setting the Settings screen may write',
        );
        expect(
          key,
          isNot(contains('Paise')),
          reason: '$key names an amount. Settings holds no money.',
        );
        expect(
          key.toLowerCase(),
          isNot(contains('discount')),
          reason: '$key configures a discount, which is a per-bill decision.',
        );
      }
    });
  });

  // ---------------------------------------------------------------- the slip ---

  group('the kitchen slip', () {
    setUp(() async {
      await saveSettings((SettingsController controller) {
        controller.editBusinessName('Brisko Pizza Kothrud');
        controller.editBusinessAddress('12 Paud Road, Kothrud, Pune 411038');
        controller.editBusinessPhone('020 2545 1234');
        controller.editGstin('27AAPFU0939F1ZV');
        controller.editReceiptHeader('Wood-fired since 2019');
        controller.editReceiptFooter('Thank you, come again');
        controller.editUpiVpa('brisko@upi');
      });
    });

    test('carries none of the receipt-only settings', () async {
      await settleOneBill();
      final EscPosTranscript slip = kot();

      // The kitchen does not need, and must not be given, the outlet's tax identity or
      // the customer's payment.
      expect(slip.hasLineContaining('GSTIN'), isFalse);
      expect(slip.hasLineContaining('27AAPFU0939F1ZV'), isFalse);
      expect(slip.hasLineContaining('Paid by'), isFalse);
      expect(slip.hasLineContaining('TOTAL'), isFalse);
      expect(slip.hasLineContaining('Subtotal'), isFalse);
      expect(slip.hasLineContaining('Thank you, come again'), isFalse);
      expect(slip.hasLineContaining('Wood-fired since 2019'), isFalse);
      expect(slip.hasLineContaining('12 Paud Road'), isFalse);
      expect(slip.hasLineContaining('020 2545 1234'), isFalse);
      expect(slip.qrPayloads, isEmpty);
    });

    test('carries no amount at all, configured or otherwise', () async {
      await settleOneBill();

      // The seeded bill is 320.00. Nothing resembling it may appear on the slip.
      expect(kot().hasLineContaining('320'), isFalse);
      expect(kot().hasLineContaining('.00'), isFalse);
    });

    test('still says what the kitchen has to cook', () async {
      await settleOneBill();
      final EscPosTranscript slip = kot();

      expect(slip.hasLineContaining('KITCHEN ORDER TICKET'), isTrue);
      expect(slip.hasLineContaining('Cheese Pizza'), isTrue);
      expect(slip.hasLineContaining('Extra Cheese'), isTrue);
      expect(slip.hasLineContaining('Qty 1'), isTrue);
    });
  });

  // ------------------------------------------------------- printer settings ---

  group('printer settings reach the encoder', () {
    test('a saved column count narrows the next document', () async {
      await saveSettings((SettingsController controller) {
        controller.editColumnOverride('42');
      });

      await settleOneBill();

      expect(encoder.profile.columns, 42);
      // Every laid-out line fits the corrected budget, without a restart.
      expect(receipt().widestLine, lessThanOrEqualTo(42));
    });

    test('a saved font changes the column budget', () async {
      await saveSettings((SettingsController controller) {
        controller.selectFont(PrinterFont.fontB);
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      expect(encoder.profile.columns, 64);
      expect(printed.widestLine, lessThanOrEqualTo(64));
      // Font B is selected on the printer at the start of the document, so a laid-out
      // 64-column line is one the printer will actually fit.
      expect(
        printed.hasCommand(
          EscPosCommands.selectFont(PrinterFont.fontB.selector),
        ),
        isTrue,
      );
    });

    test('a saved cut mode changes the command sent at the end', () async {
      await settleOneBill();
      expect(receipt().hasCommand(EscPosCommands.cutFull), isTrue);

      await saveSettings((SettingsController controller) {
        controller.selectCut(PrintCut.partial);
      });
      printer.clearRecording();
      await settleOneBill();

      expect(receipt().hasCommand(EscPosCommands.cutPartial), isTrue);
      expect(receipt().hasCommand(EscPosCommands.cutFull), isFalse);
    });

    test('a saved feed changes the paper fed before the cut', () async {
      await saveSettings((SettingsController controller) {
        controller.editFeedLinesBeforeCut('7');
      });

      await settleOneBill();

      expect(receipt().hasCommand(EscPosCommands.feed(7)), isTrue);
    });

    test('a saved QR module size and level reach the QR commands', () async {
      await saveSettings((SettingsController controller) {
        controller.editFeedbackUrl('https://g.page/r/brisko/review');
        controller.editQrModuleSize('9');
        controller.selectQrErrorCorrection(QrErrorCorrection.high);
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      expect(printed.hasCommand(EscPosCommands.qrModuleSize(9)), isTrue);
      expect(
        printed.hasCommand(
          EscPosCommands.qrErrorCorrection(
            EscPosCommands.qrErrorCorrectionHigh,
          ),
        ),
        isTrue,
      );
    });

    test('the layout is the printer\'s own until something is saved', () async {
      await settleOneBill();

      expect(encoder.profile.columns, printer.profile.columns);
      expect(receipt().widestLine, lessThanOrEqualTo(printer.profile.columns));
    });
  });

  // ------------------------------------------------------ header and footer ---

  group('a long header and footer', () {
    /// Longer than any line of 80mm paper, and made of ordinary words.
    const String longHeader =
        'Brisko Pizza Kothrud, first floor above the bakery, open from eleven '
        'in the morning until eleven at night, every day of the week';

    /// A single unbroken run, which is what a pasted URL looks like.
    const String unbrokenFooter =
        'www.brisko.example/terms-and-conditions-of-sale-and-returns-policy-in-full';

    test('wrap to the paper instead of being cut off by the printer', () async {
      await saveSettings((SettingsController controller) {
        controller.editReceiptHeader(longHeader);
        controller.editReceiptFooter(unbrokenFooter);
      });

      await settleOneBill();
      final EscPosTranscript printed = receipt();

      // Not one line exceeds the column budget, so the printer never breaks a line
      // itself and takes the rest of the layout with it.
      expect(printed.widestLine, lessThanOrEqualTo(encoder.profile.columns));

      // And nothing was thrown away: the words are all still there, across lines.
      final String flattened = printed.trimmedLines.join(' ');
      for (final String word in longHeader.split(' ')) {
        expect(
          flattened,
          contains(word),
          reason: '"$word" was dropped from the header',
        );
      }
      // A run too long to break is split rather than truncated, so its tail survives.
      expect(flattened.replaceAll(' ', ''), contains('returns-policy-in-full'));
    });

    test('wrap to a corrected column count as well', () async {
      await saveSettings((SettingsController controller) {
        controller.editReceiptHeader(longHeader);
        controller.editColumnOverride('32');
      });

      await settleOneBill();

      expect(receipt().widestLine, lessThanOrEqualTo(32));
    });

    test('a header of only spaces prints no line at all', () async {
      await saveSettings((SettingsController controller) {
        controller.editReceiptHeader('     ');
      });

      await settleOneBill();

      // Stored as absent rather than as blank, so the receipt omits the section exactly
      // as it does for a header that was never entered.
      final Map<String, String?> stored =
          (await settings.readAll()).valueOrNull!;
      expect(stored.containsKey('receipt.header'), isFalse);
    });
  });

  group('no hardware is needed', () {
    test('the whole document is produced without a printer being reached', () {
      // Encoding is a pure function of a document and a profile, so a byte stream exists
      // before any transport does. This is why every assertion above can run in CI.
      final Uint8List bytes = encoder.encode(PrinterTestPageFixture.document());

      expect(bytes, isNotEmpty);
      expect(printer.openCount, 0);
    });

    test('the settings never carry a device, host or port', () {
      final PrintSettings stored = PrintSettings.fromProfile(
        encoder.baseProfile,
      );

      expect(stored.toStored().keys, hasLength(7));
      expect(
        stored.toStored().keys.join(','),
        isNot(
          anyOf(
            contains('host'),
            contains('port'),
            contains('address'),
            contains('device'),
            contains('vendor'),
            contains('bluetooth'),
          ),
        ),
      );
    });

    test('an unconfigured terminal still has a default order type', () {
      // Behaviour configuration does not depend on hardware either.
      expect(PosSettings.unconfigured.defaultOrderType, isNotNull);
    });
  });
}

/// A test page to encode when no sale is involved.
class PrinterTestPageFixture {
  const PrinterTestPageFixture._();

  static PrinterTestPage document() =>
      PrinterTestPage(printedAt: DateTime.utc(2026, 9, 13, 12));
}
