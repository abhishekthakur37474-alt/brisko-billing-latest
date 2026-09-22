import 'paper_width.dart';
import 'printer_connection.dart';
import 'printer_connection_settings.dart';

/// Whether a transport can actually be opened on this build.
///
/// ## Why the application has to say this out loud
///
/// The outlet has chosen an 80mm ESC/POS printer and not yet bought it, so no USB or
/// network adapter ships here. That produces a state which is genuinely different from
/// both "nothing configured" and "the cable is out": the operator has filled the form in
/// correctly, and the software still cannot reach the device.
///
/// Collapsing that into a plain failure would be a lie in the direction that costs the
/// most — somebody would conclude the printer is broken and start swapping cables. So it
/// is a value, it is reported by name, and it disappears the day an adapter is added.
enum PrinterTransportSupport {
  /// An adapter for the configured transport exists and was used.
  available,

  /// The transport is understood but this build has no adapter for it.
  notInstalled,

  /// Nothing has been configured, so there is no transport to support.
  notConfigured;

  bool get isAvailable => this == PrinterTransportSupport.available;
}

/// Everything a screen needs to say about the printer, in one immutable value.
///
/// ## Why a snapshot rather than reading the printer directly
///
/// A widget that reached into a `ThermalPrinter` would be holding a live object whose
/// connection state changes underneath a build, and would have to combine it with the
/// stored settings and with what this build can support in order to write one sentence.
/// Three sources, in a widget, is how a status line comes to contradict itself.
///
/// This carries the combination, taken at one instant. It is a description, not a
/// handle: it cannot connect, print, or be out of date without being replaced.
///
/// ## It never claims paper came out
///
/// [canPrint] means a document can be *sent*. ESC/POS over USB or a socket is one-way,
/// so nothing on this side of the cable can promise more than that, and no wording here
/// does.
class PrinterStatus {
  const PrinterStatus({
    required this.settings,
    required this.connectionState,
    required this.support,
    required this.endpoint,
  });

  /// A terminal with nothing configured, which is what a fresh install reports.
  static const PrinterStatus unconfigured = PrinterStatus(
    settings: PrinterConnectionSettings.unconfigured,
    connectionState: PrinterConnectionState.unavailable,
    support: PrinterTransportSupport.notConfigured,
    endpoint: null,
  );

  /// What the operator has saved.
  final PrinterConnectionSettings settings;

  /// Where the printer stands right now.
  final PrinterConnectionState connectionState;

  /// Whether this build can open the configured transport at all.
  final PrinterTransportSupport support;

  /// Where the printer is, as the active printer reports it.
  final PrinterEndpoint? endpoint;

  /// True when the operator has turned printing on.
  bool get isEnabled => settings.isEnabled;

  /// True when the settings name a printer completely.
  bool get isConfigured => settings.isConfigured;

  /// True when a document could be sent right now.
  bool get canPrint => connectionState.canPrint;

  /// True when a test page is worth offering.
  ///
  /// Always, deliberately. A test print on a terminal with no printer is the fastest way
  /// for the operator to find out *why* nothing prints, and it is answered honestly
  /// rather than refused — which is the whole point of having one.
  bool get canTestPrint => true;

  /// The roll documents are laid out for.
  PaperWidth get paperWidth => settings.paperWidth;

  /// How the printer should be named on screen.
  String get description => settings.description;

  /// The one-line state, for a status row.
  String get headline {
    if (!isEnabled) {
      return 'Printing is turned off';
    }
    if (!isConfigured) {
      return 'No printer configured';
    }
    if (support == PrinterTransportSupport.notInstalled) {
      return 'Configured, but this build cannot reach it';
    }
    return connectionState.label;
  }

  /// What the operator should understand, and what they can do about it.
  ///
  /// Each branch names a different action, which is the reason the states are not a
  /// boolean. The [PrinterTransportSupport.notInstalled] wording is the honest hardware
  /// boundary of this build written out in full: the configuration is right, the software
  /// is incomplete, and no amount of checking the cable will help.
  String get detail {
    if (!isEnabled) {
      return 'Bills and kitchen slips are not printed on this terminal. Turn '
          'printing on once a printer is connected.';
    }
    if (!isConfigured) {
      final PrinterTransport? chosen = settings.transport;
      if (chosen == null) {
        return 'Choose how the printer is connected, then save.';
      }
      return 'The ${chosen.label} printer is not described completely enough '
          'to open yet.';
    }
    if (support == PrinterTransportSupport.notInstalled) {
      final PrinterTransport transport = settings.transport!;
      return 'This build has no ${transport.label} transport, so nothing can '
          'be sent to $description yet. The configuration is stored and will '
          'be used as soon as the transport is added.';
    }
    return switch (connectionState) {
      PrinterConnectionState.connected =>
        '$description is ready. Documents are laid out for '
            '${paperWidth.label} paper.',
      PrinterConnectionState.busy => '$description is printing.',
      PrinterConnectionState.connecting => 'Opening $description.',
      PrinterConnectionState.disconnected =>
        '$description is configured but not open. It is opened when the '
            'first document is sent.',
      PrinterConnectionState.unavailable =>
        '$description cannot be reached from this terminal.',
    };
  }

  @override
  String toString() => 'PrinterStatus($headline, ${support.name})';
}
