import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/error/app_failure.dart';
import 'package:brisko_billing/core/utils/result.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/inventory/domain/models/inventory_item.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_ingredient.dart';
import 'package:brisko_billing/features/inventory/domain/models/recipe_scope.dart';
import 'package:brisko_billing/features/inventory/domain/models/stock_quantity.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item.dart';
import 'package:brisko_billing/features/menu/domain/models/menu_item_variant.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

/// Recipes over the real seeded menu and real stock items.
///
/// The dishes and sizes here are the outlet's actual menu, read through the production
/// menu repository. The stock items are fixtures with obviously synthetic names, because
/// the outlet's real ingredients are the operator's to enter and nothing seeds them.
void main() {
  setUpAll(TestDatabase.register);

  late SqliteDatabase database;
  late SqliteMenuRepository menu;
  late SqliteInventoryRepository inventory;
  late SqliteRecipeRepository recipes;

  late MenuItem pizza;
  late MenuItemVariant medium;
  late MenuItemVariant large;
  late InventoryItem flour;
  late InventoryItem cheese;

  setUp(() async {
    database = await TestDatabase.openInMemory();
    menu = SqliteMenuRepository(database: database);
    inventory = SqliteInventoryRepository(database: database);
    recipes = SqliteRecipeRepository(database: database);

    pizza = (await menu.loadItems()).valueOrNull!.firstWhere(
      (MenuItem item) => item.name == 'Cheese Pizza',
    );
    final List<MenuItemVariant> sizes = (await menu.loadVariants(pizza.id))
        .valueOrNull!;
    medium = sizes.firstWhere((MenuItemVariant v) => v.name == 'Medium');
    large = sizes.firstWhere((MenuItemVariant v) => v.name == 'Large');

    flour = Fixtures.inventoryItem(name: 'Test Flour', currentQuantity: '50');
    cheese = Fixtures.inventoryItem(name: 'Test Cheese', currentQuantity: '20');
    await inventory.saveItem(flour);
    await inventory.saveItem(cheese);
  });

  tearDown(() async {
    await database.close();
  });

  RecipeScope productScope() => RecipeScope.product(pizza.id);

  RecipeScope scopeFor(MenuItemVariant variant) =>
      RecipeScope.variant(menuItemId: pizza.id, variantId: variant.id);

  Future<Recipe> load(RecipeScope scope) async =>
      (await recipes.loadRecipe(scope)).valueOrNull!;

  group('the scope', () {
    test('a product scope and a variant scope are different recipes', () {
      expect(productScope(), isNot(scopeFor(medium)));
      expect(productScope().isVariantScoped, isFalse);
      expect(scopeFor(medium).isVariantScoped, isTrue);
    });

    test('equal scopes are equal, so they can key a map', () {
      expect(RecipeScope.product('a'), RecipeScope.product('a'));
      expect(
        RecipeScope.variant(menuItemId: 'a', variantId: 'b'),
        RecipeScope.variant(menuItemId: 'a', variantId: 'b'),
      );
      expect(
        RecipeScope.product('a').hashCode,
        RecipeScope.product('a').hashCode,
      );
    });

    test('a variant scope falls back to its product, and no further', () {
      expect(scopeFor(medium).fallback, productScope());
      expect(productScope().fallback, isNull);
    });
  });

  group('creating a recipe', () {
    test('an unconfigured dish reads as empty rather than missing', () async {
      final Recipe recipe = await load(productScope());

      expect(recipe.isConfigured, isFalse);
      expect(recipe.ingredients, isEmpty);
      expect(recipe.scope, productScope());
    });

    test('adding the first ingredient creates the recipe', () async {
      final Result<RecipeIngredient> added = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: StockQuantity.parse('0.15'),
      );

      expect(added.isOk, isTrue);
      expect(added.valueOrNull!.quantityMilli, 150);
      expect(added.valueOrNull!.scope, productScope());

      final Recipe recipe = await load(productScope());
      expect(recipe.isConfigured, isTrue);
      expect(recipe.ingredientCount, 1);
      expect(recipe.uses(flour.id), isTrue);
    });

    test('a recipe holds several ingredients in the order added', () async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: cheese.id,
        quantityMilli: 100,
      );

      final Recipe recipe = await load(productScope());
      expect(
        recipe.ingredients.map((RecipeIngredient i) => i.inventoryItemId),
        <String>[flour.id, cheese.id],
      );
      expect(recipe.inventoryItemIds, <String>{flour.id, cheese.id});
    });
  });

  group('editing a recipe', () {
    setUp(() async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
    });

    test('an ingredient quantity can be changed', () async {
      final RecipeIngredient line = (await load(productScope()))
          .lineFor(flour.id)!;

      final Result<void> result = await recipes.updateIngredientQuantity(
        ingredientId: line.id,
        quantityMilli: StockQuantity.parse('0.2'),
      );

      expect(result.isOk, isTrue);
      expect(
        (await load(productScope())).lineFor(flour.id)!.quantityMilli,
        200,
      );
    });

    test('an ingredient can be removed', () async {
      final RecipeIngredient line = (await load(productScope()))
          .lineFor(flour.id)!;

      expect((await recipes.removeIngredient(line.id)).isOk, isTrue);

      final Recipe recipe = await load(productScope());
      expect(recipe.isConfigured, isFalse);
      expect(recipe.uses(flour.id), isFalse);
    });

    test('a removed ingredient can be added back', () async {
      // The unique index excludes soft-deleted rows precisely so this works.
      final RecipeIngredient line = (await load(productScope()))
          .lineFor(flour.id)!;
      await recipes.removeIngredient(line.id);

      final Result<RecipeIngredient> again = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 200,
      );

      expect(again.isOk, isTrue);
      expect((await load(productScope())).ingredientCount, 1);
    });

    test('changing the quantity of a removed line is refused', () async {
      final RecipeIngredient line = (await load(productScope()))
          .lineFor(flour.id)!;
      await recipes.removeIngredient(line.id);

      final Result<void> result = await recipes.updateIngredientQuantity(
        ingredientId: line.id,
        quantityMilli: 200,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });
  });

  group('validation', () {
    test('a quantity of zero is refused', () async {
      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 0,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('more than nothing'));
    });

    test('a negative quantity is refused', () async {
      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: -150,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('changing a quantity to zero is refused', () async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
      final RecipeIngredient line = (await load(productScope()))
          .lineFor(flour.id)!;

      final Result<void> result = await recipes.updateIngredientQuantity(
        ingredientId: line.id,
        quantityMilli: 0,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(
        (await load(productScope())).lineFor(flour.id)!.quantityMilli,
        150,
      );
    });

    test('a stock item that does not exist is refused', () async {
      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: 'inv-does-not-exist',
        quantityMilli: 150,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('no longer exists'));
    });

    test('a deleted stock item is refused', () async {
      final InventoryItem gone = Fixtures.inventoryItem(name: 'Test Gone');
      await inventory.saveItem(gone);
      await inventory.deleteItem(gone.id);

      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: gone.id,
        quantityMilli: 150,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
    });

    test('a menu item that does not exist is refused', () async {
      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: RecipeScope.product('item-does-not-exist'),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('menu item'));
    });

    test('a size belonging to another dish is refused', () async {
      // Without this a recipe could be scoped to another pizza's Medium, and both
      // dishes would then resolve the wrong ingredients.
      final MenuItem other = (await menu.loadItems()).valueOrNull!.firstWhere(
        (MenuItem item) => item.id != pizza.id,
      );

      final Result<RecipeIngredient> result = await recipes.addIngredient(
        scope: RecipeScope.variant(menuItemId: other.id, variantId: medium.id),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(result.failureOrNull!.message, contains('does not belong'));
    });

    test('the same stock item twice in one scope is refused', () async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );

      final Result<RecipeIngredient> duplicate = await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 200,
      );

      expect(duplicate.failureOrNull, isA<ValidationFailure>());
      expect(duplicate.failureOrNull!.message, contains('already uses'));
      expect((await load(productScope())).ingredientCount, 1);
    });

    test('the same stock item on two different sizes is allowed', () async {
      // Different scopes are different recipes, so this is not a duplicate.
      expect(
        (await recipes.addIngredient(
          scope: scopeFor(medium),
          inventoryItemId: flour.id,
          quantityMilli: 150,
        )).isOk,
        isTrue,
      );
      expect(
        (await recipes.addIngredient(
          scope: scopeFor(large),
          inventoryItemId: flour.id,
          quantityMilli: 250,
        )).isOk,
        isTrue,
      );
    });
  });

  group('scoping', () {
    test('a product level recipe is kept apart from a size recipe', () async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
      await recipes.addIngredient(
        scope: scopeFor(large),
        inventoryItemId: flour.id,
        quantityMilli: 250,
      );

      expect(
        (await load(productScope())).lineFor(flour.id)!.quantityMilli,
        150,
      );
      expect(
        (await load(scopeFor(large))).lineFor(flour.id)!.quantityMilli,
        250,
      );
      // Loading a scope shows what that scope holds, without falling back.
      expect((await load(scopeFor(medium))).isConfigured, isFalse);
    });

    test(
      'resolving a size with no recipe of its own uses the product',
      () async {
        await recipes.addIngredient(
          scope: productScope(),
          inventoryItemId: flour.id,
          quantityMilli: 150,
        );

        final Recipe resolved = (await recipes.resolveRecipe(scopeFor(medium)))
            .valueOrNull!;

        expect(resolved.scope, productScope());
        expect(resolved.lineFor(flour.id)!.quantityMilli, 150);
      },
    );

    test('resolving a size with its own recipe uses that one', () async {
      await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
      await recipes.addIngredient(
        scope: scopeFor(large),
        inventoryItemId: flour.id,
        quantityMilli: 250,
      );

      final Recipe resolved = (await recipes.resolveRecipe(scopeFor(large)))
          .valueOrNull!;

      expect(resolved.scope, scopeFor(large));
      expect(resolved.lineFor(flour.id)!.quantityMilli, 250);
    });

    test('resolving an unconfigured dish returns an empty recipe', () async {
      final Recipe resolved = (await recipes.resolveRecipe(scopeFor(medium)))
          .valueOrNull!;

      expect(resolved.isConfigured, isFalse);
    });

    test('every line for a dish is readable across its sizes', () async {
      await recipes.addIngredient(
        scope: scopeFor(medium),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );
      await recipes.addIngredient(
        scope: scopeFor(large),
        inventoryItemId: flour.id,
        quantityMilli: 250,
      );

      final List<RecipeIngredient> all =
          (await recipes.loadIngredientsForMenuItem(pizza.id)).valueOrNull!;

      expect(all, hasLength(2));
    });
  });

  group('reporting which dishes are configured', () {
    test('a dish appears once it has any ingredient anywhere', () async {
      expect((await recipes.loadConfiguredMenuItemIds()).valueOrNull, isEmpty);

      await recipes.addIngredient(
        scope: scopeFor(medium),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      );

      expect(
        (await recipes.loadConfiguredMenuItemIds()).valueOrNull,
        contains(pizza.id),
      );
    });

    test('a dish drops off when its last ingredient is removed', () async {
      final RecipeIngredient line = (await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      )).valueOrNull!;

      await recipes.removeIngredient(line.id);

      expect((await recipes.loadConfiguredMenuItemIds()).valueOrNull, isEmpty);
    });
  });

  group('stock items in use', () {
    test('a stock item on a live recipe is reported as in use', () async {
      expect(
        (await recipes.isInventoryItemInUse(flour.id)).valueOrNull,
        isFalse,
      );

      final RecipeIngredient line = (await recipes.addIngredient(
        scope: productScope(),
        inventoryItemId: flour.id,
        quantityMilli: 150,
      )).valueOrNull!;
      expect(
        (await recipes.isInventoryItemInUse(flour.id)).valueOrNull,
        isTrue,
      );

      await recipes.removeIngredient(line.id);
      expect(
        (await recipes.isInventoryItemInUse(flour.id)).valueOrNull,
        isFalse,
      );
    });
  });
}
