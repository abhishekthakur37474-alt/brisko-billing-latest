import '../../../../core/utils/result.dart';
import '../models/menu_category.dart';
import '../models/menu_item.dart';
import '../models/menu_item_option.dart';
import '../models/menu_item_variant.dart';

/// Read and write access to the menu.
///
/// Abstract so that the billing module can be written and tested against it
/// without a database, and so that no feature learns that SQLite exists.
abstract interface class MenuRepository {
  /// Active categories in display order.
  ///
  /// This is the billing view: a deactivated category is not offered at the
  /// counter, so it is excluded here. Menu maintenance wants to see and reactivate
  /// those, and calls [loadCategoriesForManagement] instead.
  Future<Result<List<MenuCategory>>> loadCategories();

  /// Emits the category list whenever it changes.
  Stream<List<MenuCategory>> watchCategories();

  /// Every category that has not been removed, in display order, including the
  /// deactivated ones.
  ///
  /// For the menu-management screen, which has to show a switched-off category so it
  /// can be switched back on. Soft-deleted rows are still excluded: a removal is
  /// meant to stay gone.
  Future<Result<List<MenuCategory>>> loadCategoriesForManagement();

  /// Active items, optionally restricted to one category.
  Future<Result<List<MenuItem>>> loadItems({String? categoryId});

  /// Every item that has not been removed, optionally restricted to one category,
  /// including deactivated and unavailable ones.
  ///
  /// The menu-management counterpart to [loadItems]. Billing hides a deactivated
  /// item; maintenance shows it so its state can be changed. Unavailable items are
  /// returned by both, because "out of stock" is a display state rather than a
  /// reason to hide the row.
  Future<Result<List<MenuItem>>> loadItemsForManagement({String? categoryId});

  Future<Result<MenuItem?>> findItem(String id);

  /// Sizes for one item, in display order. Empty for a single-price item.
  Future<Result<List<MenuItemVariant>>> loadVariants(String menuItemId);

  /// Every size of one item, in display order, including the deactivated ones.
  ///
  /// For menu maintenance. Billing's [loadVariants] omits an inactive size so it
  /// cannot be sold; this returns it so it can be edited or reactivated.
  Future<Result<List<MenuItemVariant>>> loadVariantsForManagement(
    String menuItemId,
  );

  /// Options that apply once a size has been chosen, at the price for that size.
  ///
  /// This is the call the billing screen makes. Give it the chosen variant and it
  /// returns a ready list: Extra Cheese at ₹70 for a Medium, ₹90 for a Large, with
  /// no name to parse and no scope to interpret.
  ///
  /// It combines all four scopes, narrowest first, resolving the variant to its
  /// product and category on the way:
  ///
  /// 1. options priced for this exact variant
  /// 2. options scoped to the product
  /// 3. options scoped to the product's category
  /// 4. global options
  ///
  /// Where the same option name is reachable through more than one scope, the
  /// narrowest wins, so a price set for one size overrides a general one. An option
  /// priced for a *different* variant never appears.
  Future<Result<List<MenuItemOption>>> loadOptionsForVariant(String variantId);

  /// Options that apply to a product without needing a size.
  ///
  /// Use this for something sold at one price, such as a burger. Size-dependent
  /// options are deliberately excluded, because their price is undefined until a size
  /// is known; for a pizza, call [loadOptionsForVariant] instead.
  ///
  /// Combines product-scoped, category-scoped and global options, with the same
  /// narrowest-wins precedence.
  Future<Result<List<MenuItemOption>>> loadOptionsForItem(String menuItemId);

  /// Every active option across all scopes, for menu maintenance and reporting.
  ///
  /// Not for the billing screen: it returns rows for every size of every pizza, with
  /// no indication of which one applies.
  Future<Result<List<MenuItemOption>>> loadAllOptions();

  /// Every option across all scopes, including the deactivated ones.
  ///
  /// The menu-management view. Like [loadAllOptions] it is not for billing, and it
  /// additionally keeps switched-off options so they can be turned back on. Each row
  /// still carries its scope columns, so the screen can show and preserve where an
  /// option applies.
  Future<Result<List<MenuItemOption>>> loadOptionsForManagement();

  Future<Result<void>> saveCategory(MenuCategory category);

  Future<Result<void>> saveItem(MenuItem item);

  Future<Result<void>> saveVariant(MenuItemVariant variant);

  Future<Result<void>> saveOption(MenuItemOption option);

  Future<Result<void>> deleteCategory(String id);

  Future<Result<void>> deleteItem(String id);
}
