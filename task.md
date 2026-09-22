You are working on the existing Brisko Billing Flutter POS application.

I need you to implement the COMPLETE BRISKO PIZZA MENU from the provided menu images into the existing menu/product system.

IMPORTANT:
- Do NOT create a separate hardcoded menu screen.
- Use the existing database/menu-management architecture.
- Menu items must be persisted in the existing local SQLite database and work with the existing billing/order/KOT/receipt/report architecture.
- Do NOT break existing billing, GST, discounts, inventory, printing, cloud sync, order history, reports, or existing UI.
- Do NOT delete existing data.
- Do NOT replace the existing database.
- Do NOT create duplicate menu items if they already exist. Update/migrate existing matching items safely.
- Do NOT leave out even one menu item, price, size, topping, combo, set, addon, or special menu rule from the specification below.
- Preserve the menu names and descriptions as supplied below. Do not "correct" or rename items based on assumptions.

==================================================
1. MENU STRUCTURE
==================================================

The menu must support:

Category
  -> Menu Item
      -> Variant/Size where applicable
      -> Included toppings/components
      -> Allowed customizations/modifiers
      -> Add-ons applicable to that item
      -> Special notes/custom instructions

The existing POS must be able to add an item to an order and then customize it before adding it to the cart.

Customization must be FLEXIBLE.

The cashier should be able to:
- Select any valid available customization for that specific item.
- Remove included toppings/components where applicable.
- Add extra toppings where applicable.
- Add multiple different extra toppings.
- Add the same extra topping multiple times if the existing data model supports quantity-based modifiers.
- Add Extra Cheese where applicable.
- Add Cheese Burst where applicable.
- Add Ketchup where applicable.
- Enter a free-text special instruction/note such as:
  "less spicy"
  "no cheese"
  "cut into 4"
  "make it crispy"
  etc.

However:
- Free-text notes must NOT automatically change the price.
- Only configured priced modifiers/add-ons change the price.
- Do NOT allow pizza-only addons to appear on unrelated products.
- Do NOT show irrelevant customization options globally.

==================================================
2. PIZZA SIZE SYSTEM
==================================================

For pizzas in the VEG PIZZA categories:

Sizes:
- Small
- Medium
- Large

Prices must be stored separately for each size.

The selected size must be part of the order item.

Example:
Farmhouse
Small ₹190
Medium ₹360
Large ₹540

Do NOT create three unrelated products if the existing architecture supports product variants/sizes. Use the existing variant architecture.

==================================================
3. VEG PIZZA
==================================================

CATEGORY: SIMPLY VEG

1. Cheese Pizza
Included topping/component:
- Cheese

Small: ₹130
Medium: ₹250
Large: ₹390

2. Cheese & Tomato
Included toppings:
- Cheese
- Tomato

Small: ₹130
Medium: ₹250
Large: ₹390

3. Cheese & Onion
Included toppings:
- Cheese
- Onion

Small: ₹130
Medium: ₹250
Large: ₹390


CATEGORY: VEG DELIGHT

4. Margherita
Description/included topping:
- Loaded with Extra Cheese

Small: ₹150
Medium: ₹310
Large: ₹460

5. Garden Fresh
Included toppings:
- Onion
- Capsicum
- Extra Cheese

Small: ₹150
Medium: ₹310
Large: ₹460

6. Tangy Corn
Included toppings:
- Jalapeno
- Corn
- Extra Cheese

Small: ₹150
Medium: ₹310
Large: ₹460

7. Cheese & Paneer
Included toppings:
- Paneer
- Cheese

Small: ₹150
Medium: ₹310
Large: ₹460

8. Cheese & Corn
Included toppings:
- Corn
- Extra Cheese

Small: ₹150
Medium: ₹310
Large: ₹460


CATEGORY: VEG TREAT

9. Farmhouse
Included toppings:
- Onion
- Capsicum
- Tomato
- Grilled Mushroom

Small: ₹190
Medium: ₹360
Large: ₹540

10. Country Feast
Included toppings:
- Onion
- Tomato
- Capsicum

Small: ₹190
Medium: ₹360
Large: ₹540

11. Spicy Tango Pizza
Included toppings:
- Golden Corn
- Jalapeno
- Red Pepper

Small: ₹190
Medium: ₹360
Large: ₹540

12. Wonder Pizza
Included toppings:
- Onion
- Capsicum
- Tomato
- Mexican Chilli (Jalapeno)

Small: ₹190
Medium: ₹360
Large: ₹540


CATEGORY: VEG SPECIAL

13. Peppy Paneer
Included toppings:
- Capsicum
- Spicy Paneer
- Red Pepper

Small: ₹240
Medium: ₹410
Large: ₹610

14. Three Peppers
Included toppings:
- Capsicum
- Red Pepper
- Jalapeno

Small: ₹240
Medium: ₹410
Large: ₹610

15. Delicious Pizza
Included toppings:
- Onion
- Capsicum
- Golden Corn
- Mushroom
- Paneer

Small: ₹240
Medium: ₹410
Large: ₹610

16. Veggie Lovers
Included toppings:
- Capsicum
- Black Olives
- Tomato
- Mushroom

Small: ₹240
Medium: ₹410
Large: ₹610

17. Achari Pizza
Included toppings:
- Double Golden Corn
- Capsicum
- Paneer

Small: ₹240
Medium: ₹410
Large: ₹610


CATEGORY: VEG FEAST PIZZA

18. Brisko Special Pizza
Included toppings:
- Onion
- Capsicum
- Fresh Tomato
- Jalapeno
- Golden Corn
- Olive

Small: ₹270
Medium: ₹460
Large: ₹690

19. Cloud One Pizza
Included toppings:
- Onion
- Capsicum
- Tomato
- Jalapeno
- Paneer
- Grilled Mushroom

Small: ₹270
Medium: ₹460
Large: ₹690

20. Chef's Veg Special
Included toppings:
- Red Paprika
- Capsicum
- Mushroom
- Jalapeno
- Paneer
- Golden Corn

Small: ₹270
Medium: ₹460
Large: ₹690

21. Paneer Malai Pizza
Included toppings:
- Corn
- Jalapeno
- Double Paneer
- Capsicum
- Olive

Small: ₹270
Medium: ₹460
Large: ₹690


==================================================
4. SINGLE TOPPING PIZZA
==================================================

CATEGORY: SINGLE TOPPING PIZZA

22. Tomato Pizza
Topping:
- Tomato
Price: ₹80

23. Onion Pizza
Topping:
- Onion
Price: ₹70

24. Capsicum Pizza
Topping:
- Capsicum
Price: ₹80

25. Corn Pizza
Topping:
- Corn
Price: ₹80


==================================================
5. DOUBLE TOPPING PIZZA
==================================================

CATEGORY: DOUBLE TOPPING PIZZA

26. Onion & Capsicum
Toppings:
- Onion
- Capsicum
Price: ₹100

27. Tomato & Corn
Toppings:
- Tomato
- Corn
Price: ₹100

28. Jalapeno & Onion
Toppings:
- Jalapeno
- Onion
Price: ₹100

29. Onion & Paneer
Toppings:
- Onion
- Paneer
Price: ₹110


==================================================
6. PIZZA EXTRA TOPPINGS
==================================================

IMPORTANT:
These are PIZZA-SPECIFIC modifiers.

DO NOT show these automatically for:
- Shake/Mocktail
- Coffee
- Cold Drinks
- Wraps
- Sandwiches
- Burgers
- Taco
- Side Orders
- Family Combos as a whole
- Other unrelated categories

The POS must show the Extra Toppings option only when the selected product supports pizza toppings.

Available Extra Toppings:

- Onion
- Capsicum
- Mushroom
- Tomato
- Sweet Corn
- Olive
- Paneer
- Jalapeno
- Red Paprika

Price per selected extra topping:

Small Pizza:
₹30 each

Medium Pizza:
₹50 each

Large Pizza:
₹70 each

The cashier must first choose WHICH topping they want.

Example:

Medium Farmhouse ₹360

Extra Toppings:
☐ Onion +₹50
☐ Capsicum +₹50
☐ Mushroom +₹50
☐ Tomato +₹50
☐ Sweet Corn +₹50
☐ Olive +₹50
☐ Paneer +₹50
☐ Jalapeno +₹50
☐ Red Paprika +₹50

If customer selects:
- Paneer
- Jalapeno

Then:
Farmhouse Medium = ₹360
Extra Paneer = ₹50
Extra Jalapeno = ₹50

Final = ₹460

Do NOT add every topping automatically.

The selected extra toppings must be stored against the order item so that:
- Cart displays them
- KOT displays them
- Receipt displays them
- Reprint displays them
- Order history displays them
- Reports can retain them
- Inventory deduction can account for them if inventory mapping exists


==================================================
7. EXTRA CHEESE
==================================================

PIZZA-SPECIFIC ADDON.

Do NOT show this globally.

Prices:

Small Pizza:
Extra Cheese = ₹50

Medium Pizza:
Extra Cheese = ₹70

Large Pizza:
Extra Cheese = ₹90


==================================================
8. CHEESE BURST
==================================================

PIZZA-SPECIFIC ADDON.

Do NOT show this for shakes, coffee, burgers, wraps, cold drinks, etc.

Prices:

Small Pizza:
Cheese Burst = ₹50

Medium Pizza:
Cheese Burst = ₹70

Large Pizza:
Cheese Burst = ₹90


==================================================
9. KETCHUP
==================================================

Ketchup is a separate priced add-on.

Price:
₹1 per ketchup.

IMPORTANT:
Do NOT show Ketchup as an addon for every product.

Ketchup must only be available where configured for the relevant food item/order item.

For this menu implementation, configure Ketchup primarily as a PIZZA addon.

It must NOT automatically appear under:
- Shakes
- Mocktails
- Coffee
- Cold Drinks
- Wraps
- Taco
- Sandwich
- Burger
- Side Orders

The cashier can select the quantity of ketchup.

Example:
Ketchup × 1 = ₹1
Ketchup × 2 = ₹2
Ketchup × 3 = ₹3


==================================================
10. FLEXIBLE PIZZA CUSTOMIZATION
==================================================

This is very important.

The customer may ask for different customization combinations.

For a pizza, the customization UI should allow:

Included toppings/components:
- Display clearly.
- Allow removing an included topping when applicable.

Extra toppings:
- Allow selecting any configured extra topping.
- Allow multiple toppings.
- Apply the correct size-based price.

Extra Cheese:
- Available for pizza.

Cheese Burst:
- Available for pizza.

Ketchup:
- Available for pizza according to configuration.

Special instruction:
- Free-text field.

Example:

Medium Farmhouse ₹360

Included:
✓ Onion
✓ Capsicum
✓ Tomato
✓ Grilled Mushroom

Customer says:
"No onion"
"Add paneer"
"Add jalapeno"
"Extra cheese"
"2 ketchup"

POS should record:

Farmhouse - Medium
Base ₹360

Removed:
- Onion

Added:
+ Paneer ₹50
+ Jalapeno ₹50
+ Extra Cheese ₹70
+ Ketchup ×2 ₹2

Special instruction:
"No onion"

Total:
₹532

The exact total should be calculated by the existing pricing engine, not manually hardcoded.

IMPORTANT:
Removing an included topping should normally NOT create a negative discount unless the existing business rules explicitly support that. It simply records the removal.

==================================================
11. WRAPS
==================================================

CATEGORY: WRAPS

30. Veggie Wrap — ₹80
31. Paneer Wrap — ₹80
32. Paneer Makhani Wrap — ₹100

Do NOT show pizza toppings, Extra Cheese, Cheese Burst, or pizza Ketchup customization on wraps unless explicitly configured later.


==================================================
12. TACO
==================================================

CATEGORY: TACO

33. Taco — ₹70

Do NOT show pizza toppings, Extra Cheese or Cheese Burst.


==================================================
13. COFFEE
==================================================

CATEGORY: COFFEE

34. Hot Coffee — ₹30

Do NOT show pizza toppings.
Do NOT show Cheese Burst.
Do NOT show Extra Cheese.
Do NOT show Ketchup.


==================================================
14. SANDWICH
==================================================

CATEGORY: SANDWICH

35. Veggie Sandwich — ₹60
36. Cheese Grilled Sandwich — ₹70
37. Cheese Corn Sandwich — ₹80
38. Paneer Sandwich — ₹80
39. Makhani Paneer Sandwich — ₹90
40. Achari Paneer Sandwich — ₹90

Do NOT show pizza-specific addons.


==================================================
15. BURGER
==================================================

CATEGORY: BURGER

41. Potato Burger — ₹50
42. Cheese Burger — ₹60
43. Onion & Capsicum Burger — ₹80
44. Corn Topping Burger — ₹80
45. Tandoori smoky burger — ₹80
46. Paneer Burger — ₹100
47. Achari Paneer Burger — ₹110

Do NOT show pizza-specific Extra Topping pricing.
Do NOT show Cheese Burst.
Do NOT show pizza Extra Cheese.
Do NOT show pizza Ketchup automatically.

The menu also contains the following general note:
"NO ONION / NO GARLIC PIZZA & BURGER AVAILABLE"

If the existing customization architecture supports it, provide a suitable special instruction/customization option for Burger, but do not invent additional paid burger toppings or prices that are not present in the menu.


==================================================
16. SHAKE / MOCKTAIL
==================================================

CATEGORY: SHAKE / MOCKTAIL

48. Mint Mojito — ₹80
49. Spicy Mango — ₹80
50. Cold Coffee — ₹120
51. Fruit Shake — ₹120
52. Strawberry Shake — ₹120
53. Kit-kat Shake — ₹120
54. Chocolate Shake — ₹120
55. Oreo Shake — ₹120
56. Cold Drinks — On MRP

IMPORTANT:
- Do NOT show pizza toppings.
- Do NOT show Extra Cheese.
- Do NOT show Cheese Burst.
- Do NOT show pizza Ketchup.
- Cold Drinks must retain "On MRP" pricing behavior rather than assuming a fixed price.


==================================================
17. FAMILY COMBOS
==================================================

CATEGORY: FAMILY COMBO

57. COMBO-1 — ₹220

Components:
- Double Topping Pizza
- Extra Cheese Burger
- Cheese Burger
- Cold Drinks (250ml)

IMPORTANT:
Preserve this exact menu description.

58. COMBO-2 — ₹400

Components:
- 2 Double Topping Pizza
- 2 Cheese Burger
- Cold Drinks (500ml)

59. COMBO-3 — ₹650

Components:
- 1 Medium Pizza (Veg Spl.)
- 1 Corn Garlic Bread
- 1 French Fries
- 1 Paneer Burger
- 750ml Cold Drinks

60. HAPPY FAMILY COMBO — ₹1100

Components:
- 2 Medium Pizza
- 1 Garlic Bread with Dip
- 1 Roms Parcel
- 1 French Fries
- 1 Chocolate Cake
- 1 Pasta
- 1 Cold Drinks

IMPORTANT:
Do not silently rename "Roms Parcel". Preserve the supplied menu name.

COMBO CUSTOMIZATION:
Where a combo contains a pizza, the POS should support the existing pizza customization architecture if technically appropriate.

However:
- Do NOT expose unrelated global addons.
- Pizza customization should remain attached to the pizza component.
- Do NOT apply pizza addons automatically to the whole combo.
- Any additional paid customization must be calculated only when explicitly selected and according to configured pricing.


==================================================
18. SET OF 4
==================================================

CATEGORY: SET OF 4

61. SET OF 4 — SINGLE TOPPING PIZZA
Price: ₹290

Available pizza choices:
- Onion
- Tomato
- Capsicum
- Corn

62. SET OF 4 — DOUBLE TOPPING PIZZA
Price: ₹390

Available combinations:
- Onion & Capsicum
- Tomato & Corn
- Onion & Paneer
- Jalapeno & Onion

The POS must allow the cashier to select the required four pizzas/combinations from the allowed list.

Do NOT treat Set of 4 as four normal individually priced pizzas.

The configured Set of 4 price must be used:
- Single Topping Set = ₹290
- Double Topping Set = ₹390

Store the selected components so KOT, receipt and order history can show exactly what was selected.


==================================================
19. SIDE ORDER
==================================================

CATEGORY: SIDE ORDER

63. Zingy Parcel — ₹50
64. French Fries — ₹70
65. Peri-Peri Fries — ₹90
66. Chessy Garlic Bread — ₹90
67. Corn Stuffed Garlic Bread — ₹120
68. Corn + Paneer Stuffed Garlic Bread — ₹130
69. Veg. Red Pasta — ₹110
70. Veg. White Pasta — ₹120
71. Mix Sauce Pasta — ₹130
72. Makhani Pasta — ₹140
73. Veg Calzone Pocket — ₹140
74. Chocolava Cake — ₹80
75. Cheese Dip — ₹25
76. Jalapeno Dip — ₹25

Do NOT show pizza-specific Extra Topping / Cheese Burst / Extra Cheese / Ketchup options on these items unless separately configured later.


==================================================
20. VEGETARIAN / MENU INFORMATION
==================================================

The menu lists these vegetarian ingredients/toppings:

- Onion
- Capsicum
- Mushroom Tomato
- Sweet Corn
- Olive
- Paneer
- Jalapeno
- Red Paprika

Also preserve the menu note:

"NO ONION / NO GARLIC PIZZA & BURGER AVAILABLE"

This should be treated as menu information, not as a separately priced product.


==================================================
21. FRIDAY BOGO
==================================================

The menu has:

BUY ONE GET ONE FREE

"every Friday on Medium Pizza"

Use the existing Friday BOGO implementation/business rule already present in Brisko Billing.

Do NOT replace it with a generic 50% discount.

Rules:
- Applies only on Friday.
- Applies to qualifying Medium Pizza.
- 1 qualifying pizza = 0 free.
- 2 qualifying pizzas = 1 free.
- 3 = 1 free.
- 4 = 2 free.
- 5 = 2 free.
- 6 = 3 free.
- For mixed-price qualifying pizzas, existing BOGO logic should determine the free units according to the already implemented business rule.
- KOT must show every actual pizza ordered.
- Inventory must deduct every actual pizza quantity, including free pizzas.
- Receipt must show the BOGO discount clearly.
- Do not create fake "FREE" menu products.


==================================================
22. MENU DATA MODEL REQUIREMENTS
==================================================

Do not simply hardcode these items in Dart widgets.

Use the existing database/menu architecture.

Each menu item should have, as appropriate:
- Stable ID
- Category
- Name
- Description
- Active/inactive status
- Base price or variants
- Size/variant
- Included toppings/components
- Allowed modifiers
- Modifier prices
- Modifier applicability
- Combo/set components
- MRP pricing where applicable
- Created/updated timestamps
- Existing sync fields required by Brisko

Use existing stable IDs and migration patterns.

If the current database schema already supports:
- menu_items
- variants
- options/modifiers
- combo items
- categories

reuse it instead of creating duplicate tables.

If schema changes are required:
- create a proper migration
- preserve all existing data
- make migration idempotent
- test fresh database and existing database upgrade paths.


==================================================
23. CUSTOMIZATION UI
==================================================

When cashier selects an item, show a clean customization dialog/screen.

For a pizza it could conceptually contain:

Pizza:
Farmhouse

Size:
○ Small ₹190
● Medium ₹360
○ Large ₹540

Included toppings:
✓ Onion
✓ Capsicum
✓ Tomato
✓ Grilled Mushroom

Remove:
[ Onion ] [ Capsicum ] [ Tomato ] [ Grilled Mushroom ]

Extra Toppings:
☐ Onion +₹50
☐ Capsicum +₹50
☐ Mushroom +₹50
☐ Tomato +₹50
☐ Sweet Corn +₹50
☐ Olive +₹50
☐ Paneer +₹50
☐ Jalapeno +₹50
☐ Red Paprika +₹50

Pizza Add-ons:
☐ Extra Cheese +₹70
☐ Cheese Burst +₹70
☐ Ketchup ₹1

Special Instructions:
[________________________]

Add to Cart

IMPORTANT:
The actual UI should follow the existing Brisko design system and not introduce an unrelated redesign.

For non-pizza items, only show modifiers that are explicitly applicable to that item/category.

Example:
Hot Coffee should NOT show:
- Onion
- Paneer
- Jalapeno
- Extra Cheese
- Cheese Burst
- Ketchup

This applicability rule is critical.


==================================================
24. CART / ORDER / KOT / RECEIPT
==================================================

Customized item details must be persisted.

Example cart item:

Farmhouse
Medium
₹360

Included:
Onion
Capsicum
Tomato
Grilled Mushroom

Removed:
Onion

Extra:
Paneer +₹50
Jalapeno +₹50
Extra Cheese +₹70
Ketchup ×2 +₹2

Special note:
Less spicy

Total: ₹532

The same customization information should be available to:
- Cart
- Order
- KOT
- Receipt
- Reprint
- Bill details
- Order history
- Reports where appropriate


==================================================
25. INVENTORY
==================================================

Do not invent inventory quantities.

However, the menu structure must retain enough information to support future inventory mapping.

Where existing inventory mappings exist:
- Base item usage should continue working.
- Included toppings should be represented correctly.
- Extra toppings should deduct their corresponding inventory quantity if the existing inventory system supports the mapping.
- Free BOGO pizzas must still deduct inventory because they are physically prepared.
- Removing an included topping should not deduct that topping.
- Added extra toppings should add the required deduction.

Do not break current inventory behavior.


==================================================
26. SEARCH AND MENU DISPLAY
==================================================

Menu screen must allow:
- Category browsing
- Search by item name
- Search by topping if existing search architecture supports it
- Selecting item
- Selecting size
- Customizing item
- Adding to cart

All 76 menu entries must be available.

Do not silently omit items because of screen size or pagination.

If the menu UI currently displays only a limited number of records, ensure the complete menu can be accessed through proper scrolling/search/category navigation.


==================================================
27. IMPORTANT DATA VALIDATION
==================================================

Before declaring implementation complete, verify programmatically that the seeded menu contains:

21 Veg Pizza items
4 Single Topping Pizza items
4 Double Topping Pizza items
3 Wrap items
1 Taco
1 Coffee
6 Sandwich items
7 Burger items
9 Shake/Mocktail items
4 Family Combo items
2 Set of 4 items
14 Side Order items

Total = 76 menu entries.

Also verify:
- All pizza prices
- All pizza sizes
- All included toppings
- All extra topping names
- All modifier prices
- Ketchup ₹1
- Combo prices
- Set of 4 prices
- Side order prices
- Cold Drinks = On MRP
- Friday BOGO configuration
- No irrelevant addons shown on unrelated categories


==================================================
28. TESTING
==================================================

Create/update automated tests for:

1. All 76 menu entries exist.
2. No duplicate menu item IDs.
3. No duplicate category/item combinations.
4. All pizza size prices are correct.
5. Extra topping price changes correctly by pizza size.
6. Multiple extra toppings calculate correctly.
7. Extra Cheese only appears for applicable pizza items.
8. Cheese Burst only appears for applicable pizza items.
9. Ketchup only appears for configured applicable items.
10. Ketchup quantity × ₹1 calculates correctly.
11. Coffee does not show pizza toppings.
12. Shake/Mocktail does not show pizza toppings.
13. Cold Drinks use MRP behavior.
14. Burger does not show pizza-specific addons.
15. Wrap does not show pizza-specific addons.
16. Side Order does not show pizza-specific addons.
17. Removing an included topping is recorded correctly.
18. Special instruction is persisted.
19. Customized item survives app restart.
20. Customized item appears correctly in order details.
21. Customized item appears correctly in KOT.
22. Customized item appears correctly on receipt.
23. Reprint preserves customization.
24. Set of 4 allows only configured choices.
25. Set of 4 uses ₹290/₹390 fixed configured prices.
26. Combo components are stored correctly.
27. Friday BOGO still works correctly.
28. BOGO inventory behavior remains correct.
29. Existing menu data is not deleted during migration.
30. Existing bills/orders remain intact.

Run:
- flutter analyze
- relevant unit/widget/integration tests
- full existing test suite if practical

Do not ignore existing test failures.


==================================================
29. DO NOT MAKE THESE CHANGES
==================================================

Do NOT:
- redesign the entire application
- change the existing color theme
- change printing architecture
- change printer configuration
- change Firebase/cloud architecture
- migrate the database
- delete existing orders
- delete existing menu data
- reset SQLite
- delete pending sync/outbox records
- change GST logic
- change payment logic
- change authentication
- change manager password implementation
- remove existing functionality
- use mock/static menu data only in the UI

The menu must be real persisted application data.


==================================================
30. FINAL VERIFICATION REPORT
==================================================

After implementation, give me a concise report containing:

1. Number of categories created/updated.
2. Number of menu items created/updated.
3. Confirm total = 76 menu entries.
4. Confirm all 21 Veg Pizza items are present.
5. Confirm all pizza sizes/prices.
6. Confirm all included toppings.
7. Confirm all 9 selectable extra toppings.
8. Confirm Extra Cheese pricing.
9. Confirm Cheese Burst pricing.
10. Confirm Ketchup ₹1.
11. Confirm addons are restricted to applicable items.
12. Confirm all 4 combos.
13. Confirm both Set of 4 options.
14. Confirm all 14 Side Orders.
15. Confirm Friday BOGO remains intact.
16. Confirm tests passed.
17. List any ambiguity or item that could not be implemented exactly from the supplied menu.

MOST IMPORTANT:
Do not tell me "menu implementation is complete" unless every one of the 76 menu entries and all associated pricing/customization rules above have been actually persisted and verified.