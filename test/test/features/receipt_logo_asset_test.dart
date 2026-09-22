import 'package:brisko_billing/app/receipt_logo.dart';
import 'package:brisko_billing/features/printing/domain/models/monochrome_bitmap.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled outlet logo, decoded through the real loader.
///
/// Unlike receipt_logo_test.dart, which exercises the raster encoding with a synthetic
/// bitmap, this test loads the actual `assets/images/brisko_logo.png` asset through the
/// production [loadReceiptLogo], so it fails if the file is missing from the bundle, is
/// not declared in pubspec, or cannot be decoded. It proves the supplied logo reaches
/// the print pipeline as printable dots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the supplied Brisko logo asset decodes to a printable bitmap', () async {
    final MonochromeBitmap? logo = await loadReceiptLogo();

    expect(
      logo,
      isNotNull,
      reason:
          'assets/images/brisko_logo.png must be bundled (pubspec) and decodable.',
    );
    expect(logo!.isEmpty, isFalse);

    // Scaled to the loader's target width, with the aspect ratio preserved.
    expect(logo.width, 240);
    expect(logo.widthBytes, 30); // ceil(240 / 8)
    // The supplied logo is square, so the scaled height matches the width.
    expect(logo.height, 240);
    expect(logo.rows, hasLength(logo.widthBytes * logo.height));

    // Comfortably inside the 576 printable dots of 80mm paper: centred, not oversized.
    expect(logo.width, lessThanOrEqualTo(576));
  });
}
