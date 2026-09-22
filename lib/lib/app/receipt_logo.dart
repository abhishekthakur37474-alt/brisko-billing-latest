import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import '../features/printing/domain/models/monochrome_bitmap.dart';

/// The bundled asset the outlet logo is loaded from.
///
/// A build without this file simply prints receipts with no logo — see
/// [loadReceiptLogo]. Drop the official Brisko Pizza logo here (a PNG with a
/// transparent or white background reads best on thermal paper) and it appears at the
/// top of every receipt with no further wiring.
const String receiptLogoAsset = 'assets/images/brisko_logo.png';

/// Loads the outlet logo and reduces it to a printable monochrome bitmap, or returns
/// `null` when there is nothing to print.
///
/// ## Where the image work belongs
///
/// A thermal printer prints one bit per dot, so a logo has to be decoded, scaled to a
/// sensible width for 80mm paper and thresholded to black-or-white before it can be
/// sent. That needs an image codec, which lives in Flutter, not in the pure printing
/// pipeline. This function does it once at start-up and hands the finished
/// [MonochromeBitmap] down to the print document source, so the printing layer never
/// sees a PNG.
///
/// ## Never fails
///
/// A missing asset, an unreadable file or a decode error all resolve to `null`, and a
/// `null` logo prints a header with just the outlet name. A logo is a nicety on a bill;
/// it must never be the reason a receipt fails to print.
///
/// [targetWidthDots] caps the width so the logo is a reasonable size on the roll —
/// roughly 240 of the 576 printable dots on 80mm paper, about 30mm — and the height
/// scales with it, preserving the aspect ratio. [threshold] is the luminance (0–255)
/// below which a pixel becomes a black dot; a pixel that is mostly transparent stays
/// blank so a logo on a transparent background does not print as a filled box.
Future<MonochromeBitmap?> loadReceiptLogo({
  String assetKey = receiptLogoAsset,
  int targetWidthDots = 240,
  int threshold = 128,
}) async {
  try {
    final ByteData encoded = await rootBundle.load(assetKey);
    final ui.Codec codec = await ui.instantiateImageCodec(
      encoded.buffer.asUint8List(),
      targetWidth: targetWidthDots,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image image = frame.image;

    final ByteData? rgba = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final int width = image.width;
    final int height = image.height;
    image.dispose();

    if (rgba == null || width <= 0 || height <= 0) {
      return null;
    }

    final Uint8List bytes = rgba.buffer.asUint8List();
    final List<List<bool>> pixels = List<List<bool>>.generate(height, (int y) {
      return List<bool>.generate(width, (int x) {
        final int offset = (y * width + x) * 4;
        final int r = bytes[offset];
        final int g = bytes[offset + 1];
        final int b = bytes[offset + 2];
        final int a = bytes[offset + 3];
        // A mostly transparent pixel is blank paper, not a black dot.
        if (a < 128) {
          return false;
        }
        // Rec. 601 luminance; a dark pixel burns a dot.
        final int luminance = (r * 299 + g * 587 + b * 114) ~/ 1000;
        return luminance < threshold;
      });
    });

    return MonochromeBitmap.fromPixels(width: width, pixels: pixels);
  } catch (_) {
    // No asset, or an image the codec could not read. The receipt prints without a
    // logo rather than not at all.
    return null;
  }
}
