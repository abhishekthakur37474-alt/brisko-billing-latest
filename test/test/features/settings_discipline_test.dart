import 'package:brisko_billing/features/payments/domain/models/payment_method.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_source.dart';

/// Rules about the settings module, checked by reading its source.
///
/// ## Why as a rule rather than as a value
///
/// Three of the things the settings step must not do cannot be caught by a behavioural
/// test, because a passing test proves only that the path it happened to cover is clean:
///
/// * Settings must not touch money. It configures what the paper says around the figures;
///   every figure itself is carried from the committed order.
/// * Settings must not introduce a printer transport. No device, host, port, vendor id or
///   pairing, because this terminal has no printer attached and a stored address would
///   claim it has.
/// * Settings must not introduce a feature that was not asked for at this step — a
///   loyalty wallet above all, which would mean a stored balance nobody has funded.
///
/// Each is a statement about the code, so each is checked as one. The comments are
/// stripped first, because these files discuss what they exclude in order to explain why.
void main() {
  /// Every file the settings step added or changed.
  const List<String> settingsPath = <String>[
    'lib/features/settings/domain/models/pos_settings.dart',
    'lib/features/settings/domain/models/gstin.dart',
    'lib/features/settings/domain/models/setting_keys.dart',
    'lib/features/settings/domain/active_pos_settings.dart',
    'lib/features/settings/domain/repositories/settings_repository.dart',
    'lib/features/settings/data/repositories/sqlite_settings_repository.dart',
    'lib/features/settings/presentation/controllers/settings_controller.dart',
    'lib/features/settings/presentation/screens/settings_screen.dart',
    'lib/features/settings/presentation/widgets/settings_form.dart',
    'lib/features/settings/presentation/widgets/settings_notices.dart',
    'lib/features/settings/presentation/widgets/settings_text_field.dart',
    'lib/features/printing/domain/models/print_settings.dart',
    'lib/features/printing/domain/services/active_print_profile.dart',
    'lib/features/printing/data/escpos/configurable_escpos_encoder.dart',
  ];

  void expectAbsent(
    String path,
    Map<String, String> patterns, {
    required String because,
  }) {
    final String code = DartSource.codeOf(path);

    patterns.forEach((String label, String pattern) {
      expect(
        code,
        isNot(matches(RegExp(pattern))),
        reason: '$path contains $label. $because',
      );
    });
  }

  group('settings carries no money', () {
    /// Anything that would let a setting decide, hold or alter an amount.
    const Map<String, String> money = <String, String>{
      'Money': r'\bMoney\b',
      'a paise column or field': r'Paise',
      'a double': r'\bdouble\b',
      'a num': r'\bnum\b',
      'a conversion to double': r'toDouble\s*\(',
      'a double parse': r'double\.(try)?[pP]arse',
    };

    test('nothing in the settings module mentions an amount', () {
      for (final String path in settingsPath) {
        expectAbsent(
          path,
          money,
          because:
              'Settings configures what a bill says around its figures. Every '
              'figure is carried from the committed order through Money.',
        );
      }
    });

    test('the integers settings does parse are counts, not amounts', () {
      // A column count, a line count and a dot count. The only integer parsing in the
      // module, and it is nowhere near a price.
      final String printSettings = DartSource.codeOf(
        'lib/features/printing/domain/models/print_settings.dart',
      );
      final String controller = DartSource.codeOf(
        'lib/features/settings/presentation/controllers/settings_controller.dart',
      );

      expect(printSettings, contains('int.tryParse'));
      expect(controller, contains('int.tryParse'));
      // And no amount construction anywhere in either.
      expect(printSettings, isNot(matches(RegExp(r'Money\.'))));
      expect(controller, isNot(matches(RegExp(r'Money\.'))));
    });

    test('the GST rate is configured here, and it is not an amount', () {
      // This rule used to require the settings module to mention no tax rate at all. It was
      // protecting something real — nothing here may decide a charge — but it stated it as
      // "no rate", which was accurate only while no bill charged tax. Step 14 gives the
      // outlet a GST rate to configure, so that sentence would now be false.
      //
      // What the rule was protecting is kept, and is now stated as what it actually means: a
      // rate is an integer count of basis points, it is never an amount, and it reaches a
      // bill through `BillTotals` rather than from here.
      final String settings = DartSource.codeOf(
        'lib/features/settings/domain/models/pos_settings.dart',
      );

      // The rate is stored under the key that has been in the table's vocabulary since
      // step 1, rather than under a second one invented for it.
      expect(settings, contains('gstRateBasisPoints'));
      expect(settings, contains('GstRate'));

      // And it is still not money. No paise, no amount, no arithmetic.
      expect(settings, isNot(matches(RegExp(r'\bMoney\b'))));
      expect(settings, isNot(matches(RegExp(r'Paise\b'))));
      expect(settings, isNot(matches(RegExp(r'\bdouble\b'))));
    });

    test('no discount is configured by the settings screen', () {
      // A discount is a decision about one bill, taken at the counter on the bill it applies
      // to. A configured default discount would be a standing reduction nobody had agreed to
      // on any particular sale, so there is nothing here to set one.
      //
      // Matched on identifiers rather than on the bare word: the GST section's help text
      // explains that tax is charged on the subtotal after any discount, which is a true and
      // useful sentence to put in front of an owner. What must not exist is a discount key,
      // field, or domain type.
      for (final String path in settingsPath) {
        expectAbsent(
          path,
          const <String, String>{
            'a discount setting key': r'SettingKeys\.\w*[Dd]iscount',
            'a discount field or property': r'\b_?discount[A-Z_]\w*|\b[Dd]iscount(Rate|Value|Amount|Percent|Type)\b',
            'the discount domain type': r'BillDiscount',
            'a discount editor': r'(edit|select|set|apply)[Dd]iscount',
          },
          because:
              'A discount belongs to a bill, not to the terminal. It is '
              'entered on the checkout review step.',
        );
      }
    });

    test('tax-inclusive pricing has not been started', () {
      // The key exists in the table's vocabulary from step 1 and nothing reads it. Menu
      // prices are treated as pre-GST throughout, so a switch here would change no bill and
      // would only invite the belief that it did.
      final String form = DartSource.codeOf(
        'lib/features/settings/presentation/widgets/settings_form.dart',
      );
      final String settings = DartSource.codeOf(
        'lib/features/settings/domain/models/pos_settings.dart',
      );

      expect(form, isNot(contains('pricesIncludeTax')));
      expect(settings, isNot(contains('pricesIncludeTax')));
    });
  });

  group('settings introduces no printer transport', () {
    /// Every way a physical destination could have crept in.
    const Map<String, String> transport = <String, String>{
      'USB': r'\bUSB\b|\busb\b',
      'Bluetooth': r'[Bb]luetooth',
      'a LAN or network endpoint': r'PrinterEndpoint|\bLAN\b|\blan\b',
      'a socket': r'\bSocket\b|\bsocket\b',
      'an IP address or host': r'ipAddress|\bhost\b|\bHost\b',
      'a port': r'\bport\b|\bPort\b',
      'a vendor or product id': r'vendorId|productId',
      'a device name': r'deviceName',
      'a printer model': r'printerModel|modelName',
    };

    test('no file in the settings module names a transport', () {
      for (final String path in settingsPath) {
        expectAbsent(
          path,
          transport,
          because:
              'No printer is attached to this terminal. A stored address would '
              'claim one is, and opening a device belongs to the adapter that '
              'can actually do it.',
        );
      }
    });

    test('the printer settings are seven layout values and nothing else', () {
      final String code = DartSource.codeOf(
        'lib/features/printing/domain/models/print_settings.dart',
      );

      // Layout, all of it verifiable with no hardware in the room.
      for (final String field in <String>[
        'font',
        'columnOverride',
        'cut',
        'feedLinesBeforeCut',
        'isQrEnabled',
        'qrModuleSize',
        'qrErrorCorrection',
      ]) {
        expect(code, contains(field));
      }
    });

    test('the form delegates the printer rather than growing a transport', () {
      // This rule used to require the form to state that no printer was connected. Step 13
      // gave the outlet somewhere to configure one, so that sentence would now be false.
      // What the rule was protecting is still worth keeping and is now sharper: the
      // settings module does not acquire a transport, it composes the section from the
      // module that owns one.
      final String form = DartSource.codeOf(
        'lib/features/settings/presentation/widgets/settings_form.dart',
      );

      // The printer section arrives from the printing module, whole.
      expect(form, contains('PrinterSetupSection'));

      // And this file still opens nothing and prints nothing itself. Connecting a device
      // and sending a test page both belong behind the printer abstraction, which nothing
      // here can reach.
      expect(form, isNot(contains('connect(')));
      expect(form, isNot(contains('printTestPage')));
      expect(form, isNot(contains('ThermalPrinter')));
      expect(form, isNot(contains('PrintService')));

      // The layout section still says what it is not. Choosing 48 columns is not a claim
      // that a printer is on the other end of a cable.
      expect(form, contains('does not connect a printer'));
    });

    test('nothing imports a package beyond Flutter and the SQLite binding', () {
      // No printer package, and nothing that opens a device or a socket. sqflite is
      // allowed in exactly one place — the repository that talks to the table — and
      // nowhere else in the module.
      for (final String path in settingsPath) {
        final String code = DartSource.codeOf(path);
        final bool isStorage = path.contains('/data/repositories/');

        expect(
          code,
          isNot(
            matches(
              isStorage
                  ? RegExp(r"import 'package:(?!flutter/|provider/|sqflite/)")
                  : RegExp(r"import 'package:(?!flutter/|provider/)"),
            ),
          ),
          reason: '$path imports a package it has no business with',
        );
      }
    });
  });

  group('no future feature is started here', () {
    /// The steps that come after this one, and must not have been begun.
    const Map<String, String> notYet = <String, String>{
      'a loyalty wallet': r'[Ll]oyalty|[Ww]allet',
      'Firebase': r'[Ff]irebase|[Ff]irestore',
      'authentication': r'signIn|logIn|\bpassword\b|\bPassword\b',
      'multi-terminal sync': r'terminalId|deviceId|\boutbox\b|\bOutbox\b',
      'a refund': r'[Rr]efund',
      'backup or restore': r'[Bb]ackup|[Rr]estore\b',
      'a manual sync trigger': r'syncNow|drainOutbox',
    };

    test('nothing in the settings module reaches into a later step', () {
      for (final String path in settingsPath) {
        expectAbsent(
          path,
          notYet,
          because: 'This step is settings and POS configuration, and no more.',
        );
      }
    });

    test('the payment methods are unchanged', () {
      // Cash, UPI, card, other. Settings adds none and removes none, and above all does
      // not add a wallet, which would be a balance nobody has funded.
      expect(PaymentMethod.values, <PaymentMethod>[
        PaymentMethod.cash,
        PaymentMethod.upi,
        PaymentMethod.card,
        PaymentMethod.other,
      ]);

      final String code = DartSource.codeOf(
        'lib/features/payments/domain/models/payment_method.dart',
      );
      expect(code, isNot(matches(RegExp(r'[Ll]oyalty|[Ww]allet'))));
    });
  });

  group('the layers stay where they belong', () {
    test('no widget in the settings module touches SQL or a database', () {
      const List<String> widgets = <String>[
        'lib/features/settings/presentation/screens/settings_screen.dart',
        'lib/features/settings/presentation/widgets/settings_form.dart',
        'lib/features/settings/presentation/widgets/settings_notices.dart',
        'lib/features/settings/presentation/widgets/settings_text_field.dart',
        'lib/features/settings/presentation/widgets/data_reset_section.dart',
      ];

      const Map<String, String> storage = <String, String>{
        'SQL': r'SELECT|INSERT|UPDATE\s|DELETE\s',
        'a database handle': r'\bDatabase\b|sqflite|SqliteDatabase',
        'a table name': r'SqliteTables',
        'a concrete repository': r'Sqlite\w*Repository',
      };

      for (final String path in widgets) {
        expectAbsent(
          path,
          storage,
          because: 'A widget dispatches intents; the repository owns storage.',
        );
      }
    });

    test('the controller contains no SQL and no table name', () {
      const Map<String, String> storage = <String, String>{
        'SQL': r'SELECT|INSERT|UPDATE\s|DELETE\s',
        'a database handle': r'\bDatabase\b|sqflite|SqliteDatabase',
        'a table name': r'SqliteTables',
        'a concrete repository': r'Sqlite\w*Repository',
      };

      expectAbsent(
        'lib/features/settings/presentation/controllers/settings_controller.dart',
        storage,
        because:
            'The controller validates and holds state. Storage is reached '
            'through the SettingsRepository contract.',
      );
      expectAbsent(
        'lib/features/settings/presentation/controllers/data_reset_controller.dart',
        storage,
        because:
            'The wipe controller dispatches; the OperationalDataWiper owns storage.',
      );
    });

    test('the controller returns failures as values, never as throws', () {
      final String code = DartSource.codeOf(
        'lib/features/settings/presentation/controllers/settings_controller.dart',
      );

      expect(code, contains('AppFailure'));
      expect(code, contains('Result<'));
      // Nothing is thrown at a widget, and nothing is swallowed in a catch.
      expect(code, isNot(matches(RegExp(r'\bthrow\b'))));
      expect(code, isNot(matches(RegExp(r'\bcatch\b'))));
    });

    test('billing reads the configured default through the loaded settings', () {
      // Not by querying the settings table while a screen builds, which is what
      // "billing does not reach into settings storage" means in practice.
      final String checkout = DartSource.codeOf(
        'lib/features/billing/presentation/screens/checkout_screen.dart',
      );

      expect(checkout, contains('ActivePosSettings'));
      expect(checkout, isNot(contains('SettingsRepository')));
      expect(checkout, isNot(contains('SettingKeys')));
    });

    test('the print path still reads business details through its own source', () {
      // Unchanged from step 6A: the receipt gets the outlet's details from the settings
      // table by way of one class, and no widget is involved.
      final String source = DartSource.codeOf(
        'lib/features/printing/data/repository_sale_print_document_source.dart',
      );

      expect(source, contains('SettingsBusinessIdentitySource'));
      expect(source, isNot(contains('SettingKeys')));
      expect(source, isNot(matches(RegExp(r'\bBuildContext\b'))));
    });

    test('no business detail is hard-coded into the printing path', () {
      const List<String> printPath = <String>[
        'lib/features/printing/data/escpos/escpos_document_formatter.dart',
        'lib/features/printing/data/repository_sale_print_document_source.dart',
        'lib/features/printing/data/settings_business_identity_source.dart',
        'lib/features/printing/data/escpos/configurable_escpos_encoder.dart',
      ];

      for (final String path in printPath) {
        final String code = DartSource.codeOf(path);
        // No address, telephone number or GSTIN literal anywhere.
        expect(
          code,
          isNot(matches(RegExp(r'\d{2}[A-Z]{5}\d{4}[A-Z]'))),
          reason: '$path contains something shaped like a GSTIN',
        );
        expect(
          code,
          isNot(matches(RegExp(r'@upi|@ok\w+|@paytm'))),
          reason: '$path contains something shaped like a UPI address',
        );
      }
    });
  });
}
