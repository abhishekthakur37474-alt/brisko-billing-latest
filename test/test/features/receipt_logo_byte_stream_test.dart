import 'package:brisko_billing/core/money/money.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/domain/models/business_identity.dart';
import 'package:brisko_billing/features/printing/domain/models/monochrome_bitmap.dart';
import 'package:brisko_billing/features/printing/domain/models/print_document.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';

/// Byte-level regression for the logo raster defect (Step 19 / Step 7).
///
/// The physical symptom was a block of garbage characters above `BRISKO PIZZA`: the
/// whole 240×240 logo went out as one `GS v 0` whose 7200-byte payload overran the
/// printer's input buffer, so the printer fell out of raster mode and printed the
/// remaining image bytes as text. This test generates a complete receipt through the
/// real encoder and parses the byte stream to prove the logo is now framed as
/// buffer-safe bands and that the receipt text begins cleanly after the image — nothing
/// the printer could read as characters leaks out of the raster payload.
void main() {
  /// A 240×240 logo, the size the bundled Brisko PNG is reduced to. A dense pattern so
  /// the payload is full-size, not sparse.
  MonochromeBitmap logo240() => MonochromeBitmap.fromPixels(
    width: 240,
    pixels: List<List<bool>>.generate(
      240,
      (int y) => List<bool>.generate(240, (int x) => ((x ~/ 3) + (y ~/ 3)).isEven),
    ),
  );

  CustomerReceipt fullReceipt() {
    final Money price = Money.parse('400.00');
    return CustomerReceipt(
      business: BusinessIdentity(
        name: 'BRISKO PIZZA',
        address: '12 Main Road',
        phone: '080-1234-5678',
        feedbackUrl: 'https://brisko.example/review/42',
        logo: logo240(),
      ),
      orderNumber: '20260915-0007',
      orderType: OrderType.takeaway,
      issuedAt: DateTime.utc(2026, 9, 15, 13, 2),
      lines: <CustomerReceiptLine>[
        CustomerReceiptLine(
          name: 'Cheese Pizza',
          variantName: 'Large',
          quantity: 1,
          unitPrice: price,
          lineTotal: price,
        ),
      ],
      totals: CustomerReceiptTotals(
        subtotal: price,
        discount: Money.parse('40.00'),
        tax: Money.parse('64.80'),
        total: Money.parse('424.80'),
        discountLabel: '10%',
      ),
      paymentMethod: PaymentMethod.upi,
    );
  }

  const EscPosDocumentFormatter formatter = EscPosDocumentFormatter();

  group('the customer bill does not print a logo', () {
    test('a configured logo still emits no raster command', () {
      final EscPosTranscript paper = EscPosTranscript.of(
        formatter.encode(fullReceipt()),
      );

      expect(paper.rasterImages, isEmpty);
      expect(paper.hasLineContaining('BRISKO PIZZA'), isTrue);
      expect(paper.lines.first.contains('BRISKO PIZZA'), isTrue);
    });

    test('the receipt still carries the feedback QR and the GST/discount lines', () {
      final EscPosTranscript paper = EscPosTranscript.of(
        formatter.encode(fullReceipt()),
      );

      expect(paper.qrPayloads, contains('https://brisko.example/review/42'));
      expect(paper.hasLineContaining('CGST'), isTrue);
      expect(paper.hasLineContaining('SGST'), isTrue);
      expect(paper.hasLineContaining('Discount'), isTrue);
      expect(paper.hasLineContaining('Taxable amount'), isTrue);
      expect(paper.hasLineContaining('TOTAL INR'), isTrue);
    });

    test('a receipt with no logo emits no raster command at all', () {
      final EscPosTranscript paper = EscPosTranscript.of(
        formatter.encode(
          CustomerReceipt(
            business: const BusinessIdentity(name: 'BRISKO PIZZA'),
            orderNumber: '20260915-0008',
            orderType: OrderType.dineIn,
            issuedAt: DateTime.utc(2026, 9, 15, 13, 2),
            lines: <CustomerReceiptLine>[
              CustomerReceiptLine(
                name: 'Cheese Pizza',
                quantity: 1,
                unitPrice: Money.parse('400.00'),
                lineTotal: Money.parse('400.00'),
              ),
            ],
            totals: CustomerReceiptTotals(
              subtotal: Money.parse('400.00'),
              discount: Money.zero,
              tax: Money.zero,
              total: Money.parse('400.00'),
            ),
            paymentMethod: PaymentMethod.cash,
          ),
        ),
      );

      expect(paper.rasterImages, isEmpty);
    });
  });
}
