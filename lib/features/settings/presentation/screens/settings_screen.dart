import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../billing/presentation/controllers/billing_controller.dart';
import '../../../printing/domain/printers/active_printer.dart';
import '../../../printing/domain/services/active_print_profile.dart';
import '../../../printing/domain/services/print_service.dart';
import '../../../printing/presentation/controllers/printer_controller.dart';
import '../../domain/active_pos_settings.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/operational_data_wiper.dart';
import '../../domain/services/till_backup_store.dart';
import '../controllers/data_reset_controller.dart';
import '../controllers/settings_controller.dart';
import '../widgets/settings_form.dart';
import '../widgets/settings_notices.dart';

/// Outlet and terminal configuration.
///
/// ## What is here, and what is deliberately not
///
/// Five sections: who the outlet is, how settlement opens, what the bill says around the
/// figures, how a document is laid out on the roll, and which printer it is sent to. Every
/// one of them is verifiable on this terminal today.
///
/// The printer section is supplied by the printing module rather than written here. It is
/// that module's knowledge — a transport, an endpoint, a connection state and a test page
/// — and keeping it there is what lets this module stay free of devices, sockets and
/// addresses while the screen still offers somewhere to configure one.
///
/// There is no tax rate and no discount, because nothing in this build charges either and
/// an input that changes nothing is worse than no input. Cloud sync and the signed-in
/// account live in their own sections, supplied by those modules.
///
/// ## How it is wired
///
/// Two controllers, because there are two things being configured. [SettingsController]
/// owns the outlet's configuration and the document layout, saved together in one
/// transaction because they are one document. [PrinterController] owns the device binding,
/// saved on its own and testable on its own, because a corrected printer address has to be
/// tryable without also committing whatever is half-typed in the business fields.
///
/// Everything below is widgets reporting what the operator did. No widget on this screen
/// touches SQLite, and no widget decides whether a value is acceptable.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <ChangeNotifierProvider<ChangeNotifier>>[
        ChangeNotifierProvider<SettingsController>(
          create: (BuildContext context) {
            final SettingsController controller = SettingsController(
              settings: context.read<SettingsRepository>(),
              printProfile: context.read<ActivePrintProfile>(),
              activeSettings: context.read<ActivePosSettings>(),
            );
            // Deliberately not awaited: the first frame renders the loading state while
            // the read runs.
            unawaited(controller.load());
            return controller;
          },
        ),
        // Seeded from the printer the application is already using, which the bootstrap
        // built from the stored rows before the first frame. No second read of the table,
        // so the form cannot show a binding that differs from the one in force.
        ChangeNotifierProvider<PrinterController>(
          create: (BuildContext context) => PrinterController(
            settings: context.read<SettingsRepository>(),
            printer: context.read<ActivePrinter>(),
            printService: context.read<PrintService>(),
            printProfile: context.read<ActivePrintProfile>(),
          ),
        ),
        ChangeNotifierProvider<DataResetController>(
          create: (BuildContext context) => DataResetController(
            wiper: context.read<OperationalDataWiper>(),
            billing: context.read<BillingController>(),
            settings: context.read<SettingsRepository>(),
            backups: context.read<TillBackupStore>(),
          ),
        ),
      ],
      child: const _SettingsView(),
    );
  }
}

/// Loading, a failure with a retry, or the form.
///
/// The three are mutually exclusive on purpose. A form shown beside a read failure would
/// hold blank fields that look like an unconfigured outlet, and saving them would
/// overwrite a real address with nothing.
class _SettingsView extends StatelessWidget {
  const _SettingsView();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    if (!controller.hasLoaded) {
      if (controller.hasError) {
        return SettingsErrorView(
          message: controller.errorMessage!,
          onRetry: controller.load,
        );
      }
      return const SettingsLoadingView();
    }

    return const SettingsForm();
  }
}
