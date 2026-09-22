import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/domain/models/bill_settlement.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/domain/models/monochrome_bitmap.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/sale_print_run.dart';
import 'package:brisko_billing/features/printing/domain/services/print_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/seeded_cart.dart';
import '../helpers/test_database.dart';
import '../helpers/test_printing.dart';

/// Regressions for the "first customer receipt after a KOT is corrupt near the logo, the
/// reprint is clean" report, and for the REPRINT marker that must appear only on an
/// intentional reprint.
///
/// The physical cause lived in the CUPS transport's completion detection and is defended
/// in `cups_raw_transport_test.dart`. The tests here defend the layer above it: that the
/// application prints the two documents in the right order, one at a time, that the first
/// copies of both the receipt and the kitchen slip carry no reprint marker while an
/// intentional reprint of either does, that the logo raster is the same buffer-safe band
/// run whether it is the first print or a reprint, and that a retry after a committed sale
/// prints again without writing a second sale.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteCheckoutRepository checkout;
  late FakeEscPosPrinter printer;

  /// A small on-brand logo: 24 dots wide (3 bytes/row) by 48 dots tall, every pixel set.
  /// Wide enough to produce packed raster bytes, tall enough that the band splitter has
  /// several rows to lay out, and well within the 80mm printable width.
  final MonochromeBitmap logo = MonochromeBitmap.fromPixels(
    width: 24,
    pixels: List<List<bool>>.generate(
      48,
      (int _) => List<bool>.filled(24, true),
    ),
  );

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    checkout = SqliteCheckoutRepository(database: database);
    printer = FakeEscPosPrinter();
  });

  tearDown(() async {
    await printer.dispose();
    if (database.isOpen) {
      await database.close();
    }
  });

  /// A print service that stamps the outlet logo, as the bootstrap does once the asset is
  /// decoded. The logo is what makes the receipt carry a raster, which is the document
  /// that came out corrupt on the first print.
  PrintService printingWithLogo() =>
      TestPrinting.serviceOver(database, printer: printer, logo: logo);

  PrintService printingNoLogo() =>
      TestPrinting.serviceOver(database, printer: printer);

  Future<Order> sellPizza({
    int quantity = 1,
    OrderType orderType = OrderType.takeaway,
    PaymentMethod paymentMethod = PaymentMethod.cash,
  }) async {
    final Result<Order> settled = await checkout.settle(
      BillSettlement.fromCart(
        cart: await SeededCart.mediumCheesePizzaWithExtraCheese(
          menu,
          quantity: quantity,
        ),
        orderType: orderType,
        paymentMethod: paymentMethod,
      ),
    );
    expect(settled.isOk, isTrue, reason: settled.failureOrNull?.message);
    return settled.valueOrNull!;
  }

  EscPosTranscript documentAt(int index) =>
      EscPosTranscript.of(printer.documents[index]);

  Future<int> rowCount(String table) async {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT COUNT(*) AS total FROM $table',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  const String marker = EscPosDocumentFormatter.reprintMarker;

  group('the REPRINT marker appears only on an intentional reprint', () {
    test('1. the first customer receipt has no REPRINT marker', () async {
      final Order order = await sellPizza();

      await printingNoLogo().printSale(order.id);

      final EscPosTranscript receipt = documentAt(1);
      expect(receipt.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
      expect(receipt.text, isNot(contains(marker)));
    });

    test('2. an intentional receipt reprint has the REPRINT marker', () async {
      final Order order = await sellPizza();
      await printingNoLogo().printSale(order.id);
      final int before = printer.documents.length;

      await printingNoLogo().reprintReceipt(order.id);

      // The reprint is the only document produced by the second call.
      final EscPosTranscript reprint = documentAt(before);
      expect(reprint.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
      expect(reprint.hasLineContaining(marker), isTrue);
    });

    test('3. the first kitchen slip has no REPRINT marker', () async {
      final Order order = await sellPizza();

      await printingNoLogo().printSale(order.id);

      final EscPosTranscript slip = documentAt(0);
      expect(slip.lines.first, 'KITCHEN ORDER TICKET');
      expect(slip.text, isNot(contains(marker)));
    });

    test('4. an intentional kitchen slip reprint has the REPRINT marker', () async {
      final Order order = await sellPizza();
      await printingNoLogo().printSale(order.id);
      final int before = printer.documents.length;

      await printingNoLogo().reprintKitchenSlips(order.id);

      final EscPosTranscript reprint = documentAt(before);
      expect(reprint.lines.first, 'KITCHEN ORDER TICKET');
      expect(reprint.hasLineContaining(marker), isTrue);
    });

    test('a retry of a failed first print stays unmarked', () async {
      final Order order = await sellPizza();
      final PrintService printing = printingNoLogo();

      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(order.id);
      expect(failed.hasFailure, isTrue);

      printer.repair();
      final SalePrintRun retried = await printing.retry(failed);

      expect(retried.isComplete, isTrue);
      // A retry is not a reprint: neither document carries the marker.
      for (final document in printer.documents) {
        expect(
          EscPosTranscript.of(document).text,
          isNot(contains(marker)),
        );
      }
    });
  });

  group('print order and one-document-at-a-time', () {
    test('6. jobs are serialized kitchen-slip first, then receipt', () async {
      final Order order = await sellPizza();

      final SalePrintRun run = await printingNoLogo().printSale(order.id);

      expect(run.jobs.map((PrintJob job) => job.kind), <PrintJobKind>[
        PrintJobKind.kitchenKot,
        PrintJobKind.customerReceipt,
      ]);
      // Recorded in the same order they were handed to the transport.
      expect(documentAt(0).lines.first, 'KITCHEN ORDER TICKET');
      expect(documentAt(1).hasLineContaining('Bill ${order.orderNumber}'), isTrue);
    });

    test(
      '5. the KOT and receipt never reach the printer at the same time',
      () async {
        final Order order = await sellPizza();

        // The fake transport records the connection state on every open and write, and
        // its writes are driven through the production EscPosThermalPrinter, which
        // serialises whole documents through its own queue. If the two documents could
        // overlap, the printer would move to `busy` for the second before the first left
        // it; instead each document is written whole between resets and cuts.
        await printingNoLogo().printSale(order.id);

        expect(printer.documents, hasLength(2));
        for (int index = 0; index < 2; index++) {
          final EscPosTranscript document = documentAt(index);
          // Each document is a complete, self-contained stream: it opens with a reset
          // and ends with a cut. Interleaving would break this framing.
          expect(document.commands.first, <int>[0x1B, 0x40]);
          expect(document.commands.last, <int>[0x1D, 0x56, 0x00]);
        }
        // Opened once and reused, so the second document did not race a reconnect.
        expect(printer.openCount, 1);
      },
    );

    test(
      'two sales started together do not interleave on the wire',
      () async {
        final Order order = await sellPizza();
        final PrintService printing = printingNoLogo();

        // Started without awaiting the first: the serialisation is what keeps four
        // whole documents from becoming one scrambled stream.
        await Future.wait<SalePrintRun>(<Future<SalePrintRun>>[
          printing.printSale(order.id),
          printing.printSale(order.id),
        ]);

        expect(printer.documents, hasLength(4));
        for (int index = 0; index < 4; index++) {
          final EscPosTranscript document = documentAt(index);
          expect(document.commands.first, <int>[0x1B, 0x40]);
          expect(document.commands.last, <int>[0x1D, 0x56, 0x00]);
        }
      },
    );
  });

  group('the customer bill does not print a logo', () {
    test(
      '7. a receipt with a configured logo still emits no raster',
      () async {
        final Order order = await sellPizza();
        final PrintService printing = printingWithLogo();

        await printing.printSale(order.id);
        final EscPosTranscript firstReceipt = documentAt(1);

        await printing.reprintReceipt(order.id);
        final EscPosTranscript reprint = documentAt(printer.documents.length - 1);

        expect(firstReceipt.rasterImages, isEmpty);
        expect(reprint.rasterImages, isEmpty);
        expect(firstReceipt.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
        expect(reprint.hasLineContaining('Bill ${order.orderNumber}'), isTrue);
      },
    );
  });

  group('a retry after a committed sale does not re-commit it', () {
    test('8. retry prints again and creates no second order or payment', () async {
      final Order order = await sellPizza();
      final PrintService printing = printingNoLogo();

      final int ordersBefore = await rowCount('orders');
      final int paymentsBefore = await rowCount('payments');
      final int kotsBefore = await rowCount('kot_records');

      printer.failOnWrite = true;
      final SalePrintRun failed = await printing.printSale(order.id);
      expect(failed.hasFailure, isTrue);

      printer.repair();
      final SalePrintRun retried = await printing.retry(failed);
      expect(retried.isComplete, isTrue);

      // The retry printed, and wrote nothing: still exactly one of everything.
      expect(await rowCount('orders'), ordersBefore);
      expect(await rowCount('payments'), paymentsBefore);
      expect(await rowCount('kot_records'), kotsBefore);
      expect(await rowCount('orders'), 1);
      expect(await rowCount('payments'), 1);
    });
  });
}
