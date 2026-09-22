import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/money_display.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../../menu/domain/models/menu_category.dart';
import '../../../menu/domain/models/menu_item.dart';
import '../../../menu/domain/models/menu_item_option.dart';
import '../../../menu/domain/models/menu_item_variant.dart';
import '../../../menu/domain/models/menu_option_type.dart';
import '../../../menu/domain/repositories/menu_repository.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cart_line.dart';
import '../../domain/models/held_bill.dart';
import '../../domain/models/held_bill_draft.dart';
import '../../domain/models/held_bill_summary.dart';
import '../../domain/repositories/held_bill_repository.dart';

/// Drives the billing screen: what the counter is browsing, what it is configuring,
/// and the cart it is building.
///
/// ## Boundaries
///
/// This is the only billing class that holds a [MenuRepository], and it holds it
/// under the abstract type. It calls named repository methods and reads model
/// objects; it contains no SQL, no table names and no notion that SQLite exists.
/// It never inspects an option's `variantId`, `menuItemId` or `categoryId`, and it
/// never parses a name to work out a size or a price. Scope resolution belongs to
/// the repository, so [selectVariant] simply asks
/// [MenuRepository.loadOptionsForVariant] and renders whatever comes back.
///
/// Widgets above this class render state and dispatch intents. Every rule — which
/// options may be chosen, whether a crust replaces another, when a line may be
/// added, how a quantity is clamped — lives here or in the cart model, so no rule
/// can be lost by rewriting a widget.
///
/// ## Failures
///
/// Repository calls return `Result`, so nothing throws through a widget. A failure
/// becomes [errorMessage], which the screen renders as an error state with a retry.
///
/// ## Money
///
/// Every price and total is a [Money]. There is no `double` in this file.
class BillingController extends ChangeNotifier {
  BillingController({
    required this._menuRepository,
    HeldBillRepository? heldBillRepository,
  }) : _heldBills = heldBillRepository;

  final MenuRepository _menuRepository;

  /// Where a held bill is written and read. Null when this controller was built without
  /// hold support, in which case [canHold] is false and the button is never offered.
  final HeldBillRepository? _heldBills;

  List<MenuCategory> _categories = const <MenuCategory>[];
  MenuCategory? _selectedCategory;
  List<MenuItem> _items = const <MenuItem>[];

  MenuItem? _configuringItem;
  List<MenuItemVariant> _variants = const <MenuItemVariant>[];
  MenuItemVariant? _selectedVariant;
  List<MenuItemOption> _availableOptions = const <MenuItemOption>[];
  final Set<String> _selectedOptionIds = <String>{};

  Cart _cart = const Cart.empty();

  bool _hasAttemptedLoad = false;
  bool _isLoadingMenu = false;
  bool _isLoadingItems = false;
  bool _isLoadingOptions = false;
  String? _errorMessage;

  /// True while a hold is in flight, so a double tap on Hold cannot start a second one.
  bool _isHolding = false;

  /// The confirmation shown after a bill was held, describing what was put aside, or
  /// `null` when there is nothing to confirm. Set after the cart it describes has gone.
  String? _heldNotice;

  /// The message for a hold that failed, or `null`. Kept apart from the menu's
  /// [_errorMessage] so a failed hold does not blank the menu or the bill.
  String? _holdError;

  /// Sequence numbers used to discard the results of superseded loads.
  ///
  /// A cashier taps faster than SQLite answers. Without these, tapping Burger while
  /// Veg Pizza is still loading could land the pizza list under the Burger heading.
  /// Each load claims a number and drops its result if a newer one has started.
  int _itemsRequest = 0;
  int _optionsRequest = 0;

  // ---------------------------------------------------------------- browsing ---

  /// Active categories in menu order.
  List<MenuCategory> get categories => _categories;

  MenuCategory? get selectedCategory => _selectedCategory;

  /// Active items in the selected category, in menu order.
  List<MenuItem> get items => _items;

  /// True while the first load of the menu is in flight and nothing can be shown.
  bool get isLoadingMenu => _isLoadingMenu;

  /// True once a load has finished, whether it succeeded or failed.
  ///
  /// Distinguishes "not asked yet" from "asked, and the menu is empty". Without it
  /// the screen would show an empty-menu message for the frame before the first
  /// query is even sent.
  bool get isMenuReady => _hasAttemptedLoad && !_isLoadingMenu;

  /// True while the item grid is being replaced.
  bool get isLoadingItems => _isLoadingItems;

  /// Operator-facing message for the most recent failure, or `null`.
  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the menu loaded but the selected category has nothing sellable.
  bool get hasNoItems =>
      !_isLoadingMenu && !_isLoadingItems && !hasError && _items.isEmpty;

  // ----------------------------------------------------------- configuration ---

  /// The item being configured, or `null` when the configuration panel is closed.
  MenuItem? get configuringItem => _configuringItem;

  bool get isConfiguring => _configuringItem != null;

  /// Sizes offered for the item being configured. Empty for a single-price item.
  List<MenuItemVariant> get variants => _variants;

  MenuItemVariant? get selectedVariant => _selectedVariant;

  /// True when a size must be chosen before the item can be added.
  bool get requiresVariantSelection => _variants.isNotEmpty;

  /// Options the repository says apply to the current selection, already priced for
  /// it and already ordered for display.
  ///
  /// For a size-priced item this is empty until a size is chosen, because the price
  /// of a size-dependent option is undefined before then.
  List<MenuItemOption> get availableOptions => _availableOptions;

  /// [availableOptions] grouped by kind, in the repository's order, so the panel can
  /// lay out crusts, add-ons and condiments without classifying anything itself.
  Map<MenuOptionType, List<MenuItemOption>> get optionGroups {
    final Map<MenuOptionType, List<MenuItemOption>> grouped =
        <MenuOptionType, List<MenuItemOption>>{};
    for (final MenuItemOption option in _availableOptions) {
      grouped
          .putIfAbsent(option.optionType, () => <MenuItemOption>[])
          .add(option);
    }
    return grouped;
  }

  bool get isLoadingOptions => _isLoadingOptions;

  bool isOptionSelected(String optionId) =>
      _selectedOptionIds.contains(optionId);

  /// Chosen options, in the order the repository returned them.
  List<MenuItemOption> get selectedOptions => _availableOptions
      .where((MenuItemOption option) => _selectedOptionIds.contains(option.id))
      .toList(growable: false);

  /// Price of one unit before options: the chosen size's price, or the item's own
  /// price when it is not size-priced. `null` when nothing is being configured, or
  /// when a size is required and none has been chosen.
  Money? get draftBasePrice {
    final MenuItem? item = _configuringItem;
    if (item == null) {
      return null;
    }
    if (requiresVariantSelection) {
      return _selectedVariant?.price;
    }
    return item.basePrice;
  }

  /// What the chosen options add to one unit.
  Money get draftOptionsTotal =>
      Money.sum(selectedOptions.map((MenuItemOption option) => option.price));

  /// Price of one unit as it would be charged. `null` when the draft is incomplete.
  Money? get draftUnitPrice {
    final Money? base = draftBasePrice;
    return base == null ? null : base + draftOptionsTotal;
  }

  /// True when the draft is complete enough to become a cart line.
  bool get canAddToCart =>
      _configuringItem != null && !_isLoadingOptions && draftBasePrice != null;

  // -------------------------------------------------------------------- cart ---

  Cart get cart => _cart;

  Money get subtotal => _cart.subtotal;

  // ---------------------------------------------------------------- held bills ---

  /// True when there is a bill to put aside and somewhere to put it.
  ///
  /// False on an empty cart — there is nothing to hold — and false when this controller
  /// was built without a held-bill repository, so a screen wired without one never offers
  /// the button.
  bool get canHold => _heldBills != null && _cart.isNotEmpty;

  /// True while a hold is being written.
  bool get isHolding => _isHolding;

  /// The confirmation for the bill just held, or `null`. Names the lines, items and total
  /// of what was put aside, read after the live cart has been emptied.
  String? get heldNotice => _heldNotice;

  bool get hasHeldNotice => _heldNotice != null;

  /// The message for the most recent failed hold, or `null`.
  String? get holdError => _holdError;

  bool get hasHoldError => _holdError != null;

  // ----------------------------------------------------------------- intents ---

  /// Puts the current bill aside as a held bill, then empties the live cart.
  ///
  /// Returns true when the bill was held. The cart is cleared only after the write has
  /// committed, so a hold that fails leaves the bill on screen exactly as it was, sellable,
  /// with the reason in [holdError]. A hold already in flight, an empty cart, or a
  /// controller built without a repository all return false without writing anything.
  ///
  /// Any open item configuration is closed first: a bill is held mid-configuration when
  /// the customer walks off, and that half-built draft belongs to the bill being put aside.
  Future<bool> holdCart({OrderType orderType = OrderType.takeaway}) async {
    final HeldBillRepository? repository = _heldBills;
    if (repository == null || _isHolding || _cart.isEmpty) {
      return false;
    }

    _isHolding = true;
    _holdError = null;
    _heldNotice = null;
    _clearConfiguration();
    notifyListeners();

    final Cart held = _cart;
    final Result<HeldBill> result = await repository.hold(
      HeldBillDraft.fromCart(cart: held, orderType: orderType),
    );

    _isHolding = false;

    return result.fold<bool>(
      onOk: (HeldBill record) {
        // Emptied only now the write has committed, and the confirmation is built from the
        // held record rather than the live cart, which is about to be gone.
        _cart = const Cart.empty();
        _heldNotice = _noticeFor(record);
        notifyListeners();
        return true;
      },
      onErr: (AppFailure failure) {
        _holdError = failure.message;
        notifyListeners();
        return false;
      },
    );
  }

  /// Takes a resumed bill's cart onto the counter as the live bill.
  ///
  /// The bill has already been marked resumed by the repository; this is the second half
  /// of resuming — the cart the cashier gets back. Any part-built configuration is closed,
  /// because the resumed bill is now the bill on screen.
  void adoptResumedBill(HeldBill bill) {
    _clearConfiguration();
    _holdError = null;
    _heldNotice = null;
    _cart = bill.cart;
    notifyListeners();
  }

  /// Dismisses the held-bill confirmation without holding anything else.
  void dismissHeldNotice() {
    if (_heldNotice == null) {
      return;
    }
    _heldNotice = null;
    notifyListeners();
  }

  /// Dismisses a failed-hold message.
  void dismissHoldError() {
    if (_holdError == null) {
      return;
    }
    _holdError = null;
    notifyListeners();
  }

  /// `Bill held: 1 line · 2 items · ₹640.00`, describing what was put aside.
  String _noticeFor(HeldBill record) {
    final HeldBillSummary summary = HeldBillSummary(
      id: record.id,
      orderType: record.orderType,
      status: record.status,
      heldAt: record.heldAt,
      lineCount: record.lineCount,
      itemCount: record.itemCount,
      subtotal: record.subtotal,
      customerPhone: record.customerPhone,
      notes: record.notes,
    );
    return 'Bill held: ${summary.countsLabel} \u00b7 '
        '${record.subtotal.formatted}';
  }

  /// Loads the menu the first time the billing screen is opened.
  ///
  /// The controller outlives the screen so that a part-built bill survives a trip to
  /// Orders, which means the screen is rebuilt more often than the menu needs
  /// reading. Deciding that here rather than in `initState` keeps the rule out of the
  /// widget.
  Future<void> ensureMenuLoaded() async {
    if (_isLoadingMenu || _categories.isNotEmpty) {
      return;
    }
    await loadMenu();
  }

  /// Re-reads the menu so a change made on the menu-management screen is reflected at
  /// the counter without a restart.
  ///
  /// This is what makes a deactivated item leave the grid and a new price take effect
  /// on the next line: the billing screen calls it when it comes back into view. The
  /// cart and any in-progress configuration are deliberately left untouched — a price
  /// change applies to new lines, never to what is already on the bill, and a draft
  /// the cashier is part way through building is not the menu's to discard.
  ///
  /// The currently browsed category is kept if it still exists and is active; if it was
  /// deactivated or removed, browsing falls back to the first category. Nothing here
  /// blanks the screen while it reloads: the existing grid stays until the new one is
  /// ready, so a refresh is invisible unless something actually changed.
  Future<void> reloadMenu() async {
    if (_isLoadingMenu) {
      return;
    }

    final Result<List<MenuCategory>> result = await _menuRepository
        .loadCategories();

    final List<MenuCategory>? loaded = result.fold<List<MenuCategory>?>(
      onOk: (List<MenuCategory> categories) => categories,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return null;
      },
    );

    if (loaded == null) {
      // A refresh failure is a strip, not a dead end: the menu already on screen
      // stays usable.
      notifyListeners();
      return;
    }

    _hasAttemptedLoad = true;
    _categories = List<MenuCategory>.unmodifiable(loaded);

    MenuCategory? selected;
    final String? previousId = _selectedCategory?.id;
    if (previousId != null) {
      for (final MenuCategory category in _categories) {
        if (category.id == previousId) {
          selected = category;
          break;
        }
      }
    }
    selected ??= _categories.isEmpty ? null : _categories.first;
    _selectedCategory = selected;

    if (selected == null) {
      _items = const <MenuItem>[];
      notifyListeners();
      return;
    }

    final int request = ++_itemsRequest;
    final Result<List<MenuItem>> items = await _menuRepository.loadItems(
      categoryId: selected.id,
    );

    if (request != _itemsRequest) {
      return;
    }

    _items = items.fold<List<MenuItem>>(
      onOk: List<MenuItem>.unmodifiable,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return _items;
      },
    );
    notifyListeners();
  }

  /// Loads the categories and the items of the first one.
  ///
  /// Also the retry path: the error state calls this again. Safe to call twice.
  Future<void> loadMenu() async {
    _hasAttemptedLoad = true;
    _isLoadingMenu = true;
    _errorMessage = null;
    notifyListeners();

    final Result<List<MenuCategory>> result = await _menuRepository
        .loadCategories();

    final List<MenuCategory>? loaded = result.fold<List<MenuCategory>?>(
      onOk: (List<MenuCategory> categories) => categories,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return null;
      },
    );

    _isLoadingMenu = false;

    if (loaded == null) {
      _categories = const <MenuCategory>[];
      _items = const <MenuItem>[];
      _selectedCategory = null;
      notifyListeners();
      return;
    }

    _categories = List<MenuCategory>.unmodifiable(loaded);
    final MenuCategory? first = _categories.isEmpty ? null : _categories.first;

    if (first == null) {
      _selectedCategory = null;
      _items = const <MenuItem>[];
      notifyListeners();
      return;
    }

    notifyListeners();
    await selectCategory(first);
  }

  /// Shows the items of [category].
  ///
  /// Closes any open configuration, because a draft belongs to the item it was
  /// started from and carrying it across a category change would be meaningless.
  Future<void> selectCategory(MenuCategory category) async {
    if (_selectedCategory?.id == category.id && _items.isNotEmpty) {
      return;
    }

    final int request = ++_itemsRequest;

    _selectedCategory = category;
    _isLoadingItems = true;
    _errorMessage = null;
    _clearConfiguration();
    notifyListeners();

    final Result<List<MenuItem>> result = await _menuRepository.loadItems(
      categoryId: category.id,
    );

    if (request != _itemsRequest) {
      return;
    }

    _isLoadingItems = false;
    _items = result.fold<List<MenuItem>>(
      onOk: List<MenuItem>.unmodifiable,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return const <MenuItem>[];
      },
    );
    notifyListeners();
  }

  /// Starts configuring [item]: loads its sizes, and its options if it has none.
  ///
  /// Which repository call is made is decided by whether the item has variant rows,
  /// never by the item's name or category. An item with no sizes takes
  /// [MenuRepository.loadOptionsForItem]; a sized item waits for [selectVariant] and
  /// takes [MenuRepository.loadOptionsForVariant], so no size is ever assumed.
  Future<void> selectItem(MenuItem item) async {
    if (!item.isSellable) {
      _errorMessage = '${item.name} is not available right now.';
      notifyListeners();
      return;
    }

    final int request = ++_optionsRequest;

    _configuringItem = item;
    _variants = const <MenuItemVariant>[];
    _selectedVariant = null;
    _availableOptions = const <MenuItemOption>[];
    _selectedOptionIds.clear();
    _isLoadingOptions = true;
    _errorMessage = null;
    notifyListeners();

    final Result<List<MenuItemVariant>> variants = await _menuRepository
        .loadVariants(item.id);

    if (request != _optionsRequest) {
      return;
    }

    final List<MenuItemVariant>? loaded = variants.fold<List<MenuItemVariant>?>(
      onOk: (List<MenuItemVariant> values) => values,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return null;
      },
    );

    if (loaded == null) {
      _isLoadingOptions = false;
      _configuringItem = null;
      notifyListeners();
      return;
    }

    _variants = List<MenuItemVariant>.unmodifiable(loaded);

    if (_variants.isNotEmpty) {
      // A size is required. Options arrive once it is chosen, at that size's price.
      _isLoadingOptions = false;
      notifyListeners();
      return;
    }

    await _loadOptions(
      request,
      () => _menuRepository.loadOptionsForItem(item.id),
    );
  }

  /// Chooses a size and reloads the options at that size's prices.
  ///
  /// Existing option selections are dropped, because an option chosen at another
  /// size was a different priced row and carrying the choice over would either
  /// charge the wrong amount or offer something this size does not have — a Large
  /// has no crust upgrade at all.
  Future<void> selectVariant(MenuItemVariant variant) async {
    if (_configuringItem == null) {
      return;
    }
    if (!_variants.any((MenuItemVariant known) => known.id == variant.id)) {
      return;
    }

    final int request = ++_optionsRequest;

    _selectedVariant = variant;
    _availableOptions = const <MenuItemOption>[];
    _selectedOptionIds.clear();
    _isLoadingOptions = true;
    _errorMessage = null;
    notifyListeners();

    await _loadOptions(
      request,
      () => _menuRepository.loadOptionsForVariant(variant.id),
    );
  }

  /// Selects or clears an option.
  ///
  /// Only an option present in [availableOptions] can be selected. Anything else is
  /// ignored, so an option the repository did not offer for this selection — a Large
  /// Thin Crust, a price meant for another size — cannot reach a cart line even if a
  /// widget asks for it.
  ///
  /// A crust is a choice between alternatives rather than a stackable extra, so
  /// selecting one clears any other crust. Add-ons and condiments accumulate.
  void toggleOption(MenuItemOption option) {
    final MenuItemOption? offered = _offeredOption(option.id);
    if (offered == null) {
      return;
    }

    if (_selectedOptionIds.remove(offered.id)) {
      notifyListeners();
      return;
    }

    if (offered.optionType == MenuOptionType.crust) {
      _selectedOptionIds.removeAll(
        _availableOptions
            .where(
              (MenuItemOption candidate) =>
                  candidate.optionType == MenuOptionType.crust,
            )
            .map((MenuItemOption candidate) => candidate.id)
            .toList(growable: false),
      );
    }

    _selectedOptionIds.add(offered.id);
    notifyListeners();
  }

  /// Abandons the draft without adding anything.
  void cancelConfiguration() {
    if (_configuringItem == null) {
      return;
    }
    _optionsRequest++;
    _clearConfiguration();
    notifyListeners();
  }

  /// Turns the draft into a cart line and closes the panel.
  ///
  /// The line is built by [CartLine.fromSelection], which copies the names and
  /// prices off the menu objects, so the line is independent of the menu from this
  /// moment on. Does nothing when the draft is incomplete.
  void addConfiguredItemToCart() {
    final MenuItem? item = _configuringItem;
    if (item == null || !canAddToCart) {
      return;
    }

    _cart = _cart.addLine(
      CartLine.fromSelection(
        id: EntityId.generate(prefix: 'line'),
        item: item,
        variant: _selectedVariant,
        options: selectedOptions,
      ),
    );

    _optionsRequest++;
    _clearConfiguration();
    notifyListeners();
  }

  void increaseQuantity(String lineId) {
    _updateCart(_cart.increaseQuantity(lineId));
  }

  void decreaseQuantity(String lineId) {
    _updateCart(_cart.decreaseQuantity(lineId));
  }

  void setQuantity(String lineId, int quantity) {
    _updateCart(_cart.withQuantity(lineId, quantity));
  }

  void removeLine(String lineId) {
    _updateCart(_cart.removeLine(lineId));
  }

  void clearCart() {
    if (_cart.isEmpty) {
      return;
    }
    _cart = _cart.cleared();
    notifyListeners();
  }

  /// Dismisses the error without retrying.
  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- internals ---

  Future<void> _loadOptions(
    int request,
    Future<Result<List<MenuItemOption>>> Function() load,
  ) async {
    final Result<List<MenuItemOption>> result = await load();

    if (request != _optionsRequest) {
      return;
    }

    _isLoadingOptions = false;
    _availableOptions = result.fold<List<MenuItemOption>>(
      onOk: List<MenuItemOption>.unmodifiable,
      onErr: (AppFailure failure) {
        _recordFailure(failure);
        return const <MenuItemOption>[];
      },
    );
    notifyListeners();
  }

  void _updateCart(Cart updated) {
    if (identical(updated, _cart)) {
      return;
    }
    _cart = updated;
    notifyListeners();
  }

  void _clearConfiguration() {
    _configuringItem = null;
    _variants = const <MenuItemVariant>[];
    _selectedVariant = null;
    _availableOptions = const <MenuItemOption>[];
    _selectedOptionIds.clear();
    _isLoadingOptions = false;
  }

  /// The offered option with this id, or `null` if the repository did not offer it
  /// for the current selection.
  MenuItemOption? _offeredOption(String optionId) {
    for (final MenuItemOption candidate in _availableOptions) {
      if (candidate.id == optionId) {
        return candidate;
      }
    }
    return null;
  }

  /// Stores the operator-facing message. Raw exception detail stays in
  /// `AppFailure.cause` and is never shown at the counter.
  void _recordFailure(AppFailure failure) {
    _errorMessage = failure.message;
  }
}
