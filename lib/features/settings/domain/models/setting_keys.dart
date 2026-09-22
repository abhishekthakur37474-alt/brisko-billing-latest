/// Known keys in the settings table.
///
/// Constants rather than free-form strings, so a typo is a compile error instead of
/// a silently missing GSTIN on a printed invoice.
///
/// Values are stored as text and interpreted by the settings repository. A key with
/// no row is unconfigured, which is not the same as blank: `PosSettings` and
/// `PrintSettings` decide what an absent value means, once each, rather than at every
/// reader.
class SettingKeys {
  const SettingKeys._();

  // Outlet identity, printed on every bill.
  static const String businessName = 'business.name';
  static const String businessAddress = 'business.address';
  static const String businessPhone = 'business.phone';

  /// GSTIN of the outlet. Legally required on a tax invoice.
  static const String gstin = 'tax.gstin';

  /// Combined GST rate in basis points, where 10000 is 100%. Integer for the same
  /// determinism reason money is.
  static const String gstRateBasisPoints = 'tax.gstRateBasisPoints';

  /// Whether menu prices already include tax, which changes how the tax line is
  /// derived rather than whether it is charged.
  static const String pricesIncludeTax = 'tax.pricesIncludeTax';

  static const String receiptHeader = 'receipt.header';
  static const String receiptFooter = 'receipt.footer';

  /// URL a customer scans to leave a review. Drives the feedback QR on the paid
  /// receipt. Absent means no QR is printed — a QR pointing nowhere is worse than none.
  static const String feedbackUrl = 'receipt.feedbackUrl';

  /// UPI virtual payment address used to generate the payment QR.
  static const String upiVpa = 'payment.upiVpa';

  /// Payee name shown to the customer in their UPI app.
  static const String upiPayeeName = 'payment.upiPayeeName';

  /// Order type the checkout flow opens on, as an `OrderType` name.
  ///
  /// A convenience for an outlet whose trade is mostly one kind: it changes which
  /// choice is already selected, never which choices exist, and the cashier can still
  /// pick any of them on the review step.
  static const String defaultOrderType = 'pos.defaultOrderType';

  /// Whether a kitchen slip is sent to the printer after a sale.
  ///
  /// The slip is still written to the till either way. This only decides whether paper
  /// comes out. Absent means print, which is how the till has always behaved.
  static const String printKitchenSlip = 'pos.printKitchenSlip';

  /// Whether checkout asks for the customer's name and phone, and whether those
  /// details are printed on the customer bill.
  ///
  /// Absent means ask and print, which is how the till has always behaved.
  static const String askCustomerDetails = 'pos.askCustomerDetails';

  // ------------------------------------------------------------------ printer ---
  //
  // The printer's *layout*, not its address. There is deliberately no key here for a
  // USB device, an IP address or a port: no transport exists on this terminal yet, and
  // a stored printer address would claim one does. Every key below changes how a
  // document is laid out, which is verifiable today without any hardware.

  /// `PrinterFont` name. Font A at 12 dots, or Font B at 9.
  static const String printerFont = 'printer.font';

  /// Columns to use instead of the font's own arithmetic, when a real printer
  /// disagrees with it. Absent means use the arithmetic.
  static const String printerColumnOverride = 'printer.columnOverride';

  /// `PrintCut` name: a full cut, a partial cut, or none for a printer with no blade.
  static const String printerCut = 'printer.cut';

  /// Lines fed before the cut, so the printed area clears the blade.
  static const String printerFeedLinesBeforeCut = 'printer.feedLinesBeforeCut';

  /// Whether the printer's QR engine is used. False suppresses the payment block
  /// rather than printing a heading with nothing under it.
  static const String printerQrEnabled = 'printer.qrEnabled';

  /// Size of one QR module in dots.
  static const String printerQrModuleSize = 'printer.qrModuleSize';

  /// `QrErrorCorrection` name: the redundancy built into the printed symbol.
  static const String printerQrErrorCorrection = 'printer.qrErrorCorrection';

  /// UTC milliseconds of the last till backup written before a data clear.
  static const String lastBackupAt = 'data.lastBackupAt';

  /// Absolute path of that backup file, so Settings can copy it to Downloads.
  static const String lastBackupPath = 'data.lastBackupPath';

  /// UTC milliseconds of the last time operational data was physically cleared.
  static const String lastClearedAt = 'data.lastClearedAt';

  /// Salted SHA-256 of the manager password. Cached locally so a bill can still
  /// be cancelled while the till is offline; the live copy lives on RTDB.
  static const String managerPassword = 'auth.manager_password';

  /// UTC milliseconds of the last manager-password change, used to last-write-
  /// wins against the RTDB node.
  static const String managerPasswordUpdatedAt =
      'auth.manager_password.updatedAt';
}
