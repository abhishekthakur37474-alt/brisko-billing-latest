import 'dart:typed_data';

import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_commands.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/domain/models/business_identity.dart';
import 'package:brisko_billing/features/printing/domain/models/print_document.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/services/print_job_factory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/fake_escpos_printer.dart';

/// The print job: an encoded document plus the metadata a counter needs.
///
/// This is the boundary the rest of the application works against, and these tests are
/// about that boundary rather than about a layout. A job is built by encoding a document,
/// it is handed to a transport unchanged, and re-sending one cannot change what comes out
/// — none of which involves a database, a screen or a printer.
void main() {
  final DateTime issuedAt = DateTime.utc(2026, 9, 11, 9, 0);
  final DateTime builtAt = DateTime.utc(2026, 9, 11, 9, 1);

  PrintJobFactory factory({PrintProfile profile = PrintProfile.escPos80mm}) =>
      PrintJobFactory(
        encoder: EscPosDocumentFormatter(profile: profile),
        clock: () => builtAt,
      );

  CustomerReceipt receipt({
    String orderNumber = '20260911-0001',
    PaymentMethod paymentMethod = PaymentMethod.cash,
    int quantity = 1,
  }) {
    final Money unitPrice = Money.parse('320.00');
    final Money lineTotal = unitPrice * quantity;

    return CustomerReceipt(
      business: BusinessIdentity.unconfigured,
      orderNumber: orderNumber,
      orderType: OrderType.takeaway,
      issuedAt: issuedAt,
      lines: <CustomerReceiptLine>[
        CustomerReceiptLine(
          name: 'Cheese Pizza',
          variantName: 'Medium',
          quantity: quantity,
          unitPrice: unitPrice,
          lineTotal: lineTotal,
        ),
      ],
      totals: CustomerReceiptTotals(
        subtotal: lineTotal,
        discount: Money.zero,
        tax: Money.zero,
        total: lineTotal,
      ),
      paymentMethod: paymentMethod,
    );
  }

  KitchenKot kot() => KitchenKot(
    kotNumber: 'K20260911-0001',
    orderNumber: '20260911-0001',
    orderType: OrderType.dineIn,
    issuedAt: issuedAt,
    lines: const <KitchenKotLine>[
      KitchenKotLine(name: 'Cheese Pizza', variantName: 'Medium', quantity: 2),
    ],
  );

  group('building a job', () {
    test('a receipt becomes a customer receipt job carrying its bytes', () {
      final PrintJob job = factory().build(receipt(), orderId: 'ord-1');

      expect(job.kind, PrintJobKind.customerReceipt);
      expect(job.title, 'Receipt 20260911-0001');
      expect(job.orderId, 'ord-1');
      expect(job.createdAt, builtAt);
      expect(job.state, PrintJobState.queued);
      expect(job.attempts, 0);
      expect(job.isEmpty, isFalse);
      expect(job.byteCount, job.bytes.length);
      expect(job.id, startsWith('prj-'));
    });

    test('a kitchen slip becomes a kitchen slip job', () {
      final PrintJob job = factory().build(kot(), orderId: 'ord-1');

      expect(job.kind, PrintJobKind.kitchenKot);
      expect(job.title, 'KOT K20260911-0001');
    });

    test('a test page belongs to no sale', () {
      final PrintJob job = factory().build(
        PrinterTestPage(printedAt: issuedAt),
      );

      expect(job.kind, PrintJobKind.testPage);
      expect(job.orderId, isNull);
    });

    test('the kind is derived from the document, not passed in', () {
      expect(PrintJobFactory.kindOf(receipt()), PrintJobKind.customerReceipt);
      expect(PrintJobFactory.kindOf(kot()), PrintJobKind.kitchenKot);
      expect(
        PrintJobFactory.kindOf(PrinterTestPage(printedAt: issuedAt)),
        PrintJobKind.testPage,
      );
    });

    test('the bytes are a complete document: reset first, cut last', () {
      final PrintJob job = factory().build(receipt());
      final EscPosTranscript paper = EscPosTranscript.of(job.bytes);

      expect(paper.commands.first, EscPosCommands.initialise);
      expect(paper.commands.last, EscPosCommands.cutFull);
    });

    test('a job encoded for a narrower profile is a different stream', () {
      final PrintJob wide = factory().build(receipt());
      final PrintJob narrow = factory(
        profile: PrintProfile.escPos80mm.copyWith(columnOverride: 32),
      ).build(receipt());

      expect(narrow.bytes, isNot(wide.bytes));
      expect(
        EscPosTranscript.of(narrow.bytes).widestLine,
        lessThanOrEqualTo(32),
      );
    });
  });

  group('determinism', () {
    test('the same document encodes to the same bytes every time', () {
      final PrintJobFactory jobs = factory();

      expect(jobs.build(receipt()).bytes, jobs.build(receipt()).bytes);
      expect(jobs.build(kot()).bytes, jobs.build(kot()).bytes);
      // And across factories, which is what makes a retry reproducible.
      expect(jobs.build(receipt()).bytes, factory().build(receipt()).bytes);
    });

    test('a fingerprint identifies the document, not the job', () {
      final PrintJob first = factory().build(receipt());
      final PrintJob second = factory().build(receipt());

      expect(first.id, isNot(second.id));
      expect(first.fingerprint, second.fingerprint);
      expect(first.fingerprint, hasLength(8));
    });

    test('a different bill has a different fingerprint', () {
      final PrintJob one = factory().build(receipt());
      final PrintJob other = factory().build(
        receipt(orderNumber: '20260911-0002'),
      );

      expect(one.fingerprint, isNot(other.fingerprint));
    });

    test('the state of a job does not disturb its bytes', () {
      final PrintJob job = factory().build(receipt());
      final PrintJob failed = job.started().failedWith('Out of paper.');

      expect(failed.bytes, job.bytes);
      expect(failed.fingerprint, job.fingerprint);
    });
  });

  group('money in the byte stream', () {
    /// Every decimal number that reached the paper.
    List<String> decimalsIn(PrintJob job) =>
        RegExp(r'\d+\.\d+')
            .allMatches(EscPosTranscript.of(job.bytes).text)
            .map((RegExpMatch match) => match.group(0)!)
            .toList(growable: false);

    test('every amount is exactly two decimal places', () {
      final PrintJob job = factory().build(receipt(quantity: 3));
      final List<String> decimals = decimalsIn(job);

      expect(decimals, isNotEmpty);
      for (final String value in decimals) {
        expect(
          value,
          matches(RegExp(r'^\d+\.\d{2}$')),
          reason:
              '$value is not an exact paise amount. Money reaches the paper '
              'through Money.toDecimalString and nothing else.',
        );
      }
      // 320.00 x 3, with no drift, because it is integer paise throughout.
      expect(decimals, contains('960.00'));
    });

    test('no floating point representation reaches the paper', () {
      final String text = EscPosTranscript.of(
        factory().build(receipt(quantity: 3)).bytes,
      ).text;

      // The shapes a double would leave behind: a lone decimal, a long tail, or
      // scientific notation.
      expect(RegExp(r'\d\.\d(?!\d)').hasMatch(text), isFalse);
      expect(RegExp(r'\d\.\d{3,}').hasMatch(text), isFalse);
      expect(RegExp(r'\d[eE][-+]?\d').hasMatch(text), isFalse);
      expect(text, isNot(contains('Infinity')));
      expect(text, isNot(contains('NaN')));
    });

    test('a kitchen slip has no amount at all', () {
      expect(decimalsIn(factory().build(kot())), isEmpty);
    });
  });

  group('the recording transport', () {
    late FakeEscPosPrinter printer;

    setUp(() => printer = FakeEscPosPrinter());
    tearDown(() => printer.dispose());

    test('accepts a job and records it byte for byte', () async {
      final PrintJob job = factory().build(receipt(), orderId: 'ord-1');

      final Result<void> sent = await printer.send(job);

      expect(sent.isOk, isTrue);
      expect(printer.jobs, hasLength(1));
      expect(printer.jobs.single.id, job.id);
      expect(printer.lastDocument, job.bytes);
      expect(printer.jobsOf(PrintJobKind.customerReceipt), hasLength(1));
      expect(printer.jobsOf(PrintJobKind.kitchenKot), isEmpty);
    });

    test('the transport receives exactly what the encoder produced', () async {
      final PrintJob job = factory().build(receipt());

      await printer.send(job);

      // Nothing between the encoder and the wire adds, trims or reorders a byte.
      expect(
        printer.lastDocument,
        const EscPosDocumentFormatter().encode(receipt()),
      );
    });

    test('a simulated jam fails, and records nothing', () async {
      printer.failOnWrite = true;
      printer.faultMessage = 'Out of paper.';

      final Result<void> sent = await printer.send(factory().build(receipt()));

      expect(sent.isErr, isTrue);
      expect(sent.failureOrNull, isA<PrinterFailure>());
      expect(
        sent.failureOrNull!.message,
        contains('Check the paper and the connection.'),
      );
      // A failed write left no document behind, so nothing can mistake it for one.
      expect(printer.jobs, isEmpty);
      expect(printer.hasPrinted, isFalse);
    });

    test('an unreachable printer fails before anything is written', () async {
      printer.failOnOpen = true;

      final Result<void> sent = await printer.send(factory().build(receipt()));

      expect(sent.isErr, isTrue);
      expect(
        sent.failureOrNull!.message,
        contains('Could not reach the printer'),
      );
      expect(printer.jobs, isEmpty);
    });

    test('a repaired printer accepts the same job unchanged', () async {
      final PrintJob job = factory().build(receipt());
      printer.failOnWrite = true;
      expect((await printer.send(job)).isErr, isTrue);

      printer.repair();
      expect((await printer.send(job)).isOk, isTrue);

      // One document, from one job, sent twice: the second attempt is not a new bill.
      expect(printer.jobs, hasLength(1));
      expect(printer.lastDocument, job.bytes);
    });

    test('an empty job is refused rather than reported as printed', () async {
      final PrintJob empty = PrintJob(
        id: 'prj-empty',
        kind: PrintJobKind.customerReceipt,
        title: 'Receipt 20260911-0001',
        createdAt: builtAt,
        bytes: Uint8List(0),
      );

      final Result<void> sent = await printer.send(empty);

      expect(sent.isErr, isTrue);
      expect(sent.failureOrNull!.message, contains('came out empty'));
      expect(printer.jobs, isEmpty);
    });

    test('it never claims paper came out', () async {
      // The strongest statement available: bytes were accepted. Real printing is
      // verified against real hardware, not here.
      await printer.send(factory().build(receipt()));

      expect(printer.jobs.single.state, PrintJobState.queued);
    });
  });

  group('a job through its states', () {
    test('an attempt is counted and the failure cleared', () {
      final PrintJob job = factory().build(receipt());

      final PrintJob attempted = job.started();
      expect(attempted.state, PrintJobState.printing);
      expect(attempted.attempts, 1);
      expect(attempted.state.isFinished, isFalse);

      final PrintJob printed = attempted.succeeded();
      expect(printed.isPrinted, isTrue);
      expect(printed.canRetry, isFalse);
      expect(printed.failureMessage, isNull);
    });

    test('a failure is retryable and carries the printer reason', () {
      final PrintJob failed = factory()
          .build(receipt())
          .started()
          .failedWith('Out of paper.');

      expect(failed.isFailed, isTrue);
      expect(failed.canRetry, isTrue);
      expect(failed.failureMessage, 'Out of paper.');
      expect(failed.state.label, 'Failed');

      // A second attempt clears the old reason rather than stacking messages.
      expect(failed.started().failureMessage, isNull);
      expect(failed.started().attempts, 2);
    });

    test('re-encoding keeps the job the same job', () {
      final PrintJob failed = factory()
          .build(receipt(), orderId: 'ord-1')
          .started()
          .failedWith('Out of paper.');

      final PrintJob rebuilt = factory().rebuild(failed, receipt());

      expect(rebuilt.id, failed.id);
      expect(rebuilt.orderId, 'ord-1');
      expect(rebuilt.attempts, failed.attempts);
      expect(rebuilt.createdAt, failed.createdAt);
      // Same sale, same document: byte for byte what the first attempt sent.
      expect(rebuilt.bytes, failed.bytes);
    });

    test('a document that changed underneath is re-encoded, not replayed', () {
      final PrintJob failed = factory()
          .build(receipt())
          .started()
          .failedWith('Out of paper.');

      final PrintJob rebuilt = factory().rebuild(failed, kot());

      expect(rebuilt.bytes, isNot(failed.bytes));
      // The kind is the job's, not the document's: a retry re-sends a job.
      expect(rebuilt.kind, PrintJobKind.customerReceipt);
    });

    test('the label reads as paperwork rather than as a sale', () {
      expect(PrintJobKind.customerReceipt.label, 'Customer receipt');
      expect(PrintJobKind.kitchenKot.label, 'Kitchen slip');
      expect(PrintJobKind.testPage.label, 'Test page');
    });

    test('a job describes itself with its size and fingerprint', () {
      final PrintJob job = factory().build(receipt());

      expect(job.toString(), contains('Receipt 20260911-0001'));
      expect(job.toString(), contains('${job.byteCount} bytes'));
      expect(job.toString(), contains(job.fingerprint));
    });
  });
}
