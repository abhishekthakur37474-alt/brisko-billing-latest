import '../../../../core/utils/result.dart';
import '../models/printer_connection.dart';
import '../models/printer_connection_settings.dart';
import '../models/printer_status.dart';

/// The printer this terminal is using right now.
///
/// ## Why anything is allowed to change at run time
///
/// The alternative is that saving a printer address requires restarting the till, which
/// in practice means it is configured wrongly for the rest of a shift. The way anybody
/// discovers a wrong address is by pressing Test Print and getting nothing, and the fix
/// has to be available in the same breath.
///
/// So exactly one thing about the transport is mutable: which printer object the print
/// service is sending to. Everything else stays as it was — documents are still built
/// from committed rows, encoding is still a pure function of a document and a profile, and
/// a printer is still a transport that moves bytes and reports what happened.
///
/// This is the transport-side counterpart of `ActivePrintProfile`, which does the same
/// for layout. Two interfaces rather than one, because they answer different questions:
/// "what does the paper look like" and "where does it come out".
///
/// ## What it is not
///
/// Not a claim that a printer exists. [status] is the honest combination of what the
/// operator saved, what the transport reports and what this build can support, and on a
/// terminal with no adapter it says so in as many words.
abstract interface class ActivePrinter {
  /// What the operator has saved.
  PrinterConnectionSettings get connectionSettings;

  /// The combined state, for a status row and for deciding what to offer.
  PrinterStatus get status;

  /// State changes, for a screen showing a connection indicator.
  ///
  /// Follows the printer across a reconfiguration, so a widget listening when the
  /// operator saves a new address keeps receiving states from the new printer rather than
  /// going silent on the old one.
  Stream<PrinterConnectionState> get connectionStates;

  /// Binds this terminal to the printer [settings] describe.
  ///
  /// Releases whatever was open before, so a terminal repointed from one network printer
  /// to another does not hold a socket on the first. Returns a failure only when the old
  /// printer could not be released cleanly; the new binding takes effect either way,
  /// because refusing to accept a corrected address because the previous printer misbehaved
  /// would leave the operator with no way forward.
  ///
  /// Expects settings already checked with `PrinterConnectionSettings.problems`.
  /// Validation belongs to the controller that owns the form, so a refusal reaches the
  /// operator beside the field rather than as a silently ignored change.
  Future<Result<void>> apply(PrinterConnectionSettings settings);
}
