/// Stored keys for the printer this terminal talks to.
///
/// ## Why these are here and not in `SettingKeys`
///
/// `SettingKeys` holds the printer's *layout* — font, columns, cut, feed, QR — because
/// laying a document out is something the settings screen can decide honestly with no
/// hardware in the room. The keys below are a different kind of fact: they say which
/// device this terminal is bound to. That is the printing module's knowledge, so the
/// printing module owns the keys, the model that reads them and the section of the
/// screen that edits them.
///
/// The rows live in the same `settings` table, written through the same
/// `SettingsRepository` in the same transaction. Splitting the *keys* by owner is a
/// layering decision, not a storage one, and it is what keeps the settings module free
/// of transports while still letting an operator type in an address.
///
/// ## Storing an address is not claiming a printer
///
/// A saved endpoint records where the operator says the printer is. Whether it can be
/// reached is answered by `ThermalPrinter.connectionState`, and whether this build can
/// reach it at all is answered by the transport factory — which, until an adapter ships,
/// says no. See [PrinterConnectionSettings] and `NoTransportPrinterFactory`.
class PrinterSettingKeys {
  const PrinterSettingKeys._();

  /// Whether the outlet wants this terminal to print at all.
  ///
  /// False is a legitimate configuration, not a fault: a counter can run on the screen
  /// alone while a printer is out for repair, and saying so stops every bill ending with
  /// a failure notice nobody can act on.
  static const String enabled = 'printer.enabled';

  /// `PrinterTransport` name: how the terminal reaches the printer. Absent means the
  /// operator has not chosen yet.
  static const String transport = 'printer.transport';

  /// Host name or IP address of a network printer.
  static const String address = 'printer.address';

  /// TCP port of a network printer. Absent means the ESC/POS default, 9100.
  static const String port = 'printer.port';

  /// Operating-system device name of a USB printer, when the operator has picked one
  /// out of several. Absent means the only ESC/POS device on the bus.
  static const String deviceName = 'printer.deviceName';

  /// A name for the printer, for the operator's own benefit.
  ///
  /// Printed nowhere. It exists so a status line can say "Counter printer is not
  /// responding" rather than repeating an IP address back at somebody who is holding a
  /// queue.
  static const String label = 'printer.label';

  /// `PaperWidth` name of the roll the printer takes. Absent means 80mm, which is the
  /// roll this outlet has chosen.
  static const String paperWidth = 'printer.paperWidth';
}
