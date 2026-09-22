import 'dart:typed_data';

import 'package:brisko_billing/features/printing/data/escpos/escpos_commands.dart';

/// Reads an ESC/POS byte stream back into the lines a printer would put on paper.
///
/// ## Why a decoder rather than asserting on bytes
///
/// A test that compares byte lists tells you the output changed, not whether the
/// receipt is right. A test that reads `'TOTAL INR                    640.00'` tells you
/// the customer's bill is correct, and it fails with a message a human can act on.
///
/// Decoding also proves something asserting on bytes cannot: that the stream is
/// well-formed. The decoder walks it command by command, and a command with a wrong
/// length — the classic ESC/POS mistake, where a QR payload length is off by one and the
/// printer reads the rest of the document as commands — makes the transcript come out
/// visibly wrong rather than passing silently.
///
/// [commands] keeps every command sequence in order, so a test can assert that the
/// document was initialised, that the total was bold, that a QR was emitted and that the
/// paper was fed before it was cut.
/// A raster bit image decoded out of an ESC/POS stream.
///
/// The `GS v 0` header states the row width in bytes and the height in dots; the
/// packed pixel [data] follows. A test can assert a logo was emitted, that its height
/// is what the source bitmap had, and that the byte count is `widthBytes * heightDots`.
class EscPosRasterImage {
  const EscPosRasterImage({
    required this.widthBytes,
    required this.heightDots,
    required this.data,
  });

  /// Row width in bytes, as the header states it.
  final int widthBytes;

  /// Number of rows, i.e. the image height in dots.
  final int heightDots;

  /// The packed image bytes that followed the header.
  final List<int> data;

  /// The width in bytes times the height: what the byte count should be.
  int get expectedByteCount => widthBytes * heightDots;
}

class EscPosTranscript {
  const EscPosTranscript({
    required this.lines,
    required this.commands,
    required this.qrPayloads,
    this.rasterImages = const <EscPosRasterImage>[],
  });

  /// Decodes [bytes] as this build's ESC/POS output.
  ///
  /// Handles exactly the command set `EscPosBuilder` emits. Anything else is skipped as
  /// a three-byte sequence, which is the length of every remaining `ESC x n` command in
  /// the specification that this application could reach.
  factory EscPosTranscript.of(Uint8List bytes) {
    final List<String> lines = <String>[];
    final List<List<int>> commands = <List<int>>[];
    final List<String> qrPayloads = <String>[];
    final List<EscPosRasterImage> rasterImages = <EscPosRasterImage>[];
    final StringBuffer current = StringBuffer();

    int index = 0;
    while (index < bytes.length) {
      final int byte = bytes[index];

      if (byte == EscPosCommands.lf) {
        lines.add(current.toString());
        current.clear();
        index++;
        continue;
      }

      if (byte == EscPosCommands.esc) {
        // ESC @ is two bytes; every other ESC command used here is three.
        final int length = _next(bytes, index) == 0x40 ? 2 : 3;
        commands.add(_slice(bytes, index, length));
        index += length;
        continue;
      }

      if (byte == EscPosCommands.gs) {
        final int selector = _next(bytes, index);
        if (selector == 0x28) {
          // GS ( k pL pH ... — the two length bytes cover everything after them.
          final int payload =
              _at(bytes, index + 3) | (_at(bytes, index + 4) << 8);
          final int length = 5 + payload;
          final List<int> command = _slice(bytes, index, length);
          commands.add(command);
          // Function 0x50 is "store the symbol data". Its payload, after the three
          // function bytes, is what the customer's phone will read.
          // Layout: GS ( k pL pH cn fn m <data>, so the function byte is index 6 and
          // the payload starts at index 8.
          if (command.length > 8 && command[6] == 0x50) {
            qrPayloads.add(String.fromCharCodes(command.sublist(8)));
          }
          index += length;
          continue;
        }
        if (selector == 0x76) {
          // GS v 0 m xL xH yL yH <data> — raster bit image. The width (in bytes) and
          // height (in dots) are little-endian 16-bit pairs, and exactly
          // widthBytes * heightDots data bytes follow the eight-byte header. Consuming
          // the whole block is what keeps the image bytes from being read as text.
          final int widthBytes =
              _at(bytes, index + 4) | (_at(bytes, index + 5) << 8);
          final int heightDots =
              _at(bytes, index + 6) | (_at(bytes, index + 7) << 8);
          final int total = 8 + widthBytes * heightDots;
          final List<int> block = _slice(bytes, index, total);
          // Only the header is recorded as a command, so a selector assertion sees the
          // GS v (0x76) without the image bytes leaking into the command list.
          commands.add(_slice(bytes, index, 8));
          rasterImages.add(
            EscPosRasterImage(
              widthBytes: widthBytes,
              heightDots: heightDots,
              data: block.length > 8 ? block.sublist(8) : const <int>[],
            ),
          );
          index += total;
          continue;
        }
        commands.add(_slice(bytes, index, 3));
        index += 3;
        continue;
      }

      current.writeCharCode(byte);
      index++;
    }

    if (current.isNotEmpty) {
      lines.add(current.toString());
    }

    return EscPosTranscript(
      lines: lines,
      commands: commands,
      qrPayloads: qrPayloads,
      rasterImages: rasterImages,
    );
  }

  /// The printed lines, in order, with trailing spaces intact so column positions can
  /// be asserted.
  final List<String> lines;

  /// Every command sequence, in the order it was sent.
  final List<List<int>> commands;

  /// Data stored into each QR symbol.
  final List<String> qrPayloads;

  /// Raster bit images emitted, in order. A logo larger than one buffer-safe band is
  /// emitted as several of these, back to back; [logo] stitches them together.
  final List<EscPosRasterImage> rasterImages;

  /// The raster bands stitched back into the single logical image they form.
  ///
  /// The builder sends a logo as a run of `GS v 0` bands, each under the printer's
  /// input buffer, with nothing between them; on paper they stack into one image. This
  /// reverses that: it concatenates the bands' data and sums their heights, so a test
  /// can assert the whole logo's height and total byte count without caring how many
  /// bands carried it. Returns `null` when no image was emitted. All bands are expected
  /// to share the same row width, which the builder guarantees for one image.
  EscPosRasterImage? get logo {
    if (rasterImages.isEmpty) {
      return null;
    }
    final int widthBytes = rasterImages.first.widthBytes;
    int heightDots = 0;
    final List<int> data = <int>[];
    for (final EscPosRasterImage band in rasterImages) {
      heightDots += band.heightDots;
      data.addAll(band.data);
    }
    return EscPosRasterImage(
      widthBytes: widthBytes,
      heightDots: heightDots,
      data: data,
    );
  }

  /// The whole document as text, for a readable failure message.
  String get text => lines.join('\n');

  /// Lines with their trailing padding removed, which is what most assertions want.
  List<String> get trimmedLines =>
      lines.map((String line) => line.trimRight()).toList(growable: false);

  /// True when any line contains [fragment].
  bool hasLineContaining(String fragment) =>
      lines.any((String line) => line.contains(fragment));

  /// The first line containing [fragment], or `null`.
  String? lineContaining(String fragment) {
    for (final String line in lines) {
      if (line.contains(fragment)) {
        return line;
      }
    }
    return null;
  }

  /// Every line containing [fragment].
  List<String> linesContaining(String fragment) => lines
      .where((String line) => line.contains(fragment))
      .toList(growable: false);

  /// True when [command] was sent at least once.
  bool hasCommand(List<int> command) => commands.any(
    (List<int> sent) =>
        sent.length == command.length &&
        List<int>.generate(sent.length, (int i) => sent[i]).join(',') ==
            command.join(','),
  );

  /// How many times [command] was sent.
  int commandCount(List<int> command) => commands
      .where(
        (List<int> sent) =>
            sent.length == command.length &&
            sent.join(',') == command.join(','),
      )
      .length;

  /// The widest printed line, for checking the paper budget.
  int get widestLine => lines.fold<int>(
    0,
    (int widest, String line) => line.length > widest ? line.length : widest,
  );

  static int _next(Uint8List bytes, int index) => _at(bytes, index + 1);

  static int _at(Uint8List bytes, int index) =>
      index < bytes.length ? bytes[index] : 0;

  static List<int> _slice(Uint8List bytes, int start, int length) {
    final int end = start + length;
    return bytes.sublist(start, end > bytes.length ? bytes.length : end);
  }
}
