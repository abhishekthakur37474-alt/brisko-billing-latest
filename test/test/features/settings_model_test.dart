import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/print_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_capabilities.dart';
import 'package:brisko_billing/features/settings/domain/models/gstin.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

/// The settings values themselves: what they mean, what they refuse, and how they are
/// stored.
///
/// Pure Dart. No database, no widgets and no printer, which is the point: what a GSTIN
/// is and what a printer layout may be set to are decisions, and a decision is cheaper to
/// check here than through a form.
void main() {
  group('an unconfigured terminal', () {
    test('has no business details of any kind', () {
      const PosSettings settings = PosSettings.unconfigured;

      // Nothing is invented. Every one of these is a legal or financial identifier
      // belonging to the owner, and a plausible-looking placeholder on a tax invoice is
      // worse than a blank line.
      expect(settings.businessName, isNull);
      expect(settings.businessAddress, isNull);
      expect(settings.businessPhone, isNull);
      expect(settings.gstin, isNull);
      expect(settings.receiptHeader, isNull);
      expect(settings.receiptFooter, isNull);
      expect(settings.upiVpa, isNull);
      expect(settings.upiPayeeName, isNull);
      expect(settings.isCompleteForTaxInvoice, isFalse);
    });

    test('opens settlement on the default the flow has always used', () {
      expect(PosSettings.unconfigured.defaultOrderType, OrderType.takeaway);
      expect(PosSettings.fallbackOrderType, OrderType.takeaway);
    });

    test('reads an empty table as unconfigured', () {
      expect(
        PosSettings.fromStored(const <String, String?>{}),
        PosSettings.unconfigured,
      );
    });

    test('reads a blank stored value as unconfigured, not as blank', () {
      // A row written as an empty string by an older build means the same thing as no
      // row at all, and both have to print the same bill.
      final PosSettings settings = PosSettings.fromStored(<String, String?>{
        SettingKeys.businessName: '   ',
        SettingKeys.gstin: '',
      });

      expect(settings.businessName, isNull);
      expect(settings.gstin, isNull);
    });
  });

  group('PosSettings storage', () {
    const PosSettings configured = PosSettings(
      businessName: 'Brisko Pizza Kothrud',
      businessAddress: '12 Paud Road, Kothrud, Pune 411038',
      businessPhone: '020 2545 1234',
      gstin: '27AAPFU0939F1ZV',
      receiptHeader: 'Wood-fired since 2019',
      receiptFooter: 'Thank you, come again',
      upiVpa: 'brisko@upi',
      upiPayeeName: 'Brisko Pizza',
      defaultOrderType: OrderType.delivery,
    );

    test('round-trips through the stored form unchanged', () {
      expect(PosSettings.fromStored(configured.toStored()), configured);
    });

    test('a cleared field is stored as an absent key, not an empty string', () {
      final Map<String, String?> stored = PosSettings.unconfigured.toStored();

      expect(stored[SettingKeys.businessName], isNull);
      expect(stored[SettingKeys.gstin], isNull);
      // The order type is always written: it is a choice among four, not a blank.
      expect(stored[SettingKeys.defaultOrderType], OrderType.takeaway.name);
    });

    test('the order type is stored by name so reordering cannot change it', () {
      expect(
        configured.toStored()[SettingKeys.defaultOrderType],
        OrderType.delivery.name,
      );
    });

    test('an unrecognised order type falls back rather than throwing', () {
      final PosSettings settings = PosSettings.fromStored(<String, String?>{
        SettingKeys.defaultOrderType: 'driveThrough',
      });

      expect(settings.defaultOrderType, PosSettings.fallbackOrderType);
    });

    test('the address and GSTIN together decide tax-invoice completeness', () {
      expect(configured.isCompleteForTaxInvoice, isTrue);
      expect(
        configured.copyWith().isCompleteForTaxInvoice,
        isTrue,
        reason: 'copyWith with no arguments must not drop a field',
      );
    });

    test('text is trimmed on the way in and otherwise left alone', () {
      final PosSettings settings = PosSettings.fromStored(<String, String?>{
        SettingKeys.receiptFooter: '  Thank you, come again!  ',
      });

      // Punctuation, capitalisation and inner spacing are the owner's.
      expect(settings.receiptFooter, 'Thank you, come again!');
    });

    test('kitchen-slip and customer-details flags default on when absent', () {
      expect(PosSettings.unconfigured.printKitchenSlip, isTrue);
      expect(PosSettings.unconfigured.askCustomerDetails, isTrue);
      expect(
        PosSettings.fromStored(const <String, String?>{}).printKitchenSlip,
        isTrue,
      );
      expect(
        PosSettings.fromStored(const <String, String?>{}).askCustomerDetails,
        isTrue,
      );
    });

    test('kitchen-slip and customer-details flags round-trip as true or false', () {
      const PosSettings off = PosSettings(
        printKitchenSlip: false,
        askCustomerDetails: false,
      );

      expect(off.toStored()[SettingKeys.printKitchenSlip], 'false');
      expect(off.toStored()[SettingKeys.askCustomerDetails], 'false');
      expect(PosSettings.fromStored(off.toStored()), off);

      final PosSettings fromFalse = PosSettings.fromStored(<String, String?>{
        SettingKeys.printKitchenSlip: 'false',
        SettingKeys.askCustomerDetails: 'false',
      });
      expect(fromFalse.printKitchenSlip, isFalse);
      expect(fromFalse.askCustomerDetails, isFalse);
    });
  });

  group('GSTIN', () {
    test('blank is acceptable, because the setting is optional', () {
      expect(Gstin.isBlank(''), isTrue);
      expect(Gstin.isBlank('   '), isTrue);
      expect(Gstin.isAcceptable(''), isTrue);
      expect(Gstin.isAcceptable('   '), isTrue);
    });

    test('a well-formed number is accepted and stored upper-cased', () {
      expect(Gstin.tryNormalise('27AAPFU0939F1ZV'), '27AAPFU0939F1ZV');
      expect(Gstin.tryNormalise('  29aagcb7383j1z4 '), '29AAGCB7383J1Z4');
    });

    test('the state code can be read back', () {
      expect(Gstin.stateCodeOf('27AAPFU0939F1ZV'), '27');
      expect(Gstin.stateCodeOf('not a gstin'), isNull);
    });

    test('a value that is not a GSTIN is refused, never adjusted', () {
      const List<String> refused = <String>[
        '27AAPFU0939F1Z', // fourteen characters
        '27AAPFU0939F1ZVX', // sixteen
        'AAAAAAA0939F1ZV', // letters where the state code goes
        '27AAPFU0939F1AV', // the fixed Z is not a Z
        '27AAPF10939F1ZV', // a digit inside the PAN's letters
        '27AAPFU093AF1ZV', // a letter inside the PAN's digits
        '27 AAPFU0939F1ZV', // a space inside the number
        '27-AAPFU0939F1ZV',
      ];

      for (final String value in refused) {
        expect(
          Gstin.tryNormalise(value),
          isNull,
          reason: '$value is not a GSTIN and must not be stored',
        );
        expect(Gstin.isAcceptable(value), isFalse);
      }
    });

    test('the requirement message says what a GSTIN looks like', () {
      // The operator has to be able to act on the refusal.
      expect(Gstin.requirement, contains('15'));
      expect(Gstin.length, 15);
    });
  });

  group('PrintSettings', () {
    const PrinterCapabilities full = PrinterCapabilities.escPos80mm;

    /// A printer with no blade and no QR engine: the two capability bounds.
    const PrinterCapabilities bare = PrinterCapabilities(
      paperWidth: PaperWidth.mm80,
      hasAutoCutter: false,
      supportsQrCode: false,
    );

    PrintSettings defaults() =>
        PrintSettings.fromProfile(PrintProfile.escPos80mm);

    test('its defaults are the profile the build already declares', () {
      final PrintSettings settings = defaults();

      expect(settings.font, PrintProfile.escPos80mm.font);
      expect(settings.columnOverride, PrintProfile.escPos80mm.columnOverride);
      expect(settings.cut, PrintProfile.escPos80mm.cut);
      expect(
        settings.feedLinesBeforeCut,
        PrintProfile.escPos80mm.feedLinesBeforeCut,
      );
      expect(settings.isQrEnabled, PrintProfile.escPos80mm.canPrintQrCode);
      expect(settings.qrModuleSize, PrintProfile.escPos80mm.qrModuleSize);
      expect(
        settings.qrErrorCorrection,
        PrintProfile.escPos80mm.qrErrorCorrection,
      );
    });

    test('applying the defaults changes nothing about the profile', () {
      final PrintProfile applied = defaults().applyTo(PrintProfile.escPos80mm);

      expect(applied.columns, PrintProfile.escPos80mm.columns);
      expect(applied.font, PrintProfile.escPos80mm.font);
      expect(applied.cut, PrintProfile.escPos80mm.cut);
    });

    test('the font changes the column budget', () {
      final PrintProfile applied = defaults()
          .copyWith(font: PrinterFont.fontB)
          .applyTo(PrintProfile.escPos80mm);

      expect(applied.columns, 64);
      expect(applied.usesFontColumns, isTrue);
    });

    test('a column override wins over the font arithmetic', () {
      final PrintProfile applied = defaults()
          .copyWith(columnOverride: 42)
          .applyTo(PrintProfile.escPos80mm);

      expect(applied.columns, 42);
      expect(applied.usesFontColumns, isFalse);
    });

    test('clearing the override returns to the font arithmetic', () {
      final PrintProfile applied = defaults()
          .copyWith(columnOverride: 42)
          .copyWith(clearColumnOverride: true)
          .applyTo(PrintProfile.escPos80mm);

      expect(applied.columns, 48);
      expect(applied.usesFontColumns, isTrue);
    });

    test('the paper and the indent are not the operator\'s to change', () {
      // Nothing in PrintSettings can move either, which is why they are absent from it.
      final PrintProfile applied = defaults()
          .copyWith(font: PrinterFont.fontB, columnOverride: 40)
          .applyTo(PrintProfile.escPos80mm);

      expect(applied.paper, PrintProfile.escPos80mm.paper);
      expect(applied.optionIndent, PrintProfile.escPos80mm.optionIndent);
      expect(applied.rule, PrintProfile.escPos80mm.rule);
      expect(applied.emphasisRule, PrintProfile.escPos80mm.emphasisRule);
    });

    test('the chosen hardware accepts every default', () {
      expect(defaults().problems(full), isEmpty);
      expect(defaults().isValidFor(full), isTrue);
    });

    test('a column count wider than the font fits is refused', () {
      final PrintSettings settings = defaults().copyWith(columnOverride: 49);

      expect(settings.problems(full), hasLength(1));
      expect(settings.problems(full).single, contains('Columns'));
      expect(settings.isValidFor(full), isFalse);
    });

    test('Font B allows the columns Font A would not', () {
      final PrintSettings settings = defaults().copyWith(columnOverride: 60);

      expect(settings.problems(full), isNotEmpty);
      expect(
        settings.copyWith(font: PrinterFont.fontB).problems(full),
        isEmpty,
      );
    });

    test('a column count too narrow to indent an option is refused', () {
      // Below this an option line has no width at all, so a customisation would print
      // as nothing.
      final int tooNarrow = PrintProfile.escPos80mm.optionIndent;

      expect(
        defaults().copyWith(columnOverride: tooNarrow).problems(full),
        isNotEmpty,
      );
      expect(
        defaults().copyWith(columnOverride: tooNarrow + 1).problems(full),
        isEmpty,
      );
    });

    test(
      'a feed of zero is refused, because the blade sits above the head',
      () {
        expect(
          defaults().copyWith(feedLinesBeforeCut: 0).problems(full).single,
          contains('Feed'),
        );
        expect(
          defaults()
              .copyWith(feedLinesBeforeCut: PrintSettings.minFeedLinesBeforeCut)
              .problems(full),
          isEmpty,
        );
      },
    );

    test('a feed beyond one command byte is refused', () {
      expect(
        defaults()
            .copyWith(
              feedLinesBeforeCut: PrintSettings.maxFeedLinesBeforeCut + 1,
            )
            .problems(full),
        isNotEmpty,
      );
    });

    test('a QR module outside the command range is refused', () {
      expect(
        defaults()
            .copyWith(qrModuleSize: PrintSettings.minQrModuleSize - 1)
            .problems(full),
        isNotEmpty,
      );
      expect(
        defaults()
            .copyWith(qrModuleSize: PrintSettings.maxQrModuleSize + 1)
            .problems(full),
        isNotEmpty,
      );
      expect(
        defaults()
            .copyWith(qrModuleSize: PrintSettings.maxQrModuleSize)
            .problems(full),
        isEmpty,
      );
    });

    test('a cut cannot be chosen on a printer with no blade', () {
      expect(
        defaults().copyWith(cut: PrintCut.full).problems(bare),
        contains(contains('no cutter')),
      );
      expect(
        defaults().copyWith(cut: PrintCut.partial).problems(bare),
        contains(contains('no cutter')),
      );
    });

    test('a QR cannot be enabled on a printer with no QR engine', () {
      expect(
        defaults()
            // Cut set to none as well, so the only problem left is the QR.
            .copyWith(cut: PrintCut.none, isQrEnabled: true)
            .problems(bare)
            .single,
        contains('no QR engine'),
      );
    });

    test(
      'a bare printer accepts the layout derived from its own capabilities',
      () {
        expect(
          PrintSettings.fromProfile(PrintProfile.forCapabilities(bare))
              .problems(bare),
          isEmpty,
        );
      },
    );

    test('every problem is reported at once, not one at a time', () {
      final PrintSettings settings = defaults().copyWith(
        columnOverride: 100,
        feedLinesBeforeCut: 0,
        qrModuleSize: 99,
      );

      expect(settings.problems(full), hasLength(3));
    });

    test('round-trips through the stored form unchanged', () {
      final PrintSettings settings = defaults().copyWith(
        font: PrinterFont.fontB,
        columnOverride: 42,
        cut: PrintCut.partial,
        feedLinesBeforeCut: 6,
        isQrEnabled: false,
        qrModuleSize: 8,
        qrErrorCorrection: QrErrorCorrection.high,
      );

      expect(
        PrintSettings.fromStored(
          settings.toStored(),
          fallback: PrintProfile.escPos80mm,
        ),
        settings,
      );
    });

    test('an absent column override is stored as an absent key', () {
      expect(defaults().toStored()[SettingKeys.printerColumnOverride], isNull);
      expect(
        PrintSettings.fromStored(
          defaults().toStored(),
          fallback: PrintProfile.escPos80mm,
        ).columnOverride,
        isNull,
      );
    });

    test('a corrupt stored value falls back rather than stopping the till', () {
      final PrintSettings settings = PrintSettings.fromStored(<String, String?>{
        SettingKeys.printerFont: 'fontZ',
        SettingKeys.printerCut: 'guillotine',
        SettingKeys.printerFeedLinesBeforeCut: 'four',
        SettingKeys.printerQrModuleSize: '',
        SettingKeys.printerQrErrorCorrection: 'perfect',
      }, fallback: PrintProfile.escPos80mm);

      expect(settings, defaults());
    });

    test('an empty table reads as the printer\'s own profile', () {
      expect(
        PrintSettings.fromStored(
          const <String, String?>{},
          fallback: PrintProfile.escPos80mm,
        ),
        defaults(),
      );
    });

    test('the settings carry no address, device or transport', () {
      // Read as documentation: the type has seven members and none of them is a place.
      expect(
        defaults().toStored().keys.every(
          (String key) => key.startsWith('printer.'),
        ),
        isTrue,
      );
      expect(
        defaults().toStored().keys,
        isNot(contains(anyOf(contains('host'), contains('port')))),
      );
    });
  });
}
