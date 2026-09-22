import 'dart:typed_data';

import '../../domain/models/print_document.dart';
import '../../domain/models/print_profile.dart';
import '../../domain/models/print_settings.dart';
import '../../domain/models/printer_capabilities.dart';
import '../../domain/printers/thermal_printer.dart';
import '../../domain/services/active_print_profile.dart';
import '../../domain/services/print_document_encoder.dart';
import 'escpos_document_formatter.dart';

/// The ESC/POS encoder, laying out for whichever profile is configured now.
///
/// ## Why a wrapper rather than a mutable formatter
///
/// [EscPosDocumentFormatter] is a pure function of a document and a profile, and it is
/// worth keeping that way: every layout assertion in the test suite depends on being
/// able to construct one for a known profile and get the same bytes every time. So the
/// formatter stays immutable and this class holds the profile instead, building a
/// formatter for each document.
///
/// That is not a cost worth avoiding. A formatter has one field and no state; the bytes
/// are still a pure function of the document and the profile in force when it was
/// encoded.
///
/// ## What changing the profile can and cannot do
///
/// It can change how a bill is laid out: the font, the column budget, the cut, the feed,
/// and whether and how large a QR is printed. It cannot change what the bill says.
/// Amounts, item snapshots and payment details are carried from the committed order by
/// the document source, and nothing in this class or the formatter can alter one — which
/// is why a printer setting saved after a sale changes the presentation of a reprint and
/// never its figures.
class ConfigurableEscPosEncoder
    implements PrintDocumentEncoder, ActivePrintProfile {
  ConfigurableEscPosEncoder({
    required PrintProfile base,
    required PrintSettings? settings,
    required this._capabilities,
  }) : _base = base,
       _profile = settings?.applyTo(base) ?? base;

  /// An encoder for [printer], starting from the profile the printer reports.
  ///
  /// [settings] is what the outlet has saved, or null on a terminal that has configured
  /// nothing — in which case the printer's own profile is used unchanged.
  factory ConfigurableEscPosEncoder.forPrinter(
    ThermalPrinter printer, {
    PrintSettings? settings,
  }) {
    return ConfigurableEscPosEncoder(
      base: printer.profile,
      capabilities: printer.capabilities,
      settings: settings,
    );
  }

  /// The printer's own profile, before anything the operator chose.
  ///
  /// Kept so that clearing a setting returns to the hardware's value rather than to a
  /// literal written into the settings module.
  PrintProfile _base;

  PrinterCapabilities _capabilities;

  @override
  PrinterCapabilities get capabilities => _capabilities;

  PrintProfile _profile;

  @override
  PrintProfile get profile => _profile;

  @override
  void retargetTo(PrinterCapabilities capabilities) {
    final PrintSettings chosen = PrintSettings.fromProfile(_profile);
    _capabilities = capabilities;
    _base = PrintProfile.forCapabilities(capabilities);
    // A saved column count that no longer fits — 48 columns carried onto a 58mm roll, for
    // example — is dropped rather than applied. A document laid out wider than the paper
    // does not wrap, it truncates, and what it truncates is the amount at the right-hand
    // edge.
    _profile = chosen.isValidFor(capabilities) ? chosen.applyTo(_base) : _base;
  }

  @override
  PrintSettings get settings => PrintSettings.fromProfile(_profile);

  @override
  PrintProfile get baseProfile => _base;

  @override
  void apply(PrintSettings settings) {
    _profile = settings.applyTo(_base);
  }

  @override
  Uint8List encode(PrintDocument document) =>
      EscPosDocumentFormatter(profile: _profile).encode(document);
}
