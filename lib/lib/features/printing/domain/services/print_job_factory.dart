import 'dart:typed_data';

import '../../../../core/utils/entity_id.dart';
import '../models/print_document.dart';
import '../models/print_job.dart';
import '../models/print_profile.dart';
import 'print_document_encoder.dart';

/// Turns a print document into a print job.
///
/// ## Why the encoding happens here and not in the printer
///
/// This is the step that gives the pipeline its shape:
///
/// ```
/// billing / checkout / kitchen
///          -> print document      (what goes on the paper)
///          -> encoder             (how this printer is told to print it)
///          -> print job           (bytes plus the metadata a counter needs)
///          -> printer / transport (moves bytes, understands nothing)
/// ```
///
/// Encoding before the job exists rather than inside the printer buys two things. The
/// job that a screen holds, a log records and a retry re-sends is the *same* object that
/// the transport writes, so there is no second, invisible document; and a transport
/// adapter — USB in step 6B, or a socket — becomes a class that moves a byte list and
/// nothing else, with no layout, no paper width and no formatter anywhere in it.
///
/// ## Deterministic except for identity
///
/// The bytes are a pure function of the document. The id and [PrintJob.createdAt] are
/// not, which is what [clock] is for: a test can freeze the clock, and the byte stream is
/// already stable without needing to.
class PrintJobFactory {
  PrintJobFactory({required this.encoder, DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final PrintDocumentEncoder encoder;

  final DateTime Function() _clock;

  /// The printer these jobs are laid out for.
  PrintProfile get profile => encoder.profile;

  /// A queued job carrying [document] encoded for the printer.
  ///
  /// [orderId] ties the job to a sale, so a failure can be reported against a bill and a
  /// retry can rebuild the document from the same rows. Left null for a test page, which
  /// belongs to no sale.
  PrintJob build(PrintDocument document, {String? orderId}) {
    return PrintJob(
      id: EntityId.generate(prefix: 'prj'),
      kind: kindOf(document),
      title: document.title,
      orderId: orderId,
      createdAt: _clock(),
      bytes: encoder.encode(document),
    );
  }

  /// [job] carrying [document] encoded again, keeping its identity and attempt count.
  ///
  /// This is what a retry sends. The document is rebuilt from the persisted sale rather
  /// than replayed from a cached stream, so the paper matches what is actually stored,
  /// while the job stays the same job.
  PrintJob rebuild(PrintJob job, PrintDocument document) =>
      job.withBytes(encoder.encode(document));

  /// [document] as bytes, without a job around them.
  Uint8List encode(PrintDocument document) => encoder.encode(document);

  /// Which kind of job a document produces.
  ///
  /// Exhaustive over the sealed document family, so a new document type is a compile
  /// error here rather than an unlabelled job in a log.
  static PrintJobKind kindOf(PrintDocument document) => switch (document) {
    CustomerReceipt() => PrintJobKind.customerReceipt,
    KitchenKot() => PrintJobKind.kitchenKot,
    PrinterTestPage() => PrintJobKind.testPage,
  };

  static DateTime _utcNow() => DateTime.now().toUtc();
}
