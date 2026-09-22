import 'dart:typed_data';

import '../../../core/error/app_failure.dart';
import '../../../core/utils/entity_id.dart';
import '../../../core/utils/result.dart';
import '../domain/models/print_document.dart';
import '../domain/models/print_job.dart';
import '../domain/models/sale_print_documents.dart';
import '../domain/models/sale_print_run.dart';
import '../domain/printers/thermal_printer.dart';
import '../domain/services/print_job_factory.dart';
import '../domain/services/print_service.dart';
import '../domain/services/sale_print_document_source.dart';

/// Prints a sale's paperwork on one printer, and reports what happened.
///
/// ## The order of operations, and why it matters
///
/// This class is only ever called after the settlement transaction has committed. It
/// reads; it never writes. So the guarantees the requirement asks for are not enforced by
/// checks in here, they are properties of the design:
///
/// * A printing failure cannot roll back a sale, because there is no transaction open
///   and no write to undo.
/// * A retry cannot duplicate an order, payment or kitchen slip, because the only
///   repository calls in the whole path are reads.
/// * The bill and the slip are built from the committed rows, so the paper cannot
///   disagree with the till.
///
/// ## The three steps
///
/// Read the sale into documents, encode each document into a [PrintJob], hand each job to
/// the printer. The middle step is [PrintJobFactory]'s, which is why this class contains
/// no layout and no bytes: it decides *what* is printed and *in what order*, and reports
/// the outcome.
///
/// ## The kitchen slip goes first
///
/// If the roll runs out halfway through a sale, the food should still have been started.
/// The customer's receipt is the one that can most easily be reprinted, or waived.
class DefaultPrintService implements PrintService {
  DefaultPrintService({
    required this._documents,
    required this._printer,
    required this._jobs,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  final SalePrintDocumentSource _documents;
  final ThermalPrinter _printer;
  final PrintJobFactory _jobs;
  final DateTime Function() _clock;

  @override
  Future<SalePrintRun> printSale(
    String orderId, {
    bool printKitchenSlip = true,
  }) => _run(
    orderId,
    isReprint: false,
    skipKitchenSlip: !printKitchenSlip,
  );

  @override
  Future<SalePrintRun> reprintSale(String orderId) =>
      _run(orderId, isReprint: true);

  @override
  Future<SalePrintRun> reprintReceipt(String orderId) =>
      _run(orderId, isReprint: true, only: PrintJobKind.customerReceipt);

  @override
  Future<SalePrintRun> reprintKitchenSlips(String orderId) =>
      _run(orderId, isReprint: true, only: PrintJobKind.kitchenKot);

  /// Re-sends only the jobs that failed.
  ///
  /// The documents are rebuilt from the order rather than kept from the first attempt,
  /// so a retry prints what is actually stored. The job keeps its identity and its attempt
  /// count, so a retry is visibly the same job. Jobs that already printed are left exactly
  /// as they are: sending one again would put a second bill in the customer's hand, which
  /// is the failure this method exists to avoid.
  @override
  Future<SalePrintRun> retry(SalePrintRun run) async {
    if (!run.hasFailure) {
      return run;
    }

    final Result<SalePrintDocuments> built = await _documents.forOrder(
      run.orderId,
    );
    if (built.isErr) {
      return run.withJobs(
        run.jobs
            .map(
              (PrintJob job) => job.isFailed
                  ? job.started().failedWith(built.failureOrNull!.message)
                  : job,
            )
            .toList(growable: false),
      );
    }

    final SalePrintDocuments documents = built.valueOrNull!;
    final List<PrintJob> updated = <PrintJob>[];

    for (final PrintJob job in run.jobs) {
      if (!job.isFailed) {
        updated.add(job);
        continue;
      }
      final PrintDocument? document = _documentFor(job, documents);
      if (document == null) {
        // The sale no longer produces this document, for example a slip that was
        // removed. Left failed rather than silently marked printed.
        updated.add(job);
        continue;
      }
      updated.add(await _send(_jobs.rebuild(job, document)));
    }

    return run.withJobs(updated);
  }

  @override
  Future<Result<PrintJob>> printTestPage() async {
    final PrintJob attempted = _jobs
        .build(PrinterTestPage(printedAt: _clock()))
        .started();

    final Result<void> printed = await _printer.send(attempted);
    return printed.fold<Result<PrintJob>>(
      onOk: (void _) => Ok<PrintJob>(attempted.succeeded()),
      onErr: Err<PrintJob>.new,
    );
  }

  // --------------------------------------------------------------- internals ---

  /// Builds the sale's documents and sends the ones asked for.
  ///
  /// [only] narrows the run to one kind of document, which is what a receipt-only or
  /// slip-only reprint is. It narrows what is *sent*; the whole sale is still read and
  /// still validated, so a receipt reprint of a bill whose figures no longer add up is
  /// refused rather than printed, exactly as a first print would be.
  Future<SalePrintRun> _run(
    String orderId, {
    required bool isReprint,
    PrintJobKind? only,
    bool skipKitchenSlip = false,
  }) async {
    final Result<SalePrintDocuments> built = await _documents.forOrder(
      orderId,
      isReprint: isReprint,
    );

    if (built.isErr) {
      // The documents could not even be assembled. Still reported as a print run with
      // failed jobs rather than as an error, because the sale is settled either way and
      // the cashier needs the same message and the same retry.
      return SalePrintRun(
        orderId: orderId,
        orderNumber: '',
        jobs: <PrintJob>[
          _unbuildableJob(
            orderId,
            only ?? PrintJobKind.customerReceipt,
          ).started().failedWith(built.failureOrNull!.message),
        ],
      );
    }

    final SalePrintDocuments documents = built.valueOrNull!;
    final List<PrintJob> jobs = <PrintJob>[];

    // In the order they should reach the printer: the kitchen slips first, because
    // somebody is waiting on the food.
    for (final PrintDocument document in documents.all) {
      final PrintJobKind kind = PrintJobFactory.kindOf(document);
      if (only != null && kind != only) {
        continue;
      }
      if (skipKitchenSlip && kind == PrintJobKind.kitchenKot) {
        continue;
      }
      jobs.add(await _send(_jobs.build(document, orderId: orderId)));
    }

    return SalePrintRun(
      orderId: orderId,
      orderNumber: documents.receipt.orderNumber,
      jobs: jobs,
    );
  }

  /// Sends one job and returns it carrying the outcome.
  Future<PrintJob> _send(PrintJob job) async {
    final PrintJob attempted = job.started();
    final Result<void> printed = await _printer.send(attempted);

    return printed.fold<PrintJob>(
      onOk: (void _) => attempted.succeeded(),
      onErr: (AppFailure failure) => attempted.failedWith(failure.message),
    );
  }

  /// Matches a job back to its document on a retry.
  ///
  /// A receipt is matched by kind, and a slip by the KOT number in its title, so a
  /// retry of a two-slip order re-sends the slip that failed rather than the first one.
  PrintDocument? _documentFor(PrintJob job, SalePrintDocuments documents) {
    switch (job.kind) {
      case PrintJobKind.customerReceipt:
        return documents.receipt;
      case PrintJobKind.kitchenKot:
        for (final KitchenKot kot in documents.kots) {
          if (kot.title == job.title) {
            return kot;
          }
        }
        return null;
      case PrintJobKind.testPage:
        return PrinterTestPage(printedAt: _clock());
    }
  }

  /// A job for a sale whose documents could not be built.
  ///
  /// Carries no bytes, because there was nothing to encode. It exists only to give the
  /// cashier a failure to read and a retry to press, which is why it is built by hand
  /// rather than through the factory: the factory's job is to encode a document, and
  /// here there is none.
  PrintJob _unbuildableJob(String orderId, PrintJobKind kind) => PrintJob(
    id: EntityId.generate(prefix: 'prj'),
    kind: kind,
    title: kind.label,
    orderId: orderId,
    createdAt: _clock(),
    bytes: Uint8List(0),
  );

  static DateTime _utcNow() => DateTime.now().toUtc();
}
