import 'package:brisko_billing/core/data/local/sqlite/sqlite_database.dart';
import 'package:brisko_billing/features/customers/data/repositories/sqlite_customer_repository.dart';
import 'package:brisko_billing/features/kot/data/repositories/sqlite_kot_repository.dart';
import 'package:brisko_billing/features/orders/data/repositories/sqlite_order_repository.dart';
import 'package:brisko_billing/features/payments/data/repositories/sqlite_payment_repository.dart';
import 'package:brisko_billing/features/printing/data/default_print_service.dart';
import 'package:brisko_billing/features/printing/data/escpos/escpos_document_formatter.dart';
import 'package:brisko_billing/features/printing/data/repository_sale_print_document_source.dart';
import 'package:brisko_billing/features/printing/data/settings_business_identity_source.dart';
import 'package:brisko_billing/features/printing/domain/models/monochrome_bitmap.dart';
import 'package:brisko_billing/features/printing/domain/printers/thermal_printer.dart';
import 'package:brisko_billing/features/printing/domain/services/print_document_encoder.dart';
import 'package:brisko_billing/features/printing/domain/services/print_job_factory.dart';
import 'package:brisko_billing/features/settings/data/repositories/sqlite_settings_repository.dart';

/// Wires the production printing service over a test database.
///
/// Only the printer is substituted. The document source, the repositories it reads, the
/// ESC/POS encoder and the job factory are all the real ones, wired exactly as the
/// bootstrap wires them, so a test that asserts on a receipt is asserting on the receipt
/// the application would print.
class TestPrinting {
  const TestPrinting._();

  /// A print service reading [database] and writing to [printer].
  ///
  /// Pass [encoder] to share the one the application exposes as its active print profile,
  /// which is how the bootstrap wires it and what lets a saved printer setting change the
  /// next document. Left out, an encoder is built for the printer's own profile, which is
  /// what an unconfigured terminal uses.
  /// Pass [logo] to stamp the outlet logo on receipts, which is what the bootstrap does
  /// with the asset it decodes at start-up. Left out, no logo is printed — the honest
  /// default for a harness that has not loaded the asset, and what keeps receipt tests
  /// that assert on the header text unaffected.
  static DefaultPrintService serviceOver(
    SqliteDatabase database, {
    required ThermalPrinter printer,
    PrintDocumentEncoder? encoder,
    MonochromeBitmap? logo,
  }) {
    return DefaultPrintService(
      printer: printer,
      // Encoded for the printer's own profile, as in the bootstrap.
      jobs: PrintJobFactory(
        encoder: encoder ?? EscPosDocumentFormatter(profile: printer.profile),
      ),
      documents: RepositorySalePrintDocumentSource(
        orders: SqliteOrderRepository(database: database),
        payments: SqlitePaymentRepository(database: database),
        kots: SqliteKotRepository(database: database),
        customers: SqliteCustomerRepository(database: database),
        // Reads the real settings table, which is empty unless a test writes to it.
        // That is the honest default: an unconfigured terminal prints its name and
        // claims no address, GSTIN or UPI address.
        identity: SettingsBusinessIdentitySource(
          settings: SqliteSettingsRepository(database: database),
          logo: logo,
        ),
      ),
    );
  }
}
