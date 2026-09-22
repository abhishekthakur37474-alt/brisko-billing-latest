import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/printing/data/escpos/configurable_escpos_encoder.dart';
import 'package:brisko_billing/features/printing/data/printers/configurable_thermal_printer.dart';
import 'package:brisko_billing/features/printing/data/printers/no_transport_printer_factory.dart';
import 'package:brisko_billing/features/printing/domain/models/paper_width.dart';
import 'package:brisko_billing/features/printing/domain/models/print_job.dart';
import 'package:brisko_billing/features/printing/domain/models/print_profile.dart';
import 'package:brisko_billing/features/printing/domain/models/print_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_capabilities.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_setting_keys.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_status.dart';
import 'package:brisko_billing/features/printing/presentation/controllers/printer_controller.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/repositories/settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/escpos_transcript.dart';
import '../helpers/failing_settings_repository.dart';
import '../helpers/fake_escpos_printer.dart';
import '../helpers/fixed_printer_factory.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';
import '../helpers/test_printing.dart';

/// Configuring the printer, and proving it with a test page.
///
/// ## What is being checked
///
/// Two things the outlet needs before the hardware arrives: that a printer binding can be
/// saved, read back and applied without a restart, and that Test Print reports what
/// actually happened rather than what would be reassuring. The second matters most. A
/// terminal that showed a tick beside a printer it cannot reach would be discovered at the
/// counter, in front of a customer.
///
/// ## No hardware
///
/// Every test here runs with either the honest `UnconfiguredThermalPrinter` this build
/// ships or a `FakeEscPosPrinter` standing in for a transport adapter. Where a test page
/// is reported as printed, the bytes genuinely went through a transport that accepted
/// them.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteSettingsRepository settings;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    settings = SqliteSettingsRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// A controller over [printer], with the encoder the application would share with it.
  PrinterController controllerOver(
    ConfigurableThermalPrinter printer, {
    SettingsRepository? store,
  }) {
    final ConfigurableEscPosEncoder encoder =
        ConfigurableEscPosEncoder.forPrinter(printer);
    final PrinterController controller = PrinterController(
      settings: store ?? settings,
      printer: printer,
      printService: TestPrinting.serviceOver(
        database,
        printer: printer,
        encoder: encoder,
      ),
      printProfile: encoder,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  // ============================================================== controller ===

  group('saving a printer binding', () {
    test('a network printer is stored, read back and applied', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      expect(controller.isEnabled, isFalse);
      expect(controller.isDirty, isFalse);
      expect(controller.canSave, isFalse);

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.lan);
      controller.editAddress('192.168.1.50');
      controller.editPort('9100');
      controller.editLabel('Counter printer');

      expect(controller.isDirty, isTrue);
      expect(controller.isValid, isTrue);
      expect(controller.canSave, isTrue);

      expect(await controller.save(), isTrue);

      // On disk.
      final Map<String, String?> stored =
          (await settings.readAll()).valueOrNull!;
      expect(stored[PrinterSettingKeys.enabled], 'true');
      expect(stored[PrinterSettingKeys.transport], 'lan');
      expect(stored[PrinterSettingKeys.address], '192.168.1.50');
      expect(stored[PrinterSettingKeys.port], '9100');
      expect(stored[PrinterSettingKeys.label], 'Counter printer');

      // And in force, without a restart.
      expect(printer.connectionSettings.isConfigured, isTrue);
      expect(printer.endpoint?.description, '192.168.1.50:9100');
      expect(controller.isDirty, isFalse);
      expect(controller.status.isConfigured, isTrue);
    });

    test('a USB printer needs no address', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.usb);

      expect(controller.isUsb, isTrue);
      expect(controller.isNetworked, isFalse);
      expect(controller.isValid, isTrue);
      expect(await controller.save(), isTrue);

      expect(printer.endpoint?.transport, PrinterTransport.usb);
      expect(
        (await settings.readAll()).valueOrNull![PrinterSettingKeys.transport],
        'usb',
      );
    });

    test('an incomplete binding is refused, and nothing is written', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.lan);
      // No address.

      expect(controller.isValid, isFalse);
      expect(controller.addressError, contains('IP address'));
      expect(controller.canSave, isFalse);
      expect(await controller.save(), isFalse);

      expect(controller.hasError, isTrue);
      expect(controller.errorMessage, contains('not saved'));
      // Nothing on disk, and the terminal is still on the printer it was on.
      expect((await settings.readAll()).valueOrNull, isEmpty);
      expect(printer.connectionSettings.isConfigured, isFalse);
    });

    test('a port that is not a number is refused beside the field', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.lan);
      controller.editAddress('10.0.0.7');
      controller.editPort('nine thousand');

      expect(controller.portError, contains('whole number'));
      expect(controller.isValid, isFalse);
      expect(await controller.save(), isFalse);
    });

    test('a storage failure keeps the edits and applies nothing', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(
        printer,
        store: FailingSettingsRepository(delegate: settings, failWrites: true),
      );

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.usb);

      expect(await controller.save(), isFalse);
      expect(controller.hasError, isTrue);
      // The typing survives, so Save can be pressed again.
      expect(controller.isEnabled, isTrue);
      expect(controller.transport, PrinterTransport.usb);
      expect(controller.isDirty, isTrue);
      // And the terminal is still on the printer it was on, because nothing committed.
      expect(printer.connectionSettings.isConfigured, isFalse);
    });

    test('discarding returns the form to what is stored', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      controller.setEnabled(isEnabled: true);
      controller.editAddress('10.0.0.7');
      controller.discardChanges();

      expect(controller.isEnabled, isFalse);
      expect(controller.address, isEmpty);
      expect(controller.isDirty, isFalse);
    });

    test('saving an unchanged form is reported as success', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      // Pressing Save twice must not tell the operator the second press failed.
      expect(await controller.save(), isTrue);
      expect(controller.hasError, isFalse);
    });

    test('a chosen roll re-lays the documents that follow', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final ConfigurableEscPosEncoder encoder =
          ConfigurableEscPosEncoder.forPrinter(printer);
      final PrinterController controller = PrinterController(
        settings: settings,
        printer: printer,
        printService: TestPrinting.serviceOver(
          database,
          printer: printer,
          encoder: encoder,
        ),
        printProfile: encoder,
      );
      addTearDown(controller.dispose);

      expect(encoder.profile.columns, PaperWidth.mm80.characterColumns);

      controller.setEnabled(isEnabled: true);
      controller.selectTransport(PrinterTransport.usb);
      controller.selectPaperWidth(PaperWidth.mm58);
      expect(await controller.save(), isTrue);

      // The layout follows the paper, so the next document is encoded for the roll the
      // printer actually takes rather than for the one it used to.
      expect(encoder.profile.paper, PaperWidth.mm58);
      expect(encoder.profile.columns, PaperWidth.mm58.characterColumns);
      expect(encoder.capabilities.paperWidth, PaperWidth.mm58);
      expect(
        (await settings.readAll()).valueOrNull![PrinterSettingKeys.paperWidth],
        'mm58',
      );
    });

    test('a column count too wide for a new roll is dropped, not truncated', () {
      final ConfigurableEscPosEncoder encoder = ConfigurableEscPosEncoder(
        base: PrintProfile.escPos80mm,
        capabilities: PrinterCapabilitiesFixture.mm80,
        settings: PrintSettings.fromProfile(PrintProfile.escPos80mm)
            .copyWith(columnOverride: 48),
      );
      expect(encoder.profile.columns, 48);

      encoder.retargetTo(PrinterCapabilitiesFixture.mm58);

      // 48 columns on a 32-column roll does not wrap, it truncates, and what it
      // truncates is the amount at the right-hand edge.
      expect(encoder.profile.columns, PaperWidth.mm58.characterColumns);
      expect(encoder.profile.columnOverride, isNull);
    });
  });

  // ============================================================== test print ===

  group('the test print action', () {
    test('it reports failure honestly when nothing is configured', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      // Always offered: pressing it is the fastest way to be told why nothing prints.
      expect(controller.status.canTestPrint, isTrue);

      expect(await controller.testPrint(), isFalse);

      expect(controller.didTestSucceed, isFalse);
      expect(
        controller.testMessage,
        startsWith('The test page could not be printed.'),
      );
      expect(controller.testMessage, contains('No thermal printer'));
      expect(controller.isTesting, isFalse);
    });

    test('a configured printer with no transport is told apart', () async {
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: const NoTransportPrinterFactory(),
        settings: const PrinterConnectionSettings(
          isEnabled: true,
          transport: PrinterTransport.usb,
          address: null,
          port: null,
          deviceName: null,
          label: 'Counter printer',
          paperWidth: PaperWidth.mm80,
        ),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      expect(await controller.testPrint(), isFalse);

      // Not "nothing is set up": the operator has filled the form in correctly, and
      // sending them back to it would waste their time.
      expect(controller.testMessage, isNot(contains('No thermal printer')));
      expect(controller.testMessage, contains('Counter printer'));
      expect(controller.testMessage, contains('no USB transport'));
      expect(controller.status.support, PrinterTransportSupport.notInstalled);
    });

    test('it prints through the printer a receipt would use', () async {
      final FakeEscPosPrinter transport = FakeEscPosPrinter();
      addTearDown(transport.dispose);
      final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
        factory: FixedPrinterFactory(transport),
        settings: const PrinterConnectionSettings(
          isEnabled: true,
          transport: PrinterTransport.usb,
          address: null,
          port: null,
          deviceName: null,
          label: 'Counter printer',
          paperWidth: PaperWidth.mm80,
        ),
      );
      addTearDown(printer.dispose);
      final PrinterController controller = controllerOver(printer);

      expect(await controller.testPrint(), isTrue);

      expect(controller.didTestSucceed, isTrue);
      expect(controller.testMessage, contains('Counter printer'));
      expect(controller.testMessage, contains('ruler'));

      // One document, through the real transport, encoded for the real profile.
      expect(transport.jobsOf(PrintJobKind.testPage), hasLength(1));
      final EscPosTranscript page = EscPosTranscript.of(transport.lastDocument);
      expect(
        page.widestLine,
        lessThanOrEqualTo(PaperWidth.mm80.characterColumns),
      );

      controller.dismissTestResult();
      expect(controller.testMessage, isNull);
      expect(controller.didTestSucceed, isFalse);
    });

    test(
      'saving a different printer clears the previous test result',
      () async {
        final FakeEscPosPrinter transport = FakeEscPosPrinter();
        addTearDown(transport.dispose);
        final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
          factory: FixedPrinterFactory(transport),
          settings: const PrinterConnectionSettings(
            isEnabled: true,
            transport: PrinterTransport.usb,
            address: null,
            port: null,
            deviceName: null,
            label: null,
            paperWidth: PaperWidth.mm80,
          ),
        );
        addTearDown(printer.dispose);
        final PrinterController controller = controllerOver(printer);

        expect(await controller.testPrint(), isTrue);
        expect(controller.didTestSucceed, isTrue);

        controller.editLabel('Counter printer');
        expect(await controller.save(), isTrue);

        // A tick from the previous printer would be read as belonging to this one.
        expect(controller.testMessage, isNull);
        expect(controller.didTestSucceed, isFalse);
      },
    );
  });

  // ================================================================== status ===

  group('the printer status', () {
    test('it distinguishes off, unconfigured and unreachable', () {
      expect(PrinterStatus.unconfigured.headline, 'Printing is turned off');

      const PrinterStatus enabledButBlank = PrinterStatus(
        settings: PrinterConnectionSettings(
          isEnabled: true,
          transport: null,
          address: null,
          port: null,
          deviceName: null,
          label: null,
          paperWidth: PaperWidth.mm80,
        ),
        connectionState: PrinterConnectionState.unavailable,
        support: PrinterTransportSupport.notConfigured,
        endpoint: null,
      );
      expect(enabledButBlank.headline, 'No printer configured');
      expect(enabledButBlank.detail, contains('Choose how the printer'));

      const PrinterStatus ready = PrinterStatus(
        settings: PrinterConnectionSettings(
          isEnabled: true,
          transport: PrinterTransport.usb,
          address: null,
          port: null,
          deviceName: null,
          label: 'Counter printer',
          paperWidth: PaperWidth.mm80,
        ),
        connectionState: PrinterConnectionState.connected,
        support: PrinterTransportSupport.available,
        endpoint: PrinterEndpoint.usb(),
      );
      expect(ready.headline, 'Ready');
      expect(ready.canPrint, isTrue);
      expect(ready.detail, contains('Counter printer is ready'));
      expect(ready.detail, contains('80mm'));
    });

    test('it never claims a printer can print when it cannot', () {
      for (final PrinterTransportSupport support
          in PrinterTransportSupport.values) {
        final PrinterStatus status = PrinterStatus(
          settings: PrinterConnectionSettings.unconfigured,
          connectionState: PrinterConnectionState.unavailable,
          support: support,
          endpoint: null,
        );
        expect(status.canPrint, isFalse);
      }
    });
  });

  // ================================================================== screen ===

  group('the Settings screen', () {
    /// Lets in-flight database work finish, then renders the result.
    Future<void> settleUi(WidgetTester tester) async {
      for (int round = 0; round < 6; round++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> tap(WidgetTester tester, Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await settleUi(tester);
    }

    Future<AppDependencies> openSettings(
      WidgetTester tester, {
      AppDependencies? dependencies,
    }) async {
      tester.view.physicalSize = const Size(1600, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final AppDependencies deps =
          dependencies ?? TestDependencies.over(database);
      await tester.pumpWidget(BriskoApp(dependencies: deps));
      await settleUi(tester);
      await tap(tester, find.text(PosSection.settings.label).last);
      return deps;
    }

    testWidgets('it shows a printer section and its state', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      expect(find.text('Printer'), findsWidgets);
      expect(find.text('Printing is turned off'), findsOneWidget);
      expect(find.text('Print bills and kitchen slips'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Test print'), findsOneWidget);
    });

    testWidgets('the transport fields appear only once printing is on', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      expect(find.text('Connection'), findsNothing);

      await tap(
        tester,
        find.widgetWithText(SwitchListTile, 'Print bills and kitchen slips'),
      );

      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('USB'), findsOneWidget);
      expect(find.text('Network'), findsOneWidget);
      // And still nothing claiming a connection exists.
      expect(find.text('Ready'), findsNothing);
    });

    testWidgets('a test print on an unconfigured terminal says why', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await tap(tester, find.widgetWithText(OutlinedButton, 'Test print'));

      expect(
        find.textContaining('The test page could not be printed.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('No thermal printer is set up'),
        findsOneWidget,
      );
    });

    testWidgets('a printer saved on screen reaches the settings table', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await tap(
        tester,
        find.widgetWithText(SwitchListTile, 'Print bills and kitchen slips'),
      );
      await tap(tester, find.widgetWithText(ChoiceChip, 'Network'));
      await tester.enterText(
        find.ancestor(
          of: find.text('IP address or host name'),
          matching: find.byType(TextField),
        ),
        '192.168.1.50',
      );
      await tester.pump();
      await tap(tester, find.widgetWithText(FilledButton, 'Save printer'));

      final Map<String, String?>? stored = await tester
          .runAsync<Map<String, String?>>(
            () async => (await SqliteSettingsRepository(
              database: database,
            ).readAll()).valueOrNull!,
          );

      expect(stored![PrinterSettingKeys.enabled], 'true');
      expect(stored[PrinterSettingKeys.transport], 'lan');
      expect(stored[PrinterSettingKeys.address], '192.168.1.50');
    });

    testWidgets('a saved printer is still there after leaving and returning', (
      WidgetTester tester,
    ) async {
      const PrinterConnectionSettings saved = PrinterConnectionSettings(
        isEnabled: true,
        transport: PrinterTransport.lan,
        address: '10.0.0.7',
        port: 9100,
        deviceName: null,
        label: 'Counter printer',
        paperWidth: PaperWidth.mm80,
      );
      // Inside runAsync: a widget test body runs in fake time, where a real sqflite
      // future never completes, so awaiting one directly would hang rather than fail.
      await tester.runAsync(() => settings.writeAll(saved.toStored()));

      await openSettings(
        tester,
        dependencies: TestDependencies.over(database, printerSettings: saved),
      );

      // Read from the printer the bootstrap already built, so the form cannot show a
      // binding that differs from the one in force.
      expect(find.text('10.0.0.7'), findsOneWidget);
      expect(find.text('Counter printer'), findsWidgets);
      expect(find.textContaining('this build cannot reach it'), findsOneWidget);
    });
  });
}

/// Capability fixtures for the retarget test, named for the roll they describe.
class PrinterCapabilitiesFixture {
  const PrinterCapabilitiesFixture._();

  static const PrinterCapabilities mm80 = PrinterCapabilities.escPos80mm;

  static const PrinterCapabilities mm58 = PrinterCapabilities.escPos58mm;
}
