/// Where a printer stands, from the application's point of view.
///
/// Deliberately not a boolean. A cashier needs to be told the difference between
/// "no printer has been set up yet", "the printer is set up but the cable is out"
/// and "the printer is there and busy", and each of those calls for a different
/// action.
enum PrinterConnectionState {
  /// No printer has been configured on this terminal.
  ///
  /// The honest state of this build: the hardware has been chosen but not bought, so
  /// nothing can be printed and saying so is more useful than reporting an error.
  unavailable,

  /// Configured but not currently open.
  disconnected,

  connecting,

  /// Open and ready to accept a document.
  connected,

  /// Open and writing. A second document must wait rather than interleave.
  busy;

  String get label => switch (this) {
    PrinterConnectionState.unavailable => 'No printer configured',
    PrinterConnectionState.disconnected => 'Disconnected',
    PrinterConnectionState.connecting => 'Connecting',
    PrinterConnectionState.connected => 'Ready',
    PrinterConnectionState.busy => 'Printing',
  };

  /// True when a document can be sent right now.
  bool get canPrint => this == PrinterConnectionState.connected;

  /// True when the terminal has a printer to talk to at all.
  bool get isConfigured => this != PrinterConnectionState.unavailable;
}

/// How the terminal reaches the printer.
///
/// The chosen hardware offers USB and Ethernet. Bluetooth is deliberately absent:
/// the printer sits on the counter beside the terminal, so a wireless pairing would
/// add a failure mode for no benefit. Adding a transport later means adding a value
/// here and one adapter class.
enum PrinterTransport {
  usb,
  lan;

  String get label => switch (this) {
    PrinterTransport.usb => 'USB',
    PrinterTransport.lan => 'Network',
  };

  /// True when reaching the printer needs an address and a port.
  bool get isNetworked => this == PrinterTransport.lan;
}

/// Where a specific printer can be found.
///
/// Carries no credentials and no driver handle. It is a description of a
/// destination, held in settings and handed to whichever adapter understands the
/// transport, which is what keeps the transport swappable.
class PrinterEndpoint {
  const PrinterEndpoint({
    required this.transport,
    this.address,
    this.port,
    this.deviceName,
  });

  /// A printer on the local network.
  const PrinterEndpoint.lan({required String host, int port = defaultLanPort})
    : this(transport: PrinterTransport.lan, address: host, port: port);

  /// A printer on the terminal's USB bus, identified by the name the operating
  /// system reports.
  const PrinterEndpoint.usb({String? deviceName})
    : this(transport: PrinterTransport.usb, deviceName: deviceName);

  /// The port ESC/POS network printers listen on, effectively universally.
  static const int defaultLanPort = 9100;

  final PrinterTransport transport;

  /// Host name or IP address. Null for a USB printer.
  final String? address;

  /// TCP port. Null for a USB printer.
  final int? port;

  /// Operating-system device name, for a USB printer.
  final String? deviceName;

  /// How the destination should be described to the operator.
  String get description => switch (transport) {
    PrinterTransport.usb =>
      deviceName == null ? 'USB printer' : 'USB printer ($deviceName)',
    PrinterTransport.lan =>
      '${address ?? 'unknown host'}:${port ?? defaultLanPort}',
  };

  @override
  String toString() => 'PrinterEndpoint(${transport.name}, $description)';
}
