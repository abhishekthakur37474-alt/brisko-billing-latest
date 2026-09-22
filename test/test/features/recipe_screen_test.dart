import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/theme/app_theme.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:brisko_billing/features/inventory/domain/repositories/recipe_repository.dart';
import 'package:brisko_billing/features/inventory/presentation/screens/inventory_screen.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:brisko_billing/features/menu/domain/repositories/menu_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

/// The recipe screen driven by tapping, over the real seeded menu.
///
/// The dishes and sizes are the outlet's actual menu. The stock items are fixtures with
/// obviously synthetic names, because the outlet's real ingredients are the operator's to
/// enter and nothing seeds them. No ingredient, quantity or example appears on screen
/// that was not stored first.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteInventoryRepository inventory;
  late SqliteRecipeRepository recipes;
  late SqliteInventoryDeductionRepository deductions;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    recipes = SqliteRecipeRepository(database: database);
    deductions = SqliteInventoryDeductionRepository(database: database);
  });

  tearDown(() async {
    if (database.isOpen) {
      await database.close();
    }
  });

  Future<T> real<T>(WidgetTester tester, Future<T> Function() action) async {
    final T? value = await tester.runAsync<T>(action);
    return value as T;
  }

  /// Bounded pumps rather than `pumpAndSettle`: the forms autofocus a text field, and a
  /// blinking caret means the tree is never quiescent.
  Future<void> settleUi(WidgetTester tester) async {
    for (int round = 0; round < 8; round++) {
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

  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);

  Future<void> enter(WidgetTester tester, String label, String value) async {
    await tester.enterText(
      find.ancestor(of: find.text(label), matching: find.byType(TextField)),
      value,
    );
    await tester.pump();
  }

  Future<InventoryItem> addStockItem(
    WidgetTester tester, {
    String name = 'Test Flour',
    String currentQuantity = '50',
  }) {
    return real<InventoryItem>(tester, () async {
      final InventoryItem item = Fixtures.inventoryItem(
        name: name,
        currentQuantity: currentQuantity,
        minimumQuantity: '0',
      );
      await inventory.saveItem(item);
      return item;
    });
  }

  Future<MenuItem> cheesePizza(WidgetTester tester) => real(
    tester,
    () async => (await menu.loadItems()).valueOrNull!.firstWhere(
      (MenuItem item) => item.name == 'Cheese Pizza',
    ),
  );

  Future<List<MenuItemVariant>> sizesOf(WidgetTester tester, MenuItem item) =>
      real(tester, () async => (await menu.loadVariants(item.id)).valueOrNull!);

  Future<Recipe> storedRecipe(WidgetTester tester, RecipeScope scope) =>
      real(tester, () async => (await recipes.loadRecipe(scope)).valueOrNull!);

  Future<void> runSql(WidgetTester tester, String statement) =>
      real<void>(tester, () => database.database.execute(statement));

  /// Opens the screen and switches to the Recipes half.
  Future<void> pumpRecipes(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<InventoryRepository>.value(value: inventory),
          Provider<RecipeRepository>.value(value: recipes),
          Provider<InventoryDeductionRepository>.value(value: deductions),
          Provider<MenuRepository>.value(value: menu),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: InventoryScreen()),
        ),
      ),
    );
    await settleUi(tester);
    await tap(tester, find.text('Recipes'));
  }

  group('rendering', () {
    testWidgets('the real menu is offered, with nothing configured', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      // The seeded categories and dishes, not a sample list.
      expect(find.text('SIMPLY VEG'), findsOneWidget);
      expect(find.text('Cheese Pizza'), findsOneWidget);
      expect(find.text('No recipe'), findsWidgets);
      expect(find.text('Recipe configured'), findsNothing);
    });

    testWidgets('an item with no ingredients says so honestly', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));

      expect(
        find.text('No ingredients configured for this item.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Nothing is deducted when it is sold'),
        findsOneWidget,
      );
    });

    testWidgets('an outlet with no stock items is told where to go first', (
      WidgetTester tester,
    ) async {
      await pumpRecipes(tester);

      expect(
        find.textContaining('No stock items yet. Add them under Stock first'),
        findsOneWidget,
      );
      // Nothing to add, so the button says nothing can be added.
      await tap(tester, find.text('Cheese Pizza'));
      final FilledButton add = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Add ingredient'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('the sizes of a sized dish are offered', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));

      // Opens on the shared recipe, with each size available to override.
      expect(find.text('All sizes'), findsOneWidget);
      expect(find.text('Recipe for all sizes'), findsOneWidget);
      expect(find.text('Medium'), findsOneWidget);
      expect(find.text('Large'), findsOneWidget);
    });
  });

  group('adding an ingredient', () {
    testWidgets('it is saved and shown against the dish', (
      WidgetTester tester,
    ) async {
      final InventoryItem flour = await addStockItem(
        tester,
        name: 'Test Flour',
        currentQuantity: '50',
      );
      final MenuItem pizza = await cheesePizza(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Add ingredient'));
      await tap(tester, inDialog(find.text('Ingredient')));
      await tap(tester, find.text('Test Flour (kg)').last);
      await enter(tester, 'Quantity for one (kg)', '0.15');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.text('Test Flour'), findsOneWidget);
      expect(find.text('0.15 kg'), findsOneWidget);
      expect(find.text('In stock: 50 kg'), findsOneWidget);
      expect(
        find.text('No ingredients configured for this item.'),
        findsNothing,
      );

      // Stored, not just on screen.
      final Recipe stored = await storedRecipe(
        tester,
        RecipeScope.product(pizza.id),
      );
      expect(stored.lineFor(flour.id)!.quantityMilli, 150);
    });

    testWidgets('the dish is then marked as configured in the list', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Add ingredient'));
      await tap(tester, inDialog(find.text('Ingredient')));
      await tap(tester, find.text('Test Flour (kg)').last);
      await enter(tester, 'Quantity for one (kg)', '0.15');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.text('Recipe configured'), findsOneWidget);
    });

    testWidgets('a size can be given its own recipe', (
      WidgetTester tester,
    ) async {
      final InventoryItem flour = await addStockItem(tester);
      final MenuItem pizza = await cheesePizza(tester);
      final List<MenuItemVariant> sizes = await sizesOf(tester, pizza);
      final MenuItemVariant large = sizes.firstWhere(
        (MenuItemVariant v) => v.name == 'Large',
      );
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Large'));
      expect(find.text('Recipe for Large'), findsOneWidget);

      await tap(tester, find.text('Add ingredient'));
      await tap(tester, inDialog(find.text('Ingredient')));
      await tap(tester, find.text('Test Flour (kg)').last);
      await enter(tester, 'Quantity for one (kg)', '0.25');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.text('0.25 kg'), findsOneWidget);

      // On the size, and not on the shared recipe.
      final Recipe forSize = await storedRecipe(
        tester,
        RecipeScope.variant(menuItemId: pizza.id, variantId: large.id),
      );
      expect(forSize.lineFor(flour.id)!.quantityMilli, 250);
      expect(
        (await storedRecipe(
          tester,
          RecipeScope.product(pizza.id),
        )).isConfigured,
        isFalse,
      );
    });
  });

  group('editing and removing', () {
    /// A dish with one ingredient already configured.
    Future<InventoryItem> withOneIngredient(WidgetTester tester) async {
      final InventoryItem flour = await addStockItem(tester);
      final MenuItem pizza = await cheesePizza(tester);
      await real<void>(
        tester,
        () => recipes
            .addIngredient(
              scope: RecipeScope.product(pizza.id),
              inventoryItemId: flour.id,
              quantityMilli: 150,
            )
            .then((_) {}),
      );
      return flour;
    }

    testWidgets('a quantity can be changed', (WidgetTester tester) async {
      final InventoryItem flour = await withOneIngredient(tester);
      final MenuItem pizza = await cheesePizza(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      expect(find.text('0.15 kg'), findsOneWidget);

      await tap(tester, find.byTooltip('Edit quantity'));
      await enter(tester, 'Quantity for one (kg)', '0.2');
      await tap(tester, inDialog(find.text('Save')));

      expect(find.text('0.2 kg'), findsOneWidget);
      final Recipe stored = await storedRecipe(
        tester,
        RecipeScope.product(pizza.id),
      );
      expect(stored.lineFor(flour.id)!.quantityMilli, 200);
    });

    testWidgets('an ingredient can be removed', (WidgetTester tester) async {
      await withOneIngredient(tester);
      final MenuItem pizza = await cheesePizza(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.byTooltip('Remove ingredient'));

      expect(
        find.text('No ingredients configured for this item.'),
        findsOneWidget,
      );
      expect(find.text('No recipe'), findsWidgets);
      expect(
        (await storedRecipe(
          tester,
          RecipeScope.product(pizza.id),
        )).isConfigured,
        isFalse,
      );
    });

    testWidgets('an ingredient already used cannot be added twice', (
      WidgetTester tester,
    ) async {
      // The picker cannot offer it, so the duplicate the repository would refuse is
      // unreachable from the screen.
      await withOneIngredient(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      final FilledButton add = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Add ingredient'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(add.onPressed, isNull);
    });
  });

  group('validation', () {
    testWidgets('a quantity of zero is refused without an exception', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      final MenuItem pizza = await cheesePizza(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Add ingredient'));
      await tap(tester, inDialog(find.text('Ingredient')));
      await tap(tester, find.text('Test Flour (kg)').last);
      await enter(tester, 'Quantity for one (kg)', '0');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.textContaining('more than nothing'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        (await storedRecipe(
          tester,
          RecipeScope.product(pizza.id),
        )).isConfigured,
        isFalse,
      );
    });

    testWidgets('a quantity that is not a number is refused', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Add ingredient'));
      await tap(tester, inDialog(find.text('Ingredient')));
      await tap(tester, find.text('Test Flour (kg)').last);
      await enter(tester, 'Quantity for one (kg)', 'a handful');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.textContaining('Enter the quantity'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no ingredient chosen is refused', (WidgetTester tester) async {
      await addStockItem(tester);
      await pumpRecipes(tester);

      await tap(tester, find.text('Cheese Pizza'));
      await tap(tester, find.text('Add ingredient'));
      await enter(tester, 'Quantity for one', '0.15');
      await tap(tester, inDialog(find.text('Add')));

      expect(find.text('Choose an ingredient.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('a storage failure', () {
    testWidgets('is rendered as a notice rather than thrown at the widget', (
      WidgetTester tester,
    ) async {
      await addStockItem(tester);
      await runSql(
        tester,
        'ALTER TABLE recipe_ingredients RENAME TO recipe_ingredients_moved',
      );

      await pumpRecipes(tester);
      await tap(tester, find.text('Cheese Pizza'));

      expect(tester.takeException(), isNull);
      expect(find.text('Try again'), findsOneWidget);
      // Not an empty recipe: "nothing configured" and "could not be read" are
      // different facts.
      expect(
        find.text('No ingredients configured for this item.'),
        findsNothing,
      );
    });
  });
}
