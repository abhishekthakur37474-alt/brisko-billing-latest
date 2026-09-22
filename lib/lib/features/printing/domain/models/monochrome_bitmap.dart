import 'dart:typed_data';

/// A one-bit-per-dot image, packed the way an ESC/POS raster bit image wants it.
///
/// ## Why a domain value rather than a PNG
///
/// A thermal printer has no colour and no greyscale: every dot is either burned or
/// not. A logo therefore has to be reduced to one bit per dot before it can be
/// printed, and that reduction — decoding the source image, scaling it to a sensible
/// width for 80mm paper, and thresholding each pixel to black or white — is a decision
/// about presentation, not about the protocol.
///
/// This type is the result of that decision: a fixed grid of on/off dots with its rows
/// already packed into bytes, so the builder can hand it to `GS v 0` without knowing
/// anything about images. The decode itself lives above the printing layer, where a
/// Flutter image codec is available; the printing layer stays pure Dart and receives
/// only finished bits.
///
/// ## Packing
///
/// Each row is `ceil(width / 8)` bytes wide. Within a byte the most-significant bit is
/// the left-most dot, and a set bit is a dot the printer burns black. A row narrower
/// than its byte boundary is padded with clear bits on the right, which print as blank
/// paper.
class MonochromeBitmap {
  const MonochromeBitmap._({
    required this.width,
    required this.height,
    required this.rows,
  });

  /// Packs a grid of pixels into a printable bitmap.
  ///
  /// [pixels] is [height] rows of booleans, `true` for a black dot. [width] is the
  /// dot width the grid is interpreted at; a row shorter than [width] is treated as
  /// clear to the right, and anything past [width] is ignored, so a ragged grid cannot
  /// produce a misaligned raster.
  factory MonochromeBitmap.fromPixels({
    required int width,
    required List<List<bool>> pixels,
  }) {
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be a positive dot count');
    }

    final int height = pixels.length;
    final int widthBytes = (width + 7) ~/ 8;
    final Uint8List rows = Uint8List(widthBytes * height);

    for (int y = 0; y < height; y++) {
      final List<bool> row = pixels[y];
      for (int x = 0; x < width; x++) {
        final bool on = x < row.length && row[x];
        if (on) {
          rows[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7);
        }
      }
    }

    return MonochromeBitmap._(width: width, height: height, rows: rows);
  }

  /// Width of the image in dots.
  final int width;

  /// Height of the image in dots, which is the number of rows.
  final int height;

  /// The packed rows, `widthBytes * height` bytes, MSB-first, a set bit per black dot.
  final Uint8List rows;

  /// Row width in bytes, as the `GS v 0` header states it.
  int get widthBytes => (width + 7) ~/ 8;

  /// True when there is nothing to print.
  bool get isEmpty => width == 0 || height == 0;

  @override
  String toString() =>
      'MonochromeBitmap(${width}x$height dots, ${rows.length} bytes)';
}
