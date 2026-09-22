import 'dart:typed_data';

import '../../../../core/money/money.dart';
import '../../domain/models/monochrome_bitmap.dart';
import '../../domain/models/paper_width.dart';
import '../../domain/models/print_profile.dart';
import 'escpos_commands.dart';
import 'escpos_encoding.dart';
import 'escpos_text_layout.dart';

/// Where a printed line sits across the paper.
enum EscPosAlignment { left, centre, right }

/// Builds the byte stream for one document.
///
/// ## What it is
///
/// A small, imperative writer: call [initialise], then a sequence of text, row,
/// separator, QR and feed calls, then [cut], then take [bytes]. It owns two things
/// nothing above it should have to think about — the command bytes and the column
/// budget of the paper — and it holds the layout helpers together with the encoder so
/// that a line is measured with the same rules it is printed with.
///
/// ## Everything printer-specific comes from the profile
///
/// The column count, the font, the indent under an item, the characters a rule is drawn
/// with, the lines fed before a cut, whether there is a cutter at all, and the size and
/// redundancy of a QR symbol are all read from [profile]. There are no layout constants
/// in this class, which is what makes a corrected column count or a bladeless printer a
/// one-value change rather than a search through the receipt code.
///
/// ## Money
///
/// [amountRow] and [totalRow] take a [Money] and render it with
/// `Money.toDecimalString`, which converts exact paise to two decimals with integer
/// arithmetic. There is no `double` overload and no way to pass one: an amount reaches
/// the paper as the same integer that is in the database, or it does not reach it at
/// all.
///
/// Amounts print as digits without a currency symbol, and the totals block is labelled
/// once. See [EscPosEncoding] for why the rupee glyph is not sent to this class of
/// printer.
class EscPosBuilder {
  EscPosBuilder({this.profile = PrintProfile.escPos80mm});

  /// The printer this document is laid out for.
  final PrintProfile profile;

  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Roll this document is laid out for.
  PaperWidth get paper => profile.paper;

  /// Characters available on one line.
  int get columns => profile.columns;

  /// Bytes written so far. Useful in a test for asserting nothing was emitted.
  int get length => _bytes.length;

  // -------------------------------------------------------------- structure ---

  /// Resets the printer, selects the code page and selects the font.
  ///
  /// Always the first thing in a document, so a mode left set by the previous job
  /// cannot bleed into this one. The font is selected rather than assumed, because the
  /// printer's power-on font is a setting on the device and a printer left in Font B
  /// would silently make every laid-out line come out narrow.
  void initialise() {
    _raw(EscPosCommands.initialise);
    _raw(EscPosCommands.selectCodePage(EscPosCommands.codePagePc437));
    _raw(EscPosCommands.selectFont(profile.font.selector));
  }

  void align(EscPosAlignment alignment) {
    _raw(switch (alignment) {
      EscPosAlignment.left => EscPosCommands.alignLeft,
      EscPosAlignment.centre => EscPosCommands.alignCentre,
      EscPosAlignment.right => EscPosCommands.alignRight,
    });
  }

  void bold({required bool on}) =>
      _raw(on ? EscPosCommands.boldOn : EscPosCommands.boldOff);

  void doubleHeight({required bool on}) =>
      _raw(on ? EscPosCommands.sizeDoubleHeight : EscPosCommands.sizeNormal);

  /// Feeds [lines] lines without printing.
  void feed([int lines = 1]) {
    if (lines <= 0) {
      return;
    }
    _raw(EscPosCommands.feed(lines));
  }

  /// Feeds clear of the blade and cuts, according to the profile.
  ///
  /// The feed is not optional, and it happens even on a printer with no cutter: the
  /// blade and the tear bar are both above the print head, so without it the end of the
  /// document is either cut off or still inside the printer. On a receipt that is the
  /// total, and on a slip it is the last item.
  void cut() {
    feed(profile.feedLinesBeforeCut);
    switch (profile.cut) {
      case PrintCut.full:
        _raw(EscPosCommands.cutFull);
      case PrintCut.partial:
        _raw(EscPosCommands.cutPartial);
      case PrintCut.none:
        // No blade. The feed above has already brought the document clear of the tear
        // bar, which is all that can be done for it.
        break;
    }
  }

  // ------------------------------------------------------------------- text ---

  /// One line of text, wrapped to the paper width.
  ///
  /// Wrapping rather than letting the printer do it: the printer breaks at the paper
  /// edge, mid-word, and takes the rest of the line's layout with it.
  void line(
    String text, {
    EscPosAlignment alignment = EscPosAlignment.left,
    bool bold = false,
    bool doubleHeight = false,
  }) {
    final List<String> wrapped = EscPosTextLayout.wrap(text, columns);
    if (wrapped.isEmpty) {
      blankLine();
      return;
    }

    _withEmphasis(bold: bold, tall: doubleHeight, () {
      align(alignment);
      for (final String value in wrapped) {
        _text(value);
        _newLine();
      }
      align(EscPosAlignment.left);
    });
  }

  /// A line of text centred on the paper.
  void centred(String text, {bool bold = false, bool doubleHeight = false}) =>
      line(
        text,
        alignment: EscPosAlignment.centre,
        bold: bold,
        doubleHeight: doubleHeight,
      );

  /// An empty line.
  void blankLine() => _newLine();

  /// A full-width rule.
  ///
  /// Set [emphasis] for the heavier rule that frames the total. Both characters come
  /// from the profile, so a document never names one itself.
  void separator({bool emphasis = false}) {
    _text(
      EscPosTextLayout.separator(
        columns,
        character: emphasis ? profile.emphasisRule : profile.rule,
      ),
    );
    _newLine();
  }

  /// [left] at the start of the line, [right] at the end, on one line.
  ///
  /// Built by padding rather than by the printer's right-align command, because a
  /// printer can align a whole line but cannot put two things at opposite ends of one.
  void row(String left, String right, {bool bold = false}) {
    _withEmphasis(bold: bold, tall: false, () {
      _text(EscPosTextLayout.twoColumns(left, right, width: columns));
      _newLine();
    });
  }

  /// A label with an exact amount at the right-hand edge.
  ///
  /// The only way an amount enters a document. Takes [Money], so nothing can hand it
  /// a floating point value.
  void amountRow(String label, Money amount, {bool bold = false}) =>
      row(label, amount.toDecimalString(), bold: bold);

  /// The grand total: bold, double height, and the last thing before the payment
  /// line.
  ///
  /// Double height rather than double width. Double width would halve the columns and
  /// push the amount off the paper.
  void totalRow(String label, Money amount) {
    _withEmphasis(bold: true, tall: true, () {
      _text(
        EscPosTextLayout.twoColumns(
          label,
          amount.toDecimalString(),
          // Double-height characters are still one cell wide, so the budget is
          // unchanged. Stated explicitly because double width would not be.
          width: columns,
        ),
      );
      _newLine();
    });
  }

  /// One sold or cooked item, laid out so it survives a long name.
  ///
  /// The name wraps across as many lines as it needs, each option and note is indented
  /// beneath it, and the quantity line carries the arithmetic:
  ///
  /// ```
  /// Cheese Pizza (Medium)
  ///   + Extra Cheese
  ///   2 x 320.00                                640.00
  /// ```
  ///
  /// An option or a note long enough to need two lines wraps inside the indent, so a
  /// customisation can never be mistaken for another item, and nothing is truncated:
  /// "no onion" disappearing off the edge of a kitchen slip is a remade pizza.
  ///
  /// [unitPrice] and [lineTotal] are omitted for a kitchen slip, which prints the
  /// quantity alone. That is why they are nullable rather than there being two
  /// near-identical methods: the difference between the two documents is one absent
  /// pair of amounts.
  void itemRow({
    required String name,
    required int quantity,
    Money? unitPrice,
    Money? lineTotal,
    List<String> options = const <String>[],
    String? notes,
  }) {
    line(name);

    for (final String option in options) {
      _indented('+ $option');
    }

    if (notes != null && notes.trim().isNotEmpty) {
      _indented('* ${notes.trim()}');
    }

    final String indent = ' ' * profile.optionIndent;
    final String left = unitPrice == null
        ? '${indent}Qty $quantity'
        : '$indent$quantity x ${unitPrice.toDecimalString()}';

    if (lineTotal == null) {
      _text(left);
      _newLine();
    } else {
      row(left, lineTotal.toDecimalString());
    }
  }

  // -------------------------------------------------------------- bit image ---

  /// Prints [bitmap] as a raster bit image, centred.
  ///
  /// Used for the outlet logo at the top of a receipt. Mirrors [qrCode]: it is gated on
  /// the printer actually having a graphics mode, so a device that cannot print bitmaps
  /// gets a header with no logo rather than a page of garbage, and it prints nothing at
  /// all for an empty image.
  ///
  /// A bitmap wider than the paper's printable dots, or larger than the 16-bit `GS v 0`
  /// width/height fields can carry, is dropped rather than truncated: a logo sliced off
  /// mid-row is worse than a receipt with none, and the header still identifies the
  /// bill.
  ///
  /// ## Sent in bands
  ///
  /// The image is not one `GS v 0`. It is a run of them, each carrying at most
  /// [EscPosCommands.rasterMaxBandBytes] of data — see that constant for why. A whole
  /// 240×240 logo is 7200 bytes, more than a compact printer's input buffer, and sent
  /// as a single command it overruns the buffer and prints as a block of garbage above
  /// the outlet name. Split into bands no larger than the buffer, every transfer is one
  /// the printer can hold, and because raster mode feeds the paper by exactly the dots
  /// printed the bands stack into the original image with no seam. No line feed is put
  /// between the bands for the same reason: a feed would open a white gap through the
  /// logo.
  void image(MonochromeBitmap bitmap) {
    if (!profile.canPrintGraphics || bitmap.isEmpty) {
      return;
    }
    if (bitmap.width > paper.printableDots) {
      return;
    }
    if (bitmap.height > EscPosCommands.rasterMaxDimension ||
        bitmap.widthBytes > EscPosCommands.rasterMaxDimension) {
      return;
    }

    final int widthBytes = bitmap.widthBytes;
    final int rowsPerBand = EscPosCommands.rasterRowsPerBand(widthBytes);

    align(EscPosAlignment.centre);
    for (int top = 0; top < bitmap.height; top += rowsPerBand) {
      final int bandHeight = top + rowsPerBand <= bitmap.height
          ? rowsPerBand
          : bitmap.height - top;
      _raw(
        EscPosCommands.rasterBitImage(
          widthBytes: widthBytes,
          heightDots: bandHeight,
        ),
      );
      final int start = top * widthBytes;
      final int end = start + bandHeight * widthBytes;
      _raw(Uint8List.sublistView(bitmap.rows, start, end));
    }
    _newLine();
    align(EscPosAlignment.left);
  }

  // ---------------------------------------------------------------- qr code ---

  /// Encodes [data] as a QR symbol and prints it, centred.
  ///
  /// Uses the printer's own QR engine rather than rasterising a bitmap here, which is
  /// what `PrinterCapabilities.supportsQrCode` records and `PrintProfile.canPrintQrCode`
  /// carries into the layout. The five commands must arrive in this order — model, size,
  /// error correction, store, print — because the store command's payload length is what
  /// the printer uses to know where the data ends.
  ///
  /// Prints nothing at all when the printer has no QR engine, when the data is empty, or
  /// when the payload is beyond what the store command's 16-bit length can carry. A
  /// truncated symbol would scan to a corrupted payment URI, which is worse than no
  /// symbol.
  void qrCode(String data) {
    if (!profile.canPrintQrCode || data.isEmpty) {
      return;
    }
    final List<int> payload = EscPosEncoding.encode(data);
    if (payload.isEmpty || payload.length > EscPosCommands.qrMaxDataLength) {
      return;
    }

    align(EscPosAlignment.centre);
    _raw(EscPosCommands.qrSelectModel2);
    _raw(EscPosCommands.qrModuleSize(profile.qrModuleSize));
    _raw(
      EscPosCommands.qrErrorCorrection(
        errorCorrectionByte(profile.qrErrorCorrection),
      ),
    );
    _raw(EscPosCommands.qrStoreData(payload));
    _raw(EscPosCommands.qrPrint);
    _newLine();
    align(EscPosAlignment.left);
  }

  /// The ESC/POS byte for an error correction level.
  ///
  /// The mapping lives here rather than on the enum so that a layout decision does not
  /// have to know the protocol.
  static int errorCorrectionByte(QrErrorCorrection level) => switch (level) {
    QrErrorCorrection.low => EscPosCommands.qrErrorCorrectionLow,
    QrErrorCorrection.medium => EscPosCommands.qrErrorCorrectionMedium,
    QrErrorCorrection.quartile => EscPosCommands.qrErrorCorrectionQuartile,
    QrErrorCorrection.high => EscPosCommands.qrErrorCorrectionHigh,
  };

  // ------------------------------------------------------------------ output ---

  /// The finished document.
  Uint8List bytes() => _bytes.toBytes();

  // --------------------------------------------------------------- internals ---

  /// Writes [text] wrapped inside the profile's indent.
  void _indented(String text) {
    for (final String value in EscPosTextLayout.wrapIndented(
      text,
      columns,
      by: profile.optionIndent,
    )) {
      _text(value);
      _newLine();
    }
  }

  void _raw(List<int> command) => _bytes.add(command);

  void _text(String value) => _bytes.add(EscPosEncoding.encode(value));

  void _newLine() => _bytes.addByte(EscPosCommands.lf);

  /// Runs [write] with the requested emphasis, and always turns it back off.
  ///
  /// Emphasis on an ESC/POS printer is a mode, not an attribute of a string. Leaving
  /// bold set would carry it into the next line, and then into the next document, so
  /// it is scoped here rather than at every call site.
  void _withEmphasis(
    void Function() write, {
    required bool bold,
    required bool tall,
  }) {
    if (bold) {
      this.bold(on: true);
    }
    if (tall) {
      doubleHeight(on: true);
    }
    write();
    if (tall) {
      doubleHeight(on: false);
    }
    if (bold) {
      this.bold(on: false);
    }
  }
}
