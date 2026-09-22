# Brisko Billing

Point of sale and billing application for a single Brisko Pizza outlet. One billing terminal, primarily online, fully capable of taking bills, payments, KOTs and receipts while offline.

Local SQLite is the source of truth for writes. Cloud backup is optional and never blocks a sale.

---

## Overview

| | |
|---|---|
| Product | Brisko Billing |
| Package | `brisko_billing` |
| Version | `1.0.0+1` |
| Type | Flutter desktop / tablet POS |
| Currency | INR (paise as integer; displayed as ₹) |
| Primary target | Windows 10/11 x64 counter terminal |
| Also compiled for | macOS, Linux, Android, iOS, Web |
| Cloud | Optional Firebase (Realtime Database + Auth over HTTPS REST) |
| Printer | 80mm ESC/POS thermal (TVS RP 3200 Lite USB, or LAN) |

---

## Tech stack

### Language and UI

- **Dart** SDK `^3.13.3`
- **Flutter** (Material 3, light theme pinned for a bright till)
- **cupertino_icons** for icon glyphs

### State and architecture

- **provider** `6.1.5+1` — `ChangeNotifier` controllers; widgets raise intent only
- Feature-first folders under `lib/features/<feature>/`
- Thin layered split inside each feature: `domain/` (models + repository contracts) → `data/` (SQLite) → `presentation/` (screens, widgets, controllers)
- Repositories return `Result<T>` rather than throwing
- Dependencies wired once in `lib/app/brisko_app.dart`; constructed in `lib/app/bootstrap.dart` before the first frame

### Local storage

- **sqflite** `2.4.4` — SQLite on Android, iOS, macOS
- **sqflite_common_ffi** `2.4.3` — FFI engine on Windows and Linux (`databaseFactoryFfi`)
- **path** `1.9.1` — database file path
- Schema lives in `lib/core/data/local/sqlite/` with numbered migrations `m001`–`m012`
- Money is integer **paise**; rates are integer **basis points**; stock is integer **milli**-units. `double` is never used for money.

### Printing

- Custom ESC/POS encoder (no third-party print SDK)
- **win32** `^5.5.4` + **ffi** `^2.1.0` — Windows print spooler, RAW datatype
- **CUPS** (`lp -o raw`) — USB on macOS
- **TCP socket** — network printers on every platform

### Cloud (optional)

- No FlutterFire / native Firebase plugins
- Thin `dart:io` HTTPS clients for Firebase Authentication and Realtime Database REST
- **crypto** `^3.0.7` — hashing used on the client
- Project id and Web API key baked at build time via `--dart-define`
- Session is a refresh token persisted locally; password is never stored

### Tooling

- **flutter_lints** `^6.0.0` with strict casts, strict raw types, `always_declare_return_types` and `avoid_print` as errors
- Tests under `test/` (feature screens, core, integration, Windows runtime verification)

### Platforms in the repo

`android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` — Flutter multi-platform scaffolding. Production packaging documented for Windows (`WINDOWS_BUILD.md`).

---

## Architecture

```
lib/
  main.dart                  entry: bootstrap then runApp
  app/                       root widget, routes, shell, sync wiring
  core/                      infrastructure shared by features
    constants/ theme/ error/ money/ utils/
    data/
      local/sqlite/          the only place SQL lives
      remote/firebase/       REST Auth + Realtime Database, or no-op
      sync/                  outbox, coordinator, initial restore
      connectivity/          host-lookup probe
  features/<feature>/
    domain/models/
    domain/repositories/     abstract contract
    data/repositories/       SQLite implementation
    presentation/screens/
  shared/widgets/
```

### Offline-first write path

1. Billing writes to SQLite.
2. Every write also appends a durable **outbox** row.
3. A **sync coordinator** pushes the outbox then pulls, last-write-wins on `updatedAt`.
4. Soft delete (`isDeleted`) so an offline removal can still be sent to the cloud.

Billing never waits on or asks about the network.

### Money and history

- `Money` is an exact integer count of paise.
- Tax/discount rounding happens in one place: `Money.applyRate` (half away from zero).
- Order lines, line options and KOT lines store **name and price snapshots** at sale time. Repricing the menu cannot change a printed bill.

---

## Navigation model

Top-level areas are **not** routes. They swap inside a persistent `PosShell` so the navigation frame never rebuilds.

### Shell sections (`PosSection`)

| Section | Nav label | Screen |
|---|---|---|
| Dashboard | Dashboard | `DashboardScreen` |
| Billing | New Bill | `BillingScreen` |
| Orders | Orders | `KitchenScreen` (live kitchen board) |
| Menu | Menu | `MenuScreen` |
| Inventory | Inventory | `InventoryScreen` |
| Customers | Customers | `CustomersScreen` |
| Reports | Reports | `ReportsScreen` |
| Expenses | Expenses | `ExpensesScreen` |
| Settings | Settings | `SettingsScreen` |

Wide layout (`>= 900` px): `NavigationRail`. Narrow: bottom bar (Dashboard / New Bill / Orders) plus a **More** sheet for the rest.

App bar shows the configured outlet name, the active section, and a read-only **sync status** indicator.

### Pushed routes (`AppRoutes`)

These open full-screen over the shell so the cashier can step back without committing.

| Route | Screen | Opened from |
|---|---|---|
| `/` | `AuthGate` → login or shell | App entry |
| `/checkout` | `CheckoutScreen` | Billing cart, settle |
| `/held-bills` | `HeldBillsScreen` | Billing cart, held bills |
| `/order-history` | `OrderHistoryScreen` | Dashboard |

Unknown routes show a navigation-error scaffold.

### Auth gate

- Cloud build with no session → `LoginScreen`
- Cloud build with a persisted session, even offline → `PosShell`
- Local-only build (no Firebase dart-defines) → till opens immediately, no login

---

## Pages and what each does

### 1. Login (`LoginScreen`)

Cloud-connected terminals only.

- Email + password for the restaurant's Firebase user (one restaurant = one Auth user).
- No sign-up, no password reset, no account switcher.
- Password is held only long enough to submit; exchanged for a refresh token; never stored or logged.
- On success, cloud sync starts in the background.

### 2. Dashboard (`DashboardScreen`)

Shift "Today" board. Not analytics: labelled numbers, no charts.

- Period chips (today / week / etc.) using the same aggregations as Reports.
- Sales summary: discount, GST, refunds, net sales — identical figures to Reports.
- Payment mix, top items, recent bills.
- Low-stock callouts from inventory.
- Tap a bill → stored-document view (`BillDetailView`): reprint, refund, read historical prices.
- Shortcut into **Order history**.

### 3. New Bill (`BillingScreen`)

Order entry only. Settlement is a separate route.

- Three panes on a counter display: category list, item grid, cart.
- Choosing an item opens `ItemConfigurationPanel` in place (size + options) with the cart still visible.
- Narrow screens: category chips + a cart summary bar.
- Cart is **app-scoped** (`BillingController` above the shell) so glancing at Orders does not throw away a half-built bill.
- Returning to Billing reloads the menu so Menu-management edits appear; the cart survives.
- Ends at the subtotal. Charge / hold / cancel live on the cart actions.

### 4. Checkout (`CheckoutScreen`) — route `/checkout`

Linear settlement over the billing shell. Cart is snapshotted at push time and is immutable in this flow.

Steps:

1. **Review** — order type (Dine-in / Takeaway / Delivery / Online manual), customer phone, discount, GST line.
2. **Payment** — Cash / UPI / Card / Other; cash shows change due.
3. **Confirm** — last check before the write.
4. **Success** — sale committed; live cart cleared only after the write.

On commit, in order:

- Atomic write of order + payments (`CheckoutRepository`).
- Inventory deduction **after** money commits (a short shelf cannot roll back payment).
- Print kitchen slip (KOT) and customer receipt.
- Outbox enqueue for cloud.

GST rate and default order type are read once from in-memory settings so they cannot move mid-settlement. Rate is stamped onto the order.

### 5. Held bills (`HeldBillsScreen`) — route `/held-bills`

Park and resume unpaid carts.

- Hold commits nothing: no order number, no payment, no KOT.
- Resume replaces the live cart; disabled while a cart is already on screen.
- Cancel records the held bill as cancelled.
- Held bills are **not** synced to the cloud (terminal working state, not a sale).

### 6. Orders / Kitchen (`KitchenScreen`)

The live kitchen board. Bill history is a different screen.

- Tickets from persisted KOT rows. Empty board if nothing is outstanding.
- Forward-only statuses: pending → preparing → ready.
- Payment state is independent of food state (a paid order can still be in the oven).
- Printing a slip does **not** move status (paper is a copy of the board).
- `completed` / `cancelled` are set by order-level actions, not from this board.
- Refresh on visit and on demand. One terminal owns these rows.

### 7. Order history (`OrderHistoryScreen`) — route `/order-history`

Find a settled bill after it left the kitchen board.

- Search by order number, customer phone, date range, order type, or any combination.
- Results are settled bills with the same figures Reports uses.
- Open a bill → same `BillDetailView` as Dashboard / Reports / Customer history: reprint receipt, reprint KOT, refund, historical prices.

### 8. Menu (`MenuScreen`)

Maintenance of what the outlet sells. Four tabs, one controller:

| Tab | Edits |
|---|---|
| Categories | Groups (Pizza, Combos, …) |
| Items | Products |
| Sizes | Variants (Small / Medium / Large prices) |
| Options | Extra cheese, toppings, ketchup, scoped by variant / item / category / global |

- Seeded on first install from the printed Brisko Pizza menu (12 categories, 64 products, 55 size variants, 171 option rows).
- Turning an item off hides it from billing; past sales and recipes stay.
- A new price applies only to bills from now on.

Option scope (narrowest wins):

| Scope | Applies to |
|---|---|
| `variantId` | one size of one product |
| `menuItemId` | one product, any size |
| `categoryId` | every product in a category |
| none | every product |

Billing calls `MenuRepository.loadOptionsForVariant` and never reads those columns itself.

### 9. Inventory (`InventoryScreen`)

Two halves behind one nav entry.

**Stock**

- On-hand quantities, units, adjustments, deliveries, wastage.
- Movement history.
- Auto-deducted from recipes when a bill settles (after payment).

**Recipes**

- Each dish → ingredients and quantities.
- Set up once; corrected rarely.

A fresh install shows empty stock and empty recipes.

### 10. Customers (`CustomersScreen`)

Phone-keyed directory plus history.

- Search by number; totals, last visit, bills newest first.
- Customers are created only by settling a bill with a phone — no "Add customer" (a customer with no bill is a record of nothing).
- Wide: list + history panes. Narrow: list, then history over it.
- Opening a bill uses stored line snapshots, not today's menu.

### 11. Reports (`ReportsScreen`)

Read-only aggregations over **settled** bills in local SQLite. Works offline.

Date filter (today / yesterday / week / custom) above four tabs:

| Tab | Answers |
|---|---|
| Sales summary | What came in (gross, discount, GST, refunds, net) |
| Bills | Which bills made it up |
| Item sales | What sold (from snapshots, not the live menu) |
| Payment breakdown | Cash / UPI / Card / Other mix |

Tapping a bill opens the same stored-document view used everywhere else.

### 12. Expenses (`ExpensesScreen`)

Outlet costs vs today's sales.

- Today's sales, expenses, and profit (sales − expenses).
- Add expense (name, amount, optional note).
- Delete today's expense rows.
- Local `expenses` table; synced to Realtime Database with the rest of operational data.

### 13. Settings (`SettingsScreen`)

Outlet and terminal configuration. Two controllers: outlet document vs printer device.

**Business information** — name, address, phone, GSTIN (15-character check). Printed on receipts. Blank fields are omitted, not invented. Default heading if name is blank: Brisko Pizza.

**GST** — selectable combined slab. Applies to **new** bills only. Receipt splits as CGST + SGST. Zero rate prints no tax line.

**POS behaviour** — default order type when checkout opens (cashier can still pick any of the four).

**Receipt** — header, footer, feedback/review URL (prints a Rate-us QR if set), UPI VPA + payee name (prints a pay QR if VPA is set).

**Printing layout** — font A/B, column override, cut mode, paper width. Changes encoder bytes, not the device.

**Printer setup** (printing module) — enable printing, USB vs network, Windows/CUPS device name or IP:port, paper 80mm, **Test print**. Saved separately so a printer fix does not commit half-typed business fields.

**Cloud sync** — status, last successful sync, manual sync. No-op on local-only builds.

**Account** — signed-in email and sign-out. Hidden on local-only builds.

---

## Features without their own nav entry

These are modules used by the screens above.

| Feature | Role |
|---|---|
| `orders` | Settled order entities, types, bill detail / reprint / refund UI |
| `payments` | Tenders and refunds. Refund is its own repository (atomic guard + write; original payment never rewritten) |
| `printing` | ESC/POS encode, transports, print service (KOT + receipt after sale) |
| `cloud_sync` | Shell indicator and Settings cloud section |
| `auth` | Session store, login, auth gate, account section |

### Payments

Methods: **Cash**, **UPI**, **Card**, **Other**. Non-cash can carry an external reference.

Refunds:

- Full remainder of a settled single-tender bill.
- Idempotent on the same request id.
- Does not rewrite the original payment, lines, customer, or KOT.

### Printing after a sale

On successful checkout the print service builds:

1. Kitchen slip (KOT) with item/option snapshots.
2. Customer receipt: logo (`assets/images/brisko_logo.png`) if bundled, business identity, GSTIN, lines, GST split, tenders, optional feedback QR and UPI QR.

Sale is saved even if printing fails; reprint from bill detail.

---

## Integrations

### 1. SQLite (always on)

Local database is the write source of truth.

Tables include: `categories`, `menu_items`, `menu_item_variants`, `menu_item_options`, `orders`, `order_items`, `order_item_options`, `payments`, `refunds`, `customers`, `inventory_items`, `stock_movements`, `recipe_ingredients`, `order_inventory_deductions`, `kot_records`, `kot_items`, `kot_item_options`, `held_bills`, `held_bill_lines`, `held_bill_line_options`, `settings`, `expenses`, `outbox`, `sync_metadata`.

Migrations: initial schema, menu seed, scoped options, KOT snapshots, recipes and stock deduction, held bills, refunds, bill tax/discount, cloud sync metadata, extra combos seed, expenses and cancellation.

### 2. Firebase (optional cloud backup)

Enabled only when the build is compiled with:

```
--dart-define=BRISKO_FIREBASE_PROJECT_ID=<id>
--dart-define=BRISKO_FIREBASE_API_KEY=<web-api-key>
```

Without those, the app is fully local: no login, no upload.

| Piece | How |
|---|---|
| Auth | Email/password over Firebase Auth REST. Session = refresh token in settings table |
| Data | Realtime Database REST. One node per SQLite entity, keyed by device-generated id |
| Isolation | `restaurants/{uid}/…` — restaurant id **is** the Auth uid. Rules deny everything else |
| Connectivity | DNS probe of `brisko-billing-default-rtdb.asia-southeast1.firebasedatabase.app` |
| Sync | Push outbox, then pull; last-write-wins on `updatedAt` |
| Restore | Initial sync only on a terminal with no operational rows (no bills yet) |

Synced collections (dependency order): categories, menu items, variants, options, inventory items, recipe ingredients, customers, orders, order items, order item options, payments, refunds, stock movements, order inventory deductions, KOT records/items/options, expenses.

Manager password is a singleton RTDB node (`restaurants/{uid}/managerPassword`), written and read directly — not through the outbox, and never stored in Firestore.

**Not synced:** held bills, printer state, outlet settings (except the manager-password hash, which is RTDB-only).

Project config in-repo: `.firebaserc` (`brisko-billing`), `firebase.json`, `firebase/database.rules.json`, `firebase/README.md`.

### 3. Thermal printers

| Connection | Platform | Transport |
|---|---|---|
| USB | Windows | Win32 spooler, RAW datatype |
| USB | macOS | CUPS `lp -o raw` |
| USB | other | Reported as not installed |
| Network | all | TCP socket (default port 9100) |
| None | all | `UnconfiguredThermalPrinter` — sale still commits |

Designed around **TVS Electronics RP 3200 Lite**, 80mm USB. Layout is ESC/POS bytes generated in-app.

### 4. UPI (display / print only)

No payment-gateway SDK. If Settings has a VPA, receipts (and checkout) can show a QR that pays that address. Settlement is recorded as method `upi` after the cashier confirms the customer paid.

### 5. Feedback / reviews

Optional URL in Settings. Paid receipts print a "Scan to share your feedback" QR. No Google/review API.

### 6. Aggregators

No Swiggy/Zomato API. Aggregator tickets are typed in as order type **Online (manual)** so reports can split direct vs aggregator revenue.

### 7. Assets

- `assets/images/brisko_logo.png` — receipt header logo, decoded once at bootstrap to a monochrome bitmap.

---

## Data rules that affect the UI

- **Local first.** Cloud is backup. Replacing a PC: sign in on a fresh terminal to restore (only if that terminal has no bills yet).
- **Snapshots.** Historical bills never recompute from the current menu.
- **Soft delete.** History stays auditable; offline deletes can still sync.
- **GST.** Combined rate chosen in Settings; printed as CGST + SGST; stamped on the order at settlement.
- **Inventory after money.** Deduction cannot void a payment.
- **KOT vs payment.** Kitchen status is food, not money.

---

## Order types and payment methods

**Order types:** Dine-in, Takeaway, Delivery, Online (manual).

**Payment methods:** Cash, UPI, Card, Other.

**KOT statuses (active on the board):** pending, preparing, ready.

---

## Build and run

```
flutter pub get
flutter analyze
flutter test
```

Local-only (no login):

```
flutter run
flutter build windows --release
```

Cloud-connected:

```
flutter build windows --release ^
  --dart-define=BRISKO_FIREBASE_PROJECT_ID=<project-id> ^
  --dart-define=BRISKO_FIREBASE_API_KEY=<web-api-key>
```

Windows packaging: `windows/packaging/package_release.ps1` → `dist/Brisko-Billing-Windows-x64-Release.zip`.

Operator docs: `OPERATOR_GUIDE.md`. Client install: `CLIENT_SETUP.md`. Cloud setup: `firebase/README.md`.

---

## Project layout (top level)

```
lib/                 application code
test/                unit / widget / integration tests
assets/images/       receipt logo
firebase/            Realtime Database rules and cloud README
android ios linux macos windows web/   platform runners
dist/                Windows release output (when packaged)
pubspec.yaml
README.md
CLIENT_SETUP.md
OPERATOR_GUIDE.md
WINDOWS_BUILD.md
```
