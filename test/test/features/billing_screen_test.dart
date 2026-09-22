import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/billing/presentation/controllers/billing_controller.dart';
import 'package:brisko_billing/features/billing/presentation/screens/billing_screen.dart';
import 'package:brisko_billing/features/billing/presentation/widgets/cart_panel.dart';
import 'package:brisko_billing/features/billing/presentation/widgets/item_configuration_panel.dart';
import 'package:brisko_billing/features/billing/presentation/widgets/menu_item_grid.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/test_database.dart';

/// Drives the billing screen end to end over the real seeded menu.
///
/// The widgets are pumped over the production repository, so these tests prove that
/// the counter can actually reach a priced cart line by tapping, and that a
/// repository failure arrives as a rendered error state rather than as an exception
/// thrown through the widget tree.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late BillingController controller;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    controller = BillingController(
      menuRepository: SqliteMenuRepository(database: database),
    );
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  /// Waits for the controller's outstanding repository work, then renders it.
  ///
  /// A widget test drives a fake clock, and sqflite answers from a background
  /// isolate, so a query's completion is not delivered while that clock is in
  /// control. [WidgetTester.runAsync] hands the real event loop back for as long as
  /// the load needs, and only then is a frame pumped. Without this the screen would
  /// sit on its loading state forever.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (int attempt = 0; attempt < 400; attempt++) {
        if (!controller.isLoadingMenu &&
            !controller.isLoadingItems &&
            !controller.isLoadingOptions) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle();
  }

  /// Pumps the screen at a counter-sized window, which is the three-pane layout.
  Future<void> pumpBillingScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<BillingController>.value(
        value: controller,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: BillingScreen()),
        ),
      ),
    );
    await settle(tester);
  }

  /// Taps, lets any repository work finish, and settles the animations, so the next
  /// assertion sees the frame the cashier would see.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await settle(tester);
  }

  /// Takes the database away mid-shift, which is how the real repository is made to
  /// fail. Run on the real event loop for the same reason [settle] is.
  Future<void> breakTheDatabase(WidgetTester tester) async {
    await tester.runAsync(database.close);
  }

  group('browsing', () {
    testWidgets('the seeded categories and items are rendered', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      expect(find.text('Categories'), findsOneWidget);
      expect(find.text('SIMPLY VEG'), findsOneWidget);
      expect(find.text('SIDE ORDER'), findsOneWidget);
      expect(find.text('Cold Drinks'), findsOneWidget);

      // The first category is open, so its items are on screen with their prices.
      expect(find.byType(MenuItemGrid), findsOneWidget);
      expect(find.text('Cheese Pizza'), findsOneWidget);
      expect(find.text('Single Cheese Topped'), findsOneWidget);
      expect(find.text('\u20b9130.00'), findsOneWidget);
    });

    testWidgets('choosing a category swaps the items', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      await tap(tester, find.text('SIDE ORDER'));

      expect(find.text('French Fries'), findsOneWidget);
      expect(find.text('Cheese Pizza'), findsNothing);
    });

    testWidgets('the cart starts in its empty state', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      expect(find.byType(CartPanel), findsOneWidget);
      expect(find.text('Current bill'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(find.text('No items yet'), findsOneWidget);
      expect(find.text('\u20b90.00'), findsOneWidget);
    });
  });

  group('configuring an item', () {
    testWidgets('choosing a pizza shows its sizes but no options yet', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      await tap(tester, find.text('Cheese Pizza'));

      expect(find.byType(ItemConfigurationPanel), findsOneWidget);
      expect(find.text('Size'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      expect(find.textContaining('Small'), findsOneWidget);
      expect(find.textContaining('Medium'), findsOneWidget);
      expect(find.textContaining('Large'), findsOneWidget);
      expect(
        find.text('Choose a size to see the customisations and their prices.'),
        findsOneWidget,
      );

      // Nothing can be added until a size is chosen.
      final Finder addButton = find.widgetWithText(FilledButton, 'Add to bill');
      expect(tester.widget<FilledButton>(addButton).onPressed, isNull);
    });

    testWidgets('choosing Medium shows the Medium prices only', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await tap(tester, find.text('Cheese Pizza'));

      await tap(tester, find.textContaining('Medium'));

      expect(find.text('Choice of crust'), findsOneWidget);
      expect(find.textContaining('Thin Crust  +\u20b950.00'), findsOneWidget);
      expect(find.textContaining('Cheese Burst  +\u20b990.00'), findsOneWidget);
      expect(find.textContaining('Extra Cheese  +\u20b970.00'), findsOneWidget);
      expect(find.textContaining('Ketchup  +\u20b910.00'), findsOneWidget);

      // The running unit price is the size's price.
      expect(find.text('\u20b9250.00'), findsWidgets);
    });

    testWidgets('a Large offers no crust upgrade', (WidgetTester tester) async {
      await pumpBillingScreen(tester);
      await tap(tester, find.text('Cheese Pizza'));

      await tap(tester, find.textContaining('Large'));

      expect(find.text('Choice of crust'), findsNothing);
      expect(find.textContaining('Thin Crust'), findsNothing);
      expect(find.textContaining('Cheese Burst'), findsNothing);
      expect(find.textContaining('Extra Cheese  +\u20b990.00'), findsOneWidget);
    });

    testWidgets('the running price follows the chosen options', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.textContaining('Medium'));

      await tap(tester, find.textContaining('Extra Cheese'));

      expect(find.text('\u20b9320.00'), findsOneWidget);
      expect(
        find.text('Base \u20b9250.00 + options \u20b970.00'),
        findsOneWidget,
      );
    });

    testWidgets('going back returns to the item grid', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await tap(tester, find.text('Cheese Pizza'));

      await tap(tester, find.byTooltip('Back to the menu'));

      expect(find.byType(ItemConfigurationPanel), findsNothing);
      expect(find.byType(MenuItemGrid), findsOneWidget);
    });
  });

  group('building the bill', () {
    /// Rings up one Medium Cheese Pizza with Extra Cheese: 250 + 70.
    Future<void> addMediumCheesePizzaWithExtraCheese(
      WidgetTester tester,
    ) async {
      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.textContaining('Medium'));
      await tap(tester, find.textContaining('Extra Cheese'));
      await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));
    }

    testWidgets('the configured line appears in the cart', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      await addMediumCheesePizzaWithExtraCheese(tester);

      // The panel closed and the grid is back.
      expect(find.byType(ItemConfigurationPanel), findsNothing);

      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);
      expect(find.text('Extra Cheese'), findsOneWidget);
      expect(find.text('\u20b9320.00 each'), findsOneWidget);
      expect(find.text('1 line \u00b7 1 item'), findsOneWidget);
      expect(find.text('Subtotal'), findsOneWidget);
      expect(find.text('\u20b9320.00'), findsWidgets);
    });

    testWidgets('increasing the quantity doubles the line and the subtotal', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await addMediumCheesePizzaWithExtraCheese(tester);

      await tap(tester, find.byTooltip('Increase the quantity'));

      expect(find.text('2'), findsOneWidget);
      expect(find.text('\u20b9640.00'), findsWidgets);
      expect(find.text('2 items'), findsNothing);
      expect(find.text('1 line \u00b7 2 items'), findsOneWidget);
    });

    testWidgets('reducing is disabled at one unit', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await addMediumCheesePizzaWithExtraCheese(tester);

      final Finder reduce = find.widgetWithIcon(IconButton, Icons.remove);
      expect(tester.widget<IconButton>(reduce).onPressed, isNull);

      await tap(tester, find.byTooltip('Increase the quantity'));

      expect(tester.widget<IconButton>(reduce).onPressed, isNotNull);

      await tap(tester, reduce);

      expect(find.text('1'), findsOneWidget);
      expect(find.text('\u20b9320.00'), findsWidgets);
    });

    testWidgets('a line can be removed', (WidgetTester tester) async {
      await pumpBillingScreen(tester);
      await addMediumCheesePizzaWithExtraCheese(tester);

      await tap(tester, find.byTooltip('Remove Cheese Pizza (Medium)'));

      expect(find.text('Cheese Pizza (Medium)'), findsNothing);
      expect(find.text('No items yet'), findsOneWidget);
      expect(find.text('\u20b90.00'), findsOneWidget);
    });

    testWidgets('two lines are totalled together', (WidgetTester tester) async {
      await pumpBillingScreen(tester);
      await addMediumCheesePizzaWithExtraCheese(tester);

      await tap(tester, find.text('SIDE ORDER'));
      await tap(tester, find.text('French Fries'));
      await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));

      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);
      expect(find.text('French Fries'), findsWidgets);
      expect(find.text('2 lines \u00b7 2 items'), findsOneWidget);
      // 320 + 70
      expect(find.text('\u20b9390.00'), findsOneWidget);
    });

    testWidgets('clearing the bill asks first, then empties it', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await addMediumCheesePizzaWithExtraCheese(tester);

      await tap(tester, find.widgetWithText(TextButton, 'Clear'));

      expect(find.text('Clear this bill?'), findsOneWidget);

      await tap(tester, find.widgetWithText(TextButton, 'Keep the bill'));

      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);

      await tap(tester, find.widgetWithText(TextButton, 'Clear'));
      await tap(tester, find.widgetWithText(FilledButton, 'Clear'));

      expect(find.text('Cheese Pizza (Medium)'), findsNothing);
      expect(find.text('No items yet'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
    });

    testWidgets('the Clear control is disabled on an empty bill', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);

      final Finder clear = find.widgetWithText(TextButton, 'Clear');
      expect(tester.widget<TextButton>(clear).onPressed, isNull);
    });
  });

  group('failure states', () {
    testWidgets('a repository failure is rendered, not thrown', (
      WidgetTester tester,
    ) async {
      // The database is gone before the screen ever asks for the menu.
      await breakTheDatabase(tester);

      await pumpBillingScreen(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('The menu could not be loaded'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
      expect(find.byType(MenuItemGrid), findsNothing);
    });

    testWidgets('a later failure is reported without losing the bill', (
      WidgetTester tester,
    ) async {
      await pumpBillingScreen(tester);
      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.textContaining('Medium'));
      await tap(tester, find.widgetWithText(FilledButton, 'Add to bill'));

      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);

      await breakTheDatabase(tester);
      await tap(tester, find.text('Burger'));

      expect(tester.takeException(), isNull);
      // The bill and the categories survive; the failure is a dismissible strip.
      expect(find.text('Cheese Pizza (Medium)'), findsOneWidget);
      expect(find.text('\u20b9250.00'), findsWidgets);
      expect(find.byTooltip('Dismiss'), findsOneWidget);

      await tap(tester, find.byTooltip('Dismiss'));

      expect(find.byTooltip('Dismiss'), findsNothing);
    });
  });
}
