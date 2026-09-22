import 'package:brisko_billing/app/bootstrap.dart';
import 'package:brisko_billing/app/sync/sync_endpoints.dart';
import 'package:brisko_billing/core/data/connectivity/network_probe.dart';
import 'package:brisko_billing/core/data/connectivity/polling_connectivity_monitor.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_outbox_store.dart';
import 'package:brisko_billing/core/data/local/sqlite/sqlite_sync_metadata_store.dart';
import 'package:brisko_billing/core/data/remote/remote_store_factory.dart';
import 'package:brisko_billing/core/data/sync/default_sync_coordinator.dart';
import 'package:brisko_billing/core/data/sync/sync_endpoint.dart';
import 'package:brisko_billing/features/auth/data/auth_session_store.dart';
import 'package:brisko_billing/features/auth/presentation/controllers/auth_controller.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_checkout_repository.dart';
import 'package:brisko_billing/features/billing/data/repositories/sqlite_held_bill_repository.dart';
import 'package:brisko_billing/features/billing/domain/repositories/held_bill_repository.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/expenses/data/repositories/sqlite_expense_repository.dart';
import 'package:brisko_billing/features/expenses/domain/repositories/expense_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_deduction_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_inventory_repository.dart';
import 'package:brisko_billing/features/inventory/data/repositories/sqlite_recipe_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/menu/data/repositories/sqlite_menu_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_refund_repository.dart';
import 'package:brisko_billing/features/payments/domain/repositories/refund_repository.dart';
import 'package:brisko_billing/features/printing/data/escpos/configurable_escpos_encoder.dart';
import 'package:brisko_billing/features/printing/data/printers/configurable_thermal_printer.dart';
import 'package:brisko_billing/features/printing/data/printers/no_transport_printer_factory.dart';
import 'package:brisko_billing/features/printing/domain/models/print_settings.dart';
import 'package:brisko_billing/features/printing/domain/models/printer_connection_settings.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer.dart';
import 'package:brisko_billing/features/reports/data/repositories/sqlite_sales_report_repository.dart';
import 'package:brisko_billing/features/reports/domain/repositories/sales_report_repository.dart';
import 'package:brisko_billing/features/settings/data/file_till_backup_store.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';
import 'package:brisko_billing/features/settings/data/sqlite_operational_data_wiper.dart';
import 'package:brisko_billing/features/settings/domain/active_pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/models/pos_settings.dart';
import 'package:brisko_billing/features/settings/domain/repositories/settings_repository.dart';

import 'fixed_printer_factory.dart';
import 'test_printing.dart';

/// The production dependency graph over an already-open test database.
///
/// Every repository is the real one. Only the printer is substituted, because no
/// hardware exists, and by default with the same [UnconfiguredThermalPrinter] the
/// production bootstrap builds — which is the state of every terminal today.
///
/// Written once and shared, so adding a repository to [AppDependencies] does not have to
/// be repeated in every widget test that needs a whole application.
class TestDependencies {
  const TestDependencies._();

  /// Pass [salesReportRepository] to substitute the reports data source, which is what a
  /// test that needs the Reports screen to fail does. Pass [settingsRepository] to
  /// substitute the settings data source, which is what a test that needs the Settings
  /// screen to fail does. Pass [refundRepository] to substitute refunds, which is what a
  /// test that needs a refund to fail from the bill detail screen does. Everything else
  /// stays real.
  ///
  /// [activeSettings] is the configuration the bootstrap would have read before the first
  /// frame. Left out, it is an unconfigured terminal, which is what a fresh install is.
  static AppDependencies over(
    SqliteDatabase database, {
    ThermalPrinter? printer,
    SalesReportRepository? salesReportRepository,
    SettingsRepository? settingsRepository,
    HeldBillRepository? heldBillRepository,
    RefundRepository? refundRepository,
    ExpenseRepository? expenseRepository,
    PosSettings activeSettings = PosSettings.unconfigured,
    PrintSettings? printSettings,
    PrinterConnectionSettings printerSettings =
        PrinterConnectionSettings.unconfigured,
    AuthController? authController,
    bool isCloudConfigured = false,
  }) {
    // The printer the application holds, wired exactly as the bootstrap wires it: a
    // configurable printer over a transport factory, so a test can save a printer binding
    // on the Settings screen and have it take effect. [printer] substitutes the transport
    // the factory hands back, which is the one thing no test can have for real.
    final ConfigurableThermalPrinter resolved = ConfigurableThermalPrinter(
      factory: printer == null
          ? const NoTransportPrinterFactory()
          : FixedPrinterFactory(printer),
      settings: printerSettings,
    );

    // One encoder, shared between the print service and the profile the application
    // exposes, exactly as the bootstrap wires it. That is what makes a printer setting
    // saved on the Settings screen affect the next document a test prints.
    final ConfigurableEscPosEncoder encoder =
        ConfigurableEscPosEncoder.forPrinter(resolved, settings: printSettings);

    // The sync engine, wired exactly as the bootstrap wires it but never started
    // and pointed at the no-op cloud, so widget tests get a real coordinator to
    // read a status from without any timer, network probe or backend.
    final SqliteOutboxStore outbox = SqliteOutboxStore(database: database);
    final SqliteSyncMetadataStore syncMetadata = SqliteSyncMetadataStore(
      database: database,
    );
    const NoopRemoteStoreFactory remoteFactory = NoopRemoteStoreFactory();
    final PollingConnectivityMonitor connectivity = PollingConnectivityMonitor(
      probe: const HostLookupProbe(),
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
    );

    // The whole application over a test database is a local-only, cloud-disabled build:
    // no Firebase project, so the auth gate is bypassed and the till opens straight away,
    // exactly as a plain `flutter run` or a fresh install does. Tests that need the cloud
    // or the login flow wire those pieces themselves.
    final SettingsRepository resolvedSettings =
        settingsRepository ?? SqliteSettingsRepository(database: database);
    final AuthController resolvedAuth =
        authController ??
        AuthController(
          isCloudEnabled: false,
          initiallyAuthenticated: false,
          sessionStore: AuthSessionStore(settings: resolvedSettings),
        );

    return AppDependencies(
      database: database,
      outbox: outbox,
      syncCoordinator: syncCoordinator,
      connectivityMonitor: connectivity,
      remoteStoreFactory: remoteFactory,
      syncMetadataStore: syncMetadata,
      isCloudConfigured: isCloudConfigured,
      authController: resolvedAuth,
      menuRepository: SqliteMenuRepository(database: database),
      orderRepository: SqliteOrderRepository(database: database),
      checkoutRepository: SqliteCheckoutRepository(database: database),
      heldBillRepository:
          heldBillRepository ?? SqliteHeldBillRepository(database: database),
      customerRepository: SqliteCustomerRepository(database: database),
      paymentRepository: SqlitePaymentRepository(database: database),
      refundRepository:
          refundRepository ?? SqliteRefundRepository(database: database),
      inventoryRepository: SqliteInventoryRepository(database: database),
      recipeRepository: SqliteRecipeRepository(database: database),
      inventoryDeductionRepository: SqliteInventoryDeductionRepository(
        database: database,
      ),
      kotRepository: SqliteKotRepository(database: database),
      expenseRepository:
          expenseRepository ?? SqliteExpenseRepository(database: database),
      salesReportRepository:
          salesReportRepository ??
          SqliteSalesReportRepository(database: database),
      settingsRepository: resolvedSettings,
      operationalDataWiper: SqliteOperationalDataWiper(
        database: database,
        outbox: outbox,
        settings: resolvedSettings,
        backups: FileTillBackupStore(),
        syncCoordinator: syncCoordinator,
      ),
      tillBackupStore: FileTillBackupStore(),
      activeSettings: ActivePosSettings(settings: activeSettings),
      printer: resolved,
      activePrinter: resolved,
      activePrintProfile: encoder,
      printService: TestPrinting.serviceOver(
        database,
        printer: resolved,
        encoder: encoder,
      ),
    );
  }
}
