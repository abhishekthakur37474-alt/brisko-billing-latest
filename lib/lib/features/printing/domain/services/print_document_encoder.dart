import 'dart:typed_data';

import '../models/print_document.dart';
import '../models/print_profile.dart';

/// Turns a print document into the bytes a printer understands.
///
/// ## Why this is an interface in the domain
///
/// It is the seam between "what goes on the paper" and "how this printer is told to put
/// it there". Above it, the print service builds documents and print jobs and never sees
/// a byte. Below it, the ESC/POS formatter knows nothing about orders, payments or
/// retries. A second command language — a label printer, or an ESC/POS dialect that
/// needs its QR rasterised — is a second implementation and no change anywhere else.
///
/// ## Pure
///
/// Encoding is a function. It touches no printer, opens nothing, and cannot fail: a
/// document that could not be laid out honestly is refused when it is *built*, by the
/// document source, not when it is encoded. That is why there is no `Result` here, and
/// it is what lets every layout assertion in the test suite run without a printer, a
/// database or a Flutter binding.
abstract interface class PrintDocumentEncoder {
  /// The printer these bytes are laid out for.
  ///
  /// Exposed so that a caller can report the paper and column count it is producing for
  /// — the test page prints them — without holding the profile separately and risking
  /// the two disagreeing.
  PrintProfile get profile;

  /// [document] as a complete, self-contained byte stream.
  ///
  /// Deterministic: the same document encodes to the same bytes every time. Nothing in
  /// the layout reads a clock, a random number or a database, so a retry re-sends
  /// exactly what the first attempt did.
  Uint8List encode(PrintDocument document);
}
