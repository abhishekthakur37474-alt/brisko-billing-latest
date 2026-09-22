import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';
import 'menu_option_scope.dart';
import 'menu_option_type.dart';

/// A selectable customisation such as Thin Crust, Extra Cheese or Ketchup.
///
/// These are database rows, never constants in a widget. The outlet changes its
/// add-on prices without a rebuild, and a bill printed last month must still show
/// the price that applied then, which only works if the value has a home in the
/// data layer.
///
/// ## Scope
///
/// [name] carries the customisation only, never a size. Which pizza and which size
/// an option is priced for is expressed through [variantId], [menuItemId] and
/// [categoryId], so nothing has to read meaning out of a string:
///
/// * [variantId] set means this row prices the option for that one size of that one
///   product. This is how the menu's size-dependent add-on pricing is represented:
///   Extra Cheese is ₹50 on a Small and ₹90 on a Large, which is three rows sharing
///   one name.
/// * [menuItemId] set means the option applies to that product at any size.
/// * [categoryId] set means it applies to every product in that category.
/// * All three null means it applies to everything.
///
/// Callers should not inspect these fields. Ask the repository for the options that
/// apply to a variant or an item and it resolves the scopes and their precedence.
class MenuItemOption implements SyncableEntity {
  const MenuItemOption({
    required this.id,
    required this.name,
    required this.optionType,
    required this.price,
    required this.createdAt,
    required this.updatedAt,
    this.menuItemId,
    this.variantId,
    this.categoryId,
    this.displayOrder = 0,
    this.isActive = true,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory MenuItemOption.fromRow(Map<String, Object?> row) {
    return MenuItemOption(
      id: row.requireString(SyncColumns.id),
      menuItemId: row.optionalString('menuItemId'),
      variantId: row.optionalString('variantId'),
      categoryId: row.optionalString('categoryId'),
      name: row.requireString('name'),
      optionType: row.requireEnum<MenuOptionType>(
        'optionType',
        MenuOptionType.values,
        fallback: MenuOptionType.addOn,
      ),
      price: Money.fromPaise(row.requireInt('pricePaise')),
      displayOrder: row.optionalInt('displayOrder'),
      isActive: row.requireBool('isActive'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// Scopes the option to one product at any size. `null` when not item-scoped.
  final String? menuItemId;

  /// Scopes the option to one exact size of one product. `null` when the price does
  /// not depend on size.
  final String? variantId;

  /// Scopes the option to every product in one category. `null` when not
  /// category-scoped.
  final String? categoryId;

  /// The customisation, with no size or scope encoded in it. For example
  /// `Extra Cheese`, not `Extra Cheese (Large)`.
  final String name;

  final MenuOptionType optionType;

  /// Amount added to the line when selected. May be zero for a genuinely free
  /// option, but zero must be a deliberate decision rather than a missing value.
  final Money price;

  final int displayOrder;

  final bool isActive;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  /// How widely this row applies, narrowest first.
  MenuOptionScope get scope {
    if (variantId != null) {
      return MenuOptionScope.variant;
    }
    if (menuItemId != null) {
      return MenuOptionScope.item;
    }
    if (categoryId != null) {
      return MenuOptionScope.category;
    }
    return MenuOptionScope.global;
  }

  /// True when this option can be offered on every product.
  bool get isGlobal => scope == MenuOptionScope.global;

  /// True when the price depends on the size chosen, so the option cannot be
  /// offered until a variant is known.
  bool get isSizeSpecific => variantId != null;

  MenuItemOption copyWith({
    String? menuItemId,
    String? variantId,
    String? categoryId,
    String? name,
    MenuOptionType? optionType,
    Money? price,
    int? displayOrder,
    bool? isActive,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return MenuItemOption(
      id: id,
      menuItemId: menuItemId ?? this.menuItemId,
      variantId: variantId ?? this.variantId,
      categoryId: categoryId ?? this.categoryId,
      name: name ?? this.name,
      optionType: optionType ?? this.optionType,
      price: price ?? this.price,
      displayOrder: displayOrder ?? this.displayOrder,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      SyncColumns.id: id,
      SyncColumns.createdAt: SqliteValue.fromDateTime(createdAt),
      SyncColumns.updatedAt: SqliteValue.fromDateTime(updatedAt),
      SyncColumns.isDeleted: SqliteValue.fromBool(isDeleted),
      SyncColumns.syncState: syncState.name,
      'menuItemId': menuItemId,
      'variantId': variantId,
      'categoryId': categoryId,
      'name': name,
      'optionType': optionType.name,
      'pricePaise': price.paise,
      'displayOrder': displayOrder,
      'isActive': SqliteValue.fromBool(isActive),
    };
  }
}
