import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants/app_constants.dart';
import '../core/error/app_error_reporter.dart';
import '../core/error/app_failure.dart';
import '../core/theme/app_theme.dart';
import '../features/auth/presentation/controllers/auth_controller.dart';
import '../features/billing/domain/repositories/checkout_repository.dart';
import '../features/billing/domain/repositories/held_bill_repository.dart';
import '../features/billing/presentation/controllers/billing_controller.dart';
import '../features/cloud_sync/presentation/controllers/sync_status_controller.dart';
import '../features/customers/domain/repositories/customer_repository.dart';
import '../features/expenses/domain/repositories/expense_repository.dart';
import '../features/inventory/domain/repositories/inventory_deduction_repository.dart';
import '../features/inventory/domain/repositories/inventory_repository.dart';
import '../features/inventory/domain/repositories/recipe_repository.dart';
import '../features/kot/domain/repositories/kot_repository.dart';
import '../features/menu/domain/repositories/menu_repository.dart';
import '../features/orders/domain/repositories/order_repository.dart';
import '../features/payments/domain/repositories/payment_repository.dart';
import '../features/payments/domain/repositories/refund_repository.dart';
import '../features/printing/domain/printers/active_printer.dart';
import '../features/printing/domain/printers/thermal_printer.dart';
import '../features/printing/domain/services/active_print_profile.dart';
import '../features/printing/domain/services/print_service.dart';
import '../features/reports/domain/repositories/sales_report_repository.dart';
import '../features/settings/domain/active_pos_settings.dart';
import '../features/settings/domain/repositories/settings_repository.dart';
import '../features/settings/domain/services/operational_data_wiper.dart';
import '../features/settings/domain/services/till_backup_store.dart';
import 'bootstrap.dart';
import 'routes/app_routes.dart';
import 'shell/shell_controller.dart';

/// Root widget of the application.
///
/// Owns three things and nothing else: the application-wide state objects, the
/// theme, and the route table. Business logic and data access are deliberately
/// absent here.
///
/// The provider list below is the single place dependencies are wired. Repositories
/// are provided under their abstract types, so a screen can depend on
/// `MenuRepository` and remains unaware that SQLite is behind it.
class BriskoApp extends StatelessWidget {
  const BriskoApp({required this.dependencies, super.key});

  /// Built by [bootstrap] before `runApp`, so the database is already open and
  /// migrated by the time any widget builds.
  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    // Type argument omitted deliberately: the element type
    // (`SingleChildWidget`) lives in provider's transitive `nested` package and
    // is not re-exported, so it cannot be named without an implicit
    // dependency. Inference supplies it correctly.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ShellController>(
          create: (BuildContext context) => ShellController(),
        ),
        // The sign-in state, built by the bootstrap and disposed with it, so this uses
        // `.value` and does not own its lifecycle. Provided above the router so the auth
        // gate and the Settings account section both read the one instance.
        ChangeNotifierProvider<AuthController>.value(
          value: dependencies.authController,
        ),
        // Presents the sync engine's status to the shell indicator and the
        // Settings cloud section. Reads the coordinator; owns no sync logic.
        ChangeNotifierProvider<SyncStatusController>(
          create: (BuildContext context) => SyncStatusController(
            coordinator: dependencies.syncCoordinator,
            isCloudConfigured: dependencies.isCloudConfigured,
          ),
        ),
        // Plain `Provider` rather than a factory: these are stateless
        // collaborators created once at start-up, and rebuilding one mid-shift
        // would drop any active `watch` subscription.
        Provider<MenuRepository>.value(value: dependencies.menuRepository),
        Provider<OrderRepository>.value(value: dependencies.orderRepository),
        Provider<CheckoutRepository>.value(
          value: dependencies.checkoutRepository,
        ),
        Provider<HeldBillRepository>.value(
          value: dependencies.heldBillRepository,
        ),
        Provider<CustomerRepository>.value(
          value: dependencies.customerRepository,
        ),
        Provider<PaymentRepository>.value(
          value: dependencies.paymentRepository,
        ),
        // Read by the stored-bill view, which is where a refund is authorised. Provided
        // here rather than inside that dialog so the dialog can be opened from the customer
        // history and from the reports bill list without either knowing how to build it.
        Provider<RefundRepository>.value(value: dependencies.refundRepository),
        Provider<InventoryRepository>.value(
          value: dependencies.inventoryRepository,
        ),
        Provider<RecipeRepository>.value(value: dependencies.recipeRepository),
        Provider<InventoryDeductionRepository>.value(
          value: dependencies.inventoryDeductionRepository,
        ),
        Provider<KotRepository>.value(value: dependencies.kotRepository),
        Provider<ExpenseRepository>.value(
          value: dependencies.expenseRepository,
        ),
        Provider<SalesReportRepository>.value(
          value: dependencies.salesReportRepository,
        ),
        Provider<ThermalPrinter>.value(value: dependencies.printer),
        // The same object again, under the interface the Settings screen binds a printer
        // through. Two types, one printer: the print service sends to it and the printer
        // section reconfigures it, and neither can end up holding a different one.
        Provider<ActivePrinter>.value(value: dependencies.activePrinter),
        Provider<PrintService>.value(value: dependencies.printService),
        // The same object the print service encodes with, so a corrected column count
        // saved in Settings lays out the next bill rather than the next launch.
        Provider<ActivePrintProfile>.value(
          value: dependencies.activePrintProfile,
        ),
        Provider<SettingsRepository>.value(
          value: dependencies.settingsRepository,
        ),
        Provider<OperationalDataWiper>.value(
          value: dependencies.operationalDataWiper,
        ),
        Provider<TillBackupStore>.value(value: dependencies.tillBackupStore),
        // The configuration read at start-up. Checkout reads the default order type from
        // here rather than querying the settings table while a screen is building.
        Provider<ActivePosSettings>.value(value: dependencies.activeSettings),
        // Registered above the shell rather than inside the billing screen. The
        // shell rebuilds the active section's widget on every navigation, so a
        // screen-scoped cart would be thrown away the moment the cashier glanced
        // at Orders. A half-built bill has to outlive that.
        ChangeNotifierProvider<BillingController>(
          create: (BuildContext context) => BillingController(
            menuRepository: dependencies.menuRepository,
            heldBillRepository: dependencies.heldBillRepository,
          ),
        ),
      ],
      child: MaterialApp(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        // The billing terminal is used in a bright, fixed environment, so the
        // light theme is pinned until a display preference exists in settings.
        themeMode: ThemeMode.light,
        initialRoute: AppRoutes.home,
        routes: AppRoutes.routes(),
        onUnknownRoute: AppRoutes.onUnknownRoute,
        // Sits above every route, including the login gate, so a failure reported
        // from anywhere in the application is shown on screen rather than logged.
        builder: (BuildContext context, Widget? child) =>
            _GlobalErrorListener(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}

/// Shows any failure announced on [AppErrorReporter] as a snack bar.
///
/// The application normally renders a failure on the screen that asked for the work.
/// This is the backstop for the ones with no such screen, so the operator sees the
/// error at the terminal instead of it disappearing into a file.
class _GlobalErrorListener extends StatefulWidget {
  const _GlobalErrorListener({required this.child});

  final Widget child;

  @override
  State<_GlobalErrorListener> createState() => _GlobalErrorListenerState();
}

class _GlobalErrorListenerState extends State<_GlobalErrorListener> {
  StreamSubscription<AppFailure>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = AppErrorReporter.instance.failures.listen(_show);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }

  void _show(AppFailure failure) {
    if (!mounted) {
      return;
    }
    // Defer to the next frame: a report can arrive during a build (a read on start-up,
    // a reload after a save), and showing a messenger mid-build would throw.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) {
        return;
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(failure.message),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'Dismiss',
              onPressed: messenger.hideCurrentSnackBar,
            ),
          ),
        );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
