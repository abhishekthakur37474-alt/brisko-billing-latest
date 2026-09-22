import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_builder.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_commands.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/domain/models/business_identity.dart';
import 'package:brisko_billing/features/printing/domain/models/monochrome_bitmap.dart';
import 'package:brisko_billing/features/printing/domain/models/print_document.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';

/// The outlet logo, from packed dots to the top of a receipt.
///
/// The real logo is a bundled PNG that the app layer decodes and reduces to a
/// [MonochromeBitmap] at start-up (see lib/app/receipt_logo.dart). These tests use a
/// synthetic bitmap so the layout and the ESC/POS raster encoding can be verified
/// deterministically, without a binary asset or a real printer.
void main() {
  /// A small, deterministic checkerboard: [width] × [height] dots.
  MonochromeBitmap sampleLogo({int width = 24, int height = 16}) {
    return MonochromeBitmap.fromPixels(
      width: width,
      pixels: List<List<bool>>.generate(
        height,
        (int y) => List<bool>.generate(width, (int x) => (x + y).isEven),
      ),
    );
  }

  CustomerReceipt receiptWith(BusinessIdentity business) {
    final Money price = Money.parse('320.00');
    return CustomerReceipt(
      business: business,
      orderNumber: '20260915-0001',
      orderType: OrderType.dineIn,
      issuedAt: DateTime.utc(2026, 9, 15, 13, 2),
      lines: <CustomerReceiptLine>[
        CustomerReceiptLine(
          name: 'Cheese Pizza',
          variantName: 'Medium',
          quantity: 1,
          unitPrice: price,
          lineTotal: price,
        ),
      ],
      totals: CustomerReceiptTotals(
        subtotal: price,
        discount: Money.zero,
        tax: Money.zero,
        total: price,
      ),
      paymentMethod: PaymentMethod.cash,
    );
  }

  group('MonochromeBitmap packing', () {
    test('packs a row MSB-first into ceil(width / 8) bytes', () {
      // A 10-dot row with the first and last dot set. Ten dots need two bytes; the
      // first dot is the high bit of byte 0, the tenth is bit 6 of byte 1.
      final MonochromeBitmap bitmap = MonochromeBitmap.fromPixels(
        width: 10,
        pixels: <List<bool>>[
          <bool>[true, false, false, false, false, false, false, false, false, true],
        ],
      );

      expect(bitmap.width, 10);
      expect(bitmap.height, 1);
      expect(bitmap.widthBytes, 2);
      expect(bitmap.rows, hasLength(2));
      expect(bitmap.rows[0], 0x80);
      expect(bitmap.rows[1], 0x40);
      expect(bitmap.isEmpty, isFalse);
    });

    test('a non-positive width is refused', () {
      expect(
        () => MonochromeBitmap.fromPixels(width: 0, pixels: const <List<bool>>[]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('EscPosBuilder.image', () {
    test('emits GS v 0 with the bitmap dimensions and data, centred', () {
      final MonochromeBitmap logo = sampleLogo(width: 16, height: 8);
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(logo);

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());

      expect(sent.rasterImages, hasLength(1));
      final EscPosRasterImage raster = sent.rasterImages.single;
      expect(raster.widthBytes, 2); // 16 dots => 2 bytes
      expect(raster.heightDots, 8);
      expect(raster.data, hasLength(raster.expectedByteCount)); // 2 * 8 = 16
      expect(raster.data, hasLength(16));

      // Centred: the raster is preceded by an align-centre and the alignment is put
      // back to the left afterwards, so nothing below it inherits the centring.
      expect(sent.hasCommand(EscPosCommands.alignCentre), isTrue);
      expect(sent.hasCommand(EscPosCommands.alignLeft), isTrue);
    });

    test('prints nothing when the printer has no graphics mode', () {
      final EscPosBuilder builder = EscPosBuilder(
        profile: const PrintProfile(canPrintGraphics: false),
      );
      builder.image(sampleLogo());
      expect(builder.length, 0);
    });

    test('drops a bitmap wider than the paper rather than truncating it', () {
      // 600 dots is wider than the 576 printable dots of 80mm paper.
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(sampleLogo(width: 600, height: 1));
      expect(builder.length, 0);
    });

    test('a small logo fits in a single band', () {
      // 16 dots wide, 8 tall => 2 bytes/row, 16 bytes: far under the band budget, so it
      // is sent as one GS v 0 and does not need splitting.
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(sampleLogo(width: 16, height: 8));

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());
      expect(sent.rasterImages, hasLength(1));
      expect(sent.rasterImages.single.data, hasLength(16));
    });
  });

  group('EscPosBuilder.image banding — the real logo defect', () {
    // The supplied logo lands at 240x240 dots: 30 bytes/row, 7200 bytes of image data.
    // Sent as a single GS v 0 that overruns a compact printer's input buffer, which is
    // what printed a block of garbage above the outlet name. It must go out as bands
    // that each stay under EscPosCommands.rasterMaxBandBytes.
    MonochromeBitmap fullLogo() => MonochromeBitmap.fromPixels(
      width: 240,
      pixels: List<List<bool>>.generate(
        240,
        (int y) => List<bool>.generate(240, (int x) => (x + y).isEven),
      ),
    );

    test('a 240x240 logo is split into more than one band', () {
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(fullLogo());

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());
      expect(
        sent.rasterImages.length,
        greaterThan(1),
        reason: '7200 bytes cannot go in one buffer-safe band',
      );
    });

    test('every band is a well-framed GS v 0 under the buffer budget', () {
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(fullLogo());

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());
      for (final EscPosRasterImage band in sent.rasterImages) {
        // The data that followed the header is exactly widthBytes * heightDots: no
        // missing bytes, no extra bytes. A wrong count here is what makes a printer
        // read the rest of the document as commands.
        expect(band.data, hasLength(band.expectedByteCount));
        expect(band.widthBytes, 30); // ceil(240 / 8)
        expect(band.heightDots, greaterThan(0));
        // No band exceeds the buffer budget that caused the overrun.
        expect(
          band.data.length,
          lessThanOrEqualTo(EscPosCommands.rasterMaxBandBytes),
        );
      }
    });

    test('the bands stitch back to the exact source bitmap', () {
      final MonochromeBitmap source = fullLogo();
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(source);

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());
      final EscPosRasterImage stitched = sent.logo!;

      // Same width, full height, full payload, and byte-for-byte the same packing:
      // banding changes how the data is framed on the wire, never the image.
      expect(stitched.widthBytes, source.widthBytes); // 30
      expect(stitched.heightDots, source.height); // 240
      expect(stitched.data, hasLength(source.rows.length)); // 7200
      expect(stitched.data, orderedEquals(source.rows));
    });

    test('no line feed splits the bands, so the logo has no seam', () {
      final EscPosBuilder builder = EscPosBuilder();
      builder.image(fullLogo());

      final EscPosTranscript sent = EscPosTranscript.of(builder.bytes());
      // The image occupies exactly one printed "line" in the transcript: one trailing
      // LF after the last band, none between bands. A feed between bands would show up
      // as extra blank lines and print as a white gap through the logo.
      expect(sent.lines.where((String line) => line.isEmpty).length, 1);
    });
  });

  group('the receipt logo', () {
    const EscPosDocumentFormatter formatter = EscPosDocumentFormatter();

    test('a configured logo is not printed on the customer bill', () {
      final MonochromeBitmap logo = sampleLogo(width: 24, height: 16);
      final EscPosTranscript paper = EscPosTranscript.of(
        formatter.encode(
          receiptWith(BusinessIdentity(name: 'BRISKO PIZZA', logo: logo)),
        ),
      );

      expect(paper.rasterImages, isEmpty);
      expect(paper.hasLineContaining('BRISKO PIZZA'), isTrue);
    });

    test('a receipt with no logo configured prints no raster image', () {
      final EscPosTranscript paper = EscPosTranscript.of(
        formatter.encode(
          receiptWith(const BusinessIdentity(name: 'BRISKO PIZZA')),
        ),
      );

      expect(paper.rasterImages, isEmpty);
      expect(paper.hasLineContaining('BRISKO PIZZA'), isTrue);
    });

    test('a logo is suppressed on a printer with no graphics mode', () {
      const EscPosDocumentFormatter noGraphics = EscPosDocumentFormatter(
        profile: PrintProfile(canPrintGraphics: false),
      );
      final EscPosTranscript paper = EscPosTranscript.of(
        noGraphics.encode(
          receiptWith(
            BusinessIdentity(name: 'BRISKO PIZZA', logo: sampleLogo()),
          ),
        ),
      );

      expect(paper.rasterImages, isEmpty);
      // The header still identifies the bill.
      expect(paper.hasLineContaining('BRISKO PIZZA'), isTrue);
    });
  });
}
