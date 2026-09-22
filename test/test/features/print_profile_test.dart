import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 80mm print profile: the single place a document layout learns about the printer.
///
/// Every number here is either from the ESC/POS specification or a layout decision this
/// build has made. The point of the tests is that they are decisions rather than
/// accidents, and that changing one changes every document rather than one corner of the
/// receipt.
void main() {
  group('the 80mm ESC/POS profile', () {
    const PrintProfile profile = PrintProfile.escPos80mm;

    test('is 48 columns of Font A on 80mm paper', () {
      expect(profile.paper, PaperWidth.mm80);
      expect(profile.font, PrinterFont.fontA);
      expect(profile.columns, 48);
      expect(profile.usesFontColumns, isTrue);
    });

    test('the column count is the printer arithmetic, not a literal', () {
      // 72mm printable at 203dpi is 576 dots; Font A is 12 dots wide.
      expect(PaperWidth.mm80.printableDots, 576);
      expect(PrinterFont.fontA.dotWidth, 12);
      expect(PrinterFont.fontA.columnsOn(PaperWidth.mm80), 48);
      expect(PrinterFont.fontB.columnsOn(PaperWidth.mm80), 64);
      expect(PrinterFont.fontA.columnsOn(PaperWidth.mm58), 32);
    });

    test('it cuts, feeds clear of the blade and can encode a QR', () {
      expect(profile.cut, PrintCut.full);
      expect(profile.cut.isCut, isTrue);
      expect(profile.feedLinesBeforeCut, greaterThan(0));
      expect(profile.canPrintQrCode, isTrue);
      expect(profile.qrErrorCorrection, QrErrorCorrection.medium);
      expect(profile.qrModuleSize, inInclusiveRange(1, 16));
    });

    test('an item indent leaves usable width for an option', () {
      expect(profile.optionIndent, greaterThan(0));
      expect(profile.indentedColumns, profile.columns - profile.optionIndent);
      expect(profile.indentedColumns, greaterThan(20));
    });

    test('the rule characters are single characters and differ', () {
      expect(profile.rule.length, 1);
      expect(profile.emphasisRule.length, 1);
      expect(profile.rule, isNot(profile.emphasisRule));
    });
  });

  group('a real printer that disagrees with the arithmetic', () {
    test('an override narrows the budget without touching the paper', () {
      // Some 80mm printers reserve a margin and print 42 columns of Font A. This is
      // discovered by counting the test page's ruler, and corrected here.
      const PrintProfile corrected = PrintProfile(columnOverride: 42);

      expect(corrected.columns, 42);
      expect(corrected.paper, PaperWidth.mm80);
      expect(corrected.usesFontColumns, isFalse);
      expect(corrected.indentedColumns, 42 - corrected.optionIndent);
    });

    test('an override can be dropped again', () {
      const PrintProfile corrected = PrintProfile(columnOverride: 42);

      expect(corrected.copyWith(clearColumnOverride: true).columns, 48);
      expect(corrected.copyWith(columnOverride: 47).columns, 47);
    });
  });

  group('derived from what the printer can do', () {
    test('the selected hardware yields the 80mm layout', () {
      final PrintProfile derived = PrintProfile.forCapabilities(
        PrinterCapabilities.escPos80mm,
      );

      expect(derived.paper, PaperWidth.mm80);
      expect(derived.columns, 48);
      expect(derived.cut, PrintCut.full);
      expect(derived.canPrintQrCode, isTrue);
    });

    test('a printer with no blade is never sent a cut', () {
      final PrintProfile derived = PrintProfile.forCapabilities(
        const PrinterCapabilities(
          paperWidth: PaperWidth.mm80,
          hasAutoCutter: false,
          supportsQrCode: true,
        ),
      );

      expect(derived.cut, PrintCut.none);
      expect(derived.cut.isCut, isFalse);
    });

    test('a printer with no QR engine gets no QR block', () {
      final PrintProfile derived = PrintProfile.forCapabilities(
        const PrinterCapabilities(
          paperWidth: PaperWidth.mm80,
          hasAutoCutter: true,
          supportsQrCode: false,
        ),
      );

      expect(derived.canPrintQrCode, isFalse);
    });

    test('a 58mm roll narrows the layout by itself', () {
      final PrintProfile derived = PrintProfile.forCapabilities(
        const PrinterCapabilities(
          paperWidth: PaperWidth.mm58,
          hasAutoCutter: true,
          supportsQrCode: true,
        ),
      );

      expect(derived.columns, 32);
    });

    test('the description names the device rather than a model', () {
      final String description = PrintProfile.escPos80mm.toString();

      expect(description, contains('80mm'));
      expect(description, contains('Font A'));
      expect(description, contains('48 columns'));
    });
  });
}
