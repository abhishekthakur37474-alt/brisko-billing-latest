import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_discount.dart';
import 'package:brisko_billing/features/billing/domain/models/gst_rate.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/printers/platform_thermal_printer_factory.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_run.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer_factory.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// End-to-end physical validation of the real Brisko print pipeline against the
/// TVS RP 3200 Lite, driven through the SAME production classes the app wires in
/// `bootstrap.dart`: `PlatformThermalPrinterFactory` -> `TransportThermalPrinter` ->
/// `CupsRawPrintTransport` -> a real CUPS raw queue -> USB -> the printer.
///
/// It is not a substitute for the GUI, and it does not pretend to be one: it exercises
/// the production print service, encoder, document source and transport exactly as the
/// Settings/checkout screens do, and it physically emits paper. What it cannot do is see
/// the paper — every "printed" assertion below means the spooler accepted and completed
/// the job on an enabled queue, and the physical output is confirmed separately by a
/// human looking at the roll.
///
/// It is skipped unless BRISKO_PHYSICAL_PRINT=1, because it needs the real printer and a
/// CUPS queue (default `TVS_RP3200_TEST`) attached. On every other machine it is inert,
/// so the ordinary `flutter test` run stays hardware-independent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bool enabled = Platform.environment['BRISKO_PHYSICAL_PRINT'] == '1';
  final String queue =
      Platform.environment['BRISKO_PRINT_QUEUE'] ?? 'TVS_RP3200_TEST';

  group(
    'Brisko physical print flow (TVS RP 3200 Lite via CUPS raw queue)',
    () {
      late SqliteDatabase database;
      late ThermalPrinter printer;
      late PrintService printing;

      // Carried between the ordered tests: the sale printed in test 2 is the one
      // reprinted in tests 4 and 5 and failed against in test 6.
      String? orderId;

      setUpAll(() async {
        TestDatabase.register();
        database = await TestDatabase.openInMemory();

        // Seed the outlet's printed identity, so the physical receipt shows real
        // business details, a footer and a feedback URL (which drives the "Rate us"
        // review QR — a paid bill carries no payment QR). This is data entry, the
        // equivalent of filling the Settings screen — no business logic is touched.
        //
        // The address is the current short form. No GSTIN is seeded: the real outlet
        // GSTIN is not yet configured, and a bill prints a GSTIN line only when a real
        // one is entered. The placeholder tax number this test once carried
        // (29ABCDE1234F1Z5) is deliberately gone — a fake GSTIN on a tax invoice is
        // worse than none. The feedback URL below is TEST configuration, used only
        // until the outlet's real review URL is set.
        await SqliteSettingsRepository(database: database).writeAll(
          <String, String?>{
            SettingKeys.businessName: 'BRISKO PIZZA',
            SettingKeys.businessAddress:
                'Near: RMP(PG) College, Gurukul Narsan, Haridwar',
            SettingKeys.businessPhone: '+91 9058582158',
            SettingKeys.receiptFooter: 'Thank you — validation run',
            // TEST feedback URL. Replace with the outlet's real review URL for
            // production. Verified by scanning the printed QR on the physical roll.
            SettingKeys.feedbackUrl: 'https://g.page/r/brisko-pizza/review',
          },
        );

        // The real production printer for a USB device on macOS: a CUPS raw queue named
        // by deviceName. Identical to what the bootstrap builds when the operator saves
        // USB + deviceName in Settings.
        final PrinterConnectionSettings settings = PrinterConnectionSettings(
          isEnabled: true,
          transport: PrinterTransport.usb,
          address: null,
          port: null,
          deviceName: queue,
          label: 'TVS RP 3200 Lite (validation)',
          paperWidth: PaperWidth.mm80,
        );

        final PrinterResolution resolution = PlatformThermalPrinterFactory(
          platform: PrinterHostPlatform.macos,
        ).create(settings);

        // The build genuinely has a transport for this configuration.
        expect(resolution.support, PrinterTransportSupport.available);
        printer = resolution.printer;

        printing = TestPrinting.serviceOver(
          database,
          printer: printer,
        );
      });

      tearDownAll(() async {
        await printer.dispose();
        if (database.isOpen) {
          await database.close();
        }
      });

      Future<int> rowCount(String table) async {
        final List<Map<String, Object?>> rows = await database.database
            .rawQuery('SELECT COUNT(*) AS total FROM $table');
        return (rows.first['total'] as int?) ?? 0;
      }

      Future<Map<String, int>> businessRows() async => <String, int>{
        'orders': await rowCount('orders'),
        'order_items': await rowCount('order_items'),
        'payments': await rowCount('payments'),
        'kot_records': await rowCount('kot_records'),
        'kot_items': await rowCount('kot_items'),
        'customers': await rowCount('customers'),
        'stock_movements': await rowCount('stock_movements'),
        'refunds': await rowCount('refunds'),
      };

      // ---------------------------------------------------------- 1. test print ---

      test('1. in-app Test Print reaches the printer', () async {
        final result = await printing.printTestPage();

        // Spooler/service success: the job was built, sent and completed on an enabled
        // queue. Physical output (ruler line + cut) is confirmed by the operator.
        expect(
          result.isOk,
          isTrue,
          reason: 'Test page failed: ${result.failureOrNull?.message}',
        );
      });

      // -------------------------------------------------- 2. takeaway receipt ---

      test('2. a real sale commits first, then prints receipt + KOT', () async {
        final BillingController billing = await SeededCart.controller(
          SqliteMenuRepository(database: database),
        );
        addTearDown(billing.dispose);

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
          // 5% GST, so the physical receipt demonstrates a real CGST/SGST split
          // (2.5% + 2.5%) rather than a bill with no tax lines.
          taxRate: const GstRate.ofBasisPoints(500),
        );
        addTearDown(controller.dispose);

        // A ₹20 flat discount, so the receipt physically shows a discount line and a
        // taxable amount below the subtotal. Entered through the real review-step API,
        // the same one the cashier uses — no calculation is bypassed to force values.
        controller.setDiscountOpen(isOpen: true);
        controller.selectDiscountType(BillDiscountType.amount);
        controller.editDiscount('20');

        controller.setCustomerName('Test Customer');
        controller.setCustomerPhone('9000000001');
        controller.goToPayment();
        controller.selectPaymentMethod(PaymentMethod.cash);
        controller.tenderExact();
        controller.goToConfirm();

        await controller.submit();

        // The sale is committed regardless of the printer.
        expect(controller.isSettled, isTrue);
        expect(controller.hasError, isFalse);
        expect(controller.settledOrder, isNotNull);

        orderId = controller.settledOrder!.id;

        // The print run: KOT first, then receipt, both accepted by the printer.
        expect(controller.hasPrintFailure, isFalse,
            reason: controller.printMessage);
        expect(controller.isPrinted, isTrue);
        expect(
          controller.printRun!.jobs.map((PrintJob j) => j.kind).toList(),
          <PrintJobKind>[PrintJobKind.kitchenKot, PrintJobKind.customerReceipt],
        );
        // One order, one payment, one KOT.
        expect(await rowCount('orders'), 1);
        expect(await rowCount('payments'), 1);
        expect(await rowCount('kot_records'), 1);

        // The exact bytes sent to the printer for the customer receipt. Automation
        // cannot see the paper, but it can prove the stream that produced it carries
        // every required element; the visual checks (centred, clear, clean cut) are
        // confirmed by the operator against the physical roll.
        final PrintJob receiptJob = controller.printRun!.jobs.firstWhere(
          (PrintJob j) => j.kind == PrintJobKind.customerReceipt,
        );
        final EscPosTranscript bill = EscPosTranscript.of(receiptJob.bytes);
        expect(bill.rasterImages, isEmpty, reason: 'receipt carries no logo');
        expect(bill.hasLineContaining('BRISKO PIZZA'), isTrue);
        // Address/phone (4-5): the exact short address, and never the retired long one.
        expect(
          bill.hasLineContaining(
            'Near: RMP(PG) College, Gurukul Narsan, Haridwar',
          ),
          isTrue,
        );
        expect(bill.hasLineContaining('Phone +91 9058582158'), isTrue);
        expect(bill.text, isNot(contains('Delhi Haridwar Highway')));
        // GSTIN (6): none configured, so none printed.
        expect(bill.text, isNot(contains('GSTIN')));
        // Money block (10-15).
        expect(bill.hasLineContaining('Subtotal'), isTrue);
        expect(bill.hasLineContaining('Discount'), isTrue);
        expect(bill.hasLineContaining('Taxable amount'), isTrue);
        expect(bill.hasLineContaining('CGST'), isTrue);
        expect(bill.hasLineContaining('SGST'), isTrue);
        expect(bill.hasLineContaining('TOTAL'), isTrue);
        // Payment (16).
        expect(bill.hasLineContaining('Paid by Cash'), isTrue);
        // No payment request (17-18).
        expect(bill.text, isNot(contains('Scan to pay')));
        // Feedback block + QR (19-21) carrying the configured review URL.
        expect(bill.hasLineContaining('RATE US'), isTrue);
        expect(bill.hasLineContaining('Scan to share your feedback'), isTrue);
        expect(
          bill.qrPayloads,
          contains('https://g.page/r/brisko-pizza/review'),
        );
        // A first, normal copy is not marked as a reprint.
        expect(bill.hasLineContaining('*** REPRINT ***'), isFalse);
      });

      // ----------------------------------------------------------------- 3. KOT ---

      test('3. the KOT carries items but no financial information', () async {
        // The KOT physically printed as part of the checkout in test 2. Here its content
        // is verified against the exact bytes the transport sent.
        final run = await printing.reprintKitchenSlips(orderId!);
        expect(run.hasFailure, isFalse, reason: 'KOT reprint failed');
        final PrintJob kot = run.jobs.firstWhere(
          (PrintJob j) => j.kind == PrintJobKind.kitchenKot,
        );

        final EscPosTranscript slip = EscPosTranscript.of(kot.bytes);
        // The kitchen needs to know what to cook.
        expect(slip.hasLineContaining('Cheese Pizza'), isTrue);
        expect(slip.hasLineContaining('Extra Cheese'), isTrue);
        // It must never carry money: no rupee sign, no totals, no tax, no payment.
        expect(slip.text, isNot(contains('\u20b9')));
        expect(slip.text.toLowerCase(), isNot(contains('total')));
        expect(slip.text.toLowerCase(), isNot(contains('gst')));
        expect(slip.text.toLowerCase(), isNot(contains('cash')));
      });

      // ---------------------------------------------------- 4. receipt reprint ---

      test('4. receipt reprint prints and creates no new business data', () async {
        final Map<String, int> before = await businessRows();

        final SalePrintRun run = await printing.reprintReceipt(orderId!);

        expect(run.hasFailure, isFalse, reason: 'Receipt reprint failed');
        expect(
          run.jobs.map((PrintJob j) => j.kind),
          contains(PrintJobKind.customerReceipt),
        );
        // Nothing about the sale changed: no new order, payment, KOT, customer, stock
        // movement or refund.
        expect(await businessRows(), before);
      });

      // -------------------------------------------------------- 5. KOT reprint ---

      test('5. KOT reprint prints and creates no duplicate transaction', () async {
        final Map<String, int> before = await businessRows();

        final SalePrintRun run = await printing.reprintKitchenSlips(orderId!);

        expect(run.hasFailure, isFalse, reason: 'KOT reprint failed');
        expect(
          run.jobs.map((PrintJob j) => j.kind),
          contains(PrintJobKind.kitchenKot),
        );
        expect(await businessRows(), before);
      });

      // ------------------------------------------------- 6. failure + recovery ---

      test('6. a disabled printer fails cleanly; the sale stands; recovery works',
          () async {
        final Map<String, int> before = await businessRows();

        // Take the printer offline the way an unplugged cable would: CUPS disables the
        // queue. (cupsdisable/enable work without sudo for an _lpadmin user.)
        final ProcessResult disabled = await Process.run(
          'cupsdisable',
          <String>[queue],
        );
        expect(disabled.exitCode, 0, reason: 'cupsdisable failed: ${disabled.stderr}');

        final SalePrintRun failed = await printing.reprintReceipt(orderId!);

        // The print is reported as failed...
        expect(failed.hasFailure, isTrue);
        // ...and the completed sale is completely untouched.
        expect(await businessRows(), before);
        expect(await rowCount('orders'), 1);
        expect(await rowCount('payments'), 1);

        // Purge the job stuck on the disabled queue so recovery prints exactly one slip.
        await Process.run('cancel', <String>['-a', queue]);

        // Bring the printer back.
        final ProcessResult reenabled = await Process.run(
          'cupsenable',
          <String>[queue],
        );
        expect(reenabled.exitCode, 0, reason: 'cupsenable failed: ${reenabled.stderr}');
        await Process.run('cupsaccept', <String>[queue]);

        final SalePrintRun recovered = await printing.reprintReceipt(orderId!);
        expect(recovered.hasFailure, isFalse,
            reason: 'Recovery print failed: '
                '${recovered.jobs.map((PrintJob j) => j.failureMessage)}');
        // Still no business-data change from the whole failure/recovery cycle.
        expect(await businessRows(), before);
      });

      // -------------------------------------------------- 7. dine-in receipt ---
      //
      // Placed last so it does not disturb the single-order counts the earlier tests
      // assert. Its only purpose is to physically emit a Dine-in bill + KOT, so the
      // operator can confirm the order type is stamped correctly on both.

      test('7. a paid Dine-in sale prints its receipt + KOT', () async {
        final BillingController billing = await SeededCart.controller(
          SqliteMenuRepository(database: database),
        );
        addTearDown(billing.dispose);

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
          // The one difference from the takeaway sale in test 2: the order type stamped
          // on the bill and the KOT. Otherwise the same discounted, taxed bill.
          initialOrderType: OrderType.dineIn,
          taxRate: const GstRate.ofBasisPoints(500),
        );
        addTearDown(controller.dispose);

        // Same ₹20 flat discount + 5% GST as the takeaway sale, so the Dine-in receipt
        // also physically demonstrates the discount and the CGST/SGST split.
        controller.setDiscountOpen(isOpen: true);
        controller.selectDiscountType(BillDiscountType.amount);
        controller.editDiscount('20');

        controller.setCustomerName('Test Customer');
        controller.setCustomerPhone('9000000001');
        controller.goToPayment();
        controller.selectPaymentMethod(PaymentMethod.cash);
        controller.tenderExact();
        controller.goToConfirm();

        await controller.submit();

        // Payment first, then paper — the same rule as every other sale.
        expect(controller.isSettled, isTrue);
        expect(controller.hasError, isFalse);
        expect(controller.settledOrder!.orderType, OrderType.dineIn);
        expect(controller.hasPrintFailure, isFalse,
            reason: controller.printMessage);
        expect(controller.isPrinted, isTrue);
        expect(
          controller.printRun!.jobs.map((PrintJob j) => j.kind).toList(),
          <PrintJobKind>[PrintJobKind.kitchenKot, PrintJobKind.customerReceipt],
        );
      });
    },
    skip: enabled
        ? false
        : 'Physical printer test. Run with BRISKO_PHYSICAL_PRINT=1 and the '
              '$queue CUPS queue attached.',
  );
}
