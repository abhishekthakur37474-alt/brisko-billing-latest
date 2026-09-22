import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../menu/domain/models/menu_category.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_variant.dart';
import '../../../menu/domain/repositories/menu_repository.dart';
import '../../domain/models/inventory_item.dart';
import '../../domain/models/recipe.dart';
import '../../domain/models/recipe_ingredient.dart';
import '../../domain/models/recipe_scope.dart';
import '../../domain/repositories/inventory_repository.dart';
import '../../domain/repositories/recipe_repository.dart';

/// Drives the recipe screen: pick a dish, pick a size if it has them, and say what it
/// uses.
///
/// ## Where the lists come from
///
/// The categories, dishes and sizes are the real menu, read through
/// [MenuRepository]. The ingredients that can be chosen are the real stock items, read
/// through [InventoryRepository]. Nothing on this screen is hardcoded: not an
/// ingredient name, not a quantity, not a price. An outlet with no stock items entered
/// yet is told to enter some, rather than being offered examples.
///
/// ## Every edit is saved as it is made
///
/// There is no draft. Adding an ingredient, changing a quantity or removing a line is
/// persisted immediately and the recipe is re-read from storage afterwards. On a till
/// that gets interrupted mid-task that is the safer trade: a half-configured recipe is a
/// real state the screen will show honestly next time, whereas unsaved work is silently
/// lost.
class RecipeController extends ChangeNotifier {
  RecipeController({
    required MenuRepository menuRepository,
    required InventoryRepository inventoryRepository,
    required RecipeRepository recipeRepository,
  }) : _menu = menuRepository,
       _inventory = inventoryRepository,
       _recipes = recipeRepository;

  final MenuRepository _menu;
  final InventoryRepository _inventory;
  final RecipeRepository _recipes;

  List<MenuCategory> _categories = const <MenuCategory>[];
  List<MenuItem> _items = const <MenuItem>[];
  List<MenuItemVariant> _variants = const <MenuItemVariant>[];
  List<InventoryItem> _stockItems = const <InventoryItem>[];
  Set<String> _configuredMenuItemIds = const <String>{};

  MenuCategory? _category;
  MenuItem? _item;
  MenuItemVariant? _variant;
  Recipe? _recipe;

  bool _isLoading = false;
  bool _hasLoaded = false;
  bool _isSaving = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // ------------------------------------------------------------------- state ---

  List<MenuCategory> get categories => _categories;

  /// Dishes in the chosen category.
  List<MenuItem> get items => _items;

  /// Sizes of the chosen dish. Empty for a dish sold at one price.
  List<MenuItemVariant> get variants => _variants;

  /// Stock items available as ingredients.
  List<InventoryItem> get stockItems => _stockItems;

  MenuCategory? get selectedCategory => _category;

  MenuItem? get selectedItem => _item;

  /// The chosen size, or `null` when the product-level recipe is being edited.
  MenuItemVariant? get selectedVariant => _variant;

  /// The recipe for exactly the chosen scope, or `null` before one is chosen.
  Recipe? get recipe => _recipe;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  bool get isSaving => _isSaving;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the outlet has no stock items at all, so no recipe can be written yet.
  bool get hasNoStockItems => _hasLoaded && _stockItems.isEmpty;

  /// True when there is no menu to configure recipes against.
  bool get hasNoMenu => _hasLoaded && _categories.isEmpty;

  /// True when [menuItemId] has at least one ingredient somewhere: at product level or
  /// on any of its sizes.
  bool isConfigured(String menuItemId) =>
      _configuredMenuItemIds.contains(menuItemId);

  /// The scope currently being edited, or `null` before a dish is chosen.
  RecipeScope? get scope {
    final MenuItem? item = _item;
    if (item == null) {
      return null;
    }
    final MenuItemVariant? variant = _variant;
    return variant == null
        ? RecipeScope.product(item.id)
        : RecipeScope.variant(menuItemId: item.id, variantId: variant.id);
  }

  /// True when the chosen dish has sizes, so the operator has a choice to make about
  /// which recipe they are editing.
  bool get hasVariants => _variants.isNotEmpty;

  /// The ingredient lines on screen. Empty when nothing is configured.
  List<RecipeIngredient> get ingredients =>
      _recipe?.ingredients ?? const <RecipeIngredient>[];

  /// True when a dish is chosen and it has no ingredients.
  bool get isUnconfigured => _recipe != null && !_recipe!.isConfigured;

  /// The stock items not yet on this recipe, so the add dialog cannot offer a
  /// duplicate the repository would refuse.
  List<InventoryItem> get availableStockItems {
    final Recipe? recipe = _recipe;
    if (recipe == null) {
      return const <InventoryItem>[];
    }
    return _stockItems
        .where((InventoryItem item) => !recipe.uses(item.id))
        .toList(growable: false);
  }

  /// The stock item behind an ingredient line, or `null` if it has been deleted.
  ///
  /// Nullable rather than assumed: an item can be deleted only when no recipe uses it,
  /// but the list on screen may be a moment behind, and rendering a blank name is
  /// better than crashing the screen.
  InventoryItem? stockItemFor(RecipeIngredient ingredient) {
    for (final InventoryItem item in _stockItems) {
      if (item.id == ingredient.inventoryItemId) {
        return item;
      }
    }
    return null;
  }

  // ----------------------------------------------------------------- reading ---

  /// Reads the menu and the stock items. Selects nothing.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<MenuCategory>> categories = await _menu.loadCategories();
    categories.fold<void>(
      onOk: (List<MenuCategory> value) => _categories = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _categories = const <MenuCategory>[];
      },
    );

    final Result<List<InventoryItem>> stock = await _inventory.loadItems();
    stock.fold<void>(
      onOk: (List<InventoryItem> value) => _stockItems = value,
      onErr: (AppFailure failure) {
        _errorMessage ??= failure.message;
        _stockItems = const <InventoryItem>[];
      },
    );

    await _loadConfiguredIds();

    _isLoading = false;
    _hasLoaded = true;
    _notify();

    // Opens on the first category, so the screen lands on something usable rather
    // than on three empty pickers.
    if (_categories.isNotEmpty) {
      await selectCategory(_categories.first);
    }
  }

  Future<void> refresh() => load();

  Future<void> selectCategory(MenuCategory category) async {
    _category = category;
    _item = null;
    _variant = null;
    _variants = const <MenuItemVariant>[];
    _recipe = null;
    _errorMessage = null;
    _notify();

    final Result<List<MenuItem>> items = await _menu.loadItems(
      categoryId: category.id,
    );
    items.fold<void>(
      onOk: (List<MenuItem> value) => _items = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _items = const <MenuItem>[];
      },
    );
    _notify();
  }

  /// Chooses a dish and reads its sizes and its product-level recipe.
  ///
  /// Opens on the product-level recipe even for a dish with sizes. That is the scope
  /// most outlets want: one recipe covering every size, overridden per size only where
  /// the amounts genuinely differ.
  Future<void> selectItem(MenuItem item) async {
    _item = item;
    _variant = null;
    _recipe = null;
    _errorMessage = null;
    _notify();

    final Result<List<MenuItemVariant>> variants = await _menu.loadVariants(
      item.id,
    );
    variants.fold<void>(
      onOk: (List<MenuItemVariant> value) => _variants = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _variants = const <MenuItemVariant>[];
      },
    );

    await _loadRecipe();
  }

  /// Chooses which recipe of the current dish is being edited.
  ///
  /// Pass `null` for the product-level recipe that all sizes fall back to.
  Future<void> selectVariant(MenuItemVariant? variant) async {
    if (_item == null) {
      return;
    }
    _variant = variant;
    _recipe = null;
    _errorMessage = null;
    _notify();
    await _loadRecipe();
  }

  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    _notify();
  }

  // ------------------------------------------------------------------ writing ---

  /// Adds an ingredient to the chosen recipe.
  ///
  /// [quantityMilli] is the amount one sold unit uses, in thousandths of the stock
  /// item's unit. A non-positive quantity, a duplicate ingredient or a deleted stock
  /// item is refused by the repository and arrives here as [errorMessage].
  Future<bool> addIngredient({
    required String inventoryItemId,
    required int quantityMilli,
  }) async {
    final RecipeScope? target = scope;
    if (target == null) {
      return false;
    }
    return _write(
      () => _recipes.addIngredient(
        scope: target,
        inventoryItemId: inventoryItemId,
        quantityMilli: quantityMilli,
      ),
    );
  }

  /// Changes how much of one ingredient the dish uses.
  Future<bool> updateIngredientQuantity({
    required RecipeIngredient ingredient,
    required int quantityMilli,
  }) {
    return _write(
      () => _recipes.updateIngredientQuantity(
        ingredientId: ingredient.id,
        quantityMilli: quantityMilli,
      ),
    );
  }

  /// Takes an ingredient off the recipe.
  ///
  /// Affects future sales only. Bills already deducted keep what came off the shelf,
  /// because that is recorded in the stock ledger rather than derived from here.
  Future<bool> removeIngredient(RecipeIngredient ingredient) =>
      _write(() => _recipes.removeIngredient(ingredient.id));

  // ---------------------------------------------------------------- internals ---

  Future<void> _loadRecipe() async {
    final RecipeScope? target = scope;
    if (target == null) {
      return;
    }

    final Result<Recipe> result = await _recipes.loadRecipe(target);
    result.fold<void>(
      onOk: (Recipe value) => _recipe = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        // Not an empty recipe: "nothing configured" and "could not be read" are
        // different facts, and showing the first for the second would be a lie.
        _recipe = null;
      },
    );
    _notify();
  }

  Future<void> _loadConfiguredIds() async {
    final Result<Set<String>> result = await _recipes
        .loadConfiguredMenuItemIds();
    _configuredMenuItemIds = result.valueOrNull ?? const <String>{};
  }

  /// Runs a write, then re-reads the recipe. Returns true when it succeeded.
  Future<bool> _write(Future<Result<Object?>> Function() action) async {
    if (_isSaving) {
      return false;
    }

    _isSaving = true;
    _errorMessage = null;
    _notify();

    final Result<Object?> result = await action();
    _isSaving = false;

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    await _loadRecipe();
    // The "configured" markers in the dish list change with the first ingredient
    // added and the last one removed, so they are re-read with every write.
    await _loadConfiguredIds();
    _notify();
    return true;
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
