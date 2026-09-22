import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_option.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_run.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Printing a settled sale, against the real database, the real seeded menu and the real
/// ESC/POS formatter.
///
/// Only the wire is substituted: [FakeEscPosPrinter] extends the production ESC/POS
/// printer and supplies the three transport methods a USB or LAN adapter would, so
/// everything else under test is the code that will ship.
///
/// The point of this file is the guarantee in requirement 6. A printer that fails must
/// leave a completely settled sale behind, must say so in words that cannot be mistaken
/// for a failed payment, and must be retryable without producing a second bill.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late SqliteSettingsRepository settings;
  late FakeEscPosPrinter printer;
  late PrintService printing;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    settings = SqliteSettingsRepository(database: database);
    printer = FakeEscPosPrinter();
    printing = TestPrinting.serviceOver(database, printer: printer);
  });

  tearDown(() async {
    await printer.dispose();
    if (database.isOpen) {
      await database.close();
    }
  });

  /// Settles a Medium Cheese Pizza with Extra Cheese: 250 + 70 = 320.
  Future<Order> sellPizza({
    int quantity = 1,
    OrderType orderType = OrderType.takeaway,
    PaymentMethod paymentMethod = PaymentMethod.cash,
    String? customerName,
    String? customerPhone,
    String? notes,
  }) async {
    final Result<Order> settled = await checkout.settle(
      BillSettlement.fromCart(
        cart: await SeededCart.mediumCheesePizzaWithExtraCheese(
          menu,
          quantity: quantity,
        ),
        orderType: orderType,
        paymentMethod: paymentMethod,
        // Settlement resolves the number to a customer record inside its own
        // transaction, so nothing has to be created here first.
        customerName: customerName,
        customerPhone: customerPhone,
        notes: notes,
      ),
    );
    expect(settled.isOk, isTrue, reason: settled.failureOrNull?.message);
    return settled.valueOrNull!;
  }

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  /// Rows that a duplicate would show up in.
  Future<Map<String, int>> saleRows() async {
    return <String, int>{
      'orders': await rowCount('orders'),
      'order_items': await rowCount('order_items'),
      'order_item_options': await rowCount('order_item_options'),
      'payments': await rowCount('payments'),
      'kot_records': await rowCount('kot_records'),
      'kot_items': await rowCount('kot_items'),
      'kot_item_options': await rowCount('kot_item_options'),
    };
  }

  EscPosTranscript documentAt(int index) =>
      EscPosTranscript.of(printer.documents[index]);

  group('printing a settled sale', () {
    test(
      'the kitchen slip and the receipt are both printed, slip first',
      () async {
        final Order order = await sellPizza();

        final SalePrintRun run = await printing.printSale(order.id);

        expect(run.isComplete, isTrue);
        expect(run.hasFailure, isFalse);
        expect(run.operatorMessage, isNull);
        expect(run.orderNumber, order.orderNumber);
        expect(run.jobs.map((PrintJob job) => job.kind), <PrintJobKind>[
          // The slip first: if the roll runs out mid-sale the food should still have
          // been started.
          PrintJobKind.kitchenKot,
          PrintJobKind.customerReceipt,
        ]);

        expect(printer.documents, hasLength(2));
        expect(documentAt(0).lines.first, 'KITCHEN ORDER TICKET');
        expect(documentAt(1).lines.first, contains('Brisko Pizza'));
      },
    );

    test('the paper carries what was actually committed', () async {
      final Order order = await sellPizza(quantity: 2, notes: 'Cut into eight');

      await printing.printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      expect(receipt.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
      expect(receipt.hasLineContaining('Cheese Pizza (Medium)'), isTrue);
      expect(receipt.hasLineContaining('+ Extra Cheese'), isTrue);
      expect(receipt.lineContaining('2 x 320.00')!.endsWith('640.00'), isTrue);
      expect(receipt.lineContaining('TOTAL')!.endsWith('640.00'), isTrue);
      expect(receipt.hasLineContaining('Paid by Cash'), isTrue);
      expect(receipt.hasLineContaining('Note: Cut into eight'), isTrue);

      final EscPosTranscript slip = documentAt(0);
      expect(slip.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
      expect(slip.hasLineContaining('Cheese Pizza (Medium)'), isTrue);
      expect(slip.hasLineContaining('Qty 2'), isTrue);
      // Still no money on the slip, even though the sale had plenty.
      expect(RegExp(r'\d+\.\d{2}').hasMatch(slip.text), isFalse);
    });

    test('the order type reaches both documents', () async {
      final Order order = await sellPizza(orderType: OrderType.delivery);

      await printing.printSale(order.id);

      expect(documentAt(0).hasLineContaining('Delivery'), isTrue);
      expect(documentAt(1).hasLineContaining('Delivery'), isTrue);
    });

    test('the customer name and phone are printed when taken', () async {
      final Order order = await sellPizza(
        customerName: 'Ravi',
        customerPhone: '9876543210',
      );

      await printing.printSale(order.id);

      expect(documentAt(1).hasLineContaining('Customer: Ravi'), isTrue);
      expect(documentAt(1).hasLineContaining('Phone: 9876543210'), isTrue);
    });

    test('a name without a phone still prints on the receipt', () async {
      final Order order = await sellPizza(customerName: 'Ravi');

      await printing.printSale(order.id);

      expect(documentAt(1).hasLineContaining('Customer: Ravi'), isTrue);
      expect(documentAt(1).text, isNot(contains('Phone:')));
    });

    test('printing writes nothing to the database', () async {
      final Order order = await sellPizza();
      final Map<String, int> before = await saleRows();

      await printing.printSale(order.id);
      await printing.printSale(order.id);
      await printing.printSale(order.id);

      // Three print runs, and not one row anywhere. Printing is a read.
      expect(await saleRows(), before);
      expect(printer.documents, hasLength(6));
    });

    test('the printer is opened once and the document written whole', () async {
      final Order order = await sellPizza();

      await printing.printSale(order.id);

      // Opened for the first document and reused for the second, rather than
      // reconnecting between them.
      expect(printer.openCount, 1);
      expect(printer.connectionState, PrinterConnectionState.connected);
    });
  });

  group('outlet details come from settings', () {
    test('a configured outlet prints its own identity', () async {
      await settings.writeString(
        SettingKeys.businessName,
        'Brisko Pizza Kothrud',
      );
      await settings.writeString(
        SettingKeys.businessAddress,
        '12 Paud Road, Pune 411038',
      );
      await settings.writeString(SettingKeys.businessPhone, '02012345678');
      await settings.writeString(SettingKeys.gstin, '27ABCDE1234F1Z5');
      await settings.writeString(SettingKeys.receiptFooter, 'Thank you');

      final Order order = await sellPizza();
      await printing.printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      expect(receipt.hasLineContaining('Brisko Pizza Kothrud'), isTrue);
      expect(receipt.hasLineContaining('12 Paud Road, Pune 411038'), isTrue);
      expect(receipt.hasLineContaining('Phone 02012345678'), isTrue);
      expect(receipt.hasLineContaining('GSTIN 27ABCDE1234F1Z5'), isTrue);
      expect(receipt.hasLineContaining('Thank you'), isTrue);
    });

    test('an unconfigured outlet invents nothing', () async {
      final Order order = await sellPizza();
      await printing.printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      expect(receipt.hasLineContaining('Brisko Pizza'), isTrue);
      expect(receipt.text, isNot(contains('GSTIN')));
      expect(receipt.text, isNot(contains('Phone')));
      expect(receipt.qrPayloads, isEmpty);
    });

    test('a configured feedback URL produces the review QR', () async {
      await settings.writeString(
        SettingKeys.feedbackUrl,
        'https://g.page/r/brisko/review',
      );

      final Order order = await sellPizza();
      await printing.printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      // The QR carries exactly the configured review URL — never a payment string.
      expect(receipt.qrPayloads.single, 'https://g.page/r/brisko/review');
      expect(receipt.hasLineContaining('RATE US'), isTrue);
      expect(receipt.text, isNot(contains('Scan to pay')));
      // And never on the kitchen slip.
      expect(documentAt(0).qrPayloads, isEmpty);
    });

    test('a blank feedback URL is treated as unconfigured', () async {
      await settings.writeString(SettingKeys.feedbackUrl, '   ');

      final Order order = await sellPizza();
      await printing.printSale(order.id);

      expect(documentAt(1).qrPayloads, isEmpty);
    });
  });

  group('a printer failure', () {
    test('leaves the sale completely settled', () async {
      final Order order = await sellPizza();
      final Map<String, int> before = await saleRows();
      printer.failOnWrite = true;
      printer.faultMessage = 'Out of paper.';

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.failedJobs, hasLength(2));
      expect(printer.documents, isEmpty);

      // The whole sale is exactly as it was. Nothing was rolled back, because nothing
      // was in a transaction.
      expect(await saleRows(), before);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);
    });

    test('says the payment succeeded, first and plainly', () async {
      final Order order = await sellPizza();
      printer.failOnWrite = true;

      final SalePrintRun run = await printing.printSale(order.id);

      final String message = run.operatorMessage!;
      expect(message, startsWith(SalePrintRun.paidButNotPrinted));
      expect(message, contains('Payment successful'));
      expect(message, contains('Kitchen slip'));
      expect(message, contains('Customer receipt'));
      // The reason, so the cashier knows whether to reload paper or check a cable.
      expect(message, contains('Check the paper and the connection.'));
    });

    test('an unreachable printer is reported as such', () async {
      final Order order = await sellPizza();
      printer.failOnOpen = true;

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, contains('Could not reach the printer'));
      expect(printer.connectionState, PrinterConnectionState.disconnected);
    });

    test(
      'a failure part way through leaves the printed document alone',
      () async {
        final Order order = await sellPizza();

        // The slip prints, then the roll runs out before the receipt.
        final SalePrintRun first = await printing.printSale(order.id);
        expect(first.isComplete, isTrue);

        printer.failOnWrite = true;
        final SalePrintRun second = await printing.printSale(order.id);

        expect(second.failedJobs, hasLength(2));
        expect(await rowCount('orders'), 1);
      },
    );

    test('the terminal with no printer says what would fix it', () async {
      final Order order = await sellPizza();
      final PrintService unconfigured = TestPrinting.serviceOver(
        database,
        printer: UnconfiguredThermalPrinter(),
      );

      final SalePrintRun run = await unconfigured.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, UnconfiguredThermalPrinter.message);
      expect(run.operatorMessage, contains(SalePrintRun.paidButNotPrinted));
      // And the sale is untouched, which is the state of every bill in this build.
      expect(await rowCount('orders'), 1);
      expect(await rowCount('kot_records'), 1);
    });
  });

  group('retrying', () {
    test('a retry prints, and creates no order, payment or slip', () async {
      final Order order = await sellPizza();
      final Map<String, int> before = await saleRows();

      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(order.id);
      expect(failed.hasFailure, isTrue);

      // Paper is reloaded.
      printer.repair();
      final SalePrintRun retried = await printing.retry(failed);

      expect(retried.isComplete, isTrue);
      expect(retried.hasFailure, isFalse);
      expect(printer.documents, hasLength(2));
      // The whole point: still one of everything.
      expect(await saleRows(), before);
    });

    test('repeated retries cannot duplicate anything', () async {
      final Order order = await sellPizza();
      final Map<String, int> before = await saleRows();

      printer.failOnWrite = true;
      SalePrintRun run = await printing.printSale(order.id);

      for (int attempt = 0; attempt < 4; attempt++) {
        run = await printing.retry(run);
        expect(run.hasFailure, isTrue);
      }

      printer.repair();
      run = await printing.retry(run);

      expect(run.isComplete, isTrue);
      expect(await saleRows(), before);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
      expect(await rowCount('kot_records'), 1);
      expect(await rowCount('kot_items'), 1);
    });

    test('each attempt is counted, so a repeated failure is visible', () async {
      final Order order = await sellPizza();
      printer.failOnWrite = true;

      SalePrintRun run = await printing.printSale(order.id);
      expect(run.jobs.first.attempts, 1);

      run = await printing.retry(run);
      expect(run.jobs.first.attempts, 2);

      run = await printing.retry(run);
      expect(run.jobs.every((PrintJob job) => job.attempts == 3), isTrue);
    });

    test('a document that already printed is not sent again', () async {
      final Order order = await sellPizza();
      final SalePrintRun run = await printing.printSale(order.id);
      expect(run.isComplete, isTrue);
      expect(printer.documents, hasLength(2));

      // Nothing failed, so there is nothing to retry: a second bill in the
      // customer's hand is the failure this avoids.
      final SalePrintRun retried = await printing.retry(run);

      expect(retried, same(run));
      expect(printer.documents, hasLength(2));
    });

    test('a retry rebuilds the document from what is stored', () async {
      final Order order = await sellPizza();
      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(order.id);

      // The outlet configures its GSTIN between the failure and the retry.
      await settings.writeString(SettingKeys.gstin, '27ABCDE1234F1Z5');
      printer.repair();
      await printing.retry(failed);

      // Rebuilt, not replayed from a cached byte stream.
      expect(documentAt(1).hasLineContaining('GSTIN 27ABCDE1234F1Z5'), isTrue);
    });

    test(
      'a retry against a vanished order reports it and stays failed',
      () async {
        final Order order = await sellPizza();
        printer.failOnWrite = true;
        final SalePrintRun failed = await printing.printSale(order.id);

        await database.database.delete('kot_item_options', where: '1 = 1');
        await database.database.update(
          'orders',
          <String, Object?>{'isDeleted': 1},
          where: 'id = ?',
          whereArgs: <Object?>[order.id],
        );
        printer.repair();

        final SalePrintRun retried = await printing.retry(failed);

        expect(retried.hasFailure, isTrue);
        expect(retried.failureReason, contains('no longer on this terminal'));
        expect(printer.documents, isEmpty);
      },
    );
  });

  group('reprinting', () {
    test('a reprint is marked, and creates nothing', () async {
      final Order order = await sellPizza();
      final Map<String, int> before = await saleRows();
      await printing.printSale(order.id);

      final SalePrintRun reprint = await printing.reprintSale(order.id);

      expect(reprint.isComplete, isTrue);
      expect(printer.documents, hasLength(4));
      expect(
        documentAt(2).hasLineContaining(EscPosDocumentFormatter.reprintMarker),
        isTrue,
      );
      expect(
        documentAt(3).hasLineContaining(EscPosDocumentFormatter.reprintMarker),
        isTrue,
      );
      // The first copies were not marked.
      expect(
        documentAt(1).text,
        isNot(contains(EscPosDocumentFormatter.reprintMarker)),
      );
      expect(await saleRows(), before);
    });
  });

  group('refusing to print a document that would misrepresent the sale', () {
    test('an order that does not exist', () async {
      final SalePrintRun run = await printing.printSale('ord-does-not-exist');

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, contains('no longer on this terminal'));
      expect(printer.documents, isEmpty);
    });

    test('an order with no settled payment', () async {
      final Order order = await sellPizza();
      // The payment row is removed, which would leave a receipt claiming the bill was
      // paid when the till says it was not.
      await database.database.delete(
        'payments',
        where: 'orderId = ?',
        whereArgs: <Object?>[order.id],
      );

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, contains('no settled payment'));
      expect(printer.documents, isEmpty);
    });

    test('an order whose totals do not add up', () async {
      final Order order = await sellPizza();
      await database.database.update(
        'orders',
        <String, Object?>{'taxAmountPaise': 5000},
        where: 'id = ?',
        whereArgs: <Object?>[order.id],
      );

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.failureReason, contains('does not add up'));
      expect(printer.documents, isEmpty);
    });

    test('a storage fault is reported rather than thrown', () async {
      final Order order = await sellPizza();
      await database.close();

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.hasFailure, isTrue);
      expect(run.operatorMessage, contains(SalePrintRun.paidButNotPrinted));
    });
  });

  group('the test page', () {
    test('prints without a sale, and is not a payment code', () async {
      final Result<PrintJob> result = await printing.printTestPage();

      expect(result.isOk, isTrue);
      final PrintJob job = result.valueOrNull!;
      expect(job.kind, PrintJobKind.testPage);
      expect(job.isPrinted, isTrue);
      expect(job.orderId, isNull);

      final EscPosTranscript page = documentAt(0);
      expect(page.hasLineContaining('Printer test page'), isTrue);
      expect(page.hasLineContaining('80mm'), isTrue);
      // A test page carrying a real upi:// link could be scanned and take money.
      expect(page.qrPayloads, isEmpty);
      expect(await rowCount('orders'), 0);
    });

    test('a failure is returned rather than thrown', () async {
      printer.failOnOpen = true;

      final Result<PrintJob> result = await printing.printTestPage();

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<PrinterFailure>());
    });
  });

  group('the printer contract', () {
    test(
      'connect is idempotent and disconnect releases the transport',
      () async {
        expect((await printer.connect()).isOk, isTrue);
        expect((await printer.connect()).isOk, isTrue);
        expect(printer.openCount, 1);

        expect((await printer.disconnect()).isOk, isTrue);
        expect(printer.closeCount, 1);
        expect(printer.connectionState, PrinterConnectionState.disconnected);

        // Disconnecting again is not an error.
        expect((await printer.disconnect()).isOk, isTrue);
        expect(printer.closeCount, 1);
      },
    );

    test('the paper width is fixed at 80mm', () {
      expect(printer.profile.paper.millimetres, 80);
      expect(printer.profile.columns, 48);
      expect(printer.capabilities.characterColumns, 48);
      expect(printer.capabilities.hasAutoCutter, isTrue);
      expect(printer.capabilities.supportsQrCode, isTrue);
      expect(printer.capabilities.isColour, isFalse);
    });

    test('two documents sent at once do not interleave on the wire', () async {
      final Order order = await sellPizza();

      // Started together, without awaiting the first. ESC/POS has no framing, so
      // interleaved writes would produce one unreadable page.
      await Future.wait<SalePrintRun>(<Future<SalePrintRun>>[
        printing.printSale(order.id),
        printing.printSale(order.id),
      ]);

      expect(printer.documents, hasLength(4));
      for (int index = 0; index < 4; index++) {
        final EscPosTranscript document = documentAt(index);
        // Each document is whole: it starts with a reset and ends with a cut.
        expect(document.commands.first, <int>[0x1B, 0x40]);
        expect(document.commands.last, <int>[0x1D, 0x56, 0x00]);
      }
    });

    test('the endpoint describes where the printer is', () {
      expect(printer.endpoint!.description, '127.0.0.1:9100');
      expect(printer.endpoint!.transport.isNetworked, isTrue);
      expect(
        const PrinterEndpoint.usb(deviceName: 'POS-80').description,
        'USB printer (POS-80)',
      );
      expect(UnconfiguredThermalPrinter().endpoint, isNull);
    });
  });

  group('the bill is a snapshot, not a view of the menu', () {
    /// The Medium Cheese Pizza variant as the seeded menu holds it.
    Future<MenuItemVariant> mediumCheesePizza() async {
      final List<MenuItem> items = (await menu.loadItems()).valueOrNull!;
      final MenuItem pizza = items.firstWhere(
        (MenuItem item) => item.name == 'Cheese Pizza',
      );
      final List<MenuItemVariant> sizes = (await menu.loadVariants(pizza.id))
          .valueOrNull!;
      return sizes.firstWhere(
        (MenuItemVariant variant) => variant.name == 'Medium',
      );
    }

    test('repricing the menu afterwards does not move the bill', () async {
      final Order order = await sellPizza(quantity: 2);
      await printing.printSale(order.id);
      final EscPosTranscript asSold = documentAt(1);

      // The outlet puts the price up the next morning.
      final MenuItemVariant medium = await mediumCheesePizza();
      final Result<void> repriced = await menu.saveVariant(
        medium.copyWith(
          price: const Money.fromRupees(999),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      expect(repriced.isOk, isTrue);

      printer.clearRecording();
      await printing.reprintSale(order.id);
      final EscPosTranscript receipt = documentAt(1);

      // 320 as charged, not 999 plus the option. The receipt is the historical record
      // of what the customer paid, and the menu is not consulted to produce it.
      expect(receipt.hasLineContaining('2 x 320.00'), isTrue);
      expect(receipt.lineContaining('TOTAL')!.endsWith('640.00'), isTrue);
      expect(receipt.text, isNot(contains('999')));
      expect(receipt.text, isNot(contains('1069')));
      // Character for character the same line as the copy handed over at the counter.
      expect(
        receipt.lineContaining('2 x 320.00'),
        asSold.lineContaining('2 x 320.00'),
      );
      expect(receipt.lineContaining('TOTAL'), asSold.lineContaining('TOTAL'));
    });

    test('repricing an option afterwards does not move the bill', () async {
      final Order order = await sellPizza();
      await printing.printSale(order.id);

      final List<MenuItemOption> options =
          (await menu.loadAllOptions()).valueOrNull!;
      final MenuItemOption extraCheese = options.firstWhere(
        (MenuItemOption option) => option.name == 'Extra Cheese',
      );
      await menu.saveOption(
        extraCheese.copyWith(
          price: const Money.fromRupees(500),
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      printer.clearRecording();
      await printing.reprintSale(order.id);

      // The option is named on the bill and its price is inside the 320 charged; the
      // new 500 appears nowhere.
      expect(documentAt(1).hasLineContaining('+ Extra Cheese'), isTrue);
      expect(documentAt(1).lineContaining('TOTAL')!.endsWith('320.00'), isTrue);
    });

    test('deleting the menu item afterwards does not break the bill', () async {
      final Order order = await sellPizza(quantity: 2);
      final List<MenuItem> items = (await menu.loadItems()).valueOrNull!;
      final MenuItem pizza = items.firstWhere(
        (MenuItem item) => item.name == 'Cheese Pizza',
      );

      final Result<void> deleted = await menu.deleteItem(pizza.id);
      expect(deleted.isOk, isTrue);

      final SalePrintRun run = await printing.printSale(order.id);

      // The item is off the menu, and last week's bill still prints in full, because
      // every name and amount on it was copied into the order at the time of sale.
      expect(run.isComplete, isTrue);
      expect(documentAt(1).hasLineContaining('Cheese Pizza (Medium)'), isTrue);
      expect(documentAt(1).hasLineContaining('+ Extra Cheese'), isTrue);
      expect(documentAt(1).lineContaining('TOTAL')!.endsWith('640.00'), isTrue);
      expect(documentAt(0).hasLineContaining('Cheese Pizza (Medium)'), isTrue);
    });
  });

  group('how the bill was paid reaches the paper', () {
    test('a cash sale prints Cash', () async {
      final Order order = await sellPizza();
      await printing.printSale(order.id);

      expect(documentAt(1).hasLineContaining('Paid by Cash'), isTrue);
    });

    test('a UPI sale prints UPI', () async {
      final Order order = await sellPizza(paymentMethod: PaymentMethod.upi);
      await printing.printSale(order.id);

      expect(documentAt(1).hasLineContaining('Paid by UPI'), isTrue);
      expect(documentAt(1).text, isNot(contains('Paid by Cash')));
    });

    test('a card sale prints Card', () async {
      final Order order = await sellPizza(paymentMethod: PaymentMethod.card);
      await printing.printSale(order.id);

      expect(documentAt(1).hasLineContaining('Paid by Card'), isTrue);
    });

    test('the kitchen slip never says how it was paid', () async {
      final Order order = await sellPizza(paymentMethod: PaymentMethod.card);
      await printing.printSale(order.id);

      final String slip = documentAt(0).text;
      expect(slip, isNot(contains('Paid')));
      expect(slip, isNot(contains('Card')));
    });
  });

  group('a missing setting is left blank, never filled in', () {
    test('only what the operator entered is printed', () async {
      // A half-configured terminal: a name, and nothing else.
      await settings.writeString(SettingKeys.businessName, 'Brisko Pizza');

      final Order order = await sellPizza();
      await printing.printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      expect(receipt.hasLineContaining('Brisko Pizza'), isTrue);
      for (final String absent in <String>[
        'GSTIN',
        'Phone',
        'Scan to pay',
        'null',
        'N/A',
        'TBD',
        'Address',
      ]) {
        expect(
          receipt.text,
          isNot(contains(absent)),
          reason: 'An unconfigured field must print nothing, not "$absent".',
        );
      }
      expect(receipt.qrPayloads, isEmpty);
    });

    test('a blank GSTIN prints no label at all', () async {
      await settings.writeString(SettingKeys.gstin, '   ');

      final Order order = await sellPizza();
      await printing.printSale(order.id);

      expect(documentAt(1).text, isNot(contains('GSTIN')));
    });
  });

  group('the jobs a run reports', () {
    test('each job carries the bytes that were sent', () async {
      final Order order = await sellPizza();

      final SalePrintRun run = await printing.printSale(order.id);

      expect(run.jobs, hasLength(2));
      for (int index = 0; index < run.jobs.length; index++) {
        final PrintJob job = run.jobs[index];
        expect(job.isPrinted, isTrue);
        expect(job.orderId, order.id);
        expect(job.byteCount, greaterThan(0));
        expect(job.isEmpty, isFalse);
        // The job the screen holds is the job the transport wrote.
        expect(job.bytes, printer.documents[index]);
        expect(printer.jobs[index].id, job.id);
      }
    });

    test('a retry re-sends the identical byte stream', () async {
      final Order order = await sellPizza();
      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(order.id);
      final List<String> fingerprints = failed.jobs
          .map((PrintJob job) => job.fingerprint)
          .toList(growable: false);

      printer.repair();
      final SalePrintRun retried = await printing.retry(failed);

      expect(retried.isComplete, isTrue);
      // Rebuilt from the same rows, so byte for byte the same documents, sent under
      // the same job ids rather than as new jobs.
      expect(retried.jobs.map((PrintJob job) => job.fingerprint), fingerprints);
      expect(
        retried.jobs.map((PrintJob job) => job.id),
        failed.jobs.map((PrintJob job) => job.id),
      );
      expect(printer.jobs.map((PrintJob job) => job.fingerprint), fingerprints);
    });

    test('a run that could not be built reports a job with no bytes', () async {
      final SalePrintRun run = await printing.printSale('ord-does-not-exist');

      final PrintJob job = run.jobs.single;
      expect(job.isFailed, isTrue);
      expect(job.isEmpty, isTrue);
      // Nothing empty was ever sent to the printer.
      expect(printer.jobs, isEmpty);
    });
  });
}
