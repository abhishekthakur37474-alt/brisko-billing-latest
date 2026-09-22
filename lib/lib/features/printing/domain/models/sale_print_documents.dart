import 'print_document.dart';

/// Every piece of paper one settled sale produces.
///
/// One receipt for the customer, and one slip per kitchen ticket raised against the
/// order. Both go to the same printer, because the outlet has one.
///
/// Built together, from one read of the persisted sale, so the two documents cannot
/// disagree about what was ordered.
class SalePrintDocuments {
  const SalePrintDocuments({required this.receipt, required this.kots});

  final CustomerReceipt receipt;

  /// Kitchen slips, oldest first. Normally one; more when items were added to an
  /// order after the first slip went to the kitchen.
  final List<KitchenKot> kots;

  /// Documents in the order they should be printed.
  ///
  /// The kitchen slip first. It is the one somebody is waiting on, and if the roll runs
  /// out halfway through a sale the food should still be started.
  List<PrintDocument> get all => <PrintDocument>[...kots, receipt];

  int get documentCount => kots.length + 1;
}
