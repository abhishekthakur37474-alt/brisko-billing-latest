import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/menu_category.dart';
import '../../domain/models/menu_item.dart';
import '../../domain/models/menu_item_option.dart';
import '../../domain/models/menu_item_type.dart';
import '../../domain/models/menu_item_variant.dart';
import '../../domain/models/menu_option_type.dart';
import '../../domain/repositories/menu_repository.dart';

/// Holds the menu-management screen: the categories, items, variants and options the
/// owner maintains, and the writes that change them.
///
/// ## Boundaries
///
/// This is the only menu-management class that holds a [MenuRepository], under the
/// abstract type. It contains no SQL, no table names, and no knowledge that SQLite
/// exists. Every price it stores is a [Money] in paise; there is no `double` in this
/// file, and no amount is ever parsed from the text on a screen — a widget parses its
/// field into a [Money] and hands it in.
///
/// ## Why edits keep the row
///
/// Renaming an item or changing its price is a save of the same entity with the same
/// id, never a delete-and-recreate. That is what keeps a bill's history, an inventory
/// recipe and a stock movement pointing at the item they always pointed at. Removing a
/// category or item is a soft delete for the same reason. Turning something off is
/// [MenuCategory.isActive] / [MenuItem.isActive], which hides it from billing while
/// leaving every historical reference intact.
///
/// ## Failure
///
/// Nothing throws. A repository failure becomes [errorMessage] and the list falls back
/// to what was last read, so a storage fault is something the owner reads rather than a
/// crash. Every write re-reads afterwards, so the screen always shows stored state.
class MenuManagementController extends ChangeNotifier {
  MenuManagementController({required MenuRepository menuRepository})
    : _menu = menuRepository;

  final MenuRepository _menu;

  List<MenuCategory> _categories = const <MenuCategory>[];
  List<MenuItem> _items = const <MenuItem>[];
  List<MenuItemOption> _options = const <MenuItemOption>[];

  /// The item whose sizes are open on the Variants tab, and its sizes.
  String? _variantItemId;
  List<MenuItemVariant> _variants = const <MenuItemVariant>[];

  bool _isLoading = false;
  bool _hasLoaded = false;
  bool _isSaving = false;
  bool _isLoadingVariants = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // -------------------------------------------------------------------- state ---

  /// Every category that has not been removed, including deactivated ones, in
  /// display order.
  List<MenuCategory> get categories => _categories;

  /// Every item that has not been removed, including deactivated and unavailable
  /// ones, across all categories.
  List<MenuItem> get items => _items;

  /// Every option that has not been removed, including deactivated ones, across all
  /// scopes.
  List<MenuItemOption> get options => _options;

  /// The sizes of [variantItemId], including deactivated ones.
  List<MenuItemVariant> get variants => _variants;

  /// The item whose sizes are being managed, or `null`.
  String? get variantItemId => _variantItemId;

  bool get isLoadingVariants => _isLoadingVariants;

  bool get isLoading => _isLoading;

  /// True once a read has finished, successfully or not. Distinguishes "nothing on
  /// the menu yet" from "not read yet".
  bool get hasLoaded => _hasLoaded;

  bool get isSaving => _isSaving;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// The items in one category, in display order.
  List<MenuItem> itemsInCategory(String categoryId) => _items
      .where((MenuItem item) => item.categoryId == categoryId)
      .toList(growable: false);

  /// The category with [id], or `null` if it is not loaded.
  MenuCategory? categoryById(String id) {
    for (final MenuCategory category in _categories) {
      if (category.id == id) {
        return category;
      }
    }
    return null;
  }

  /// The item with [id], or `null` if it is not loaded.
  MenuItem? itemById(String id) {
    for (final MenuItem item in _items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  /// A readable name for [categoryId], or a placeholder if it is unknown.
  String categoryName(String categoryId) =>
      categoryById(categoryId)?.name ?? 'Unknown category';

  // ------------------------------------------------------------------ reading ---

  /// Replaces the screen's contents from storage.
  ///
  /// Ignores a call made while a read is already running, so a double tap on refresh
  /// cannot interleave two reads and discard the later one's result.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<MenuCategory>> categories = await _menu
        .loadCategoriesForManagement();
    categories.fold<void>(
      onOk: (List<MenuCategory> value) => _categories = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _categories = const <MenuCategory>[];
      },
    );

    final Result<List<MenuItem>> items = await _menu.loadItemsForManagement();
    items.fold<void>(
      onOk: (List<MenuItem> value) => _items = value,
      onErr: (AppFailure failure) {
        _errorMessage ??= failure.message;
        _items = const <MenuItem>[];
      },
    );

    final Result<List<MenuItemOption>> options = await _menu
        .loadOptionsForManagement();
    options.fold<void>(
      onOk: (List<MenuItemOption> value) => _options = value,
      onErr: (AppFailure failure) {
        _errorMessage ??= failure.message;
        _options = const <MenuItemOption>[];
      },
    );

    // Refresh the open size list too, so a reload does not leave the Variants tab a
    // step behind the rest of the screen.
    final String? openItem = _variantItemId;
    if (openItem != null) {
      await _reloadVariants(openItem);
    }

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  Future<void> refresh() => load();

  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    _notify();
  }

  /// Opens an item's sizes on the Variants tab.
  Future<void> selectVariantItem(String menuItemId) async {
    _variantItemId = menuItemId;
    _variants = const <MenuItemVariant>[];
    _isLoadingVariants = true;
    _notify();
    await _reloadVariants(menuItemId);
    _isLoadingVariants = false;
    _notify();
  }

  void clearVariantItem() {
    if (_variantItemId == null) {
      return;
    }
    _variantItemId = null;
    _variants = const <MenuItemVariant>[];
    _isLoadingVariants = false;
    _notify();
  }

  /// The sizes of one item, read on demand without touching the Variants tab.
  ///
  /// Used by the option editor to offer a size when a size-scoped option is being
  /// created. Returns an empty list on failure, which the caller reads as "this item
  /// has no size to scope to".
  Future<List<MenuItemVariant>> variantsOf(String menuItemId) async {
    final Result<List<MenuItemVariant>> result = await _menu
        .loadVariantsForManagement(menuItemId);
    return result.valueOrNull ?? const <MenuItemVariant>[];
  }

  // --------------------------------------------------------------- categories ---

  /// Adds a category at the end of the current order.
  ///
  /// Returns true when it was created. On failure the message is in [errorMessage]
  /// and nothing was written.
  Future<bool> createCategory(String name) {
    final DateTime now = DateTime.now().toUtc();
    return _write(
      () => _menu.saveCategory(
        MenuCategory(
          id: EntityId.generate(prefix: 'cat'),
          name: name.trim(),
          displayOrder: _nextCategoryOrder(),
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  /// Renames a category, keeping its id, order and state.
  Future<bool> renameCategory(MenuCategory category, String name) {
    return _write(
      () => _menu.saveCategory(
        category.copyWith(name: name.trim(), updatedAt: DateTime.now().toUtc()),
      ),
    );
  }

  /// Switches a category on or off. A switched-off category is hidden from billing
  /// but keeps its items and history.
  Future<bool> setCategoryActive(
    MenuCategory category, {
    required bool isActive,
  }) {
    if (category.isActive == isActive) {
      return Future<bool>.value(true);
    }
    return _write(
      () => _menu.saveCategory(
        category.copyWith(
          isActive: isActive,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  /// Moves a category one place earlier in the counter order by swapping its
  /// display order with the category above it.
  Future<bool> moveCategoryUp(MenuCategory category) =>
      _swapCategoryOrder(category, -1);

  /// Moves a category one place later in the counter order.
  Future<bool> moveCategoryDown(MenuCategory category) =>
      _swapCategoryOrder(category, 1);

  // -------------------------------------------------------------------- items ---

  /// Adds an item to a category.
  ///
  /// [basePrice] is the price when the item is sold without a size. A sized product's
  /// sizes are added separately on the Variants tab; this is the fallback and the
  /// smallest-size default.
  Future<bool> createItem({
    required String categoryId,
    required String name,
    required Money basePrice,
    required MenuItemType itemType,
    String? description,
    bool isAvailable = true,
  }) {
    final DateTime now = DateTime.now().toUtc();
    final String? note = _trimToNull(description);
    return _write(
      () => _menu.saveItem(
        MenuItem(
          id: EntityId.generate(prefix: 'item'),
          categoryId: categoryId,
          name: name.trim(),
          description: note,
          itemType: itemType,
          basePrice: basePrice,
          isAvailable: isAvailable,
          displayOrder: _nextItemOrder(categoryId),
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  /// Edits an item's name, description, type, base price or category.
  ///
  /// The same id is kept, so a recipe or a historical bill line that references this
  /// item still references it. A new base price changes only bills settled from now
  /// on: existing bills carry the price they were charged.
  Future<bool> updateItem(
    MenuItem item, {
    required String name,
    required Money basePrice,
    required MenuItemType itemType,
    required String categoryId,
    String? description,
  }) {
    return _write(
      () => _menu.saveItem(
        item.copyWith(
          categoryId: categoryId,
          name: name.trim(),
          description: _trimToNull(description),
          itemType: itemType,
          basePrice: basePrice,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  /// Switches an item on or off. A switched-off item leaves the billing menu but its
  /// history and recipe remain.
  Future<bool> setItemActive(MenuItem item, {required bool isActive}) {
    if (item.isActive == isActive) {
      return Future<bool>.value(true);
    }
    return _write(
      () => _menu.saveItem(
        item.copyWith(isActive: isActive, updatedAt: DateTime.now().toUtc()),
      ),
    );
  }

  /// Marks an item available or temporarily out of stock. Unavailable items stay on
  /// the billing menu but cannot be added to a bill.
  Future<bool> setItemAvailable(MenuItem item, {required bool isAvailable}) {
    if (item.isAvailable == isAvailable) {
      return Future<bool>.value(true);
    }
    return _write(
      () => _menu.saveItem(
        item.copyWith(
          isAvailable: isAvailable,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  // ----------------------------------------------------------------- variants ---

  /// Adds a size to an item.
  Future<bool> createVariant({
    required String menuItemId,
    required String name,
    required Money price,
  }) {
    final DateTime now = DateTime.now().toUtc();
    return _write(
      () => _menu.saveVariant(
        MenuItemVariant(
          id: EntityId.generate(prefix: 'var'),
          menuItemId: menuItemId,
          name: name.trim(),
          price: price,
          displayOrder: _nextVariantOrder(),
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  /// Edits a size's name or price. A new price applies to new bills only.
  Future<bool> updateVariant(
    MenuItemVariant variant, {
    required String name,
    required Money price,
  }) {
    return _write(
      () => _menu.saveVariant(
        variant.copyWith(
          name: name.trim(),
          price: price,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  /// Switches a size on or off. A switched-off size cannot be chosen at the counter.
  Future<bool> setVariantActive(
    MenuItemVariant variant, {
    required bool isActive,
  }) {
    if (variant.isActive == isActive) {
      return Future<bool>.value(true);
    }
    return _write(
      () => _menu.saveVariant(
        variant.copyWith(isActive: isActive, updatedAt: DateTime.now().toUtc()),
      ),
    );
  }

  // ------------------------------------------------------------------ options ---

  /// Adds an option at a chosen scope.
  ///
  /// The scope is expressed as the id columns the existing option system uses, so
  /// nothing here redesigns that system:
  ///
  /// * a variant id scopes the option to one size of one product;
  /// * an item id scopes it to one product at any size;
  /// * a category id scopes it to every product in a category;
  /// * all three null makes it global.
  ///
  /// The caller passes exactly the ids for the scope it chose. Passing more than one
  /// is refused, so an option cannot accidentally be made both item- and
  /// category-scoped.
  Future<bool> createOption({
    required String name,
    required MenuOptionType optionType,
    required Money price,
    String? menuItemId,
    String? variantId,
    String? categoryId,
  }) {
    final AppFailure? scopeError = _scopeError(
      menuItemId: menuItemId,
      variantId: variantId,
      categoryId: categoryId,
    );
    if (scopeError != null) {
      return _fail(scopeError);
    }

    final DateTime now = DateTime.now().toUtc();
    return _write(
      () => _menu.saveOption(
        MenuItemOption(
          id: EntityId.generate(prefix: 'opt'),
          menuItemId: menuItemId,
          variantId: variantId,
          categoryId: categoryId,
          name: name.trim(),
          optionType: optionType,
          price: price,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  /// Edits an option's name, kind or price.
  ///
  /// The scope is deliberately not editable here: an option priced for one size of
  /// one pizza must not become available to every product because a name was
  /// corrected. Changing where an option applies is done by deactivating it and
  /// adding a new one at the intended scope.
  Future<bool> updateOption(
    MenuItemOption option, {
    required String name,
    required MenuOptionType optionType,
    required Money price,
  }) {
    return _write(
      () => _menu.saveOption(
        option.copyWith(
          name: name.trim(),
          optionType: optionType,
          price: price,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  /// Switches an option on or off. A switched-off option is not offered at the
  /// counter, at any scope it reaches.
  Future<bool> setOptionActive(
    MenuItemOption option, {
    required bool isActive,
  }) {
    if (option.isActive == isActive) {
      return Future<bool>.value(true);
    }
    return _write(
      () => _menu.saveOption(
        option.copyWith(isActive: isActive, updatedAt: DateTime.now().toUtc()),
      ),
    );
  }

  // ---------------------------------------------------------------- internals ---

  Future<void> _reloadVariants(String menuItemId) async {
    final Result<List<MenuItemVariant>> result = await _menu
        .loadVariantsForManagement(menuItemId);
    // Ignore a stale result if the owner has since opened another item's sizes.
    if (_variantItemId != menuItemId) {
      return;
    }
    result.fold<void>(
      onOk: (List<MenuItemVariant> value) => _variants = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _variants = const <MenuItemVariant>[];
      },
    );
  }

  Future<bool> _swapCategoryOrder(MenuCategory category, int delta) {
    final List<MenuCategory> ordered = _categories;
    final int index = ordered.indexWhere(
      (MenuCategory c) => c.id == category.id,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= ordered.length) {
      // Already at the edge; nothing to do, and reported as success so a button at
      // the end of the list does not look like it failed.
      return Future<bool>.value(true);
    }

    final MenuCategory a = ordered[index];
    final MenuCategory b = ordered[target];
    final DateTime now = DateTime.now().toUtc();

    return _write(() async {
      final Result<void> first = await _menu.saveCategory(
        a.copyWith(displayOrder: b.displayOrder, updatedAt: now),
      );
      if (first.isErr) {
        return first;
      }
      return _menu.saveCategory(
        b.copyWith(displayOrder: a.displayOrder, updatedAt: now),
      );
    });
  }

  int _nextCategoryOrder() {
    int highest = 0;
    for (final MenuCategory category in _categories) {
      if (category.displayOrder > highest) {
        highest = category.displayOrder;
      }
    }
    return highest + 1;
  }

  int _nextItemOrder(String categoryId) {
    int highest = 0;
    for (final MenuItem item in _items) {
      if (item.categoryId == categoryId && item.displayOrder > highest) {
        highest = item.displayOrder;
      }
    }
    return highest + 1;
  }

  int _nextVariantOrder() {
    int highest = 0;
    for (final MenuItemVariant variant in _variants) {
      if (variant.displayOrder > highest) {
        highest = variant.displayOrder;
      }
    }
    return highest + 1;
  }

  /// Refuses a scope that names more than one target.
  AppFailure? _scopeError({
    String? menuItemId,
    String? variantId,
    String? categoryId,
  }) {
    final int named = <String?>[
      menuItemId,
      variantId,
      categoryId,
    ].where((String? id) => id != null).length;
    if (named > 1) {
      return const ValidationFailure(
        'An option belongs to a single scope. Choose one of a size, an item, a '
        'category, or all items.',
      );
    }
    return null;
  }

  static String? _trimToNull(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<bool> _fail(AppFailure failure) {
    _errorMessage = failure.message;
    _notify();
    return Future<bool>.value(false);
  }

  /// Runs a write, then re-reads. Returns true when it succeeded.
  ///
  /// Every write goes through here so the saving flag, the error message and the
  /// reload after a change are handled identically. Re-reading rather than mutating
  /// the list in place means the screen always shows stored state.
  Future<bool> _write(Future<Result<void>> Function() action) async {
    if (_isSaving) {
      return false;
    }

    _isSaving = true;
    _errorMessage = null;
    _notify();

    final Result<void> result = await action();
    _isSaving = false;

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    await load();
    return true;
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Notifies unless the controller has already been disposed.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
