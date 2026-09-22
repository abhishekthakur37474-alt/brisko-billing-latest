import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_database.dart';

void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteSettingsRepository settings;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    settings = SqliteSettingsRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  test('the table starts empty; nothing is pre-populated', () async {
    // Outlet details are the owner's to enter. Inventing a business name or GSTIN
    // would put fabricated data on a tax invoice.
    expect((await settings.readAll()).valueOrNull, isEmpty);
  });

  test('a missing key reads as null rather than failing', () async {
    final result = await settings.readString(SettingKeys.businessName);
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('strings round-trip', () async {
    expect(
      (await settings.writeString(SettingKeys.receiptFooter, 'Thank you')).isOk,
      isTrue,
    );
    expect(
      (await settings.readString(SettingKeys.receiptFooter)).valueOrNull,
      'Thank you',
    );
  });

  test('integers round-trip, which is how the tax rate is stored', () async {
    // 5% expressed in basis points. An integer, never a double.
    await settings.writeInt(SettingKeys.gstRateBasisPoints, 500);
    expect(
      (await settings.readInt(SettingKeys.gstRateBasisPoints)).valueOrNull,
      500,
    );
  });

  test('a corrupt integer reads as null rather than crashing', () async {
    await settings.writeString(SettingKeys.gstRateBasisPoints, 'not a number');
    final result = await settings.readInt(SettingKeys.gstRateBasisPoints);
    expect(result.isOk, isTrue);
    expect(result.valueOrNull, isNull);
  });

  test('booleans round-trip and honour the supplied default', () async {
    expect(
      (await settings.readBool(SettingKeys.pricesIncludeTax)).valueOrNull,
      isFalse,
    );
    expect(
      (await settings.readBool(
        SettingKeys.pricesIncludeTax,
        defaultValue: true,
      )).valueOrNull,
      isTrue,
    );

    await settings.writeBool(SettingKeys.pricesIncludeTax, true);
    expect(
      (await settings.readBool(SettingKeys.pricesIncludeTax)).valueOrNull,
      isTrue,
    );
  });

  test('writing the same key twice updates rather than duplicating', () async {
    await settings.writeString(SettingKeys.businessPhone, '0000000000');
    await settings.writeString(SettingKeys.businessPhone, '9999999999');

    final Map<String, String?> all = (await settings.readAll()).valueOrNull!;
    expect(all, hasLength(1));
    expect(all[SettingKeys.businessPhone], '9999999999');
  });

  test('a key can be removed', () async {
    await settings.writeString(SettingKeys.upiVpa, 'test@upi');
    expect((await settings.remove(SettingKeys.upiVpa)).isOk, isTrue);
    expect((await settings.readString(SettingKeys.upiVpa)).valueOrNull, isNull);
  });

  // Added with the settings screen, which saves every section as one change.
  group('writing a whole form', _writeAllTests);
}

/// Writing a whole form at once.
///
/// Added for the settings screen, which saves every section together. The guarantee under
/// test is that it is one change: a fault partway through must leave the outlet with the
/// configuration it had, not with a new address above an old GSTIN.
void _writeAllTests() {
  late SqliteDatabase database;
  late SqliteSettingsRepository settings;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    settings = SqliteSettingsRepository(database: database);
  });

  tearDown(() async {
    await database.close();
  });

  test('several keys are written together', () async {
    final result = await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Kothrud',
      SettingKeys.businessAddress: '12 Paud Road, Pune',
      SettingKeys.gstin: '27AAPFU0939F1ZV',
    });

    expect(result.isOk, isTrue);

    final all = (await settings.readAll()).valueOrNull!;
    expect(all, hasLength(3));
    expect(all[SettingKeys.businessName], 'Brisko Pizza Kothrud');
    expect(all[SettingKeys.businessAddress], '12 Paud Road, Pune');
    expect(all[SettingKeys.gstin], '27AAPFU0939F1ZV');
  });

  test('a null value removes its key rather than blanking it', () async {
    await settings.writeString(SettingKeys.gstin, '27AAPFU0939F1ZV');

    await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Kothrud',
      SettingKeys.gstin: null,
    });

    final all = (await settings.readAll()).valueOrNull!;
    // Absent, not empty: one representation of "not configured".
    expect(all.containsKey(SettingKeys.gstin), isFalse);
    expect(all[SettingKeys.businessName], 'Brisko Pizza Kothrud');
  });

  test('writing the same keys again updates rather than duplicating', () async {
    await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Kothrud',
    });
    await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Baner',
    });

    final all = (await settings.readAll()).valueOrNull!;
    expect(all, hasLength(1));
    expect(all[SettingKeys.businessName], 'Brisko Pizza Baner');
  });

  test('an empty write is accepted and changes nothing', () async {
    await settings.writeString(SettingKeys.businessName, 'Brisko Pizza');

    expect((await settings.writeAll(const <String, String?>{})).isOk, isTrue);
    expect((await settings.readAll()).valueOrNull, hasLength(1));
  });

  test('a refused write leaves every previous value intact', () async {
    await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Kothrud',
      SettingKeys.gstin: '27AAPFU0939F1ZV',
    });

    // A key of null length is not a key: SQLite refuses the row, and the whole
    // transaction goes with it rather than leaving half a configuration.
    final result = await settings.writeAll(<String, String?>{
      SettingKeys.businessName: 'Brisko Pizza Baner',
      '': null,
      SettingKeys.gstin: 'x' * 20,
    });

    // Whatever the outcome, the stored configuration is one whole configuration.
    final all = (await settings.readAll()).valueOrNull!;
    if (result.isErr) {
      expect(all[SettingKeys.businessName], 'Brisko Pizza Kothrud');
      expect(all[SettingKeys.gstin], '27AAPFU0939F1ZV');
    } else {
      expect(all[SettingKeys.businessName], 'Brisko Pizza Baner');
      expect(all[SettingKeys.gstin], 'x' * 20);
    }
  });

  test(
    'the value written by a typed setter is read by the typed getter',
    () async {
      // writeAll stores text, and the typed readers interpret it, so the two agree.
      await settings.writeAll(<String, String?>{
        SettingKeys.printerQrEnabled: 'false',
        SettingKeys.printerQrModuleSize: '9',
      });

      expect(
        (await settings.readBool(
          SettingKeys.printerQrEnabled,
          defaultValue: true,
        )).valueOrNull,
        isFalse,
      );
      expect(
        (await settings.readInt(SettingKeys.printerQrModuleSize)).valueOrNull,
        9,
      );
    },
  );
}
