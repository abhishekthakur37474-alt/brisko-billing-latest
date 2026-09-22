import '../models/print_profile.dart';
import '../models/print_settings.dart';
import '../models/printer_capabilities.dart';

/// The layout every document printed from now on is encoded for.
///
/// ## Why this is mutable, and why that is the smallest honest design
///
/// A [PrintProfile] is read once, when the encoder is built. That was right while the
/// profile came from the printer alone: hardware does not change mid-shift. It is wrong
/// once the operator can correct the column count on the Settings screen, because the
/// receipt they are trying to fix would keep printing wrapped until the application was
/// restarted — and the way anyone discovers a wrong column count is by looking at a
/// misprinted bill.
///
/// So exactly one thing about the printing pipeline is allowed to change at run time:
/// which profile the encoder lays out for. Everything else stays as it was. Documents
/// are still built from committed rows, encoding is still a pure function of a document
/// and a profile, and a printer is still a transport that moves bytes.
///
/// ## What it is not
///
/// Not a connection, and not a claim that a printer exists. [capabilities] describes
/// the class of hardware the outlet has chosen, which is what a layout can honestly
/// assume; opening a device is a transport's job and no transport exists yet.
abstract interface class ActivePrintProfile {
  /// What the printer this terminal is laid out for can physically do.
  ///
  /// The bound on what may be configured: a cut cannot be selected on a printer with no
  /// blade, and a QR cannot be enabled on one with no QR engine.
  PrinterCapabilities get capabilities;

  /// The profile in effect right now.
  PrintProfile get profile;

  /// The profile the printer itself reports, before anything was configured.
  ///
  /// What a cleared setting returns to. Exposed so that the settings module does not
  /// have to keep its own copy of a printer default and let the two drift.
  PrintProfile get baseProfile;

  /// The configurable part of [profile], as it stands.
  PrintSettings get settings;

  /// Uses [settings] for every document encoded after this call.
  ///
  /// Expects settings already checked with `PrintSettings.problems`. Validation belongs
  /// to the controller that owns the form, so that a refusal reaches the operator as a
  /// message beside the field rather than as a silently ignored change.
  void apply(PrintSettings settings);

  /// Lays documents out for a printer with [capabilities] from now on.
  ///
  /// Called when the terminal is bound to a different printer, which is the only way the
  /// paper under a document can change. It exists because [capabilities] is otherwise the
  /// one thing here that was fixed at start-up, and a roll width chosen in the printer
  /// section that did not reach the encoder would produce documents laid out for paper the
  /// printer does not have.
  ///
  /// Layout choices are kept where they still fit the new printer and dropped where they
  /// do not, because a column count wider than the paper truncates rather than wraps.
  void retargetTo(PrinterCapabilities capabilities);
}
