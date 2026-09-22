import '../../../../utils/entity_id.dart';

/// The real Brisko Pizza menu, as reference data for the seed migration.
///
/// ## Provenance
///
/// Every name, price and description here is transcribed from the outlet's printed
/// menu. Nothing is invented, rounded or filled in from a sample dataset. A wrong
/// price here becomes a wrong bill and a wrong GST figure, so a value that is not
/// printed on the menu is left out and recorded in [pendingFromMenuImage] instead of
/// being guessed.
///
/// Outlet: Brisko Pizza, Opp. Ch. Charan Singh Library, Baraut Road, Chhaprauli,
/// Baghpat (U.P.) 250617.
///
/// ## Food classification
///
/// The menu carries the green vegetarian mark and the words "PURE VEG" in its
/// masthead, so every product is [itemTypeName] `veg`. That is read from the menu
/// rather than assumed. No item is egg or non-veg, and none is marked as such.
///
/// ## Structure notes
///
/// The pizza panel is printed in four sub-sections (Simply Veg, Veg Delight, Veg
/// Treat, Veg Special). The schema has categories and items, with no sub-category
/// level, and the agreed category list treats "Veg Pizza" as one section. The
/// sub-sections are therefore preserved through banded [displayOrder] values so the
/// counter lists pizzas in printed order, rather than by inventing four categories
/// that were not agreed.
///
/// Combos are products in their own combo category, carrying the menu's own contents
/// text in [SeedMenuItem.description]. They are deliberately not decomposed into
/// links to the individual pizzas and burgers: the menu sells "Combo-1" at a single
/// price, and modelling it as a bundle of separately priced parts would invite a
/// bill that does not add up to what the board says.
class MenuSeedData {
  const MenuSeedData._();

  /// Menu sections, in printed order.
  static const List<SeedCategory> categories = <SeedCategory>[
    SeedCategory(slug: 'veg-pizza', name: 'Veg Pizza', displayOrder: 10),
    SeedCategory(slug: 'burger', name: 'Burger', displayOrder: 20),
    SeedCategory(slug: 'wraps', name: 'Wraps', displayOrder: 30),
    SeedCategory(slug: 'taco', name: 'Taco', displayOrder: 40),
    SeedCategory(slug: 'sandwich', name: 'Sandwich', displayOrder: 50),
    SeedCategory(slug: 'coffee', name: 'Coffee', displayOrder: 60),
    SeedCategory(
      slug: 'shakes-mocktails',
      name: 'Shakes / Mocktails',
      displayOrder: 70,
    ),
    SeedCategory(
      slug: 'family-combos',
      name: 'Family Combos',
      displayOrder: 80,
    ),
    SeedCategory(
      slug: 'twin-treat-pizza-combo',
      name: 'Twin Treat Pizza Combo',
      displayOrder: 90,
    ),
    SeedCategory(slug: 'burger-combo', name: 'Burger Combo', displayOrder: 100),
    SeedCategory(slug: 'side-orders', name: 'Side Orders', displayOrder: 110),
    SeedCategory(slug: 'cold-drinks', name: 'Cold Drinks', displayOrder: 120),
  ];

  /// Every product. Pizzas are expanded from [_pizzas] so that the three size
  /// prices are written once, next to each other, where a transcription slip is
  /// visible.
  static final List<SeedMenuItem> items = <SeedMenuItem>[
    for (final PizzaSpec pizza in _pizzas)
      SeedMenuItem(
        slug: pizza.slug,
        categorySlug: 'veg-pizza',
        name: pizza.name,
        itemTypeName: _veg,
        // Smallest printed size. The price actually charged comes from the
        // selected variant.
        basePriceRupees: pizza.small,
        description: pizza.description,
        displayOrder: pizza.displayOrder,
      ),
    ..._otherItems,
  ];

  /// Size variants: three per pizza, four for the cold drink sizes.
  static final List<SeedVariant> variants = <SeedVariant>[
    for (final PizzaSpec pizza in _pizzas) ...<SeedVariant>[
      SeedVariant(
        itemSlug: pizza.slug,
        name: 'Small',
        priceRupees: pizza.small,
        displayOrder: 1,
      ),
      SeedVariant(
        itemSlug: pizza.slug,
        name: 'Medium',
        priceRupees: pizza.medium,
        displayOrder: 2,
      ),
      SeedVariant(
        itemSlug: pizza.slug,
        name: 'Large',
        priceRupees: pizza.large,
        displayOrder: 3,
      ),
    ],
    // "COLD DRINKS ON MRP" prints a price per bottle size, so the sizes are
    // variants of one product rather than four separate products.
    const SeedVariant(
      itemSlug: 'cold-drinks',
      name: '250ml',
      priceRupees: '30',
      displayOrder: 1,
    ),
    const SeedVariant(
      itemSlug: 'cold-drinks',
      name: '500ml',
      priceRupees: '50',
      displayOrder: 2,
    ),
    const SeedVariant(
      itemSlug: 'cold-drinks',
      name: '750ml',
      priceRupees: '80',
      displayOrder: 3,
    ),
    const SeedVariant(
      itemSlug: 'cold-drinks',
      name: '1Ltr',
      priceRupees: '110',
      displayOrder: 4,
    ),
  ];

  /// Crust choices, paid additions and condiments.
  ///
  /// ## Why there are so many rows
  ///
  /// The menu prices most of these per pizza size: Extra Cheese is ₹50 on a Small
  /// and ₹90 on a Large. A row holds one price, so a size-dependent option needs one
  /// row per size it is offered at.
  ///
  /// There is no shared "Small" entity to point at, because a variant row exists per
  /// product and size: a Small Farmfresh and a Small Cheese Pizza are two different
  /// variants. Scoping by `variantId` therefore expands to one row per pizza per
  /// size, which is 170 rows, plus Ketchup as the single global option.
  ///
  /// That is more rows than the menu has printed cells, and it is the honest cost of
  /// expressing the scope as a relationship instead of hiding it in the name. It also
  /// buys real expressiveness: the outlet can charge more for extra paneer on a
  /// premium pizza without any schema change. The trade-off is that a uniform price
  /// rise for one size touches seventeen rows.
  ///
  /// Every row's [SeedOption.name] is the plain customisation, with no size in it.
  static final List<SeedOption> options = <SeedOption>[
    for (final PizzaSpec pizza in _pizzas)
      for (final PizzaOptionSpec spec in _pizzaOptions)
        for (final MapEntry<String, String> priced in spec.pricesBySize.entries)
          SeedOption(
            slug: '${spec.slug}-${pizza.slug}-${priced.key}',
            name: spec.name,
            optionTypeName: spec.optionTypeName,
            priceRupees: priced.value,
            variantItemSlug: pizza.slug,
            variantName: priced.key,
            displayOrder: spec.displayOrder,
          ),

    // Ketchup is printed at a single flat price. It is scoped to food categories
    // so it does not appear on shakes or cold drinks.
    for (final String categorySlug in const <String>[
      'veg-pizza',
      'burger',
      'wraps',
      'taco',
      'sandwich',
      'family-combos',
      'twin-treat-pizza-combo',
      'burger-combo',
      'side-orders',
    ])
      SeedOption(
        slug: 'ketchup-$categorySlug',
        categorySlug: categorySlug,
        name: 'Ketchup',
        optionTypeName: _condiment,
        priceRupees: '10',
        displayOrder: 50,
      ),
  ];

  /// Pizza options and the printed price for each size they are offered at.
  ///
  /// A size absent from [PizzaOptionSpec.pricesBySize] is not offered, which is how
  /// the two missing Large crust prices are represented: the menu does not print
  /// them, so no row exists and no price is invented.
  static const List<PizzaOptionSpec> _pizzaOptions = <PizzaOptionSpec>[
    // CHOICE OF CRUST. Thin Crust prints Small and Medium only.
    PizzaOptionSpec(
      slug: 'thin-crust',
      name: 'Thin Crust',
      optionTypeName: _crust,
      pricesBySize: <String, String>{'Small': '30', 'Medium': '50'},
      displayOrder: 10,
    ),
    // Cheese Burst also prints Small and Medium only. The menu lists it twice, in
    // its own box and again under Choice of Crust, at the same prices.
    PizzaOptionSpec(
      slug: 'cheese-burst',
      name: 'Cheese Burst',
      optionTypeName: _crust,
      pricesBySize: <String, String>{'Small': '80', 'Medium': '90'},
      displayOrder: 20,
    ),
    PizzaOptionSpec(
      slug: 'extra-cheese',
      name: 'Extra Cheese',
      optionTypeName: _addOn,
      pricesBySize: <String, String>{
        'Small': '50',
        'Medium': '70',
        'Large': '90',
      },
      displayOrder: 30,
    ),
    PizzaOptionSpec(
      slug: 'extra-toppings',
      name: 'Extra Toppings',
      optionTypeName: _addOn,
      pricesBySize: <String, String>{
        'Small': '30',
        'Medium': '50',
        'Large': '70',
      },
      displayOrder: 40,
    ),
  ];

  /// Option rows seeded before scope columns existed, identified by their
  /// deterministic ids.
  ///
  /// These carried the size in the name (`Extra Cheese (Small)`) because there was
  /// nowhere else to put it. Migration v4 retires them in favour of the scoped rows
  /// above. Listed here rather than in the migration so the two stay together with
  /// the data they replace.
  static const List<String> retiredUnscopedOptionIds = <String>[
    'opt-thin-crust-small',
    'opt-thin-crust-medium',
    'opt-cheese-burst-small',
    'opt-cheese-burst-medium',
    'opt-extra-cheese-small',
    'opt-extra-cheese-medium',
    'opt-extra-cheese-large',
    'opt-extra-toppings-small',
    'opt-extra-toppings-medium',
    'opt-extra-toppings-large',
  ];

  /// Values printed on the menu that could not be read, or that are genuinely
  /// absent from it. Asserted by a test so the list cannot quietly rot.
  ///
  /// Both entries are absences rather than illegible text: the menu simply does not
  /// print a Large price for either crust upgrade.
  static const List<String> pendingFromMenuImage = <String>[
    'Thin Crust price for a Large pizza. The menu prints Small (30) and Medium '
        '(50) only, so no Large row is seeded.',
    'Cheese Burst price for a Large pizza. The menu prints Small (80) and '
        'Medium (90) only, so no Large row is seeded.',
  ];

  /// True once real products are present.
  static bool get hasProducts => items.isNotEmpty;

  /// The whole menu is vegetarian; the masthead says so.
  static const String _veg = 'veg';

  static const String _crust = 'crust';
  static const String _addOn = 'addOn';
  static const String _condiment = 'condiment';

  /// Pizzas, with the three printed size prices kept together.
  ///
  /// [displayOrder] is banded by the printed sub-section: 10s Simply Veg, 20s Veg
  /// Delight, 30s Veg Treat, 40s Veg Special.
  static const List<PizzaSpec> _pizzas = <PizzaSpec>[
    // ------------------------------------------------------- SIMPLY VEG ---
    PizzaSpec(
      slug: 'cheese-pizza',
      name: 'Cheese Pizza',
      description: 'Single Cheese Topped',
      small: '130',
      medium: '250',
      large: '400',
      displayOrder: 11,
    ),
    PizzaSpec(
      slug: 'cheese-and-tomato',
      name: 'Cheese & Tomato',
      description: 'Tomato Topping Pizza',
      small: '200',
      medium: '310',
      large: '480',
      displayOrder: 12,
    ),
    PizzaSpec(
      slug: 'cheese-and-onion',
      name: 'Cheese & Onion',
      description: 'Onion Topping Pizza',
      small: '200',
      medium: '310',
      large: '480',
      displayOrder: 13,
    ),

    // ------------------------------------------------------ VEG DELIGHT ---
    PizzaSpec(
      slug: 'double-cheese-pizza',
      name: 'Double Cheese Pizza',
      description: 'Loaded with Extra Cheese',
      small: '150',
      medium: '310',
      large: '480',
      displayOrder: 21,
    ),
    PizzaSpec(
      slug: 'garden-fresh',
      name: 'Garden Fresh',
      description: 'Onion, Capsicum, Loaded with Extra Cheese',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 22,
    ),
    // Printed with no description.
    PizzaSpec(
      slug: 'cheese-and-paneer',
      name: 'Cheese & Paneer',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 23,
    ),
    PizzaSpec(
      slug: 'cheese-and-corn',
      name: 'Cheese & Corn',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 24,
    ),

    // -------------------------------------------------------- VEG TREAT ---
    PizzaSpec(
      slug: 'farmfresh',
      name: 'Farmfresh',
      description: 'Onion, Capsicum, Tomato with Grilled Mushroom',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 31,
    ),
    PizzaSpec(
      slug: 'country-feast',
      name: 'Country Feast',
      description: 'Onion, Tomato & Capsicum',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 32,
    ),
    PizzaSpec(
      slug: 'spicy-tango-pizza',
      name: 'Spicy Tango Pizza',
      description: 'Onion, Corn, Jalapeno & Red Paprika',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 33,
    ),
    PizzaSpec(
      slug: 'wonder-pizza',
      name: 'Wonder Pizza',
      description: 'Green Capsicum, Tomato with Mexican Chilli Jalapeno',
      small: '240',
      medium: '370',
      large: '560',
      displayOrder: 34,
    ),

    // ------------------------------------------------------ VEG SPECIAL ---
    PizzaSpec(
      slug: 'spicy-paneer',
      name: 'Spicy Paneer',
      description: 'Capsicum, Spicy Paneer & Red Paprika',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 41,
    ),
    PizzaSpec(
      slug: 'three-peppers',
      name: 'Three Peppers',
      description: 'Capsicum, Red Pepper & Jalapeno',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 42,
    ),
    PizzaSpec(
      slug: 'delicious-pizza',
      name: 'Delicious Pizza',
      description: 'Onion, Capsicum, Potato, Corn, Mushroom & Paneer',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 43,
    ),
    PizzaSpec(
      slug: 'veggie-lovers',
      name: 'Veggie Lovers',
      description: 'Capsicum, Black Olives & Red Paprika',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 44,
    ),
    PizzaSpec(
      slug: 'achari-pizza',
      name: 'Achari Pizza',
      description: 'Double Topping: Corn, Capsicum & Paneer',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 45,
    ),
    PizzaSpec(
      slug: 'tandoori-paneer-pizza',
      name: 'Tandoori Paneer Pizza',
      description: 'Onion, Red & Green Capsicum, Corn',
      small: '270',
      medium: '460',
      large: '700',
      displayOrder: 46,
    ),
  ];

  /// Everything that is not a pizza.
  static const List<SeedMenuItem> _otherItems = <SeedMenuItem>[
    // ----------------------------------------------------------- BURGER ---
    SeedMenuItem(
      slug: 'potato-burger',
      categorySlug: 'burger',
      name: 'Potato Burger',
      itemTypeName: _veg,
      basePriceRupees: '50',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'cheese-burger',
      categorySlug: 'burger',
      name: 'Cheese Burger',
      itemTypeName: _veg,
      basePriceRupees: '60',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'onion-and-capsicum-burger',
      categorySlug: 'burger',
      name: 'Onion & Capsicum Burger',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'corn-topping-burger',
      categorySlug: 'burger',
      name: 'Corn Topping Burger',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'tandoori-sauce-burger',
      categorySlug: 'burger',
      name: 'Tandoori Sauce Burger',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'paneer-burger',
      categorySlug: 'burger',
      name: 'Paneer Burger',
      itemTypeName: _veg,
      basePriceRupees: '100',
      displayOrder: 60,
    ),
    SeedMenuItem(
      slug: 'achari-paneer-burger',
      categorySlug: 'burger',
      name: 'Achari Paneer Burger',
      itemTypeName: _veg,
      basePriceRupees: '110',
      displayOrder: 70,
    ),

    // ------------------------------------------------------------ WRAPS ---
    SeedMenuItem(
      slug: 'veggies-wrap',
      categorySlug: 'wraps',
      name: 'Veggies Wrap',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'paneer-wrap',
      categorySlug: 'wraps',
      name: 'Paneer Wrap',
      itemTypeName: _veg,
      basePriceRupees: '100',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'paneer-makhani-wrap',
      categorySlug: 'wraps',
      name: 'Paneer Makhani Wrap',
      itemTypeName: _veg,
      basePriceRupees: '100',
      displayOrder: 30,
    ),

    // ------------------------------------------------------------- TACO ---
    SeedMenuItem(
      slug: 'taco',
      categorySlug: 'taco',
      name: 'Taco',
      itemTypeName: _veg,
      basePriceRupees: '70',
      displayOrder: 10,
    ),

    // --------------------------------------------------------- SANDWICH ---
    SeedMenuItem(
      slug: 'veggie-sandwich',
      categorySlug: 'sandwich',
      name: 'Veggie Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '60',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'cheese-grilled-sandwich',
      categorySlug: 'sandwich',
      name: 'Cheese Grilled Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '70',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'veggie-corn-sandwich',
      categorySlug: 'sandwich',
      name: 'Veggie Corn Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'paneer-sandwich',
      categorySlug: 'sandwich',
      name: 'Paneer Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'makhani-paneer-sandwich',
      categorySlug: 'sandwich',
      name: 'Makhani Paneer Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'achari-paneer-sandwich',
      categorySlug: 'sandwich',
      name: 'Achari Paneer Sandwich',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 60,
    ),

    // ----------------------------------------------------------- COFFEE ---
    // Cold Coffee is printed under Shakes / Mocktail, not here, and is seeded
    // there to match the menu's own grouping.
    SeedMenuItem(
      slug: 'hot-coffee',
      categorySlug: 'coffee',
      name: 'Hot Coffee',
      itemTypeName: _veg,
      basePriceRupees: '30',
      displayOrder: 10,
    ),

    // ------------------------------------------------- SHAKES / MOCKTAIL ---
    SeedMenuItem(
      slug: 'mint-mojito',
      categorySlug: 'shakes-mocktails',
      name: 'Mint Mojito',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'spicy-mango',
      categorySlug: 'shakes-mocktails',
      name: 'Spicy Mango',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'cold-coffee',
      categorySlug: 'shakes-mocktails',
      name: 'Cold Coffee',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'fruit-shake',
      categorySlug: 'shakes-mocktails',
      name: 'Fruit Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'strawberry-shake',
      categorySlug: 'shakes-mocktails',
      name: 'Strawberry Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'kit-kat-shake',
      categorySlug: 'shakes-mocktails',
      name: 'Kit-Kat Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 60,
    ),
    SeedMenuItem(
      slug: 'chocolate-shake',
      categorySlug: 'shakes-mocktails',
      name: 'Chocolate Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 70,
    ),
    SeedMenuItem(
      slug: 'oreo-shake',
      categorySlug: 'shakes-mocktails',
      name: 'Oreo Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 80,
    ),

    // ---------------------------------------------------- FAMILY COMBOS ---
    // Contents transcribed from the menu and kept as the product description.
    SeedMenuItem(
      slug: 'combo-1',
      categorySlug: 'family-combos',
      name: 'Combo-1',
      itemTypeName: _veg,
      basePriceRupees: '220',
      description:
          'Double Topping Pizza With Extra Cheese + Cheese Burger + '
          'Cold Drinks 250ml',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'combo-2',
      categorySlug: 'family-combos',
      name: 'Combo-2',
      itemTypeName: _veg,
      basePriceRupees: '400',
      description:
          '2 Double Topping Pizza With Extra Cheese + 2 Cheese Burger '
          '+ Cold Drinks 500ml',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'combo-3',
      categorySlug: 'family-combos',
      name: 'Combo-3',
      itemTypeName: _veg,
      basePriceRupees: '650',
      description:
          '1 Medium Pizza + 1 Garlic Bread With Dip + 1 Brisko Parcel '
          '+ 1 Chocolava Cake + Cold Drinks (750ml)',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'happy-family-combo',
      categorySlug: 'family-combos',
      name: 'Happy Family Combo',
      itemTypeName: _veg,
      basePriceRupees: '1100',
      description:
          '2 Medium Pizza + 1 Garlic Bread With Dip + 1 Brisko Parcel '
          '+ 1 French Fries + 1 Chocolava Cake + Pasta + Cold Drinks (1Ltr)',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'set-of-4-single-topping',
      categorySlug: 'family-combos',
      name: 'Set of 4 Single Topping Pizzas',
      itemTypeName: _veg,
      basePriceRupees: '290',
      description: 'Exactly 4 pizzas: Onion, Tomato, Capsicum, Corn',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'set-of-4-double-topping',
      categorySlug: 'family-combos',
      name: 'Set of 4 Double Topping Pizzas',
      itemTypeName: _veg,
      basePriceRupees: '390',
      description: 'Set of 4 Double Topping Pizzas',
      displayOrder: 60,
    ),

    // -------------------------------------------- TWIN TREAT PIZZA COMBO ---
    // The menu prices these as "any" pizza of that size, so the choice is made at
    // the counter rather than fixed here.
    SeedMenuItem(
      slug: 'twin-treat-any-2-medium-pizzas',
      categorySlug: 'twin-treat-pizza-combo',
      name: 'Any 2 Medium Pizzas',
      itemTypeName: _veg,
      basePriceRupees: '700',
      description: 'Any 2 Medium pizzas',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'twin-treat-any-2-large-pizzas',
      categorySlug: 'twin-treat-pizza-combo',
      name: 'Any 2 Large Pizzas',
      itemTypeName: _veg,
      basePriceRupees: '1000',
      description: 'Any 2 Large pizzas',
      displayOrder: 20,
    ),

    // ----------------------------------------------------- BURGER COMBO ---
    SeedMenuItem(
      slug: 'burger-combo-any-2',
      categorySlug: 'burger-combo',
      name: 'Any 2 Any Burger',
      itemTypeName: _veg,
      basePriceRupees: '290',
      description: 'Any 2 Any Burger',
      displayOrder: 10,
    ),

    // ------------------------------------------------------ SIDE ORDERS ---
    SeedMenuItem(
      slug: 'brisko-parcel',
      categorySlug: 'side-orders',
      name: 'Brisko Parcel',
      itemTypeName: _veg,
      basePriceRupees: '50',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'french-fries',
      categorySlug: 'side-orders',
      name: 'French Fries',
      itemTypeName: _veg,
      basePriceRupees: '70',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'peri-peri-french-fries',
      categorySlug: 'side-orders',
      name: 'Peri-Peri French Fries',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'cheese-garlic-bread',
      categorySlug: 'side-orders',
      name: 'Cheese Garlic Bread',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'stuffed-garlic-bread',
      categorySlug: 'side-orders',
      name: 'Stuffed Garlic Bread',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'veg-red-sauce-pasta',
      categorySlug: 'side-orders',
      name: 'Veg Red Sauce Pasta',
      itemTypeName: _veg,
      basePriceRupees: '110',
      displayOrder: 60,
    ),
    SeedMenuItem(
      slug: 'veg-white-sauce-pasta',
      categorySlug: 'side-orders',
      name: 'Veg White Sauce Pasta',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 70,
    ),
    SeedMenuItem(
      slug: 'mix-sauce-pasta',
      categorySlug: 'side-orders',
      name: 'Mix Sauce Pasta',
      itemTypeName: _veg,
      basePriceRupees: '130',
      displayOrder: 80,
    ),
    SeedMenuItem(
      slug: 'makhani-sauce-pasta',
      categorySlug: 'side-orders',
      name: 'Makhani Sauce Pasta',
      itemTypeName: _veg,
      basePriceRupees: '140',
      displayOrder: 90,
    ),
    SeedMenuItem(
      slug: 'veg-calzone-pocket',
      categorySlug: 'side-orders',
      name: 'Veg Calzone Pocket',
      itemTypeName: _veg,
      basePriceRupees: '140',
      displayOrder: 100,
    ),
    SeedMenuItem(
      slug: 'chocolava-cake',
      categorySlug: 'side-orders',
      name: 'Chocolava Cake',
      itemTypeName: _veg,
      basePriceRupees: '60',
      displayOrder: 110,
    ),
    SeedMenuItem(
      slug: 'cheese-dip',
      categorySlug: 'side-orders',
      name: 'Cheese Dip',
      itemTypeName: _veg,
      basePriceRupees: '20',
      displayOrder: 120,
    ),
    SeedMenuItem(
      slug: 'jalapeno-dip',
      categorySlug: 'side-orders',
      name: 'Jalapeno Dip',
      itemTypeName: _veg,
      basePriceRupees: '20',
      displayOrder: 130,
    ),

    // ------------------------------------------------------ COLD DRINKS ---
    // One product with a variant per bottle size. Shakes / Mocktail also lists
    // "Cold Drinks — On MRP" with no price, which is a cross-reference to this
    // section rather than a second product, so it is not duplicated.
    SeedMenuItem(
      slug: 'cold-drinks',
      categorySlug: 'cold-drinks',
      name: 'Cold Drinks',
      itemTypeName: _veg,
      basePriceRupees: '30',
      description: 'Sold at MRP. 250ml, 500ml, 750ml and 1Ltr.',
      displayOrder: 10,
    ),
  ];
}

/// A pizza and its three printed size prices.
///
/// Exists so the sizes are transcribed side by side rather than spread across three
/// separate variant entries, where a mistyped price is far harder to spot.
class PizzaSpec {
  const PizzaSpec({
    required this.slug,
    required this.name,
    required this.small,
    required this.medium,
    required this.large,
    required this.displayOrder,
    this.description,
  });

  final String slug;

  final String name;

  /// Printed price for Small, which serves 1.
  final String small;

  /// Printed price for Medium, which serves 2.
  final String medium;

  /// Printed price for Large, which serves 4.
  final String large;

  final int displayOrder;

  /// Topping list as printed, or `null` where the menu prints none.
  final String? description;
}

/// A category row defined by the seed.
class SeedCategory {
  const SeedCategory({
    required this.slug,
    required this.name,
    required this.displayOrder,
  });

  /// Stable key used to derive the primary key. Never change a shipped slug; it
  /// is the identity of the row.
  final String slug;

  final String name;

  final int displayOrder;

  String get id => EntityId.seeded('cat', slug);
}

/// A product row defined by the seed.
class SeedMenuItem {
  const SeedMenuItem({
    required this.slug,
    required this.categorySlug,
    required this.name,
    required this.itemTypeName,
    required this.basePriceRupees,
    this.description,
    this.displayOrder = 0,
  });

  final String slug;

  final String categorySlug;

  final String name;

  /// Name of a `MenuItemType` value.
  final String itemTypeName;

  /// Price as a decimal string such as `'249'` or `'249.50'`, parsed with
  /// `Money.parse`. A string rather than a number so the source value is recorded
  /// exactly as printed on the menu, with no chance of a float creeping in.
  ///
  /// For a size-priced product this is the smallest size's price, and each size
  /// also gets a variant row.
  final String basePriceRupees;

  final String? description;

  final int displayOrder;

  String get id => EntityId.seeded('item', slug);

  String get categoryId => EntityId.seeded('cat', categorySlug);
}

/// A size variant row defined by the seed.
class SeedVariant {
  const SeedVariant({
    required this.itemSlug,
    required this.name,
    required this.priceRupees,
    required this.displayOrder,
  });

  final String itemSlug;

  /// For example `Small`, `Medium`, `Large`.
  final String name;

  /// Decimal string, as printed on the menu.
  final String priceRupees;

  final int displayOrder;

  String get id => EntityId.seeded('var', '$itemSlug-$name');

  String get menuItemId => EntityId.seeded('item', itemSlug);
}

/// A pizza option together with the printed price for each size it is offered at.
///
/// Expanded by the seed into one [SeedOption] per pizza per priced size. Keeping the
/// prices in one place per option means the four printed cells for Extra Cheese are
/// written once and read as a group, rather than being spread over fifty-one rows
/// where a mistake would be invisible.
class PizzaOptionSpec {
  const PizzaOptionSpec({
    required this.slug,
    required this.name,
    required this.optionTypeName,
    required this.pricesBySize,
    required this.displayOrder,
  });

  final String slug;

  /// The customisation, with no size in it.
  final String name;

  /// Name of a `MenuOptionType` value.
  final String optionTypeName;

  /// Variant name to printed price, for example `{'Small': '50'}`. A size the menu
  /// does not price is simply absent, and no row is created for it.
  final Map<String, String> pricesBySize;

  final int displayOrder;
}

/// A crust, add-on or condiment row defined by the seed.
///
/// At most one of [itemSlug], [variantItemSlug] and [categorySlug] should be set.
/// None set means the option is global.
class SeedOption {
  const SeedOption({
    required this.slug,
    required this.name,
    required this.optionTypeName,
    required this.priceRupees,
    this.itemSlug,
    this.variantItemSlug,
    this.variantName,
    this.categorySlug,
    this.displayOrder = 0,
  }) : assert(
         variantItemSlug == null || variantName != null,
         'A variant-scoped option needs the variant name to resolve its id',
       );

  final String slug;

  /// The customisation, never carrying a size.
  final String name;

  /// Name of a `MenuOptionType` value.
  final String optionTypeName;

  /// Decimal string, as printed on the menu.
  final String priceRupees;

  /// Scopes the option to one product at any size.
  final String? itemSlug;

  /// Product half of the variant this option is priced for.
  final String? variantItemSlug;

  /// Size half of the variant this option is priced for, for example `Medium`.
  final String? variantName;

  /// Scopes the option to every product in one category.
  final String? categorySlug;

  final int displayOrder;

  String get id => EntityId.seeded('opt', slug);

  String? get menuItemId =>
      itemSlug == null ? null : EntityId.seeded('item', itemSlug!);

  /// Derived the same way `SeedVariant.id` is, so the two always agree.
  String? get variantId => variantItemSlug == null
      ? null
      : EntityId.seeded('var', '$variantItemSlug-$variantName');

  String? get categoryId =>
      categorySlug == null ? null : EntityId.seeded('cat', categorySlug!);
}
