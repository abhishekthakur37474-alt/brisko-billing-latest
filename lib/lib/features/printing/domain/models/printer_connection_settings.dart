import 'paper_width.dart';
import 'printer_capabilities.dart';
import 'printer_connection.dart';
import 'printer_setting_keys.dart';

/// Which printer this terminal is bound to, as the operator configured it.
///
/// ## What this is, and what it is not
///
/// It is a stored intention: "the printer is a network device at 192.168.1.50, it takes
/// an 80mm roll, and I want bills printed on it." It is *not* a connection, not a
/// handle, and not a claim that anything answered. Those are
/// `ThermalPrinter.connectionState`'s business, and on this build the honest answer is
/// still [PrinterConnectionState.unavailable], because no transport adapter ships —
/// see `NoTransportPrinterFactory`.
///
/// Keeping the two apart is what lets the outlet finish configuring a printer before it
/// arrives, and lets the terminal say precisely what is wrong afterwards: "not
/// configured" and "configured but not answering" need different actions from whoever
/// is at the counter.
///
/// ## Why it is separate from `PrintSettings`
///
/// [PrintSettings] is layout: it changes the bytes a document encodes to, and every one
/// of its values can be judged by looking at a byte stream. This is a device binding: it
/// changes *where* those bytes go and nothing about what they are. A single model would
/// have made "the column count is wrong" and "the cable is in the wrong socket" the same
/// kind of problem, and they are not.
///
/// ## No money, ever
///
/// Nothing here is an amount. [port] is a TCP port and [paperWidth] is millimetres of
/// paper; both are counts, both are integers, and neither goes anywhere near `Money`.
class PrinterConnectionSettings {
  const PrinterConnectionSettings({
    required this.isEnabled,
    required this.transport,
    required this.address,
    required this.port,
    required this.deviceName,
    required this.label,
    required this.paperWidth,
  });

  /// What has been saved, or [unconfigured] where nothing has.
  ///
  /// A key that is absent, blank or corrupt falls back rather than failing. A terminal
  /// has to open and take money even if one row of its configuration is unreadable, and
  /// the fallback here — no printer — is the safe direction to fall: it reports that
  /// nothing is configured instead of pointing bills at a half-read address.
  factory PrinterConnectionSettings.fromStored(Map<String, String?> stored) {
    return PrinterConnectionSettings(
      isEnabled: stored[PrinterSettingKeys.enabled] == 'true',
      transport: _named<PrinterTransport>(
        stored[PrinterSettingKeys.transport],
        PrinterTransport.values,
      ),
      address: _text(stored[PrinterSettingKeys.address]),
      port: _count(stored[PrinterSettingKeys.port]),
      deviceName: _text(stored[PrinterSettingKeys.deviceName]),
      label: _text(stored[PrinterSettingKeys.label]),
      paperWidth:
          _named<PaperWidth>(
            stored[PrinterSettingKeys.paperWidth],
            PaperWidth.values,
          ) ??
          defaultPaperWidth,
    );
  }

  /// A terminal that has been told nothing about a printer.
  ///
  /// What a fresh install is, and what this build ships as. Printing is off rather than
  /// on-and-failing, because a bill that ends in a red notice the cashier cannot act on
  /// teaches them to ignore red notices.
  static const PrinterConnectionSettings unconfigured =
      PrinterConnectionSettings(
        isEnabled: false,
        transport: null,
        address: null,
        port: null,
        deviceName: null,
        label: null,
        paperWidth: defaultPaperWidth,
      );

  /// The roll this outlet has chosen: 80mm, which is the same thing as 3-inch.
  static const PaperWidth defaultPaperWidth = PaperWidth.mm80;

  /// Lowest and highest usable TCP port. 0 is reserved and 65535 is the top of the
  /// 16-bit field, so anything outside is not a port at all.
  static const int minPort = 1;
  static const int maxPort = 65535;

  /// Longest printer label worth storing. Long enough for "Counter printer (back
  /// office)", short enough to sit on one line of a status row.
  static const int maxLabelLength = 40;

  /// Whether the outlet wants bills printed on this terminal.
  final bool isEnabled;

  /// How the terminal reaches the printer, or `null` when nothing has been chosen.
  final PrinterTransport? transport;

  /// Host name or IP address, for a network printer.
  final String? address;

  /// TCP port, for a network printer. `null` means [PrinterEndpoint.defaultLanPort].
  final int? port;

  /// Operating-system device name, for a USB printer.
  final String? deviceName;

  /// The operator's own name for the printer. Printed nowhere.
  final String? label;

  /// The roll the printer takes, which decides the layout budget.
  final PaperWidth paperWidth;

  // ------------------------------------------------------------------ reading ---

  /// These settings as rows for the settings table.
  ///
  /// A `null` value removes the key, which is how "not chosen" is stored: an absent row
  /// rather than a sentinel. That matters for [transport] in particular, because a
  /// stored empty string would read back as an unrecognised transport rather than as no
  /// choice at all.
  Map<String, String?> toStored() => <String, String?>{
    PrinterSettingKeys.enabled: isEnabled ? 'true' : 'false',
    PrinterSettingKeys.transport: transport?.name,
    PrinterSettingKeys.address: address,
    PrinterSettingKeys.port: port?.toString(),
    PrinterSettingKeys.deviceName: deviceName,
    PrinterSettingKeys.label: label,
    PrinterSettingKeys.paperWidth: paperWidth.name,
  };

  // ------------------------------------------------------------------ derived ---

  /// True when these settings name a printer completely enough to try to open it.
  ///
  /// Requires printing to be turned on, a transport to be chosen, and — for a network
  /// printer — an address to reach. A USB printer needs no further detail: a terminal
  /// with one ESC/POS device on the bus is the ordinary case, and demanding a device
  /// name for it would be a field nobody could fill in correctly.
  bool get isConfigured {
    if (!isEnabled || transport == null) {
      return false;
    }
    return switch (transport!) {
      PrinterTransport.usb => true,
      PrinterTransport.lan => _isNotBlank(address),
    };
  }

  /// Where the printer is, or `null` when [isConfigured] is false.
  ///
  /// The value handed to whichever adapter understands the transport. Built here so the
  /// adapter never has to interpret a half-filled form.
  PrinterEndpoint? get endpoint {
    if (!isConfigured) {
      return null;
    }
    return switch (transport!) {
      PrinterTransport.usb => PrinterEndpoint.usb(deviceName: deviceName),
      PrinterTransport.lan => PrinterEndpoint.lan(
        host: address!.trim(),
        port: port ?? PrinterEndpoint.defaultLanPort,
      ),
    };
  }

  /// What the printer this terminal is bound to can physically do.
  ///
  /// Derived from the roll, so the layout budget and the paper cannot disagree. The
  /// cutter and the QR engine are assumed present because every 80mm ESC/POS printer in
  /// this class has both; a device that turns out not to is corrected in the layout
  /// settings, where `PrintSettings.problems` already refuses a cut on a bladeless
  /// printer.
  PrinterCapabilities get capabilities =>
      PrinterCapabilities.escPosFor(paperWidth);

  /// How the printer should be named in a status line.
  ///
  /// The operator's label if they gave one, otherwise the endpoint, otherwise a plain
  /// noun. Never blank, because a status line reading "  is not responding" is worse
  /// than one naming nothing in particular.
  String get description {
    final String? named = _text(label);
    if (named != null) {
      return named;
    }
    return endpoint?.description ?? 'No printer';
  }

  // --------------------------------------------------------------- validation ---

  /// Everything wrong with these settings, in the order the form shows it.
  ///
  /// Empty when they can be saved. Nothing here checks whether the printer answers:
  /// that is not a property of a form, and refusing to save an address because the
  /// printer is switched off would make the printer impossible to configure before it is
  /// plugged in.
  List<String> get problems {
    if (!isEnabled) {
      // Nothing is refused on a terminal that has printing turned off. Whatever is in
      // the other fields is a note for later, not a fault.
      return const <String>[];
    }

    final List<String> problems = <String>[];
    final PrinterTransport? chosen = transport;
    if (chosen == null) {
      problems.add('Choose whether the printer is connected by USB or network');
      return problems;
    }

    if (chosen.isNetworked) {
      if (!_isNotBlank(address)) {
        problems.add('Enter the network printer’s IP address or host name');
      }
      final int? chosenPort = port;
      if (chosenPort != null &&
          (chosenPort < minPort || chosenPort > maxPort)) {
        problems.add(
          'The port must be between $minPort and $maxPort, or left blank to '
          'use ${PrinterEndpoint.defaultLanPort}',
        );
      }
    }

    final String? named = _text(label);
    if (named != null && named.length > maxLabelLength) {
      problems.add(
        'The printer name must be $maxLabelLength characters or fewer',
      );
    }

    return problems;
  }

  bool get isValid => problems.isEmpty;

  // ----------------------------------------------------------------- updating ---

  PrinterConnectionSettings copyWith({
    bool? isEnabled,
    PrinterTransport? transport,
    bool clearTransport = false,
    String? address,
    bool clearAddress = false,
    int? port,
    bool clearPort = false,
    String? deviceName,
    bool clearDeviceName = false,
    String? label,
    bool clearLabel = false,
    PaperWidth? paperWidth,
  }) {
    return PrinterConnectionSettings(
      isEnabled: isEnabled ?? this.isEnabled,
      transport: clearTransport ? null : transport ?? this.transport,
      address: clearAddress ? null : address ?? this.address,
      port: clearPort ? null : port ?? this.port,
      deviceName: clearDeviceName ? null : deviceName ?? this.deviceName,
      label: clearLabel ? null : label ?? this.label,
      paperWidth: paperWidth ?? this.paperWidth,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrinterConnectionSettings &&
      other.isEnabled == isEnabled &&
      other.transport == transport &&
      other.address == address &&
      other.port == port &&
      other.deviceName == deviceName &&
      other.label == label &&
      other.paperWidth == paperWidth;

  @override
  int get hashCode => Object.hash(
    isEnabled,
    transport,
    address,
    port,
    deviceName,
    label,
    paperWidth,
  );

  @override
  String toString() =>
      'PrinterConnectionSettings(enabled: $isEnabled, '
      '${transport?.label ?? 'no transport'}, $description, '
      '${paperWidth.label})';

  // --------------------------------------------------------------- internals ---

  /// The enum value in [values] whose name is [stored], or `null`.
  ///
  /// Stored by name so that reordering a declaration cannot silently rebind a saved
  /// setting to a different transport.
  static T? _named<T extends Enum>(String? stored, List<T> values) {
    if (stored == null) {
      return null;
    }
    for (final T value in values) {
      if (value.name == stored) {
        return value;
      }
    }
    return null;
  }

  /// [stored] trimmed, or `null` when it holds nothing.
  static String? _text(String? stored) {
    if (stored == null) {
      return null;
    }
    final String trimmed = stored.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// [stored] as a whole number, or `null`.
  ///
  /// A TCP port. Not an amount: nothing in this file constructs `Money`, and no figure
  /// from it ever reaches a printed amount row.
  static int? _count(String? stored) =>
      stored == null ? null : int.tryParse(stored.trim());

  static bool _isNotBlank(String? value) =>
      value != null && value.trim().isNotEmpty;
}
