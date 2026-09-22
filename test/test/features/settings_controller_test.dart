import 'dart:io';

import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/printing/data/escpos/configurable_escpos_encoder.dart';
import 'package:brisko_billing/features/printing/data/printers/unconfigured_thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/print_settings.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/active_pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/gstin.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:brisko_billing/features/settings/domain/repositories/settings_repository.dart';
import 'package:brisko_billing/features/settings/presentation/controllers/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/failing_settings_repository.dart';
import '../helpers/test_database.dart';

/// The Settings controller: its states, what it refuses, and what survives.
///
/// Everything here runs against the real settings table through the real repository, so a
/// "saves and reloads" test is a statement about what is on disk rather than about a field
/// on a controller.
///
/// No printer is involved beyond [UnconfiguredThermalPrinter], which is the printer this
/// terminal actually has: none. Nothing in this file opens a device, a socket or a port.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteSettingsRepository repository;
  late ConfigurableEscPosEncoder encoder;
  late ActivePosSettings active;

  /// A controller over [source], already loaded.
  Future<SettingsController> loaded({SettingsRepository? source}) async {
    final SettingsController controller = SettingsController(
      settings: source ?? repository,
      printProfile: encoder,
      activeSettings: active,
    );
    addTearDown(controller.dispose);
    await controller.load();
    return controller;
  }

  setUp(() async {
    database = await TestDatabase.openInMemory();
    repository = SqliteSettingsRepository(database: database);
    encoder = ConfigurableEscPosEncoder.forPrinter(
      UnconfiguredThermalPrinter(),
    );
    active = ActivePosSettings();
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  // --------------------------------------------------------------- loading ---

  group('loading', () {
    test('an empty table loads as an unconfigured outlet', () async {
      final SettingsController controller = await loaded();

      expect(controller.status, SettingsStatus.loaded);
      expect(controller.hasLoaded, isTrue);
      expect(controller.hasError, isFalse);
      expect(controller.isDirty, isFalse);

      // Blank fields, not invented ones.
      expect(controller.businessName, isEmpty);
      expect(controller.businessAddress, isEmpty);
      expect(controller.businessPhone, isEmpty);
      expect(controller.gstin, isEmpty);
      expect(controller.receiptHeader, isEmpty);
      expect(controller.receiptFooter, isEmpty);
      expect(controller.upiVpa, isEmpty);
      expect(controller.defaultOrderType, PosSettings.fallbackOrderType);
    });

    test('the printer form starts on the printer\'s own profile', () async {
      final SettingsController controller = await loaded();
      final PrintProfile base = encoder.baseProfile;

      expect(controller.font, base.font);
      expect(controller.columnOverride, isEmpty);
      expect(controller.cut, base.cut);
      expect(controller.feedLinesBeforeCut, base.feedLinesBeforeCut.toString());
      expect(controller.isQrEnabled, base.canPrintQrCode);
      expect(controller.qrModuleSize, base.qrModuleSize.toString());
      expect(controller.qrErrorCorrection, base.qrErrorCorrection);
      expect(controller.isValid, isTrue);
    });

    test('it starts in the loading state before the read finishes', () {
      final SettingsController controller = SettingsController(
        settings: repository,
        printProfile: encoder,
        activeSettings: active,
      );
      addTearDown(controller.dispose);

      expect(controller.status, SettingsStatus.loading);
      expect(controller.hasLoaded, isFalse);
      expect(controller.canSave, isFalse);
    });

    test('a read failure becomes an error state with a retry', () async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
        failReads: true,
      );

      final SettingsController controller = await loaded(source: failing);

      expect(controller.status, SettingsStatus.error);
      expect(controller.hasLoaded, isFalse);
      expect(controller.errorMessage, FailingSettingsRepository.readMessage);
      expect(controller.canSave, isFalse);

      // The retry is the same call, and it succeeds once storage does.
      failing.failReads = false;
      await controller.retry();

      expect(controller.status, SettingsStatus.loaded);
      expect(controller.hasLoaded, isTrue);
      expect(controller.hasError, isFalse);
    });

    test('a read failure does not blank the form over stored values', () async {
      await repository.writeString(
        SettingKeys.businessAddress,
        '12 Paud Road, Pune',
      );

      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
        failReads: true,
      );
      final SettingsController controller = await loaded(source: failing);

      // The screen shows the failure instead of the form, so nothing can be saved over
      // an address that is on disk and merely unreadable at this moment.
      expect(controller.hasLoaded, isFalse);
      expect(
        (await repository.readString(SettingKeys.businessAddress)).valueOrNull,
        '12 Paud Road, Pune',
      );
    });
  });

  // ---------------------------------------------------------------- saving ---

  group('saving', () {
    test('the business name saves and reloads', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');

      expect(controller.isDirty, isTrue);
      expect(controller.canSave, isTrue);
      expect(await controller.save(), isTrue);
      expect(controller.status, SettingsStatus.saved);
      expect(controller.isDirty, isFalse);

      final SettingsController reopened = await loaded();
      expect(reopened.businessName, 'Brisko Pizza Kothrud');
    });

    test('the address saves and reloads', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessAddress('12 Paud Road, Kothrud, Pune 411038');
      expect(await controller.save(), isTrue);

      expect(
        (await loaded()).businessAddress,
        '12 Paud Road, Kothrud, Pune 411038',
      );
    });

    test('the phone saves and reloads exactly as typed', () async {
      final SettingsController controller = await loaded();
      // A landline with an STD code. The customer-phone rule would refuse this, which is
      // why the outlet's own number is deliberately not put through it.
      controller.editBusinessPhone('020 2545 1234');
      expect(await controller.save(), isTrue);

      expect((await loaded()).businessPhone, '020 2545 1234');
    });

    test('the GSTIN saves and reloads', () async {
      final SettingsController controller = await loaded();
      controller.editGstin('27AAPFU0939F1ZV');
      expect(controller.gstinError, isNull);
      expect(await controller.save(), isTrue);

      expect((await loaded()).gstin, '27AAPFU0939F1ZV');
    });

    test('a GSTIN typed in lower case is stored in its own alphabet', () async {
      final SettingsController controller = await loaded();
      controller.editGstin('27aapfu0939f1zv');
      expect(await controller.save(), isTrue);

      // Upper-casing is not a repair: it is the alphabet a GSTIN is defined in, and the
      // form shows back exactly what was stored.
      expect(controller.gstin, '27AAPFU0939F1ZV');
      expect((await loaded()).gstin, '27AAPFU0939F1ZV');
    });

    test('the receipt header saves and reloads', () async {
      final SettingsController controller = await loaded();
      controller.editReceiptHeader('Wood-fired since 2019');
      expect(await controller.save(), isTrue);

      expect((await loaded()).receiptHeader, 'Wood-fired since 2019');
    });

    test('the receipt footer saves and reloads, wording intact', () async {
      const String footer = 'Thank you! No returns on cut pizza.';
      final SettingsController controller = await loaded();
      controller.editReceiptFooter(footer);
      expect(await controller.save(), isTrue);

      expect((await loaded()).receiptFooter, footer);
    });

    test('the UPI address and payee name save and reload', () async {
      final SettingsController controller = await loaded();
      controller.editUpiVpa('brisko@upi');
      controller.editUpiPayeeName('Brisko Pizza Kothrud');
      expect(await controller.save(), isTrue);

      final SettingsController reopened = await loaded();
      expect(reopened.upiVpa, 'brisko@upi');
      expect(reopened.upiPayeeName, 'Brisko Pizza Kothrud');
    });

    test('the default order type saves and reloads', () async {
      final SettingsController controller = await loaded();
      controller.selectDefaultOrderType(OrderType.delivery);
      expect(await controller.save(), isTrue);

      expect((await loaded()).defaultOrderType, OrderType.delivery);
    });

    test('the kitchen-slip and customer-details flags save and reload', () async {
      final SettingsController controller = await loaded();
      expect(controller.printKitchenSlip, isTrue);
      expect(controller.askCustomerDetails, isTrue);

      controller.setPrintKitchenSlip(isEnabled: false);
      controller.setAskCustomerDetails(isEnabled: false);
      expect(controller.isDirty, isTrue);
      expect(await controller.save(), isTrue);

      final SettingsController reopened = await loaded();
      expect(reopened.printKitchenSlip, isFalse);
      expect(reopened.askCustomerDetails, isFalse);
      expect(active.settings.printKitchenSlip, isFalse);
      expect(active.settings.askCustomerDetails, isFalse);
    });

    test('every printer setting saves and reloads', () async {
      final SettingsController controller = await loaded();

      controller.selectFont(PrinterFont.fontB);
      controller.editColumnOverride('56');
      controller.selectCut(PrintCut.partial);
      controller.editFeedLinesBeforeCut('6');
      controller.setQrEnabled(isEnabled: false);
      controller.editQrModuleSize('8');
      controller.selectQrErrorCorrection(QrErrorCorrection.high);

      expect(controller.printerProblems, isEmpty);
      expect(await controller.save(), isTrue);

      final SettingsController reopened = await loaded();
      expect(reopened.font, PrinterFont.fontB);
      expect(reopened.columnOverride, '56');
      expect(reopened.cut, PrintCut.partial);
      expect(reopened.feedLinesBeforeCut, '6');
      expect(reopened.isQrEnabled, isFalse);
      expect(reopened.qrModuleSize, '8');
      expect(reopened.qrErrorCorrection, QrErrorCorrection.high);
    });

    test('clearing a field removes it rather than storing a blank', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');
      await controller.save();

      controller.editBusinessName('   ');
      expect(await controller.save(), isTrue);

      final Map<String, String?> stored =
          (await repository.readAll()).valueOrNull!;
      expect(stored.containsKey(SettingKeys.businessName), isFalse);
      expect((await loaded()).businessName, isEmpty);
    });

    test('a save applies the settings the terminal is running with', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');
      controller.selectDefaultOrderType(OrderType.dineIn);
      controller.editColumnOverride('42');
      await controller.save();

      // The in-memory copy checkout reads, and the profile the encoder lays out for.
      expect(active.settings.businessName, 'Brisko Pizza Kothrud');
      expect(active.settings.defaultOrderType, OrderType.dineIn);
      expect(encoder.profile.columns, 42);
    });

    test('nothing is applied until the write commits', () async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
        failWrites: true,
      );
      final SettingsController controller = await loaded(source: failing);

      controller.editBusinessName('Brisko Pizza Kothrud');
      controller.editColumnOverride('42');
      expect(await controller.save(), isFalse);

      expect(active.settings.businessName, isNull);
      expect(encoder.profile.columns, encoder.baseProfile.columns);
    });

    test('saving with nothing changed is not offered', () async {
      final SettingsController controller = await loaded();

      expect(controller.isDirty, isFalse);
      expect(controller.canSave, isFalse);
    });

    test('discarding returns the form to what is stored', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');
      await controller.save();

      controller.editBusinessName('Typed by mistake');
      controller.editGstin('nonsense');
      controller.discardChanges();

      expect(controller.businessName, 'Brisko Pizza Kothrud');
      expect(controller.gstin, isEmpty);
      expect(controller.isDirty, isFalse);
      expect(controller.hasError, isFalse);
    });

    test(
      'the saved confirmation clears as soon as anything is edited',
      () async {
        final SettingsController controller = await loaded();
        controller.editReceiptFooter('Thank you');
        await controller.save();
        expect(controller.isSaved, isTrue);

        controller.editReceiptFooter('Thank you, come again');
        expect(controller.isSaved, isFalse);
        expect(controller.status, SettingsStatus.loaded);
      },
    );
  });

  // ------------------------------------------------------------ validation ---

  group('validation', () {
    test('an invalid GSTIN is refused and nothing is written', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');
      controller.editGstin('27AAPFU0939F1Z');

      expect(controller.gstinError, Gstin.requirement);
      expect(controller.isValid, isFalse);
      expect(controller.canSave, isFalse);
      expect(await controller.save(), isFalse);

      expect(controller.status, SettingsStatus.error);
      expect(controller.errorMessage, contains('GSTIN'));
      // Not one key of the form reached the table, including the valid ones.
      expect((await repository.readAll()).valueOrNull, isEmpty);
      // And the typing is still there to be corrected.
      expect(controller.gstin, '27AAPFU0939F1Z');
      expect(controller.businessName, 'Brisko Pizza Kothrud');
    });

    test(
      'a blank GSTIN is accepted, because the setting is optional',
      () async {
        final SettingsController controller = await loaded();
        controller.editGstin('  ');

        expect(controller.gstinError, isNull);
        expect(controller.isValid, isTrue);
      },
    );

    test('a column count wider than the paper is refused', () async {
      final SettingsController controller = await loaded();
      controller.editColumnOverride('96');

      expect(controller.columnOverrideError, isNotNull);
      expect(controller.canSave, isFalse);
      expect(await controller.save(), isFalse);
      expect((await repository.readAll()).valueOrNull, isEmpty);
    });

    test('a column count that is not a number is refused', () async {
      final SettingsController controller = await loaded();
      controller.editColumnOverride('forty two');

      expect(controller.columnOverrideError, isNotNull);
      expect(await controller.save(), isFalse);
    });

    test(
      'a blank column count means the font arithmetic, not an error',
      () async {
        final SettingsController controller = await loaded();
        controller.editColumnOverride('42');
        await controller.save();

        controller.editColumnOverride('');
        expect(controller.columnOverrideError, isNull);
        expect(await controller.save(), isTrue);

        expect(encoder.profile.usesFontColumns, isTrue);
        expect(encoder.profile.columns, encoder.baseProfile.columns);
      },
    );

    test('a feed of zero is refused', () async {
      final SettingsController controller = await loaded();
      controller.editFeedLinesBeforeCut('0');

      expect(controller.feedLinesError, isNotNull);
      expect(await controller.save(), isFalse);
    });

    test('an empty feed is refused rather than treated as zero', () async {
      final SettingsController controller = await loaded();
      controller.editFeedLinesBeforeCut('');

      expect(controller.feedLinesError, isNotNull);
      expect(await controller.save(), isFalse);
    });

    test('a QR module beyond the command range is refused', () async {
      final SettingsController controller = await loaded();
      controller.editQrModuleSize('${PrintSettings.maxQrModuleSize + 1}');

      expect(controller.qrModuleSizeError, isNotNull);
      expect(await controller.save(), isFalse);
    });

    test('the chosen hardware allows a cut and a QR', () async {
      final SettingsController controller = await loaded();

      // The printer this build targets has both, so neither is refused. What is asserted
      // is that the bound exists and is read from the capabilities.
      expect(controller.capabilities.hasAutoCutter, isTrue);
      expect(controller.capabilities.supportsQrCode, isTrue);
      expect(controller.cutError, isNull);
      expect(controller.qrEnabledError, isNull);
    });

    test(
      'a refusal names every problem, so the form is fixed in one pass',
      () async {
        final SettingsController controller = await loaded();
        controller.editGstin('nope');
        controller.editColumnOverride('96');
        controller.editQrModuleSize('99');

        expect(await controller.save(), isFalse);
        expect(controller.errorMessage, contains('GSTIN'));
        expect(controller.errorMessage, contains('Columns'));
        expect(controller.errorMessage, contains('QR module size'));
      },
    );
  });

  // --------------------------------------------------------------- failures ---

  group('a failed save', () {
    test(
      'leaves the previously stored settings exactly as they were',
      () async {
        final FailingSettingsRepository failing = FailingSettingsRepository(
          delegate: repository,
          failWrites: false,
        );
        final SettingsController controller = await loaded(source: failing);

        controller.editBusinessName('Brisko Pizza Kothrud');
        controller.editGstin('27AAPFU0939F1ZV');
        expect(await controller.save(), isTrue);

        failing.failWrites = true;
        controller.editBusinessName('Half-typed name');
        controller.editGstin('29AAGCB7383J1Z4');
        expect(await controller.save(), isFalse);

        // On disk: the first configuration, whole.
        final SettingsController reopened = await loaded();
        expect(reopened.businessName, 'Brisko Pizza Kothrud');
        expect(reopened.gstin, '27AAPFU0939F1ZV');
      },
    );

    test('keeps the edits so the operator can try again', () async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
        failWrites: true,
      );
      final SettingsController controller = await loaded(source: failing);

      controller.editBusinessName('Brisko Pizza Kothrud');
      controller.editReceiptFooter('Thank you');
      expect(await controller.save(), isFalse);

      expect(controller.status, SettingsStatus.error);
      expect(controller.errorMessage, FailingSettingsRepository.writeMessage);
      expect(controller.businessName, 'Brisko Pizza Kothrud');
      expect(controller.receiptFooter, 'Thank you');
      expect(controller.isDirty, isTrue);

      // Retrying after storage recovers stores exactly what is still in the form.
      failing.failWrites = false;
      await controller.retry();

      expect(controller.status, SettingsStatus.saved);
      final SettingsController reopened = await loaded();
      expect(reopened.businessName, 'Brisko Pizza Kothrud');
      expect(reopened.receiptFooter, 'Thank you');
    });

    test('a half-written form cannot reach the table', () async {
      // The write is one transaction, so there is no state in which the new address is
      // stored above the old GSTIN.
      final SettingsController controller = await loaded();
      controller.editBusinessAddress('12 Paud Road, Pune');
      controller.editGstin('27AAPFU0939F1ZV');
      await controller.save();

      final Map<String, String?> stored =
          (await repository.readAll()).valueOrNull!;
      expect(stored[SettingKeys.businessAddress], '12 Paud Road, Pune');
      expect(stored[SettingKeys.gstin], '27AAPFU0939F1ZV');
    });
  });

  group('duplicate submissions', () {
    test('two saves at once reach storage once and store one thing', () async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
      );
      final SettingsController controller = await loaded(source: failing);
      controller.editBusinessName('Brisko Pizza Kothrud');

      final List<bool> outcomes = await Future.wait(<Future<bool>>[
        controller.save(),
        controller.save(),
      ]);

      // The first owns the write; the second is refused rather than racing it.
      expect(outcomes, <bool>[true, false]);
      expect(failing.writeAllCount, 1);
      expect((await loaded()).businessName, 'Brisko Pizza Kothrud');
    });

    test('saving again after a save writes nothing new', () async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: repository,
      );
      final SettingsController controller = await loaded(source: failing);
      controller.editBusinessName('Brisko Pizza Kothrud');

      expect(await controller.save(), isTrue);
      // Reported as stored, because it is, but nothing goes to the table a second time.
      expect(await controller.save(), isTrue);

      expect(failing.writeAllCount, 1);
      expect((await loaded()).businessName, 'Brisko Pizza Kothrud');
    });

    test('two loads at once do not interleave', () async {
      final SettingsController controller = await loaded();
      controller.editBusinessName('Brisko Pizza Kothrud');
      await controller.save();

      await Future.wait(<Future<void>>[controller.load(), controller.load()]);

      expect(controller.status, SettingsStatus.loaded);
      expect(controller.businessName, 'Brisko Pizza Kothrud');
    });
  });

  // ------------------------------------------------------------- durability ---

  group('durability', () {
    test('settings survive the controller being recreated', () async {
      final SettingsController first = await loaded();
      first.editBusinessName('Brisko Pizza Kothrud');
      first.editBusinessAddress('12 Paud Road, Pune');
      first.editGstin('27AAPFU0939F1ZV');
      first.editReceiptFooter('Thank you');
      first.selectDefaultOrderType(OrderType.dineIn);
      first.selectFont(PrinterFont.fontB);
      first.editColumnOverride('60');
      await first.save();

      // A brand new controller, as navigating away from Settings and back builds one.
      final SettingsController second = await loaded();

      expect(second.businessName, 'Brisko Pizza Kothrud');
      expect(second.businessAddress, '12 Paud Road, Pune');
      expect(second.gstin, '27AAPFU0939F1ZV');
      expect(second.receiptFooter, 'Thank you');
      expect(second.defaultOrderType, OrderType.dineIn);
      expect(second.font, PrinterFont.fontB);
      expect(second.columnOverride, '60');
      expect(second.isDirty, isFalse);
    });
  });

  group('durability across a restart', () {
    late Directory directory;
    late String path;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('brisko_settings');
      path = p.join(directory.path, 'settings.db');
    });

    tearDown(() async {
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    });

    test('settings survive closing and reopening the database', () async {
      // The in-memory database used elsewhere cannot demonstrate this, so this one is on
      // disk: written, closed as the application would close it, and read back.
      final SqliteDatabase first = await TestDatabase.openOnDisk(path);
      final SettingsController writing = SettingsController(
        settings: SqliteSettingsRepository(database: first),
        printProfile: ConfigurableEscPosEncoder.forPrinter(
          UnconfiguredThermalPrinter(),
        ),
        activeSettings: ActivePosSettings(),
      );
      await writing.load();
      writing.editBusinessName('Brisko Pizza Kothrud');
      writing.editBusinessAddress('12 Paud Road, Kothrud, Pune 411038');
      writing.editBusinessPhone('020 2545 1234');
      writing.editGstin('27AAPFU0939F1ZV');
      writing.editReceiptHeader('Wood-fired since 2019');
      writing.editReceiptFooter('Thank you, come again');
      writing.editUpiVpa('brisko@upi');
      writing.selectDefaultOrderType(OrderType.delivery);
      writing.selectFont(PrinterFont.fontB);
      writing.editColumnOverride('60');
      writing.selectCut(PrintCut.partial);
      writing.editFeedLinesBeforeCut('7');
      writing.setQrEnabled(isEnabled: false);
      writing.editQrModuleSize('9');
      writing.selectQrErrorCorrection(QrErrorCorrection.quartile);
      expect(await writing.save(), isTrue);
      writing.dispose();
      await first.close();

      final SqliteDatabase second = await TestDatabase.openOnDisk(path);
      addTearDown(second.close);
      final ConfigurableEscPosEncoder reopenedEncoder =
          ConfigurableEscPosEncoder.forPrinter(UnconfiguredThermalPrinter());
      final SettingsController reading = SettingsController(
        settings: SqliteSettingsRepository(database: second),
        printProfile: reopenedEncoder,
        activeSettings: ActivePosSettings(),
      );
      addTearDown(reading.dispose);
      await reading.load();

      expect(reading.businessName, 'Brisko Pizza Kothrud');
      expect(reading.businessAddress, '12 Paud Road, Kothrud, Pune 411038');
      expect(reading.businessPhone, '020 2545 1234');
      expect(reading.gstin, '27AAPFU0939F1ZV');
      expect(reading.receiptHeader, 'Wood-fired since 2019');
      expect(reading.receiptFooter, 'Thank you, come again');
      expect(reading.upiVpa, 'brisko@upi');
      expect(reading.defaultOrderType, OrderType.delivery);
      expect(reading.font, PrinterFont.fontB);
      expect(reading.columnOverride, '60');
      expect(reading.cut, PrintCut.partial);
      expect(reading.feedLinesBeforeCut, '7');
      expect(reading.isQrEnabled, isFalse);
      expect(reading.qrModuleSize, '9');
      expect(reading.qrErrorCorrection, QrErrorCorrection.quartile);
      expect(reading.isDirty, isFalse);
    });

    test(
      'a reopened terminal lays documents out for the stored layout',
      () async {
        // What the bootstrap does at start-up, checked end to end: the stored settings are
        // read and handed to the encoder, so the first bill after a restart is laid out for
        // the configuration the owner saved.
        final SqliteDatabase first = await TestDatabase.openOnDisk(path);
        final SqliteSettingsRepository writing = SqliteSettingsRepository(
          database: first,
        );
        await writing.writeAll(
          PrintSettings.fromProfile(PrintProfile.escPos80mm)
              .copyWith(columnOverride: 42)
              .toStored(),
        );
        await first.close();

        final SqliteDatabase second = await TestDatabase.openOnDisk(path);
        addTearDown(second.close);
        final Map<String, String?> stored = (await SqliteSettingsRepository(
          database: second,
        ).readAll()).valueOrNull!;

        final ConfigurableEscPosEncoder encoder =
            ConfigurableEscPosEncoder.forPrinter(
              UnconfiguredThermalPrinter(),
              settings: PrintSettings.fromStored(
                stored,
                fallback: PrintProfile.escPos80mm,
              ),
            );

        expect(encoder.profile.columns, 42);
      },
    );
  });
}
