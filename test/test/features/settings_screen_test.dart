import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/brisko_app.dart';
import 'package:brisko_billing/app/shell/pos_section.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_tables.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/orders/domain/models/order.dart';
import 'package:brisko_billing/features/orders/domain/models/order_item.dart';
import 'package:brisko_billing/features/orders/domain/models/order_type.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/setting_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/failing_settings_repository.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

/// The Settings screen, driven through the real application.
///
/// ## Why the whole app rather than the screen alone
///
/// The screen is reached by navigating the shell and is rebuilt from scratch every time
/// the operator leaves it and comes back — which is exactly the behaviour a settings form
/// has to survive. So these tests build `BriskoApp` over a real in-memory database, tap
/// the navigation rail, type into the form, and read back what the table holds.
///
/// Nothing here needs a printer.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;

  setUp(() async {
    database = await TestDatabase.openInMemory();
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  /// Lets in-flight database work finish, then renders the result.
  ///
  /// A widget test body runs inside a fake-async zone where real I/O never completes, and
  /// sqflite answers from outside it. Bounded pumps interleaved with
  /// [WidgetTester.runAsync] rather than `pumpAndSettle`.
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

  /// Builds the application wide enough for the navigation rail, and opens Settings.
  Future<AppDependencies> openSettings(
    WidgetTester tester, {
    AppDependencies? dependencies,
  }) async {
    tester.view.physicalSize = const Size(1600, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppDependencies deps =
        dependencies ?? TestDependencies.over(database);
    await tester.pumpWidget(BriskoApp(dependencies: deps));
    await settleUi(tester);
    await tap(tester, find.text(PosSection.settings.label).last);
    return deps;
  }

  /// Types [value] into the field labelled [label].
  Future<void> enter(WidgetTester tester, String label, String value) async {
    await tester.enterText(
      find.ancestor(of: find.text(label), matching: find.byType(TextField)),
      value,
    );
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) =>
      tap(tester, find.widgetWithText(FilledButton, 'Save settings'));

  /// What is in the settings table right now.
  ///
  /// Read inside [WidgetTester.runAsync]. A widget test body runs in fake time, where a
  /// real sqflite future never completes, so awaiting one directly would hang rather
  /// than fail.
  Future<Map<String, String?>> stored(WidgetTester tester) async {
    final Map<String, String?>? values = await tester
        .runAsync<Map<String, String?>>(
          () async =>
              (await SqliteSettingsRepository(
                database: database,
              ).readAll()).valueOrNull ??
              const <String, String?>{},
        );
    return values!;
  }

  group('opening the screen', () {
    testWidgets('it is reachable from the POS navigation', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      expect(find.text('Business information'), findsOneWidget);
      expect(find.text('POS behaviour'), findsOneWidget);
      expect(find.text('Receipt'), findsOneWidget);
      expect(find.text('Printing'), findsOneWidget);
      expect(find.text('Data'), findsOneWidget);
      expect(find.text('Clear till data'), findsOneWidget);
    });

    testWidgets('an unconfigured terminal shows an empty form', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      // No invented outlet name, address or GSTIN anywhere on screen.
      expect(find.text('Brisko Pizza Kothrud'), findsNothing);
      expect(find.textContaining('27AAPFU'), findsNothing);
      // Save is offered but does nothing until something changes.
      final FilledButton saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save settings'),
      );
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('it offers no printer address, host or device', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      // Printing is off on an unconfigured terminal, and the transport fields appear only
      // once it is turned on. Nothing invites an address to be typed into a terminal that
      // has not said it wants to print.
      expect(find.textContaining('IP address'), findsNothing);
      expect(find.textContaining('Bluetooth'), findsNothing);
      expect(find.textContaining('USB'), findsNothing);
      expect(find.textContaining('Port'), findsNothing);
    });

    testWidgets('it offers no loyalty wallet and no default discount', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      expect(find.textContaining('Loyalty'), findsNothing);
      expect(find.textContaining('Wallet'), findsNothing);
      // A discount is a decision about one bill, taken at the counter on the review step.
      // There is no configured default, because a standing reduction is not something
      // anybody agreed to on any particular sale.
      expect(find.textContaining('Discount rate'), findsNothing);
      expect(find.textContaining('Default discount'), findsNothing);
    });

    testWidgets('it offers a GST rate, and nothing is chosen for the outlet', (
      WidgetTester tester,
    ) async {
      // This used to assert that no tax rate was offered at all, which was correct while no
      // bill could carry tax. Step 14 gives the outlet a rate to configure, so the rule is
      // now about what that control may and may not do: it offers the standard combined
      // slabs, it starts at none, and it picks no slab on the outlet's behalf.
      await openSettings(tester);

      expect(find.text('GST rate'), findsOneWidget);
      for (final String slab in <String>['0%', '5%', '12%', '18%']) {
        expect(
          find.widgetWithText(ChoiceChip, slab),
          findsOneWidget,
          reason: 'the $slab slab should be offered',
        );
      }

      final ChoiceChip none = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '0%'),
      );
      expect(none.selected, isTrue);
      expect(
        find.textContaining('No GST is charged'),
        findsOneWidget,
        reason: 'the screen should say what a zero rate means for a bill',
      );
      // And it says the change cannot reach a bill already given out, which is the fact an
      // owner needs before touching a slab.
      expect(find.textContaining('already issued'), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('the business details are written to the table', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await enter(tester, 'Business name', 'Brisko Pizza Kothrud');
      await enter(tester, 'Address', '12 Paud Road, Kothrud, Pune 411038');
      await enter(tester, 'Phone', '020 2545 1234');
      await enter(tester, 'GSTIN', '27AAPFU0939F1ZV');
      await save(tester);

      final Map<String, String?> values = await stored(tester);
      expect(values[SettingKeys.businessName], 'Brisko Pizza Kothrud');
      expect(
        values[SettingKeys.businessAddress],
        '12 Paud Road, Kothrud, Pune 411038',
      );
      expect(values[SettingKeys.businessPhone], '020 2545 1234');
      expect(values[SettingKeys.gstin], '27AAPFU0939F1ZV');
    });

    testWidgets('the feedback / review URL is written to the table', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await enter(
        tester,
        'Feedback / Review URL',
        'https://g.page/r/brisko/review',
      );
      await save(tester);

      final Map<String, String?> values = await stored(tester);
      expect(values[SettingKeys.feedbackUrl], 'https://g.page/r/brisko/review');
    });

    testWidgets('a confirmation is shown, and only after the write', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);
      await enter(tester, 'Receipt footer', 'Thank you, come again');

      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.textContaining('Saved.'), findsNothing);

      await save(tester);

      expect(find.textContaining('Saved.'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsNothing);
    });

    testWidgets('what was saved is still there after leaving and returning', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);
      await enter(tester, 'Business name', 'Brisko Pizza Kothrud');
      await enter(tester, 'Receipt header', 'Wood-fired since 2019');
      await save(tester);

      // Away to another section, which throws the whole screen and its controller away.
      await tap(tester, find.text(PosSection.reports.label).last);
      expect(find.text('Business information'), findsNothing);

      await tap(tester, find.text(PosSection.settings.label).last);

      // The saved values are restored into the form fields. The business name is scoped
      // to its TextField because it now also appears in the shell's app bar, which reads
      // the same saved outlet name — the branding is intentional, so the assertion targets
      // the field rather than counting every occurrence.
      expect(
        find.widgetWithText(TextField, 'Brisko Pizza Kothrud'),
        findsOneWidget,
      );
      expect(find.text('Wood-fired since 2019'), findsOneWidget);
      expect(find.text('Unsaved changes'), findsNothing);
    });

    testWidgets('a chosen default order type is written and shown again', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await tap(
        tester,
        find.widgetWithText(ChoiceChip, OrderType.delivery.label),
      );
      await save(tester);

      expect(
        (await stored(tester))[SettingKeys.defaultOrderType],
        OrderType.delivery.name,
      );

      await tap(tester, find.text(PosSection.reports.label).last);
      await tap(tester, find.text(PosSection.settings.label).last);

      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, OrderType.delivery.label),
      );
      expect(chip.selected, isTrue);
    });

    testWidgets('a chosen GST rate is written and shown again', (
      WidgetTester tester,
    ) async {
      final AppDependencies deps = await openSettings(tester);

      await tap(tester, find.widgetWithText(ChoiceChip, '18%'));
      await save(tester);

      // Stored as basis points, because that is what the arithmetic multiplies by. 18% is
      // 1800, not 18 and not 0.18.
      expect((await stored(tester))[SettingKeys.gstRateBasisPoints], '1800');

      // And the copy the next bill reads is updated, but only now the write has committed.
      expect(deps.activeSettings.settings.gstRate.basisPoints, 1800);
      expect(deps.activeSettings.settings.chargesGst, isTrue);

      await tap(tester, find.text(PosSection.reports.label).last);
      await tap(tester, find.text(PosSection.settings.label).last);

      final ChoiceChip chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '18%'),
      );
      expect(chip.selected, isTrue);
      // The help text now describes a taxed bill rather than an untaxed one.
      expect(find.textContaining('CGST and SGST'), findsOneWidget);
    });

    testWidgets('a rate can be taken back off', (WidgetTester tester) async {
      // An outlet that stops charging GST has to be able to say so, and a bill taken
      // afterwards must carry no tax line.
      final AppDependencies deps = await openSettings(tester);

      await tap(tester, find.widgetWithText(ChoiceChip, '12%'));
      await save(tester);
      expect(deps.activeSettings.settings.gstRate.basisPoints, 1200);

      await tap(tester, find.widgetWithText(ChoiceChip, '0%'));
      await save(tester);

      expect((await stored(tester))[SettingKeys.gstRateBasisPoints], '0');
      expect(deps.activeSettings.settings.gstRate.isZero, isTrue);
      expect(deps.activeSettings.settings.chargesGst, isFalse);
    });

    testWidgets('discarding restores what is stored', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);
      await enter(tester, 'Business name', 'Brisko Pizza Kothrud');
      await save(tester);

      await enter(tester, 'Business name', 'Typed by mistake');
      await tap(tester, find.widgetWithText(TextButton, 'Discard changes'));

      expect(find.text('Brisko Pizza Kothrud'), findsOneWidget);
      expect(find.text('Typed by mistake'), findsNothing);
    });
  });

  group('validation on screen', () {
    testWidgets('an invalid GSTIN is refused with a message beside the field', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await enter(tester, 'Business name', 'Brisko Pizza Kothrud');
      await enter(tester, 'GSTIN', '27AAPFU0939F1Z');
      await settleUi(tester);

      // Named, and Save withheld rather than silently storing a broken tax number.
      expect(find.textContaining('15 characters'), findsWidgets);
      final FilledButton saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save settings'),
      );
      expect(saveButton.onPressed, isNull);
      expect(await stored(tester), isEmpty);
    });

    testWidgets('a column count wider than the paper is refused', (
      WidgetTester tester,
    ) async {
      await openSettings(tester);

      await enter(tester, 'Columns', '96');
      await settleUi(tester);

      expect(find.textContaining('Columns must be between'), findsWidgets);
      final FilledButton saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save settings'),
      );
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('a valid printer layout saves', (WidgetTester tester) async {
      await openSettings(tester);

      await enter(tester, 'Columns', '42');
      await enter(tester, 'Feed before cut', '6');
      await save(tester);

      final Map<String, String?> values = await stored(tester);
      expect(values[SettingKeys.printerColumnOverride], '42');
      expect(values[SettingKeys.printerFeedLinesBeforeCut], '6');
    });
  });

  group('a storage failure', () {
    testWidgets('a failed read renders an error with a retry, not an exception', (
      WidgetTester tester,
    ) async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: SqliteSettingsRepository(database: database),
        failReads: true,
      );

      await openSettings(
        tester,
        dependencies: TestDependencies.over(
          database,
          settingsRepository: failing,
        ),
      );

      // Rendered, not thrown. The whole point of a Result-returning repository.
      expect(tester.takeException(), isNull);
      expect(find.text('These settings could not be read'), findsOneWidget);
      expect(find.text(FailingSettingsRepository.readMessage), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      // And no form, so nothing can be saved over configuration that is merely
      // unreadable at this moment.
      expect(find.text('Business information'), findsNothing);

      failing.failReads = false;
      await tap(tester, find.widgetWithText(FilledButton, 'Try again'));

      expect(tester.takeException(), isNull);
      expect(find.text('Business information'), findsOneWidget);
    });

    testWidgets('a failed save keeps the typing and offers a retry', (
      WidgetTester tester,
    ) async {
      final FailingSettingsRepository failing = FailingSettingsRepository(
        delegate: SqliteSettingsRepository(database: database),
      );

      await openSettings(
        tester,
        dependencies: TestDependencies.over(
          database,
          settingsRepository: failing,
        ),
      );

      failing.failWrites = true;
      await enter(tester, 'Business name', 'Brisko Pizza Kothrud');
      await save(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Not saved'), findsOneWidget);
      expect(find.text(FailingSettingsRepository.writeMessage), findsOneWidget);
      // The typing is still on screen, because the draft never lived in the widget.
      expect(find.text('Brisko Pizza Kothrud'), findsOneWidget);
      expect(await stored(tester), isEmpty);

      failing.failWrites = false;
      await tap(tester, find.widgetWithText(TextButton, 'Try again'));

      expect(tester.takeException(), isNull);
      expect(find.text('Not saved'), findsNothing);
      expect(
        (await stored(tester))[SettingKeys.businessName],
        'Brisko Pizza Kothrud',
      );
    });
  });

  group('the configured default order type', () {
    /// Opens checkout on a real bill and returns which order-type chip is selected.
    Future<OrderType> orderTypeCheckoutOpensOn(
      WidgetTester tester, {
      required PosSettings configuration,
    }) async {
      tester.view.physicalSize = const Size(1600, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // The bootstrap reads the stored settings before the first frame; this dependency
      // graph is that same graph with the value already loaded.
      await tester.pumpWidget(
        BriskoApp(
          dependencies: TestDependencies.over(
            database,
            activeSettings: configuration,
          ),
        ),
      );
      await settleUi(tester);

      await tap(tester, find.text(PosSection.billing.label).last);
      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.textContaining('Medium'));
      await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Checkout \u20b9250.00'),
      );

      expect(find.text('Review bill'), findsOneWidget);

      for (final OrderType type in OrderType.values) {
        final ChoiceChip chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, type.label),
        );
        if (chip.selected) {
          return type;
        }
      }
      fail('no order type was selected on the review step');
    }

    testWidgets(
      'an unconfigured terminal opens on takeaway, as it always has',
      (WidgetTester tester) async {
        expect(
          await orderTypeCheckoutOpensOn(
            tester,
            configuration: PosSettings.unconfigured,
          ),
          OrderType.takeaway,
        );
      },
    );

    testWidgets('a configured default is the one already selected', (
      WidgetTester tester,
    ) async {
      expect(
        await orderTypeCheckoutOpensOn(
          tester,
          configuration: const PosSettings(
            defaultOrderType: OrderType.delivery,
          ),
        ),
        OrderType.delivery,
      );
    });
  });

  group('clearing till data', () {
    Future<int> tableCount(WidgetTester tester, String table) async {
      final int? n = await tester.runAsync<int>(() async {
        final List<Map<String, Object?>> rows = await database.database
            .rawQuery('SELECT COUNT(*) AS count FROM $table');
        return (rows.first['count'] as int?) ?? 0;
      });
      return n!;
    }

    Future<void> seedBillAndLogin(WidgetTester tester) async {
      await tester.runAsync(() async {
        expect(
          (await SqliteSettingsRepository(database: database).writeAll(
            <String, String?>{
              SettingKeys.businessName: 'Brisko Pizza Kothrud',
              AuthSessionStore.keyAccountEmail: 'till@example.com',
            },
          )).isOk,
          isTrue,
        );
        expect(
          (await SqliteCustomerRepository(
            database: database,
          ).save(Fixtures.customer())).isOk,
          isTrue,
        );
        final Order order = Fixtures.order(orderNumber: 'T-0001');
        expect(
          (await SqliteOrderRepository(database: database).saveOrder(
            order,
            items: <OrderItem>[Fixtures.orderItem(orderId: order.id)],
          )).isOk,
          isTrue,
        );
      });
    }

    Future<void> revealClearSwitch(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Clear till data'));
      await tester.pump();
    }

    testWidgets('cancelling the confirmation leaves bills and the menu', (
      WidgetTester tester,
    ) async {
      await seedBillAndLogin(tester);
      await openSettings(tester);
      await revealClearSwitch(tester);

      expect(await tableCount(tester, SqliteTables.orders), 1);
      expect(await tableCount(tester, SqliteTables.categories), greaterThan(0));

      await tap(
        tester,
        find.widgetWithText(SwitchListTile, 'Clear till data'),
      );
      expect(find.text('Clear till data?'), findsOneWidget);

      await tap(tester, find.widgetWithText(TextButton, 'Cancel'));

      expect(find.text('Clear till data?'), findsNothing);
      expect(find.text('Till data cleared. Login and settings are unchanged.'), findsNothing);
      expect(await tableCount(tester, SqliteTables.orders), 1);
      expect(await tableCount(tester, SqliteTables.customers), 1);
      expect(await tableCount(tester, SqliteTables.categories), greaterThan(0));
      expect(
        (await stored(tester))[SettingKeys.businessName],
        'Brisko Pizza Kothrud',
      );
    });

    testWidgets('confirming deletes bills and the menu, and keeps the sign-in', (
      WidgetTester tester,
    ) async {
      await seedBillAndLogin(tester);
      await openSettings(tester);
      await revealClearSwitch(tester);

      await tap(
        tester,
        find.widgetWithText(SwitchListTile, 'Clear till data'),
      );
      await tap(tester, find.widgetWithText(FilledButton, 'Clear data'));

      expect(
        find.text('Till data cleared. Login and settings are unchanged.'),
        findsOneWidget,
      );
      expect(await tableCount(tester, SqliteTables.orders), 0);
      expect(await tableCount(tester, SqliteTables.orderItems), 0);
      expect(await tableCount(tester, SqliteTables.customers), 0);
      expect(await tableCount(tester, SqliteTables.categories), 0);
      expect(await tableCount(tester, SqliteTables.menuItems), 0);

      final Map<String, String?> values = await stored(tester);
      expect(values[SettingKeys.businessName], 'Brisko Pizza Kothrud');
      expect(values[AuthSessionStore.keyAccountEmail], 'till@example.com');
    });
  });
}
