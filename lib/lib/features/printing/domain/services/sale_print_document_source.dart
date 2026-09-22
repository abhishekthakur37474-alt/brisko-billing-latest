import '../../../../core/utils/result.dart';
import '../models/sale_print_documents.dart';

/// Builds the printable documents for a settled sale.
///
/// ## Read-only, by contract
///
/// Given an order id, it reads the order, its lines, their options, the payment, the
/// customer's phone number, the kitchen slips and the outlet's configured details, and
/// returns documents. It writes nothing, anywhere. That is what makes reprinting and
/// retrying safe by construction rather than by a duplicate check: there is no code
/// path from printing back into the database.
///
/// ## Why documents are rebuilt rather than cached
///
/// A retry could have kept the documents from the first attempt in memory. Reading them
/// again is better: it proves the paper matches what is actually stored, it survives a
/// screen being rebuilt, and it is the same call a reprint from the order history will
/// make months later.
abstract interface class SalePrintDocumentSource {
  /// Documents for the order with [orderId].
  ///
  /// Returns a `ValidationFailure` when the order does not exist, has no lines, has no
  /// settled payment, or when its totals do not add up. Each of those means the
  /// document would misrepresent the sale, and a wrong receipt in a customer's hand is
  /// worse than an apology for a printer.
  ///
  /// Set [isReprint] to mark the paper as a second copy.
  Future<Result<SalePrintDocuments>> forOrder(
    String orderId, {
    bool isReprint = false,
  });
}
