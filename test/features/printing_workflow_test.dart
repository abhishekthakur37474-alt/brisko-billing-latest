import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/checkout_controller.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket.dart';
import 'package:brisko_billing/features/kot/domain/models/kitchen_ticket_draft.dart';
import 'package:brisko_billing/features/kot/domain/models/kot_status.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item_option.dart';
import 'package:brisko_billing/features/orders/presentation/controllers/bill_detail_controller.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/printers/configurable_thermal_printer.dart';
import 'package:brisko_billing/features/printing/data/printers/no_transport_printer_factory.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_setting_keys.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_run.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_source.dart';
import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/fixed_printer_factory.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// The printing workflow, from a settled bill to paper and back again.
///
/// ## What this file is for
///
/// The pieces of printing each have their own test — the byte protocol in
/// `escpos_builder_test`, the layout in `print_document_test`, the service in
/// `print_service_test`, the settled-but-not-printed guarantee in
/// `checkout_printing_test`. What is checked here is the *workflow* those pieces make
/// when they are wired together the way the application wires them: paid bill → receipt
/// job → kitchen slip job → printer → status → what the operator is told, and then the
/// reprint, the retry and the test page that hang off it.
///
/// ## Every one of these runs with no printer in the room
///
/// The transport is either the honest `UnconfiguredThermalPrinter` this build ships or a
/// `FakeEscPosPrinter` that extends the production `EscPosThermalPrinter` and so exercises
/// its real connection state machine. Nothing below fakes a successful write: where a
/// send succeeds it is because the fake transport accepted the bytes, and where it fails
/// it is because it was told to throw.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkoutRepository;
  late SqliteCustomerRepository customers;
  late SqliteOrderRepository orders;
  late SqlitePaymentRepository payments;
  late SqliteKotRepository kots;
  late SqliteSettingsRepository settings;
  late SqliteInventoryDeductionRepository deductions;
  late BillingController billing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkoutRepository = SqliteCheckoutRepository(database: database);
    customers = SqliteCustomerRepository(database: database);
    orders = SqliteOrderRepository(database: database);
    payments = SqlitePaymentRepository(database: database);
    kots = SqliteKotRepository(database: database);
    settings = SqliteSettingsRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
    billing = await SeededCart.controller(menu);
  });

  tearDown(() async {
    billing.dispose();
    if (database.isOpen) {
      await database.close();
    }
  });

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Clears every kitchen slip, which is the shape of a bill whose slips were never
  /// raised. Deleted child-first, because each level carries a foreign key onto the one
  /// above it.
  Future<void> clearKitchenSlips() async {
    await database.database.delete('kot_item_options');
    await database.database.delete('kot_items');
    await database.database.delete('kot_records');
  }

  /// Every row a sale writes, so a reprint can be shown to add none of them.
  Future<Map<String, int>> saleRows() async => <String, int>{
    'orders': await rowCount('orders'),
    'order_items': await rowCount('order_items'),
    'order_item_options': await rowCount('order_item_options'),
    'payments': await rowCount('payments'),
    'kot_records': await rowCount('kot_records'),
    'kot_items': await rowCount('kot_items'),
    'stock_movements': await rowCount('stock_movements'),
  };

  /// Settles one bill through the real checkout, on [printer].
  ///
  /// Returns the settled order id. The whole sale — order, lines, options, payment,
  /// kitchen slip — is committed by `SqliteCheckoutRepository` in one transaction before
  /// anything prints, which is the ordering the rest of this file depends on.
  Future<String> settleBill(
    PrintService printing, {
    PaymentMethod method = PaymentMethod.cash,
    FakeEscPosPrinter? clearRecording,
  }) async {
    await SeededCart.add(
      billing,
      category: 'SIMPLY VEG',
      item: 'Cheese Pizza',
      size: 'Medium',
      options: <String>['Extra Cheese'],
    );
      final CheckoutController controller = CheckoutController(
        cart: billing.cart,
        checkoutRepository: checkoutRepository,
        customerRepository: customers,
        inventoryDeductionRepository: deductions,
        printService: printing,
        onSettled: billing.clearCart,
      );
      addTearDown(controller.dispose);
      controller.setCustomerName('Test Customer');
      controller.setCustomerPhone('9000000001');
      controller.goToPayment();
    controller.selectPaymentMethod(method);
    controller.tenderExact();
    controller.goToConfirm();
    await controller.submit();
    expect(
      controller.isSettled,
      isTrue,
      reason: 'the fixture must settle before anything is printed',
    );
    // Settlement already printed, which is the workflow. A test that counts documents is
    // interested in the run it starts itself, so the fixture's paper is forgotten here.
    clearRecording?.clearRecording();
    return controller.settledOrder!.id;
  }

  // ================================================================ jobs ===

  group('the jobs a paid bill produces', () {
    test('a receipt job and a kitchen slip job, in that order', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.jobs, hasLength(2));
      // The kitchen first: somebody is waiting on the food, and if the roll runs out
      // halfway through a sale it is the receipt that can be reprinted.
      expect(run.jobs.first.kind, PrintJobKind.kitchenKot);
      expect(run.jobs.last.kind, PrintJobKind.customerReceipt);
      expect(run.orderId, orderId);
      expect(run.orderNumber, isNotEmpty);
    });

    test('each job carries encoded bytes, a title and the order', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      final SalePrintRun run = await printing.printSale(orderId);

      for (final PrintJob job in run.jobs) {
        expect(job.bytes, isNotEmpty);
        expect(job.isEmpty, isFalse);
        expect(job.title, isNotEmpty);
        expect(job.orderId, orderId);
        expect(job.createdAt.isUtc, isTrue);
        expect(job.fingerprint, hasLength(8));
      }

      // Distinct identities, so a log or a screen can tell one from the other.
      expect(run.jobs.first.id, isNot(run.jobs.last.id));
    });

    test('one order can produce several kitchen slips and one receipt', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);

      // A second slip raised against the same order, which is what adding items to a
      // bill after the first slip went to the kitchen produces. Written through the
      // repository the same way an after-the-fact slip is.
      expect(
        (await kots.loadTicketsForOrder(orderId)).valueOrNull,
        hasLength(1),
      );
      final Order order = (await orders.findOrder(orderId)).valueOrNull!;
      final List<OrderItem> items = (await orders.loadItems(orderId))
          .valueOrNull!;
      final List<OrderItemOption> options = <OrderItemOption>[];
      for (final OrderItem item in items) {
        options.addAll((await orders.loadItemOptions(item.id)).valueOrNull!);
      }
      final KitchenTicketDraft second = KitchenTicketDraft.fromOrder(
        order: order,
        items: items,
        itemOptions: options,
        kotNumber: (await kots.nextKotNumber()).valueOrNull!,
      );
      _expectOk(
        await kots.createKot(
          second.record,
          second.items,
          itemOptions: second.itemOptions,
        ),
      );

      printer.clearRecording();
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.jobs, hasLength(3));
      expect(
        run.jobs.where((PrintJob job) => job.kind == PrintJobKind.kitchenKot),
        hasLength(2),
      );
      expect(
        run.jobs.where(
          (PrintJob job) => job.kind == PrintJobKind.customerReceipt,
        ),
        hasLength(1),
      );
      // Two slips with different titles, so a retry can tell which one failed.
      final List<String> slipTitles = run.jobs
          .where((PrintJob job) => job.kind == PrintJobKind.kitchenKot)
          .map((PrintJob job) => job.title)
          .toList(growable: false);
      expect(slipTitles.toSet(), hasLength(2));
    });
  });

  // ============================================================ documents ===

  group('what reaches the paper', () {
    late FakeEscPosPrinter printer;
    late PrintService printing;

    setUp(() {
      printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      printing = TestPrinting.serviceOver(database, printer: printer);
    });

    /// The transcript of one kind of document from the last run.
    EscPosTranscript documentOf(PrintJobKind kind) =>
        EscPosTranscript.of(printer.jobsOf(kind).last.bytes);

    test('the receipt carries the bill the customer was charged', () async {
      _expectOk(
        await settings.writeAll(<String, String?>{
          SettingKeys.businessName: 'Brisko Pizza',
          SettingKeys.businessPhone: '020 2545 1234',
          SettingKeys.gstin: '27AAPFU0939F1ZV',
          SettingKeys.receiptFooter: 'Thank you, come again',
        }),
      );

      final String orderId = await settleBill(printing);
      await printing.printSale(orderId);

      final EscPosTranscript receipt = documentOf(PrintJobKind.customerReceipt);

      // Who the outlet is, and what it is registered as.
      expect(receipt.hasLineContaining('Brisko Pizza'), isTrue);
      expect(receipt.hasLineContaining('020 2545 1234'), isTrue);
      expect(receipt.hasLineContaining('27AAPFU0939F1ZV'), isTrue);
      // The bill itself.
      expect(receipt.hasLineContaining('Cheese Pizza'), isTrue);
      expect(receipt.hasLineContaining('Medium'), isTrue);
      expect(receipt.hasLineContaining('Extra Cheese'), isTrue);
      expect(receipt.hasLineContaining('Takeaway'), isTrue);
      // The figures, and how they were paid.
      expect(receipt.hasLineContaining('Subtotal'), isTrue);
      expect(receipt.hasLineContaining('TOTAL'), isTrue);
      expect(receipt.hasLineContaining('Paid by Cash'), isTrue);
      expect(receipt.hasLineContaining('Thank you, come again'), isTrue);
    });

    test('the kitchen slip carries the food and none of the money', () async {
      final String orderId = await settleBill(printing);
      await printing.printSale(orderId);

      final EscPosTranscript slip = documentOf(PrintJobKind.kitchenKot);

      // What the kitchen has to cook.
      expect(slip.hasLineContaining('Cheese Pizza'), isTrue);
      expect(slip.hasLineContaining('Medium'), isTrue);
      expect(slip.hasLineContaining('Extra Cheese'), isTrue);
      expect(slip.hasLineContaining('Qty'), isTrue);

      // And nothing a customer would be charged. A price on a kitchen slip is a slip
      // that can be handed over as a bill by mistake.
      for (final String forbidden in <String>[
        'Subtotal',
        'Discount',
        'Tax',
        'Total',
        'Cash',
        'UPI',
        'Card',
        'Paid',
        'Change',
      ]) {
        expect(
          slip.hasLineContaining(forbidden),
          isFalse,
          reason: 'the kitchen slip must not mention $forbidden',
        );
      }

      // No amount at all: two decimal places anywhere would be one.
      expect(
        RegExp(r'\d+\.\d{2}').hasMatch(slip.text),
        isFalse,
        reason: 'the kitchen slip must carry no amount',
      );
    });

    test('both documents are laid out inside the 80mm budget', () async {
      final String orderId = await settleBill(printing);
      await printing.printSale(orderId);

      for (final PrintJobKind kind in <PrintJobKind>[
        PrintJobKind.kitchenKot,
        PrintJobKind.customerReceipt,
      ]) {
        final EscPosTranscript document = documentOf(kind);
        expect(
          document.widestLine,
          lessThanOrEqualTo(PaperWidth.mm80.characterColumns),
          reason: '$kind overflows 48 columns',
        );
      }
    });
  });

  // ============================================================== printer ===

  group('the printer', () {
    test('an unconfigured terminal reports that, and prints nothing', () async {
      final UnconfiguredThermalPrinter printer = UnconfiguredThermalPrinter();
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      final SalePrintRun run = await printing.printSale(orderId);

      expect(printer.connectionState, PrinterConnectionState.unavailable);
      expect(printer.connectionState.isConfigured, isFalse);
      expect(run.hasFailure, isTrue);
      expect(run.isComplete, isFalse);
      expect(run.printedJobs, isEmpty);
      // Every document failed, and each says what would fix it.
      for (final PrintJob job in run.jobs) {
        expect(job.state, PrintJobState.failed);
        expect(job.failureMessage, contains('Settings'));
      }
      // And the message leads with the fact that the money is safe.
      expect(run.operatorMessage, startsWith(SalePrintRun.paidButNotPrinted));
      expect(run.failedDocuments, contains('Customer receipt'));
      expect(run.failedDocuments, contains('Kitchen slip'));
    });

    test('a configured printer with no transport says exactly that', () async {
      // The honest hardware boundary of this build: the operator has filled the form in
      // correctly and the software still cannot reach the device. That is neither
      // "nothing configured" nor "the cable is out", and it must not be reported as
      // either.
      const PrinterConnectionSettings configured = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '192.168.1.50',
        port: 9100,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
        settings: configured,
      );
      addTearDown(printer.dispose);

      expect(printer.status.support, PrinterTransportSupport.notInstalled);
      expect(printer.status.isConfigured, isTrue);
      expect(printer.status.canPrint, isFalse);
      expect(printer.endpoint?.description, '192.168.1.50:9100');
      expect(printer.status.detail, contains('Counter printer'));
      expect(printer.status.detail, contains('no Network transport'));

      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );
      final String orderId = await settleBill(printing);
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, contains('Counter printer'));
      expect(run.failureReason, contains('configuration is stored'));
    });

    test('a working printer prints every document and says so', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(
        printing,
        clearRecording: printer,
      );
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.isComplete, isTrue);
      expect(run.hasFailure, isFalse);
      expect(run.isInProgress, isFalse);
      expect(run.operatorMessage, isNull);
      expect(run.printedJobs, hasLength(2));
      for (final PrintJob job in run.jobs) {
        expect(job.state, PrintJobState.printed);
        expect(job.isPrinted, isTrue);
        expect(job.attempts, 1);
        expect(job.failureMessage, isNull);
        expect(job.canRetry, isFalse);
      }
      // The bytes actually went through the transport.
      expect(printer.documents, hasLength(2));
      expect(printer.openCount, greaterThan(0));
    });

    test(
      'a printer that faults mid-run leaves each job with its own outcome',
      () async {
        final FakeEscPosPrinter printer = FakeEscPosPrinter();
        addTearDown(printer.dispose);
        final PrintService printing = TestPrinting.serviceOver(
          database,
          printer: printer,
        );

        final String orderId = await settleBill(printing);
        printer
          ..failOnWrite = true
          ..faultMessage = 'Out of paper.';

        final SalePrintRun run = await printing.printSale(orderId);

        expect(run.hasFailure, isTrue);
        expect(run.isComplete, isFalse);
        expect(run.failedJobs, hasLength(2));
        // The transport's exception is translated into a sentence the cashier can act
        // on by `EscPosThermalPrinter`, and that sentence is what reaches the run.
        expect(
          run.failureReason,
          contains('The printer stopped while printing'),
        );
        expect(
          run.operatorMessage,
          contains('Check the paper and the connection'),
        );
        expect(run.operatorMessage, startsWith(SalePrintRun.paidButNotPrinted));
        for (final PrintJob job in run.jobs) {
          expect(job.state, PrintJobState.failed);
          expect(job.canRetry, isTrue);
          expect(job.attempts, 1);
        }
      },
    );
  });

  // ================================================================ retry ===

  group('retrying', () {
    test('a retry re-sends only what failed and counts the attempt', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(orderId);
      expect(failed.hasFailure, isTrue);

      printer
        ..repair()
        ..clearRecording();
      final SalePrintRun retried = await printing.retry(failed);

      expect(retried.isComplete, isTrue);
      expect(retried.hasFailure, isFalse);
      expect(printer.documents, hasLength(2));
      for (final PrintJob job in retried.jobs) {
        expect(job.attempts, 2);
        expect(job.failureMessage, isNull);
      }
      // The same jobs, not new ones. A retry that minted fresh ids would read as a
      // second sale in any log that grouped by job.
      expect(
        retried.jobs.map((PrintJob job) => job.id),
        failed.jobs.map((PrintJob job) => job.id),
      );
    });

    test('a retry of a run with nothing failed sends nothing', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      final SalePrintRun run = await printing.printSale(orderId);
      expect(run.isComplete, isTrue);

      printer.clearRecording();
      final SalePrintRun again = await printing.retry(run);

      // Untouched, and above all nothing sent: re-sending a receipt that printed would
      // put a second bill in the customer's hand.
      expect(printer.documents, isEmpty);
      expect(again.jobs.map((PrintJob job) => job.attempts), <int>[1, 1]);
    });

    test('retrying many times writes no row and keeps one sale', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      printer.failOnWrite = true;
      SalePrintRun run = await printing.printSale(orderId);

      final Map<String, int> before = await saleRows();
      for (int attempt = 0; attempt < 5; attempt++) {
        run = await printing.retry(run);
      }
      final Map<String, int> after = await saleRows();

      expect(run.hasFailure, isTrue);
      expect(run.jobs.first.attempts, 6);
      // The point of the whole design: printing has no write in its path, so no number
      // of retries can duplicate anything.
      expect(after, before);
      expect(after['orders'], 1);
      expect(after['payments'], 1);
      expect(after['kot_records'], 1);
    });
  });

  // ============================================================== reprint ===

  group('reprinting', () {
    late FakeEscPosPrinter printer;
    late PrintService printing;

    setUp(() {
      printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      printing = TestPrinting.serviceOver(database, printer: printer);
    });

    test('a receipt reprint sends the receipt and not the slip', () async {
      final String orderId = await settleBill(printing);
      printer.clearRecording();

      final SalePrintRun run = await printing.reprintReceipt(orderId);

      expect(run.isComplete, isTrue);
      expect(run.jobs, hasLength(1));
      expect(run.jobs.single.kind, PrintJobKind.customerReceipt);
      expect(printer.jobsOf(PrintJobKind.kitchenKot), isEmpty);
      // Marked, so a second copy cannot be mistaken for a second sale.
      expect(
        EscPosTranscript.of(printer.lastDocument).text.toUpperCase(),
        contains('REPRINT'),
      );
    });

    test('a kitchen slip reprint sends the slip and not the receipt', () async {
      final String orderId = await settleBill(printing);
      printer.clearRecording();

      final SalePrintRun run = await printing.reprintKitchenSlips(orderId);

      expect(run.isComplete, isTrue);
      expect(run.jobs, hasLength(1));
      expect(run.jobs.single.kind, PrintJobKind.kitchenKot);
      expect(printer.jobsOf(PrintJobKind.customerReceipt), isEmpty);
    });

    test('reprinting writes nothing at all', () async {
      final String orderId = await settleBill(printing);
      // The stock deduction the settlement kicked off has already run by now, so this
      // baseline includes it.
      final Map<String, int> before = await saleRows();

      await printing.reprintSale(orderId);
      await printing.reprintReceipt(orderId);
      await printing.reprintReceipt(orderId);
      await printing.reprintKitchenSlips(orderId);

      // No second order, no second payment, no second kitchen ticket, and no second
      // stock movement. Reprinting is a read followed by a write to a cable.
      expect(await saleRows(), before);
    });

    test('reprinting does not move a kitchen slip off the board', () async {
      final String orderId = await settleBill(printing);
      final KitchenTicket before = (await kots.loadTicketsForOrder(orderId))
          .valueOrNull!
          .single;
      expect(before.status, KotStatus.pending);

      await printing.reprintKitchenSlips(orderId);
      await printing.reprintSale(orderId);

      final KitchenTicket after = (await kots.loadTicketsForOrder(orderId))
          .valueOrNull!
          .single;
      // Still pending, and still active. Printing paper is not the kitchen starting the
      // food, and a slip that left the board when it printed would be a slip nobody
      // cooks.
      expect(after.status, KotStatus.pending);
      expect(after.status.isActive, isTrue);
    });

    test('the kitchen workflow still advances after printing', () async {
      final String orderId = await settleBill(printing);
      await printing.reprintSale(orderId);

      final KitchenTicket ticket = (await kots.loadTicketsForOrder(orderId))
          .valueOrNull!
          .single;
      _expectOk(await kots.advanceStatus(ticket.id, KotStatus.preparing));
      _expectOk(await kots.advanceStatus(ticket.id, KotStatus.ready));

      final KitchenTicket done = (await kots.loadTicketsForOrder(orderId))
          .valueOrNull!
          .single;
      expect(done.status, KotStatus.ready);
    });

    test('a reprint is built from storage, not from the cart', () async {
      final String orderId = await settleBill(printing);
      // The cart is already cleared by settlement. Cleared again, explicitly, so the
      // reprint below cannot be reading anything that is still in memory.
      billing.clearCart();
      expect(billing.cart.isEmpty, isTrue);
      printer.clearRecording();

      final SalePrintRun run = await printing.reprintReceipt(orderId);

      expect(run.isComplete, isTrue);
      final EscPosTranscript receipt = EscPosTranscript.of(
        printer.lastDocument,
      );
      expect(receipt.hasLineContaining('Cheese Pizza'), isTrue);
      expect(receipt.hasLineContaining('Extra Cheese'), isTrue);
    });

    test(
      'a reprint of an order with no slips reports nothing to print',
      () async {
        final String orderId = await settleBill(printing);
        await clearKitchenSlips();

        final SalePrintRun run = await printing.reprintKitchenSlips(orderId);

        // Not a failure. There is genuinely nothing to print, and that is a different
        // thing to tell somebody.
        expect(run.isEmpty, isTrue);
        expect(run.hasFailure, isFalse);
        expect(run.isComplete, isFalse);
      },
    );

    test('a reprint of an unknown order fails without throwing', () async {
      final SalePrintRun run = await printing.reprintReceipt('ord_missing');

      expect(run.hasFailure, isTrue);
      expect(run.jobs.single.kind, PrintJobKind.customerReceipt);
      expect(run.jobs.single.isEmpty, isTrue);
      expect(run.failureReason, isNotNull);
    });
  });

  // ================================================= reprint from the bill ===

  group('reprinting from a stored bill', () {
    Future<BillDetailController> openBill(
      String orderId,
      PrintService printing,
    ) async {
      final BillDetailController controller = BillDetailController(
        orderId: orderId,
        orderRepository: orders,
        paymentRepository: payments,
        customerRepository: customers,
        refundRepository: SqliteRefundRepository(database: database),
        printService: printing,
      );
      addTearDown(controller.dispose);
      await controller.load();
      return controller;
    }

    test('the receipt can be reprinted and reports success', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      final BillDetailController bill = await openBill(orderId, printing);
      printer.clearRecording();

      expect(bill.canReprint, isTrue);
      expect(await bill.reprintReceipt(), isTrue);

      expect(bill.didReprint, isTrue);
      expect(bill.reprintMessage, 'Receipt sent to the printer.');
      expect(printer.jobsOf(PrintJobKind.customerReceipt), hasLength(1));
      expect(printer.jobsOf(PrintJobKind.kitchenKot), isEmpty);
    });

    test(
      'a reprint writes no order, no payment and no stock movement',
      () async {
        final FakeEscPosPrinter printer = FakeEscPosPrinter();
        addTearDown(printer.dispose);
        final PrintService printing = TestPrinting.serviceOver(
          database,
          printer: printer,
        );

        final String orderId = await settleBill(printing);
        final BillDetailController bill = await openBill(orderId, printing);
        final Map<String, int> before = await saleRows();

        await bill.reprintReceipt();
        await bill.reprintKitchenSlips();
        await bill.reprintReceipt();

        expect(await saleRows(), before);
        // And the figures on the bill are the ones that were read, unchanged.
        expect(
          bill.order!.totalAmount,
          (await orders.findOrder(orderId)).valueOrNull!.totalAmount,
        );
      },
    );

    test('a printer failure is reported without hiding the bill', () async {
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      );

      final String orderId = await settleBill(printing);
      final BillDetailController bill = await openBill(orderId, printing);

      expect(await bill.reprintReceipt(), isFalse);
      expect(bill.didReprint, isFalse);
      expect(bill.reprintMessage, startsWith('Receipt could not be printed.'));
      expect(bill.reprintMessage, contains('Settings'));
      // The document is still on screen, and the money is untouched.
      expect(bill.hasError, isFalse);
      expect(bill.order, isNotNull);
      expect(bill.refundError, isNull);

      bill.dismissReprintMessage();
      expect(bill.reprintMessage, isNull);
    });

    test('an order with no slip says so rather than failing', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(printing);
      await clearKitchenSlips();
      final BillDetailController bill = await openBill(orderId, printing);

      expect(await bill.reprintKitchenSlips(), isFalse);
      expect(
        bill.reprintMessage,
        'There is no kitchen slip stored against this bill.',
      );
      expect(bill.didReprint, isFalse);
    });
  });

  // ================================================ reprint from the till ===

  group('reprinting from the success screen', () {
    /// A checkout walked all the way to a settled bill, held so its actions can be
    /// pressed.
    Future<CheckoutController> settledCheckout(PrintService printing) async {
      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
      );
      final CheckoutController controller = CheckoutController(
        cart: billing.cart,
        checkoutRepository: checkoutRepository,
        customerRepository: customers,
        inventoryDeductionRepository: deductions,
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
      return controller;
    }

    test('the receipt can be sent again, and only the receipt', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final CheckoutController controller = await settledCheckout(printing);
      printer.clearRecording();

      expect(controller.canReprint, isTrue);
      await controller.reprintReceipt();

      expect(printer.jobsOf(PrintJobKind.customerReceipt), hasLength(1));
      // Re-cutting a slip for food already being cooked would put a second order into
      // the pass.
      expect(printer.jobsOf(PrintJobKind.kitchenKot), isEmpty);
      expect(controller.isPrinted, isTrue);
    });

    test('the kitchen slip can be sent again, and only the slip', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final CheckoutController controller = await settledCheckout(printing);
      printer.clearRecording();

      await controller.reprintKitchenSlips();

      expect(printer.jobsOf(PrintJobKind.kitchenKot), hasLength(1));
      expect(printer.jobsOf(PrintJobKind.customerReceipt), isEmpty);
    });

    test(
      'reprinting from the till writes nothing and keeps one sale',
      () async {
        final FakeEscPosPrinter printer = FakeEscPosPrinter();
        addTearDown(printer.dispose);
        final PrintService printing = TestPrinting.serviceOver(
          database,
          printer: printer,
        );

        final CheckoutController controller = await settledCheckout(printing);
        final Map<String, int> before = await saleRows();

        await controller.reprintReceipt();
        await controller.reprintReceipt();
        await controller.reprintKitchenSlips();

        expect(await saleRows(), before);
        expect(controller.isSettled, isTrue);
        expect(controller.errorMessage, isNull);
      },
    );

    test('it is still offered after a printing failure was dismissed', () async {
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      );

      final CheckoutController controller = await settledCheckout(printing);
      expect(controller.hasPrintFailure, isTrue);

      controller.dismissPrintFailure();
      expect(controller.printMessage, isNull);

      // The bill is on disk, which is all a reprint needs.
      expect(controller.canReprint, isTrue);
      await controller.reprintReceipt();

      // And it reports the printer honestly rather than quietly doing nothing.
      expect(controller.hasPrintFailure, isTrue);
      expect(controller.isSettled, isTrue);
    });
  });

  // =========================================================== settlement ===

  group('printing cannot cost a sale', () {
    test('a total printer failure leaves the bill settled and paid', () async {
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      );

      await SeededCart.add(
        billing,
        category: 'SIMPLY VEG',
        item: 'Cheese Pizza',
        size: 'Medium',
      );
      final CheckoutController controller = CheckoutController(
        cart: billing.cart,
        checkoutRepository: checkoutRepository,
        customerRepository: customers,
        inventoryDeductionRepository: deductions,
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

      // The sale stands, in full.
      expect(controller.isSettled, isTrue);
      expect(controller.errorMessage, isNull);
      expect(controller.settledOrder, isNotNull);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);

      // And the printer's problem is reported as a printer's problem.
      expect(controller.hasPrintFailure, isTrue);
      expect(controller.isPrinted, isFalse);
      expect(
        controller.printMessage,
        startsWith(SalePrintRun.paidButNotPrinted),
      );

      // Dismissing the notice clears a message, not a record.
      controller.dismissPrintFailure();
      expect(controller.printMessage, isNull);
      expect(controller.isSettled, isTrue);
      expect(await rowCount('orders'), 1);
    });
  });

  // ============================================================== offline ===

  group('printing is independent of the cloud', () {
    /// Every file the printing feature owns.
    List<String> printingFiles() =>
        Directory('lib/features/printing')
            .listSync(recursive: true)
            .whereType<File>()
            .map((File file) => file.path)
            .where((String path) => path.endsWith('.dart'))
            .toList(growable: false)
          ..sort();

    test('nothing in the printing module reaches for a network', () {
      // A bill has to print in a power cut with the line down, so printing must not
      // acquire a dependency that can be unavailable. Checked as a rule about the code
      // rather than as a behaviour, because a passing behavioural test only proves the
      // one path it happened to take was offline.
      const Map<String, String> cloud = <String, String>{
        'connectivity': r'[Cc]onnectivity',
        'the sync coordinator': r'SyncCoordinator|SyncState|syncNow',
        'the upload queue': r'\bOutbox\b|outboxStore',
        'a remote store': r'RemoteStore|[Ff]irebase|[Ff]irestore',
        'an HTTP client': r'\bhttp\b|HttpClient|\bdio\b',
        'a URL fetch': r'https?://',
      };

      final List<String> files = printingFiles();
      expect(files, isNotEmpty);

      for (final String path in files) {
        final String code = DartSource.codeOf(path);
        cloud.forEach((String label, String pattern) {
          expect(
            code,
            isNot(matches(RegExp(pattern))),
            reason:
                '$path mentions $label. A bill must print with the line down.',
          );
        });
      }
    });

    test('a bill prints with no connectivity anywhere in the graph', () async {
      // The positive half of the same statement: the whole path from a committed sale to
      // a byte stream runs with nothing but a local database and a transport.
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final String orderId = await settleBill(
        printing,
        clearRecording: printer,
      );
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.isComplete, isTrue);
      expect(printer.documents, hasLength(2));
    });
  });

  // =========================================================== test print ===

  group('the test page', () {
    test('it fails honestly on a terminal with no printer', () async {
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      );

      final Result<PrintJob> printed = await printing.printTestPage();

      expect(printed.isErr, isTrue);
      expect(printed.failureOrNull!.message, contains('No thermal printer'));
      expect(printed.valueOrNull, isNull);
    });

    test('it prints through the same printer a receipt uses', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      final Result<PrintJob> printed = await printing.printTestPage();

      expect(printed.isOk, isTrue);
      final PrintJob job = printed.valueOrNull!;
      expect(job.kind, PrintJobKind.testPage);
      expect(job.state, PrintJobState.printed);
      // It belongs to no sale, so it carries no order.
      expect(job.orderId, isNull);
      expect(printer.jobsOf(PrintJobKind.testPage), hasLength(1));
    });

    test('the test page carries no payment code and no amount', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );

      await printing.printTestPage();
      final EscPosTranscript page = EscPosTranscript.of(printer.lastDocument);

      // A test page with a real `upi://pay` link on it could be scanned and take money
      // against no order.
      expect(page.qrPayloads, isEmpty);
      expect(page.text, isNot(contains('upi://')));
      expect(RegExp(r'\d+\.\d{2}').hasMatch(page.text), isFalse);
    });

    test('a fault during a test page is reported, not thrown', () async {
      final FakeEscPosPrinter printer = FakeEscPosPrinter();
      addTearDown(printer.dispose);
      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );
      printer
        ..failOnOpen = true
        ..faultMessage = 'Nothing on the socket.';

      final Result<PrintJob> printed = await printing.printTestPage();

      expect(printed.isErr, isTrue);
      expect(printed.failureOrNull!.message, contains('Could not reach'));
    });
  });

  // ====================================================== print settings ===

  group('the printer binding', () {
    test('it round-trips through the settings table', () async {
      const PrinterConnectionSettings saved = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '10.0.0.7',
        port: 9101,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );

      _expectOk(await settings.writeAll(saved.toStored()));

      final Map<String, String?> stored =
          (await settings.readAll()).valueOrNull!;
      expect(stored[PrinterSettingKeys.enabled], 'true');
      expect(stored[PrinterSettingKeys.transport], 'lan');
      expect(stored[PrinterSettingKeys.address], '10.0.0.7');
      expect(stored[PrinterSettingKeys.port], '9101');
      expect(stored[PrinterSettingKeys.label], 'Counter printer');
      expect(stored[PrinterSettingKeys.paperWidth], 'mm80');

      expect(PrinterConnectionSettings.fromStored(stored), saved);
    });

    test('a USB binding stores no address and no port', () async {
      const PrinterConnectionSettings usb = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.usb,
        address: null,
        port: null,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );

      _expectOk(await settings.writeAll(usb.toStored()));
      final Map<String, String?> stored =
          (await settings.readAll()).valueOrNull!;

      // A null value removes the key rather than storing a blank, so "not chosen" and
      // "chosen as empty" cannot be confused on the way back in.
      expect(stored.containsKey(PrinterSettingKeys.address), isFalse);
      expect(stored.containsKey(PrinterSettingKeys.port), isFalse);
      expect(PrinterConnectionSettings.fromStored(stored), usb);
      expect(usb.endpoint?.transport, PrinterTransport.usb);
      expect(usb.isConfigured, isTrue);
    });

    test('an empty table reads as an unconfigured terminal', () {
      expect(
        PrinterConnectionSettings.fromStored(const <String, String?>{}),
        PrinterConnectionSettings.unconfigured,
      );
      expect(PrinterConnectionSettings.unconfigured.isEnabled, isFalse);
      expect(PrinterConnectionSettings.unconfigured.isConfigured, isFalse);
      expect(PrinterConnectionSettings.unconfigured.endpoint, isNull);
      expect(
        PrinterConnectionSettings.unconfigured.paperWidth,
        PaperWidth.mm80,
      );
    });

    test('a corrupt row falls back rather than failing', () {
      final PrinterConnectionSettings read =
          PrinterConnectionSettings.fromStored(<String, String?>{
            PrinterSettingKeys.enabled: 'yes',
            PrinterSettingKeys.transport: 'carrier-pigeon',
            PrinterSettingKeys.port: 'nine thousand',
            PrinterSettingKeys.paperWidth: 'A4',
          });

      // A terminal has to open and take money even if one row of its configuration is
      // unreadable, and the safe direction to fall is "no printer".
      expect(read.isEnabled, isFalse);
      expect(read.transport, isNull);
      expect(read.port, isNull);
      expect(read.paperWidth, PaperWidth.mm80);
      expect(read.isConfigured, isFalse);
    });

    test('an incomplete binding is refused with a reason', () {
      const PrinterConnectionSettings noTransport = PrinterConnectionSettings(
        isEnabled: true,
        transport: null,
        address: null,
        port: null,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      expect(noTransport.isValid, isFalse);
      expect(noTransport.problems.single, contains('USB or network'));

      const PrinterConnectionSettings noAddress = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '  ',
        port: null,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      expect(noAddress.isValid, isFalse);
      expect(noAddress.problems.single, contains('IP address'));
      expect(noAddress.isConfigured, isFalse);

      const PrinterConnectionSettings badPort = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '10.0.0.7',
        port: 70000,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      expect(badPort.isValid, isFalse);
      expect(badPort.problems.single, contains('port must be between'));
    });

    test('nothing is refused while printing is turned off', () {
      // Half-filled fields on a terminal that is not printing are a note for later, not
      // a fault, and refusing to save them would make the switch impossible to turn off.
      const PrinterConnectionSettings off = PrinterConnectionSettings(
        isEnabled: false,
        transport: PrinterTransport.lan,
        address: null,
        port: 999999,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      expect(off.problems, isEmpty);
      expect(off.isValid, isTrue);
      expect(off.isConfigured, isFalse);
    });

    test('the layout settings still carry no device, host or port', () async {
      // The two halves stay separate. `PrintSettings` decides what the bytes look like
      // and this decides where they go, and a value from one must never appear in the
      // other.
      const PrinterConnectionSettings binding = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '10.0.0.7',
        port: 9100,
        deviceName: null,
        label: null,
        paperWidth: PaperWidth.mm80,
      );
      for (final String key in binding.toStored().keys) {
        expect(key, startsWith('printer.'));
      }
      // And none of the seven layout keys is written by a binding.
      expect(binding.toStored().containsKey('printer.font'), isFalse);
      expect(binding.toStored().containsKey('printer.cut'), isFalse);
      expect(binding.toStored().containsKey('printer.qrEnabled'), isFalse);
    });
  });

  // ==================================================== rebinding at run time ===

  group('rebinding the printer', () {
    test('a saved binding changes where the next document goes', () async {
      final FakeEscPosPrinter real = FakeEscPosPrinter();
      addTearDown(real.dispose);

      // Starts unconfigured, exactly as a fresh terminal does.
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: FixedPrinterFactory(real),
      );
      addTearDown(printer.dispose);
      expect(printer.connectionSettings.isConfigured, isFalse);

      const PrinterConnectionSettings usb = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.usb,
        address: null,
        port: null,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );
      _expectOk(await printer.apply(usb));

      expect(printer.connectionSettings, usb);
      expect(printer.status.isConfigured, isTrue);
      expect(printer.status.support, PrinterTransportSupport.available);

      final PrintService printing = TestPrinting.serviceOver(
        database,
        printer: printer,
      );
      final String orderId = await settleBill(printing, clearRecording: real);
      final SalePrintRun run = await printing.printSale(orderId);

      expect(run.isComplete, isTrue);
      expect(real.documents, hasLength(2));
    });

    test(
      'the print service keeps the same printer object across a rebind',
      () async {
        final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
          factory: const NoTransportPrinterFactory(),
        );
        addTearDown(printer.dispose);

        final ThermalPrinter before = printer.delegate;
        _expectOk(
          await printer.apply(
            const PrinterConnectionSettings(
              isEnabled: true,
              transport: PrinterTransport.usb,
              address: null,
              port: null,
              deviceName: null,
              label: null,
              paperWidth: PaperWidth.mm80,
            ),
          ),
        );

        // The delegate underneath was replaced, which is the point; the object the print
        // service holds was not, which is what stops a bill being sent to a printer nobody
        // is using any more.
        expect(printer.delegate, isNot(same(before)));
        expect(printer.status.support, PrinterTransportSupport.notInstalled);
      },
    );

    test('turning printing off reports it as off, not as broken', () async {
      final FakeEscPosPrinter real = FakeEscPosPrinter();
      addTearDown(real.dispose);
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: FixedPrinterFactory(real),
        settings: const PrinterConnectionSettings(
          isEnabled: true,
          transport: PrinterTransport.usb,
          address: null,
          port: null,
          deviceName: null,
          label: null,
          paperWidth: PaperWidth.mm80,
        ),
      );
      addTearDown(printer.dispose);

      _expectOk(await printer.apply(PrinterConnectionSettings.unconfigured));

      expect(printer.status.isEnabled, isFalse);
      expect(printer.status.headline, 'Printing is turned off');
      expect(printer.status.detail, contains('not printed on this terminal'));
    });
  });
}

/// Asserts a repository write committed, so a fixture failure is a failure here rather
/// than a confusing assertion three lines later.
void _expectOk(Result<void> result) {
  expect(
    result.isOk,
    isTrue,
    reason: result.failureOrNull?.message ?? 'the write did not commit',
  );
}
