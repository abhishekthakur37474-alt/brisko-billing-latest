import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/data/connectivity/connectivity_monitor.dart';
import '../core/data/connectivity/network_probe.dart';
import '../core/data/connectivity/polling_connectivity_monitor.dart';
import '../core/data/local/sqlite/database_factory_initializer.dart';
import '../core/data/local/sqlite/sqlite_database.dart';
import '../core/data/local/sqlite/sqlite_databases_path.dart';
import '../core/data/local/sqlite/sqlite_outbox_store.dart';
import '../core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import '../core/data/remote/firebase/firebase_config.dart';
import '../core/data/remote/firebase/firebase_options.dart';
import '../core/data/remote/remote_store_factory.dart';
import '../core/data/sync/default_sync_coordinator.dart';
import '../core/data/sync/initial_sync_service.dart';
import '../core/data/sync/sync_coordinator.dart';
import '../core/data/sync/sync_endpoint.dart';
import '../core/data/sync/sync_metadata_store.dart';
import '../features/auth/data/auth_session_store.dart';
import '../features/auth/presentation/controllers/auth_controller.dart';
import '../features/billing/data/repositories/sqlite_checkout_repository.dart';
import '../features/billing/data/repositories/sqlite_held_bill_repository.dart';
import '../features/billing/domain/repositories/checkout_repository.dart';
import '../features/billing/domain/repositories/held_bill_repository.dart';
import '../features/customers/data/repositories/sqlite_customer_repository.dart';
import '../features/customers/domain/repositories/customer_repository.dart';
import '../features/expenses/data/repositories/sqlite_expense_repository.dart';
import '../features/expenses/domain/repositories/expense_repository.dart';
import '../features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import '../features/inventory/data/repositories/sqlite_inventory_repository.dart';
import '../features/inventory/data/repositories/sqlite_recipe_repository.dart';
import '../features/inventory/domain/repositories/inventory_deduction_repository.dart';
import '../features/inventory/domain/repositories/inventory_repository.dart';
import '../features/inventory/domain/repositories/recipe_repository.dart';
import '../features/kot/data/repositories/sqlite_kot_repository.dart';
import '../features/kot/domain/repositories/kot_repository.dart';
import '../features/menu/data/repositories/sqlite_menu_repository.dart';
import '../features/menu/domain/repositories/menu_repository.dart';
import '../features/orders/data/repositories/sqlite_order_repository.dart';
import '../features/orders/domain/repositories/order_repository.dart';
import '../features/payments/data/repositories/sqlite_payment_repository.dart';
import '../features/payments/data/repositories/sqlite_refund_repository.dart';
import '../features/payments/domain/repositories/payment_repository.dart';
import '../features/payments/domain/repositories/refund_repository.dart';
import '../features/printing/data/default_print_service.dart';
import '../features/printing/data/escpos/configurable_escpos_encoder.dart';
import '../features/printing/data/printers/configurable_thermal_printer.dart';
import '../features/printing/data/printers/platform_thermal_printer_factory.dart';
import '../features/printing/data/repository_sale_print_document_source.dart';
import '../features/printing/data/settings_business_identity_source.dart';
import '../features/printing/domain/models/print_settings.dart';
import '../features/printing/domain/models/printer_connection_settings.dart';
import '../features/printing/domain/printers/active_printer.dart';
import '../features/printing/domain/printers/thermal_printer.dart';
import '../features/printing/domain/services/active_print_profile.dart';
import '../features/printing/domain/services/print_job_factory.dart';
import '../features/printing/domain/services/print_service.dart';
import '../features/reports/data/repositories/sqlite_sales_report_repository.dart';
import '../features/reports/domain/repositories/sales_report_repository.dart';
import '../features/settings/data/file_till_backup_store.dart';
import '../features/settings/data/repositories/sqlite_settings_repository.dart';
import '../features/settings/data/sqlite_operational_data_wiper.dart';
import '../features/settings/domain/active_pos_settings.dart';
import '../features/settings/domain/models/pos_settings.dart';
import '../features/settings/domain/repositories/settings_repository.dart';
import '../features/settings/domain/services/operational_data_wiper.dart';
import '../features/settings/domain/services/till_backup_store.dart';
import 'sync/cloud_sync_activation.dart';
import 'sync/sync_endpoints.dart';

/// Everything the application needs, constructed once at start-up.
///
/// Repositories are exposed through their abstract types, so nothing downstream can
/// reach the SQLite implementations even by accident.
class AppDependencies {
  const AppDependencies({
    required this.database,
    required this.outbox,
    required this.syncCoordinator,
    required this.connectivityMonitor,
    required this.remoteStoreFactory,
    required this.syncMetadataStore,
    required this.isCloudConfigured,
    required this.authController,
    required this.menuRepository,
    required this.orderRepository,
    required this.checkoutRepository,
    required this.heldBillRepository,
    required this.customerRepository,
    required this.paymentRepository,
    required this.refundRepository,
    required this.inventoryRepository,
    required this.recipeRepository,
    required this.inventoryDeductionRepository,
    required this.kotRepository,
    required this.expenseRepository,
    required this.salesReportRepository,
      required this.settingsRepository,
      required this.operationalDataWiper,
      required this.tillBackupStore,
      required this.activeSettings,
    required this.printer,
    required this.activePrinter,
    required this.activePrintProfile,
    required this.printService,
  });

  final SqliteDatabase database;

  /// Durable upload queue. Reconciled from the local sync state and drained by the
  /// [syncCoordinator] whenever the cloud is reachable.
  final SqliteOutboxStore outbox;

  /// Drives push/pull synchronisation between SQLite and the cloud. Runs entirely
  /// behind the write path, so nothing here can delay a sale. Started only when a
  /// cloud backend is configured; otherwise it exists but does nothing, so the
  /// outbox never fills for a terminal that has no backend to drain to.
  final SyncCoordinator syncCoordinator;

  /// Reports whether the cloud is currently reachable. Drives the sync indicator
  /// and the automatic drain when the link returns.
  final ConnectivityMonitor connectivityMonitor;

  /// Builds a cloud store per collection. Either a real Firebase factory or the
  /// no-op factory that reports the cloud as unreachable.
  final RemoteStoreFactory remoteStoreFactory;

  /// Durable bookmarks for the sync engine: the pull cursor and the last
  /// successful sync time. Read by the Settings cloud section.
  final SyncMetadataStore syncMetadataStore;

  /// True when this build carries a Firebase project, so the cloud is available and the
  /// login gate applies. When false, the terminal runs purely local and the UI says the
  /// cloud is not configured.
  final bool isCloudConfigured;

  /// The terminal's sign-in state and the sign-in/sign-out actions. Gates the application
  /// between the login screen and the till, and switches synchronisation on and off with
  /// the session. On a local-only build it reports itself authenticated so the till opens
  /// straight away.
  final AuthController authController;

  final MenuRepository menuRepository;
  final OrderRepository orderRepository;

  /// Writes a settled bill across the order and payment tables in one transaction.
  /// Separate from [orderRepository] because neither repository alone can make that
  /// write atomic.
  final CheckoutRepository checkoutRepository;

  /// Puts a bill aside at the counter and brings it back. Separate from
  /// [checkoutRepository] because holding a bill commits to nothing: no order number, no
  /// payment, no kitchen slip. See `M007HeldBills`.
  final HeldBillRepository heldBillRepository;

  final CustomerRepository customerRepository;
  final PaymentRepository paymentRepository;

  /// Hands money back on a settled bill, and reads what a bill could have refunded.
  ///
  /// Separate from [paymentRepository] because it is not a write of a payment: deciding a
  /// refund means reading the order's status, the bill's settled tenders and any reversal
  /// already recorded, all inside the transaction that writes the new row. A repository
  /// whose writes are whole-entity upserts cannot make that atomic. See
  /// [RefundRepository].
  final RefundRepository refundRepository;

  final InventoryRepository inventoryRepository;

  /// Links a dish to the stock it consumes. Read by the deduction and edited on the
  /// recipe screen; nothing in billing or printing touches it.
  final RecipeRepository recipeRepository;

  /// Takes a settled bill's ingredients off the shelf.
  ///
  /// Separate from [inventoryRepository] and from [checkoutRepository] because it is
  /// neither: it runs strictly after the money has committed, in its own transaction,
  /// so a shelf that is short can never roll a payment back. See
  /// [InventoryDeductionRepository].
  final InventoryDeductionRepository inventoryDeductionRepository;

  final KotRepository kotRepository;
  
  final ExpenseRepository expenseRepository;

  /// Aggregates over settled bills for the Reports screen.
  ///
  /// Separate from [orderRepository] because a report is a grouped query rather than a
  /// collection of entities: totalling a month by reading its orders into memory would be
  /// the wrong shape of work, and item-wise sales would mean reading every line of every
  /// bill. It is read-only, so no report can alter a bill.
  final SalesReportRepository salesReportRepository;

  final SettingsRepository settingsRepository;

  /// Removes bills, the menu, orders and the rest of the till's working data
  /// without touching the sign-in or the settings table. Backs up first, then
  /// clears SQLite and the cloud restaurant node.
  final OperationalDataWiper operationalDataWiper;

  /// Writes the JSON backup taken before a till wipe, and copies it to Downloads.
  final TillBackupStore tillBackupStore;

  /// The configuration this terminal is running with, read once at start-up.
  ///
  /// Held in memory because settlement needs the default order type at the moment a
  /// screen is built, and a widget cannot await a database read while it builds. The
  /// table stays the source of truth; the Settings screen replaces this after a save
  /// commits, so a change takes effect on the next bill rather than the next launch.
  final ActivePosSettings activeSettings;

  /// The terminal's thermal printer.
  ///
  /// An [UnconfiguredThermalPrinter] in this build, because the 80mm ESC/POS printer
  /// has been chosen but not bought. It reports itself as unavailable and fails every
  /// print with a message naming what would fix it, which means the settled-but-not-
  /// printed path is exercised in production rather than waiting for hardware.
  ///
  /// Swapping in a USB or LAN adapter is a change to this one line.
  final ThermalPrinter printer;

  /// The printer binding the operator can change while the application is running.
  ///
  /// The same object as [printer], deliberately: the print service has to keep sending to
  /// whatever the Settings screen last saved, and holding two printers is how a bill comes
  /// to be sent to the one that was replaced. See [ConfigurableThermalPrinter].
  final ActivePrinter activePrinter;

  /// The layout documents are encoded for, and the one thing about printing the operator
  /// can change while the application is running.
  ///
  /// The same object as the encoder inside [printService], deliberately: a correction
  /// saved on the Settings screen has to reach the encoder that lays out the next bill,
  /// and holding two copies of a column count is how they come to disagree.
  final ActivePrintProfile activePrintProfile;

  /// Builds and prints the paperwork for a settled sale.
  ///
  /// Separate from [printer] because it coordinates reads across four repositories and
  /// reports per-document outcomes, none of which is a printer's business.
  final PrintService printService;

  Future<void> dispose() async {
    authController.dispose();
    // Sync first: stop its timer and connectivity listener before the database it
    // reads is closed underneath it.
    await syncCoordinator.dispose();
    final ConnectivityMonitor monitor = connectivityMonitor;
    if (monitor is PollingConnectivityMonitor) {
      await monitor.dispose();
    }
    await remoteStoreFactory.dispose();
    await printer.dispose();
    await outbox.dispose();
    await database.close();
  }
}

/// Opens the database, runs migrations and builds the dependency graph.
///
/// Start-up is explicit and ordered rather than lazy: the database must be open and
/// migrated before any repository is constructed, and a failure here should surface
/// at launch rather than halfway through a bill.
///
/// Pass [databasePath] to point at a different file, which is what tests use.
Future<AppDependencies> bootstrap({
  String? databasePath,
  FirebaseOptions? firebaseOptions,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Install the SQLite database factory for this platform before anything opens a
  // database. On Windows and Linux sqflite ships no native plugin, so the global
  // `databaseFactory` is null and the first `openDatabase` below would throw
  // "databaseFactory not initialized"; this installs the FFI engine there. On the
  // platforms sqflite covers natively (macOS, iOS, Android) it is a no-op and the
  // native factory is left exactly as it was. Must run before `database.open()`.
  initializeDatabaseFactory();

  // On Windows/Linux the FFI factory would otherwise put the file under the
  // process working directory, which is often not writable on a till (Program
  // Files, a USB, an admin-extracted folder). Reads then succeed and every
  // save fails with "The local database is read-only." Skip when a caller
  // already named a file, which is what tests do.
  if (databasePath == null) {
    await prepareWritableDatabasesPath();
  }

  final SqliteDatabase database = SqliteDatabase();
  await database.open(path: databasePath);

  final SqliteOrderRepository orders = SqliteOrderRepository(
    database: database,
  );
  final SqlitePaymentRepository payments = SqlitePaymentRepository(
    database: database,
  );
  final SqliteKotRepository kots = SqliteKotRepository(database: database);
  final SqliteCustomerRepository customers = SqliteCustomerRepository(
    database: database,
  );
  final SqliteSettingsRepository settings = SqliteSettingsRepository(
    database: database,
  );

  // The stored configuration, read once, before the first frame. A failure here is not
  // fatal: an unreadable settings table means an unconfigured terminal, which prints its
  // own name, claims no GSTIN and lays documents out for the printer's own profile. The
  // Settings screen reads the table again and reports the failure properly.
  final Map<String, String?> stored =
      (await settings.readAll()).valueOrNull ?? const <String, String?>{};

  final ActivePosSettings activeSettings = ActivePosSettings(
    settings: PosSettings.fromStored(stored),
  );

  // The printer the operator has configured, resolved through the transport factory.
  //
  // The platform factory chooses a real transport from the saved settings and the
  // operating system: a CUPS raw queue for a USB printer on macOS, the Windows print
  // spooler (RAW datatype) for a USB printer on Windows, and a TCP socket for a network
  // printer on either. A connection this build cannot serve still resolves to a printer
  // that reports honestly that it cannot be reached, rather than one that pretends to
  // print. Everything above this line is written against `ThermalPrinter`, so this single
  // seam is the whole of the hardware integration.
  final ConfigurableThermalPrinter printer = ConfigurableThermalPrinter(
    factory: PlatformThermalPrinterFactory(),
    settings: PrinterConnectionSettings.fromStored(stored),
  );

  // The encoder holds the profile rather than being handed a fixed one, so that a
  // corrected column count saved on the Settings screen lays out the next bill instead of
  // waiting for a restart. It is both the encoder and the profile the application exposes,
  // which is what stops the two disagreeing.
  final ConfigurableEscPosEncoder encoder =
      ConfigurableEscPosEncoder.forPrinter(
        printer,
        settings: PrintSettings.fromStored(stored, fallback: printer.profile),
      );

  // ---------------------------------------------------------------- cloud sync ---
  //
  // The cloud is optional, and split into two things it was previously conflated with.
  //
  // The Firebase *project* — its id and client-safe Web API key — is application
  // configuration, baked into the build (see FirebaseOptions), not a restaurant setting
  // and never typed into a screen. A build compiled without a project runs purely local:
  // every change is saved to SQLite and queued, exactly the offline-first behaviour the
  // architecture already handles.
  //
  // The *session* is per terminal: obtained by signing in and persisted locally, so the
  // next launch skips the login screen. It is not part of the build. A build that has a
  // project but no persisted session shows the login screen; local billing is unaffected
  // either way.
  final FirebaseOptions effectiveFirebaseOptions =
      firebaseOptions ?? FirebaseOptions.current;
  final bool isCloudConfigured = effectiveFirebaseOptions.isConfigured;

  final AuthSessionStore sessionStore = AuthSessionStore(settings: settings);
  final PersistedSession? persistedSession = isCloudConfigured
      ? sessionStore.fromStored(stored)
      : null;
  final bool isAuthenticated = persistedSession != null;

  // Project id and key from the build; the refresh token from the persisted session, if
  // any. A build with a project but no session yet is "configured" for the cloud but not
  // authenticated: the login screen is shown, and nothing is uploaded until sign-in.
  final FirebaseConfig cloudConfig = effectiveFirebaseOptions.toConfig(
    refreshToken: persistedSession?.refreshToken,
  );

  // Build the whole cloud transport whenever the build has a project, regardless of
  // whether there is a session yet: signing in later adopts a session into the shared
  // FirebaseAuthSession this factory holds, and every store then signs its requests with
  // it. A local-only build gets the no-op factory that reports the cloud unreachable.
  final FirebaseRemoteStoreFactory? firebaseFactory = isCloudConfigured
      ? FirebaseRemoteStoreFactory(config: cloudConfig)
      : null;
  final RemoteStoreFactory remoteFactory =
      firebaseFactory ?? const NoopRemoteStoreFactory();

  final SqliteOutboxStore outbox = SqliteOutboxStore(database: database);
  final SqliteSyncMetadataStore syncMetadata = SqliteSyncMetadataStore(
    database: database,
  );

  // The RTDB host is a constant, so the connectivity probe targets it whenever the
  // build has a project — even before sign-in — so that a sync started on login notices
  // the link straight away. A local-only build has no host and reads as offline.
  final PollingConnectivityMonitor connectivity = PollingConnectivityMonitor(
    probe: HostLookupProbe(
      host: isCloudConfigured ? FirebaseConfig.rtdbHost : null,
    ),
  );

  final List<SyncEndpointBase> endpoints = buildSyncEndpoints(
    database,
    remoteFactory,
    outbox,
  );

  final DefaultSyncCoordinator syncCoordinator = DefaultSyncCoordinator(
    endpoints: endpoints,
    outbox: outbox,
    metadata: syncMetadata,
    connectivity: connectivity,
    // A completed sale writes to SQLite and announces its tables here; the
    // coordinator turns that into a debounced cycle, so the sale reconciles and
    // uploads promptly rather than waiting for the periodic timer.
    tableChanges: database.tableChanges,
  );

  // The one-time restore/bootstrap, in the background so a slow or absent network never
  // delays the first frame. It refuses to run over a database that already holds bills, so
  // it can only ever seed a genuinely empty terminal.
  final InitialSyncService initialSync = InitialSyncService(
    endpoints: endpoints,
    metadata: syncMetadata,
    hasOperationalData: () => _hasOperationalData(database),
  );

  // The seam between "signed in" and "syncing". Present only on a cloud build; a
  // local-only build has nothing to activate.
  final CloudSyncActivation? syncActivation = isCloudConfigured
      ? DefaultCloudSyncActivation(
          connectivity: connectivity,
          coordinator: syncCoordinator,
          initialSync: initialSync,
        )
      : null;

  final AuthController authController = AuthController(
    isCloudEnabled: isCloudConfigured,
    initiallyAuthenticated: isAuthenticated,
    initialEmail: persistedSession?.email,
    authClient: firebaseFactory?.authClient,
    session: firebaseFactory?.session,
    sessionStore: sessionStore,
    syncActivation: syncActivation,
  );

  // Only start the engine when the terminal is already signed in. An unauthenticated
  // terminal shows the login screen and syncs nothing; signing in switches it on through
  // the activation above.
  if (isAuthenticated) {
    await syncActivation!.enable();
  }

  return AppDependencies(
    database: database,
    outbox: outbox,
    syncCoordinator: syncCoordinator,
    connectivityMonitor: connectivity,
    remoteStoreFactory: remoteFactory,
    syncMetadataStore: syncMetadata,
    isCloudConfigured: isCloudConfigured,
    authController: authController,
    menuRepository: SqliteMenuRepository(database: database),
    orderRepository: orders,
    checkoutRepository: SqliteCheckoutRepository(database: database),
    heldBillRepository: SqliteHeldBillRepository(database: database),
    customerRepository: customers,
    paymentRepository: payments,
    refundRepository: SqliteRefundRepository(database: database),
    inventoryRepository: SqliteInventoryRepository(database: database),
    recipeRepository: SqliteRecipeRepository(database: database),
    inventoryDeductionRepository: SqliteInventoryDeductionRepository(
      database: database,
    ),
    kotRepository: kots,
    expenseRepository: SqliteExpenseRepository(database: database),
    salesReportRepository: SqliteSalesReportRepository(database: database),
    settingsRepository: settings,
    operationalDataWiper: SqliteOperationalDataWiper(
      database: database,
      outbox: outbox,
      settings: settings,
      backups: FileTillBackupStore(),
      rtdb: firebaseFactory?.restClient,
      syncCoordinator: syncCoordinator,
    ),
    tillBackupStore: FileTillBackupStore(),
    activeSettings: activeSettings,
    printer: printer,
    activePrinter: printer,
    activePrintProfile: encoder,
    printService: DefaultPrintService(
      printer: printer,
      // The encoder starts from the printer's own profile, so the layout the documents
      // are encoded for is by construction the layout of the printer they are sent to.
      // When a real 80mm device turns out to print a different number of columns, the
      // correction is saved in Settings and every document narrows with it.
      jobs: PrintJobFactory(encoder: encoder),
      documents: RepositorySalePrintDocumentSource(
        orders: orders,
        payments: payments,
        kots: kots,
        customers: customers,
        // Business details, GSTIN and the UPI address all come from settings. None of
        // them has a hard-coded value anywhere in the printing layer. The customer bill
        // is text only: no outlet logo is loaded or printed.
        identity: SettingsBusinessIdentitySource(settings: settings),
      ),
    ),
  );
}

/// True when the terminal already holds real, operator-created records.
///
/// The initial cloud restore is only safe over a database that has none, so this
/// checks the transactional tables — bills, payments, customers and the rest — and
/// deliberately ignores the seeded menu, which every fresh install carries. A
/// single non-empty table is enough to conclude the terminal is in use, so the
/// scan stops at the first row it finds.
Future<bool> _hasOperationalData(SqliteDatabase database) async {
  for (final String table in operationalTables) {
    final List<Map<String, Object?>> rows = await database.database.rawQuery(
      'SELECT 1 FROM $table LIMIT 1',
    );
    if (rows.isNotEmpty) {
      return true;
    }
  }
  return false;
}
