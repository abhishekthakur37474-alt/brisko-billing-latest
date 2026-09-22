import '../../../../core/utils/result.dart';
import '../models/print_job.dart';
import '../models/sale_print_run.dart';

/// Prints the paperwork for a sale.
///
/// ## Where this sits in the checkout
///
/// Strictly after persistence. By the time [printSale] is called, the order, its
/// lines, their options, the payment and the kitchen slip have all been committed in
/// one transaction. Printing is a separate step with its own outcome, and it is a
/// deliberate design decision that it cannot influence the sale:
///
/// * It writes nothing. Documents are built by *reading* persisted rows.
/// * It never returns a failure that a caller could mistake for a failed sale.
/// * A failure leaves the bill settled, the money recorded and the kitchen slip
///   raised. The only thing missing is paper.
///
/// ## Retry
///
/// [retry] re-sends the documents that failed, rebuilding them from the same rows by
/// order id. It cannot create a second order, payment or kitchen slip, because it has
/// no repository write in its path at all. That is the guarantee: not a duplicate
/// check, but the absence of any code that could duplicate.
abstract interface class PrintService {
  /// Builds and prints the receipt and, when asked, the kitchen slip for a settled
  /// order.
  ///
  /// [printKitchenSlip] is the owner’s choice from Settings. False skips the slip’s
  /// paper only; the ticket is already written. A reprint of the slip is still
  /// offered from bill detail.
  ///
  /// Returns the run rather than a `Result`, because "the printer failed" is the
  /// normal, expected outcome this method exists to report, and the caller needs the
  /// per-document detail to tell the cashier what to do.
  Future<SalePrintRun> printSale(
    String orderId, {
    bool printKitchenSlip = true,
  });

  /// Re-sends the failed documents of [run], leaving the printed ones alone.
  ///
  /// Returns the run with those jobs' states and attempt counts updated. Sending a
  /// document that already printed is not offered: it would put a second bill in the
  /// customer's hand.
  Future<SalePrintRun> retry(SalePrintRun run);

  /// Prints every document for a settled order again, marked as a reprint.
  ///
  /// For the case where paper came out but was lost or torn. Marked on the paper so a
  /// second copy cannot be mistaken for a second sale.
  Future<SalePrintRun> reprintSale(String orderId);

  /// Prints the customer's receipt again, and nothing else.
  ///
  /// The usual reprint. A customer asking for their bill at the door does not need the
  /// kitchen slip re-cut, and sending one would put a second slip for food that has
  /// already been cooked into the pass.
  ///
  /// Rebuilt from the persisted order and payment, so it does not depend on the original
  /// cart still existing anywhere. It writes nothing: no second order, no second payment,
  /// no change to a total, a report or a stock figure.
  Future<SalePrintRun> reprintReceipt(String orderId);

  /// Prints the order's kitchen slips again, and nothing else.
  ///
  /// For a slip lost between the counter and the pass. Built from the kitchen tickets
  /// already stored against the order, so it raises no new ticket, deducts no stock and
  /// does not disturb where the existing slips stand in
  /// pending → preparing → ready.
  ///
  /// Returns a run with no jobs when the order has no kitchen tickets, which is a
  /// statement rather than a failure: there is nothing to print again.
  Future<SalePrintRun> reprintKitchenSlips(String orderId);

  /// Prints a short self-test page.
  ///
  /// Exists so a printer can be proved working from the settings screen without
  /// spending a real bill on it, and so a mis-sized roll is discovered before a
  /// customer's receipt comes out wrapped. Belongs to no sale, and never carries a
  /// payment code: a test page with a real `upi://pay` link on it could be scanned and
  /// take money against no order.
  Future<Result<PrintJob>> printTestPage();
}
