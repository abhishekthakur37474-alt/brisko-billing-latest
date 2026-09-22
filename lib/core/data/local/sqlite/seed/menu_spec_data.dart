import 'menu_seed_data.dart';

/// The Brisko Pizza menu exactly as supplied in the client's menu specification.
///
/// ## Provenance
///
/// Every name, price, size, included topping and modifier price below is transcribed
/// from the supplied specification, not from the earlier printed-menu seed in
/// [MenuSeedData]. Where the two disagree, this file is the authority: migration
/// v15 soft-retires the earlier seed rows and writes these instead.
///
/// ## What this file deliberately does not guess
///
/// * A single-price pizza (the Single Topping and Double Topping sections) is stored
///   without size variants, because the specification prints one price for it. No
///   Small/Medium/Large price is invented.
/// * `Cold Drinks` keeps its `On MRP` behaviour by carrying one variant per bottle
///   size rather than a fixed counter price.
/// * The specification's menu notes ("NO ONION / NO GARLIC PIZZA & BURGER
///   AVAILABLE", the vegetarian ingredient list) are information, not priced
///   products, and are therefore not seeded as items.
///
/// ## Size-priced modifiers and why the row count is large
///
/// Extra Toppings, Extra Cheese and Cheese Burst are all priced by pizza size, and a
/// variant row exists per product and size. A topping therefore expands to one row
/// per pizza per size, exactly as the earlier seed's size-dependent options did. The
/// nine selectable toppings turn the pizza panel into many rows; that is the honest
/// cost of storing the relationship instead of encoding a size in a name.
class MenuSpecData {
  const MenuSpecData._();

  static const String _veg = 'veg';
  static const String _addOn = 'addOn';
  static const String _condiment = 'condiment';

  /// The specification's sixteen sections, in printed order.
  static const List<SeedCategory> categories = <SeedCategory>[
    SeedCategory(slug: 'simply-veg', name: 'SIMPLY VEG', displayOrder: 10),
    SeedCategory(slug: 'veg-delight', name: 'VEG DELIGHT', displayOrder: 20),
    SeedCategory(slug: 'veg-treat', name: 'VEG TREAT', displayOrder: 30),
    SeedCategory(slug: 'veg-special', name: 'VEG SPECIAL', displayOrder: 40),
    SeedCategory(
      slug: 'veg-feast-pizza',
      name: 'VEG FEAST PIZZA',
      displayOrder: 50,
    ),
    SeedCategory(
      slug: 'single-topping-pizza',
      name: 'SINGLE TOPPING PIZZA',
      displayOrder: 60,
    ),
    SeedCategory(
      slug: 'double-topping-pizza',
      name: 'DOUBLE TOPPING PIZZA',
      displayOrder: 70,
    ),
    SeedCategory(slug: 'wraps', name: 'WRAPS', displayOrder: 80),
    SeedCategory(slug: 'taco', name: 'TACO', displayOrder: 90),
    SeedCategory(slug: 'coffee', name: 'COFFEE', displayOrder: 100),
    SeedCategory(slug: 'sandwich', name: 'SANDWICH', displayOrder: 110),
    SeedCategory(slug: 'burger', name: 'BURGER', displayOrder: 120),
    SeedCategory(
      slug: 'shake-mocktail',
      name: 'SHAKE / MOCKTAIL',
      displayOrder: 130,
    ),
    SeedCategory(slug: 'family-combo', name: 'FAMILY COMBO', displayOrder: 140),
    SeedCategory(slug: 'set-of-4', name: 'SET OF 4', displayOrder: 150),
    SeedCategory(slug: 'side-order', name: 'SIDE ORDER', displayOrder: 160),
  ];

  /// The pizza categories that carry pizza-only add-ons (ketchup and the priced
  /// extras). Shakes, coffee, wraps, tacos, sandwiches, burgers, combos and side
  /// orders are deliberately absent so no pizza add-on can leak onto them.
  static const List<String> pizzaCategorySlugs = <String>[
    'simply-veg',
    'veg-delight',
    'veg-treat',
    'veg-special',
    'veg-feast-pizza',
    'single-topping-pizza',
    'double-topping-pizza',
  ];

  /// Pizzas whose price depends on the chosen size.
  static const List<SpecPizza> sizePricedPizzas = <SpecPizza>[
    // ---------------------------------------------------------- SIMPLY VEG ---
    SpecPizza(
      slug: 'cheese-pizza',
      categorySlug: 'simply-veg',
      name: 'Cheese Pizza',
      includedToppings: <String>['Cheese'],
      small: '130',
      medium: '250',
      large: '390',
      displayOrder: 11,
    ),
    SpecPizza(
      slug: 'cheese-and-tomato',
      categorySlug: 'simply-veg',
      name: 'Cheese & Tomato',
      includedToppings: <String>['Cheese', 'Tomato'],
      small: '130',
      medium: '250',
      large: '390',
      displayOrder: 12,
    ),
    SpecPizza(
      slug: 'cheese-and-onion',
      categorySlug: 'simply-veg',
      name: 'Cheese & Onion',
      includedToppings: <String>['Cheese', 'Onion'],
      small: '130',
      medium: '250',
      large: '390',
      displayOrder: 13,
    ),

    // --------------------------------------------------------- VEG DELIGHT ---
    SpecPizza(
      slug: 'margherita',
      categorySlug: 'veg-delight',
      name: 'Margherita',
      includedToppings: <String>['Extra Cheese'],
      description: 'Loaded with Extra Cheese',
      small: '150',
      medium: '310',
      large: '460',
      displayOrder: 21,
    ),
    SpecPizza(
      slug: 'garden-fresh',
      categorySlug: 'veg-delight',
      name: 'Garden Fresh',
      includedToppings: <String>['Onion', 'Capsicum', 'Extra Cheese'],
      small: '150',
      medium: '310',
      large: '460',
      displayOrder: 22,
    ),
    SpecPizza(
      slug: 'tangy-corn',
      categorySlug: 'veg-delight',
      name: 'Tangy Corn',
      includedToppings: <String>['Jalapeno', 'Corn', 'Extra Cheese'],
      small: '150',
      medium: '310',
      large: '460',
      displayOrder: 23,
    ),
    SpecPizza(
      slug: 'cheese-and-paneer',
      categorySlug: 'veg-delight',
      name: 'Cheese & Paneer',
      includedToppings: <String>['Paneer', 'Cheese'],
      small: '150',
      medium: '310',
      large: '460',
      displayOrder: 24,
    ),
    SpecPizza(
      slug: 'cheese-and-corn',
      categorySlug: 'veg-delight',
      name: 'Cheese & Corn',
      includedToppings: <String>['Corn', 'Extra Cheese'],
      small: '150',
      medium: '310',
      large: '460',
      displayOrder: 25,
    ),

    // ----------------------------------------------------------- VEG TREAT ---
    SpecPizza(
      slug: 'farmhouse',
      categorySlug: 'veg-treat',
      name: 'Farmhouse',
      includedToppings: <String>[
        'Onion',
        'Capsicum',
        'Tomato',
        'Grilled Mushroom',
      ],
      small: '190',
      medium: '360',
      large: '540',
      displayOrder: 31,
    ),
    SpecPizza(
      slug: 'country-feast',
      categorySlug: 'veg-treat',
      name: 'Country Feast',
      includedToppings: <String>['Onion', 'Tomato', 'Capsicum'],
      small: '190',
      medium: '360',
      large: '540',
      displayOrder: 32,
    ),
    SpecPizza(
      slug: 'spicy-tango-pizza',
      categorySlug: 'veg-treat',
      name: 'Spicy Tango Pizza',
      includedToppings: <String>['Golden Corn', 'Jalapeno', 'Red Pepper'],
      small: '190',
      medium: '360',
      large: '540',
      displayOrder: 33,
    ),
    SpecPizza(
      slug: 'wonder-pizza',
      categorySlug: 'veg-treat',
      name: 'Wonder Pizza',
      includedToppings: <String>[
        'Onion',
        'Capsicum',
        'Tomato',
        'Mexican Chilli (Jalapeno)',
      ],
      small: '190',
      medium: '360',
      large: '540',
      displayOrder: 34,
    ),

    // --------------------------------------------------------- VEG SPECIAL ---
    SpecPizza(
      slug: 'peppy-paneer',
      categorySlug: 'veg-special',
      name: 'Peppy Paneer',
      includedToppings: <String>['Capsicum', 'Spicy Paneer', 'Red Pepper'],
      small: '240',
      medium: '410',
      large: '610',
      displayOrder: 41,
    ),
    SpecPizza(
      slug: 'three-peppers',
      categorySlug: 'veg-special',
      name: 'Three Peppers',
      includedToppings: <String>['Capsicum', 'Red Pepper', 'Jalapeno'],
      small: '240',
      medium: '410',
      large: '610',
      displayOrder: 42,
    ),
    SpecPizza(
      slug: 'delicious-pizza',
      categorySlug: 'veg-special',
      name: 'Delicious Pizza',
      includedToppings: <String>[
        'Onion',
        'Capsicum',
        'Golden Corn',
        'Mushroom',
        'Paneer',
      ],
      small: '240',
      medium: '410',
      large: '610',
      displayOrder: 43,
    ),
    SpecPizza(
      slug: 'veggie-lovers',
      categorySlug: 'veg-special',
      name: 'Veggie Lovers',
      includedToppings: <String>[
        'Capsicum',
        'Black Olives',
        'Tomato',
        'Mushroom',
      ],
      small: '240',
      medium: '410',
      large: '610',
      displayOrder: 44,
    ),
    SpecPizza(
      slug: 'achari-pizza',
      categorySlug: 'veg-special',
      name: 'Achari Pizza',
      includedToppings: <String>[
        'Double Golden Corn',
        'Capsicum',
        'Paneer',
      ],
      small: '240',
      medium: '410',
      large: '610',
      displayOrder: 45,
    ),

    // ---------------------------------------------------- VEG FEAST PIZZA ---
    SpecPizza(
      slug: 'brisko-special-pizza',
      categorySlug: 'veg-feast-pizza',
      name: 'Brisko Special Pizza',
      includedToppings: <String>[
        'Onion',
        'Capsicum',
        'Fresh Tomato',
        'Jalapeno',
        'Golden Corn',
        'Olive',
      ],
      small: '270',
      medium: '460',
      large: '690',
      displayOrder: 51,
    ),
    SpecPizza(
      slug: 'cloud-one-pizza',
      categorySlug: 'veg-feast-pizza',
      name: 'Cloud One Pizza',
      includedToppings: <String>[
        'Onion',
        'Capsicum',
        'Tomato',
        'Jalapeno',
        'Paneer',
        'Grilled Mushroom',
      ],
      small: '270',
      medium: '460',
      large: '690',
      displayOrder: 52,
    ),
    SpecPizza(
      slug: 'chefs-veg-special',
      categorySlug: 'veg-feast-pizza',
      name: "Chef's Veg Special",
      includedToppings: <String>[
        'Red Paprika',
        'Capsicum',
        'Mushroom',
        'Jalapeno',
        'Paneer',
        'Golden Corn',
      ],
      small: '270',
      medium: '460',
      large: '690',
      displayOrder: 53,
    ),
    SpecPizza(
      slug: 'paneer-malai-pizza',
      categorySlug: 'veg-feast-pizza',
      name: 'Paneer Malai Pizza',
      includedToppings: <String>[
        'Corn',
        'Jalapeno',
        'Double Paneer',
        'Capsicum',
        'Olive',
      ],
      small: '270',
      medium: '460',
      large: '690',
      displayOrder: 54,
    ),
  ];

  /// Every product. Pizzas are expanded from [sizePricedPizzas] so the three size
  /// prices are written once, next to each other. [itemDescriptions] carries the
  /// single-price pizzas, combos and note-bearing products onto the same list.
  static final List<SeedMenuItem> items = <SeedMenuItem>[
    for (final SpecPizza pizza in sizePricedPizzas)
      SeedMenuItem(
        slug: pizza.slug,
        categorySlug: pizza.categorySlug,
        name: pizza.name,
        itemTypeName: _veg,
        basePriceRupees: pizza.small,
        description: pizza.descriptionText,
        displayOrder: pizza.displayOrder,
      ),
    ..._otherItems,
  ];

  /// Size variants: three per size-priced pizza, four for the cold drink sizes.
  static final List<SeedVariant> variants = <SeedVariant>[
    for (final SpecPizza pizza in sizePricedPizzas) ...<SeedVariant>[
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
    // Cold Drinks is sold at MRP, so it keeps a variant per bottle size.
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

  /// Pizza-only priced extras, scoped to each pizza's size variant, plus Ketchup
  /// scoped to each pizza category at ₹1.
  static final List<SeedOption> options = <SeedOption>[
    for (final SpecPizza pizza in sizePricedPizzas) ..._optionsFor(pizza),

    // Ketchup is a pizza condiment only. It is deliberately not scoped to shakes,
    // coffee, wraps, tacos, sandwiches, burgers, combos or side orders.
    for (final String categorySlug in pizzaCategorySlugs)
      SeedOption(
        slug: 'ketchup-$categorySlug',
        categorySlug: categorySlug,
        name: 'Ketchup',
        optionTypeName: _condiment,
        priceRupees: '1',
        displayOrder: 60,
      ),
  ];

  /// The nine selectable extra toppings, each priced per pizza size.
  static const List<SpecTopping> extraToppings = <SpecTopping>[
    SpecTopping(slug: 'onion', name: 'Onion', displayOrder: 10),
    SpecTopping(slug: 'capsicum', name: 'Capsicum', displayOrder: 20),
    SpecTopping(slug: 'mushroom', name: 'Mushroom', displayOrder: 30),
    SpecTopping(slug: 'tomato', name: 'Tomato', displayOrder: 40),
    SpecTopping(slug: 'sweet-corn', name: 'Sweet Corn', displayOrder: 50),
    SpecTopping(slug: 'olive', name: 'Olive', displayOrder: 60),
    SpecTopping(slug: 'paneer', name: 'Paneer', displayOrder: 70),
    SpecTopping(slug: 'jalapeno', name: 'Jalapeno', displayOrder: 80),
    SpecTopping(slug: 'red-paprika', name: 'Red Paprika', displayOrder: 90),
  ];

  /// Extra Toppings, Extra Cheese and Cheese Burst, by size.
  static const Map<String, String> extraToppingPrices = <String, String>{
    'Small': '30',
    'Medium': '50',
    'Large': '70',
  };

  static const Map<String, String> extraCheesePrices = <String, String>{
    'Small': '50',
    'Medium': '70',
    'Large': '90',
  };

  static const Map<String, String> cheeseBurstPrices = <String, String>{
    'Small': '50',
    'Medium': '70',
    'Large': '90',
  };

  /// True once the specification menu is present.
  static bool get hasProducts => items.isNotEmpty;

  static List<SeedOption> _optionsFor(SpecPizza pizza) {
    return <SeedOption>[
      for (final MapEntry<String, String> priced
          in extraCheesePrices.entries)
        SeedOption(
          slug: 'extra-cheese-${pizza.slug}-${priced.key}',
          name: 'Extra Cheese',
          optionTypeName: _addOn,
          priceRupees: priced.value,
          variantItemSlug: pizza.slug,
          variantName: priced.key,
          displayOrder: 10,
        ),
      for (final MapEntry<String, String> priced
          in cheeseBurstPrices.entries)
        SeedOption(
          slug: 'cheese-burst-${pizza.slug}-${priced.key}',
          name: 'Cheese Burst',
          optionTypeName: _addOn,
          priceRupees: priced.value,
          variantItemSlug: pizza.slug,
          variantName: priced.key,
          displayOrder: 20,
        ),
      for (final SpecTopping topping in extraToppings)
        for (final MapEntry<String, String> priced
            in extraToppingPrices.entries)
          SeedOption(
            slug: '${topping.slug}-${pizza.slug}-${priced.key}',
            name: topping.name,
            optionTypeName: _addOn,
            priceRupees: priced.value,
            variantItemSlug: pizza.slug,
            variantName: priced.key,
            displayOrder: 30 + topping.displayOrder,
          ),
    ];
  }

  /// Everything that is not a size-priced pizza.
  static const List<SeedMenuItem> _otherItems = <SeedMenuItem>[
    // ---------------------------------------------- SINGLE TOPPING PIZZA ---
    SeedMenuItem(
      slug: 'tomato-pizza',
      categorySlug: 'single-topping-pizza',
      name: 'Tomato Pizza',
      itemTypeName: _veg,
      basePriceRupees: '80',
      description: 'Tomato',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'onion-pizza',
      categorySlug: 'single-topping-pizza',
      name: 'Onion Pizza',
      itemTypeName: _veg,
      basePriceRupees: '70',
      description: 'Onion',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'capsicum-pizza',
      categorySlug: 'single-topping-pizza',
      name: 'Capsicum Pizza',
      itemTypeName: _veg,
      basePriceRupees: '80',
      description: 'Capsicum',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'corn-pizza',
      categorySlug: 'single-topping-pizza',
      name: 'Corn Pizza',
      itemTypeName: _veg,
      basePriceRupees: '80',
      description: 'Corn',
      displayOrder: 40,
    ),

    // ---------------------------------------------- DOUBLE TOPPING PIZZA ---
    SeedMenuItem(
      slug: 'onion-and-capsicum',
      categorySlug: 'double-topping-pizza',
      name: 'Onion & Capsicum',
      itemTypeName: _veg,
      basePriceRupees: '100',
      description: 'Onion, Capsicum',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'tomato-and-corn',
      categorySlug: 'double-topping-pizza',
      name: 'Tomato & Corn',
      itemTypeName: _veg,
      basePriceRupees: '100',
      description: 'Tomato, Corn',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'jalapeno-and-onion',
      categorySlug: 'double-topping-pizza',
      name: 'Jalapeno & Onion',
      itemTypeName: _veg,
      basePriceRupees: '100',
      description: 'Jalapeno, Onion',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'onion-and-paneer',
      categorySlug: 'double-topping-pizza',
      name: 'Onion & Paneer',
      itemTypeName: _veg,
      basePriceRupees: '110',
      description: 'Onion, Paneer',
      displayOrder: 40,
    ),

    // ----------------------------------------------------------- WRAPS ---
    SeedMenuItem(
      slug: 'veggie-wrap',
      categorySlug: 'wraps',
      name: 'Veggie Wrap',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'paneer-wrap',
      categorySlug: 'wraps',
      name: 'Paneer Wrap',
      itemTypeName: _veg,
      basePriceRupees: '80',
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

    // ------------------------------------------------------------ TACO ---
    SeedMenuItem(
      slug: 'taco',
      categorySlug: 'taco',
      name: 'Taco',
      itemTypeName: _veg,
      basePriceRupees: '70',
      displayOrder: 10,
    ),

    // ---------------------------------------------------------- COFFEE ---
    SeedMenuItem(
      slug: 'hot-coffee',
      categorySlug: 'coffee',
      name: 'Hot Coffee',
      itemTypeName: _veg,
      basePriceRupees: '30',
      displayOrder: 10,
    ),

    // -------------------------------------------------------- SANDWICH ---
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
      slug: 'cheese-corn-sandwich',
      categorySlug: 'sandwich',
      name: 'Cheese Corn Sandwich',
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
      slug: 'tandoori-smoky-burger',
      categorySlug: 'burger',
      name: 'Tandoori smoky burger',
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

    // -------------------------------------------------- SHAKE / MOCKTAIL ---
    SeedMenuItem(
      slug: 'mint-mojito',
      categorySlug: 'shake-mocktail',
      name: 'Mint Mojito',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'spicy-mango',
      categorySlug: 'shake-mocktail',
      name: 'Spicy Mango',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'cold-coffee',
      categorySlug: 'shake-mocktail',
      name: 'Cold Coffee',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'fruit-shake',
      categorySlug: 'shake-mocktail',
      name: 'Fruit Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'strawberry-shake',
      categorySlug: 'shake-mocktail',
      name: 'Strawberry Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'kit-kat-shake',
      categorySlug: 'shake-mocktail',
      name: 'Kit-kat Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 60,
    ),
    SeedMenuItem(
      slug: 'chocolate-shake',
      categorySlug: 'shake-mocktail',
      name: 'Chocolate Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 70,
    ),
    SeedMenuItem(
      slug: 'oreo-shake',
      categorySlug: 'shake-mocktail',
      name: 'Oreo Shake',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 80,
    ),
    // On MRP: the base price is the smallest bottle and the four MRP variants hold
    // the actual amounts.
    SeedMenuItem(
      slug: 'cold-drinks',
      categorySlug: 'shake-mocktail',
      name: 'Cold Drinks',
      itemTypeName: _veg,
      basePriceRupees: '30',
      description: 'On MRP. 250ml, 500ml, 750ml and 1Ltr.',
      displayOrder: 90,
    ),

    // ----------------------------------------------------- FAMILY COMBO ---
    SeedMenuItem(
      slug: 'combo-1',
      categorySlug: 'family-combo',
      name: 'COMBO-1',
      itemTypeName: _veg,
      basePriceRupees: '220',
      description:
          'Double Topping Pizza, Extra Cheese Burger, Cheese Burger, '
          'Cold Drinks (250ml)',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'combo-2',
      categorySlug: 'family-combo',
      name: 'COMBO-2',
      itemTypeName: _veg,
      basePriceRupees: '400',
      description:
          '2 Double Topping Pizza, 2 Cheese Burger, Cold Drinks (500ml)',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'combo-3',
      categorySlug: 'family-combo',
      name: 'COMBO-3',
      itemTypeName: _veg,
      basePriceRupees: '650',
      description:
          '1 Medium Pizza (Veg Spl.), 1 Corn Garlic Bread, 1 French Fries, '
          '1 Paneer Burger, 750ml Cold Drinks',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'happy-family-combo',
      categorySlug: 'family-combo',
      name: 'HAPPY FAMILY COMBO',
      itemTypeName: _veg,
      basePriceRupees: '1100',
      description:
          '2 Medium Pizza, 1 Garlic Bread with Dip, 1 Roms Parcel, '
          '1 French Fries, 1 Chocolate Cake, 1 Pasta, 1 Cold Drinks',
      displayOrder: 40,
    ),

    // -------------------------------------------------------- SET OF 4 ---
    SeedMenuItem(
      slug: 'set-of-4-single-topping-pizza',
      categorySlug: 'set-of-4',
      name: 'SET OF 4 \u2014 SINGLE TOPPING PIZZA',
      itemTypeName: _veg,
      basePriceRupees: '290',
      description: 'Choose 4: Onion, Tomato, Capsicum, Corn',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'set-of-4-double-topping-pizza',
      categorySlug: 'set-of-4',
      name: 'SET OF 4 \u2014 DOUBLE TOPPING PIZZA',
      itemTypeName: _veg,
      basePriceRupees: '390',
      description:
          'Choose 4: Onion & Capsicum, Tomato & Corn, Onion & Paneer, '
          'Jalapeno & Onion',
      displayOrder: 20,
    ),

    // -------------------------------------------------------- SIDE ORDER ---
    SeedMenuItem(
      slug: 'zingy-parcel',
      categorySlug: 'side-order',
      name: 'Zingy Parcel',
      itemTypeName: _veg,
      basePriceRupees: '50',
      displayOrder: 10,
    ),
    SeedMenuItem(
      slug: 'french-fries',
      categorySlug: 'side-order',
      name: 'French Fries',
      itemTypeName: _veg,
      basePriceRupees: '70',
      displayOrder: 20,
    ),
    SeedMenuItem(
      slug: 'peri-peri-fries',
      categorySlug: 'side-order',
      name: 'Peri-Peri Fries',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 30,
    ),
    SeedMenuItem(
      slug: 'chessy-garlic-bread',
      categorySlug: 'side-order',
      name: 'Chessy Garlic Bread',
      itemTypeName: _veg,
      basePriceRupees: '90',
      displayOrder: 40,
    ),
    SeedMenuItem(
      slug: 'corn-stuffed-garlic-bread',
      categorySlug: 'side-order',
      name: 'Corn Stuffed Garlic Bread',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 50,
    ),
    SeedMenuItem(
      slug: 'corn-paneer-stuffed-garlic-bread',
      categorySlug: 'side-order',
      name: 'Corn + Paneer Stuffed Garlic Bread',
      itemTypeName: _veg,
      basePriceRupees: '130',
      displayOrder: 60,
    ),
    SeedMenuItem(
      slug: 'veg-red-pasta',
      categorySlug: 'side-order',
      name: 'Veg. Red Pasta',
      itemTypeName: _veg,
      basePriceRupees: '110',
      displayOrder: 70,
    ),
    SeedMenuItem(
      slug: 'veg-white-pasta',
      categorySlug: 'side-order',
      name: 'Veg. White Pasta',
      itemTypeName: _veg,
      basePriceRupees: '120',
      displayOrder: 80,
    ),
    SeedMenuItem(
      slug: 'mix-sauce-pasta',
      categorySlug: 'side-order',
      name: 'Mix Sauce Pasta',
      itemTypeName: _veg,
      basePriceRupees: '130',
      displayOrder: 90,
    ),
    SeedMenuItem(
      slug: 'makhani-pasta',
      categorySlug: 'side-order',
      name: 'Makhani Pasta',
      itemTypeName: _veg,
      basePriceRupees: '140',
      displayOrder: 100,
    ),
    SeedMenuItem(
      slug: 'veg-calzone-pocket',
      categorySlug: 'side-order',
      name: 'Veg Calzone Pocket',
      itemTypeName: _veg,
      basePriceRupees: '140',
      displayOrder: 110,
    ),
    SeedMenuItem(
      slug: 'chocolava-cake',
      categorySlug: 'side-order',
      name: 'Chocolava Cake',
      itemTypeName: _veg,
      basePriceRupees: '80',
      displayOrder: 120,
    ),
    SeedMenuItem(
      slug: 'cheese-dip',
      categorySlug: 'side-order',
      name: 'Cheese Dip',
      itemTypeName: _veg,
      basePriceRupees: '25',
      displayOrder: 130,
    ),
    SeedMenuItem(
      slug: 'jalapeno-dip',
      categorySlug: 'side-order',
      name: 'Jalapeno Dip',
      itemTypeName: _veg,
      basePriceRupees: '25',
      displayOrder: 140,
    ),
  ];
}

/// A pizza whose price depends on the chosen size, with its included toppings.
class SpecPizza {
  const SpecPizza({
    required this.slug,
    required this.categorySlug,
    required this.name,
    required this.includedToppings,
    required this.small,
    required this.medium,
    required this.large,
    required this.displayOrder,
    this.description,
  });

  final String slug;
  final String categorySlug;
  final String name;

  /// The toppings the pizza comes with, as supplied. Stored on the item as its
  /// description so the counter can see what is included.
  final List<String> includedToppings;

  final String small;
  final String medium;
  final String large;
  final int displayOrder;

  /// An override for pizzas whose supplied wording is not just a topping list,
  /// such as Margherita's "Loaded with Extra Cheese".
  final String? description;

  /// The included toppings as the item description.
  String get descriptionText => description ?? includedToppings.join(', ');
}

/// A selectable extra topping, priced by pizza size via [MenuSpecData].
class SpecTopping {
  const SpecTopping({
    required this.slug,
    required this.name,
    required this.displayOrder,
  });

  final String slug;
  final String name;
  final int displayOrder;
}
