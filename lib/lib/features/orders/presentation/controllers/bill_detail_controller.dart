import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../auth/domain/services/manager_auth_service.dart';
import '../../../customers/domain/models/customer.dart';
import '../../../customers/domain/repositories/customer_repository.dart';
import '../../../payments/domain/models/payment.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../payments/domain/models/payment_status.dart';
import '../../../payments/domain/models/refund.dart';
import '../../../payments/domain/models/refund_request.dart';
import '../../../payments/domain/models/refundable_bill.dart';
import '../../../payments/domain/repositories/payment_repository.dart';
import '../../../payments/domain/repositories/refund_repository.dart';
import '../../../printing/domain/models/sale_print_run.dart';
import '../../../printing/domain/services/print_service.dart';
import '../../domain/models/bill_line_snapshot.dart';
import '../../domain/models/order.dart';
import '../../domain/models/order_cancellation.dart';
import '../../domain/repositories/order_repository.dart';

/// Holds one stored bill, exactly as it was written.
///
/// ## The one rule this file exists to keep
///
/// Every figure it exposes was read from `orders`, `order_items`, `order_item_options`
/// or `payments`. There is no `MenuRepository` here and there cannot be one: looking up
/// a current price to display a historical bill would mean a receipt reprinted next
/// month disagreed with the one the customer was handed, and a bill whose product has
/// since been deleted could not be opened at all.
///
/// ## Money
///
/// Totals are the persisted [Money] values in integer paise. Nothing is recalculated,
/// nothing is parsed from a string, and [linesTotal] exists only so a reader can see
/// that the stored lines add up to the stored subtotal — not to replace it.
///
/// ## Failure
///
/// Nothing throws. A read that fails becomes [errorMessage] with no bill attached, which
/// the view renders as a notice with a retry.
///
/// ## Refunding
///
/// This is the one thing here that writes. [refund] hands back the whole of what the bill
/// collected and is the only mutation on the controller; everything else is a read of a
/// document that must never change.
///
/// The controller decides nothing about whether a refund is allowed. It shows the figures
/// [RefundableBill] derived and calls [RefundRepository.refund], which re-reads and
/// re-decides the whole thing inside the transaction that writes it. A screen's idea of
/// what is refundable is always slightly stale, so it is used to draw a button and never to
/// authorise money.
///
/// [refundError] is kept separate from [errorMessage] on purpose: a refund that was refused
/// must not blank out the bill behind it. The document is still perfectly readable and the
/// cashier needs to see it while being told why the refund did not happen.
class BillDetailController extends ChangeNotifier {
  BillDetailController({
    required this._orderId,
    required OrderRepository orderRepository,
    required PaymentRepository paymentRepository,
    required CustomerRepository customerRepository,
    required RefundRepository refundRepository,
    required this._managerAuthService,
    required this._printService,
  }) : _orders = orderRepository,
       _payments = paymentRepository,
       _customers = customerRepository,
       _refunds = refundRepository;

  final String _orderId;
  final OrderRepository _orders;
  final PaymentRepository _payments;
  final CustomerRepository _customers;
  final RefundRepository _refunds;
  final ManagerAuthService _managerAuthService;

  /// Sends the bill or the kitchen slip to paper again.
  ///
  /// The second thing on this controller that does something rather than reading, and
  /// unlike [refund] it changes nothing at all. See the reprint section below.
  final PrintService _printService;

  Order? _order;
  List<BillLineSnapshot> _lines = const <BillLineSnapshot>[];
  List<Payment> _tenders = const <Payment>[];
  Customer? _customer;
  RefundableBill? _refundable;

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  bool _isRefunding = false;
  String? _refundError;
  Refund? _justRefunded;

  bool _isReprinting = false;
  String? _reprintMessage;
  bool _didReprint = false;

  bool _isCancelling = false;
  String? _cancelError;
  bool _didCancel = false;

  /// The request currently being attempted, held so a retry is a retry.
  ///
  /// Reused rather than rebuilt, because the id inside it is what makes the repository
  /// recognise a second attempt at the same intent and return the reversal it already wrote
  /// instead of writing another. Cleared once the outcome is known and acted on.
  RefundRequest? _attempt;

  // ------------------------------------------------------------------- state ---

  String get orderId => _orderId;

  /// The stored bill header, or `null` before it has been read or if it is gone.
  Order? get order => _order;

  /// The stored lines with their customisations, in bill order.
  List<BillLineSnapshot> get lines => _lines;

  /// Tenders recorded against the bill, oldest first.
  List<Payment> get payments => _tenders;

  /// The customer the bill was filed against, or `null` for a walk-in.
  Customer? get customer => _customer;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the read finished and the bill is not on this terminal.
  bool get isMissing => _hasLoaded && !hasError && _order == null;

  // ------------------------------------------------------------------ refund ---

  /// What the bill collected, what has gone back and what is left, or `null` before the
  /// read.
  RefundableBill? get refundable => _refundable;

  /// True while a refund is being written.
  bool get isRefunding => _isRefunding;

  /// Why the last refund attempt did not happen, or `null`.
  ///
  /// Separate from [errorMessage]: the bill is still shown behind this.
  String? get refundError => _refundError;

  bool get hasRefundError => _refundError != null;

  /// The reversal this screen just wrote, or `null` when it has not written one.
  ///
  /// Set only by a refund made here, so the view can confirm the action rather than merely
  /// showing that the bill is now refunded. [RefundableBill.existingRefund] is what says a
  /// bill arrived already refunded.
  Refund? get justRefunded => _justRefunded;

  /// True when a refund made on this screen has succeeded.
  bool get hasRefunded => _justRefunded != null;

  /// What has been handed back on this bill in total, including before this screen opened.
  Money get refundedAmount => _refundable?.refundedAmount ?? Money.zero;

  /// What could still be handed back.
  Money get refundableAmount => _refundable?.refundableAmount ?? Money.zero;

  /// What the bill collected, which is the ceiling on any refund.
  Money get paidAmount => _refundable?.paidAmount ?? Money.zero;

  /// True when a refund can be attempted right now.
  ///
  /// False while one is in flight, and false once one has succeeded here, so the action
  /// cannot be fired twice from the same screen. The repository refuses a second refund
  /// anyway; this only avoids asking it to.
  bool get canRefund =>
      !_isRefunding && !hasRefunded && (_refundable?.canRefund ?? false);

  /// Why a refund cannot be attempted, or `null` when one can.
  ///
  /// Drawn from the read model, so the wording a disabled action explains itself with is the
  /// same wording the repository would refuse with.
  String? get refundRefusal => hasRefunded ? null : _refundable?.refusalReason;

  // -------------------------------------------------------------- reprint state ---

  /// True while a document is being sent.
  bool get isReprinting => _isReprinting;

  /// What the last reprint did, or `null` when none has been attempted.
  ///
  /// Kept apart from both [errorMessage] and [refundError]. A printer that would not take
  /// the paper says nothing about the bill or about the money, so it must not blank out the
  /// document or sit where a refund refusal sits.
  String? get reprintMessage => _reprintMessage;

  /// True when the last reprint reached the printer.
  bool get didReprint => _didReprint;

  /// True when there is a settled bill worth reprinting.
  ///
  /// A bill that has not loaded has nothing to print from. Cancelled and refunded bills are
  /// deliberately still reprintable: a customer asking for the paperwork on a reversed sale
  /// is entitled to it, and the document says what it says.
  bool get canReprint => _order != null && !_isReprinting;

  // -------------------------------------------------------------- cancel state ---

  /// True while a cancellation is being written.
  bool get isCancelling => _isCancelling;

  /// Why the last cancellation did not happen, or `null`.
  ///
  /// Kept apart from [errorMessage] and the refund and reprint notices, for the same reason
  /// they are kept apart from each other: a refused cancellation is a fact about one action,
  /// not about the bill, and must not blank the document out.
  String? get cancelError => _cancelError;

  bool get hasCancelError => _cancelError != null;

  /// True when a cancellation made on this screen has succeeded.
  bool get didCancel => _didCancel;

  /// True when this bill can be cancelled from here right now.
  ///
  /// Only a live bill: one that has not been settled and has not already been cancelled.
  /// A completed sale is not cancelled — it is refunded, which is a separate action with a
  /// separate button — so offering cancel on it would invite undoing a paid bill without
  /// giving the money back. The domain rule `OrderCancellation.canCancel` still guards the
  /// write; this getter is the narrower question of whether to show the action at all.
  /// A completed sale can now be cancelled with a manager password, per business requirement.
  bool get canCancel =>
      _order != null &&
      !_isCancelling &&
      !_didCancel &&
      OrderCancellation.canCancel(_order!.status);

  /// Why cancelling is not offered, or `null` when it is.
  ///
  /// Only spelled out for a bill that has already been cancelled, which is the one case a
  /// reader might expect the action and needs told about.
  String? get cancelRefusal {
    final Order? order = _order;
    if (order == null || _didCancel) {
      return null;
    }
    return OrderCancellation.refusalReason(order.status);
  }

  // ----------------------------------------------------------------- derived ---

  String? get orderNumber => _order?.orderNumber;

  /// The number recorded for the customer, or `null` for a walk-in.
  String? get customerPhone => _customer?.phone;

  /// The name recorded for the customer, or `null` when none was stored.
  ///
  /// Prefers the name stamped on the bill, so a walk-in whose name was taken
  /// without a phone still shows it. Falls back to the customer record for bills
  /// settled before that snapshot existed.
  String? get customerName {
    final String? onBill = _order?.customerName?.trim();
    if (onBill != null && onBill.isNotEmpty) {
      return onBill;
    }
    final String? name = _customer?.name?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  /// What the bill shows for the customer: the name when one was stored.
  String get customerDisplayName {
    final String? name = customerName;
    if (name != null) {
      return name;
    }
    final String? phone = customerPhone;
    if (phone == null) {
      return 'Walk-in';
    }
    return phone;
  }

  /// How the bill was paid, or `null` when no settled tender is stored.
  ///
  /// The first settled tender. Split payment is a later feature, and this is the line
  /// that changes when it arrives.
  PaymentMethod? get paymentMethod {
    for (final Payment payment in _tenders) {
      if (payment.status == PaymentStatus.completed) {
        return payment.paymentMethod;
      }
    }
    return null;
  }

  /// The transaction reference on the settled tender, if one was recorded.
  String? get paymentReference {
    for (final Payment payment in _tenders) {
      if (payment.status == PaymentStatus.completed) {
        final String? reference = payment.reference?.trim();
        return reference == null || reference.isEmpty ? null : reference;
      }
    }
    return null;
  }

  /// Number of units sold on the bill.
  int get itemCount => _lines.fold<int>(
    0,
    (int total, BillLineSnapshot line) => total + line.quantity,
  );

  /// Sum of the stored line totals.
  ///
  /// For checking, not for displaying as the bill's subtotal. The subtotal on the header
  /// is the figure that was charged, and this is here so a discrepancy between the two
  /// is visible rather than hidden.
  Money get linesTotal =>
      Money.sum(_lines.map((BillLineSnapshot line) => line.lineTotal));

  /// True when the stored lines add up to the stored subtotal, to the paisa.
  ///
  /// An exact comparison, not a tolerance: both sides are integers.
  bool get isConsistent => _order != null && linesTotal == _order!.subtotal;

  // ----------------------------------------------------------------- reading ---

  /// Reads the bill and everything shown beside it.
  ///
  /// Ignores a call made while a read is already running, so a double tap on retry
  /// cannot interleave two reads.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<Order?> found = await _orders.findOrder(_orderId);
    final AppFailure? headerFailure = found.failureOrNull;
    if (headerFailure != null) {
      _fail(headerFailure.message);
      return;
    }

    final Order? order = found.valueOrNull;
    if (order == null) {
      // Not a failure. The bill is simply not here, which is a different thing to tell
      // the cashier than a storage fault.
      _order = null;
      _lines = const <BillLineSnapshot>[];
      _tenders = const <Payment>[];
      _customer = null;
      _isLoading = false;
      _hasLoaded = true;
      _notify();
      return;
    }

    final Result<List<BillLineSnapshot>> lines = await _orders.loadBillLines(
      order.id,
    );
    final AppFailure? lineFailure = lines.failureOrNull;
    if (lineFailure != null) {
      _fail(lineFailure.message);
      return;
    }

    final Result<List<Payment>> tendered = await _payments.loadForOrder(
      order.id,
    );
    final AppFailure? paymentFailure = tendered.failureOrNull;
    if (paymentFailure != null) {
      _fail(paymentFailure.message);
      return;
    }

    final Result<RefundableBill?> refundable = await _refunds.loadRefundable(
      order.id,
    );
    final AppFailure? refundableFailure = refundable.failureOrNull;
    if (refundableFailure != null) {
      // Fatal, unlike the customer read below. This read is what the refund figures and the
      // refund action are drawn from, and a bill shown with a Refund button whose amounts
      // could not be read is a bill somebody could refund the wrong amount of.
      _fail(refundableFailure.message);
      return;
    }

    _order = order;
    _lines = lines.valueOrNull!;
    _tenders = tendered.valueOrNull!;
    _refundable = refundable.valueOrNull;
    // Deliberately last, and deliberately not fatal. A bill whose customer record could
    // not be read is still a complete bill; the phone number is one line on it.
    _customer = await _customerFor(order.customerId);

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  Future<void> retry() => load();

  // ----------------------------------------------------------------- writing ---

  /// Hands back the whole of what this bill collected.
  ///
  /// Returns true when the money went back. On failure returns false and leaves everything
  /// on screen exactly as it was, with [refundError] set: the sale is untouched, so there is
  /// nothing to redraw except the notice.
  ///
  /// Ignores a call made while one is already running, so a double tap cannot start two.
  /// Where a tap does get through twice — a retry after an outcome nobody saw — the held
  /// [RefundRequest] is reused, so the repository recognises it and returns the reversal it
  /// already wrote rather than writing a second.
  ///
  /// The figures are re-read afterwards, from storage, so what the screen shows next is what
  /// is on disk rather than what this method assumed it would be.
  Future<bool> refund({String? reason}) async {
    if (_isRefunding || hasRefunded) {
      return false;
    }

    final RefundableBill? bill = _refundable;
    if (bill == null) {
      // No figures were read, so there is nothing to refund against. Reported rather than
      // attempted, because the repository would only refuse it after a round trip.
      _refundError =
          'This bill has not finished loading, so it cannot be refunded yet.';
      _notify();
      return false;
    }

    _isRefunding = true;
    _refundError = null;
    _notify();

    // Built once and held. A retry of a refund whose outcome was lost has to be the same
    // request, or it becomes a second refund.
    final RefundRequest request = _attempt ??= RefundRequest.forBill(
      bill,
      reason: reason,
    );

    final Result<Refund> outcome = await _refunds.refund(request);

    final AppFailure? failure = outcome.failureOrNull;
    if (failure != null) {
      _isRefunding = false;
      _refundError = failure.message;
      // The request is kept, so tapping again retries this same intent rather than starting a
      // new one. Nothing was written, so the bill on screen is still correct.
      _notify();
      return false;
    }

    _justRefunded = outcome.valueOrNull;
    _attempt = null;
    _isRefunding = false;
    // Re-read rather than adjusted in memory: the refunded and refundable figures now come
    // from the committed rows, so the screen cannot disagree with the database.
    await _reloadRefundable();
    _notify();
    return true;
  }

  /// Clears the failure notice, leaving the bill and its figures alone.
  void dismissRefundError() {
    if (_refundError == null) {
      return;
    }
    _refundError = null;
    _notify();
  }

  // ---------------------------------------------------------------- reprinting ---
  //
  // Printing is the one action on this screen that cannot go wrong in a way that matters.
  // Nothing below writes: not an order, not a payment, not a kitchen ticket, not a stock
  // movement and not a report row. The documents are rebuilt by the print service from the
  // same committed rows this screen is showing, so a reprint pressed a dozen times
  // produces a dozen pieces of paper and exactly one sale — which is why there is no
  // duplicate check here. There is no code that could duplicate.
  //
  // It also does not depend on the original cart. That was cleared the moment the bill
  // settled, possibly months ago on a terminal that has been restarted since.

  /// Sends the customer's receipt to the printer again.
  ///
  /// Returns true when it reached the printer. On failure the bill on screen is untouched
  /// and [reprintMessage] says what the printer reported, because a printer that is
  /// unplugged is not a reason to stop showing somebody their bill.
  Future<bool> reprintReceipt() =>
      _reprint(() => _printService.reprintReceipt(_orderId), what: 'Receipt');

  /// Sends the order's kitchen slips to the printer again.
  ///
  /// For a slip lost between the counter and the pass. It raises no new ticket and does not
  /// disturb where the existing ones stand in pending → preparing → ready: the kitchen
  /// board is driven by the ticket rows, and this reads them.
  ///
  /// An order with no kitchen tickets reports that there is nothing to print rather than a
  /// failure. That is a different thing to tell somebody, and it is the honest answer for a
  /// bill whose slips were never raised.
  Future<bool> reprintKitchenSlips() => _reprint(
    () => _printService.reprintKitchenSlips(_orderId),
    what: 'Kitchen slip',
    nothingToPrint: 'There is no kitchen slip stored against this bill.',
  );

  /// Clears the reprint notice.
  void dismissReprintMessage() {
    if (_reprintMessage == null) {
      return;
    }
    _reprintMessage = null;
    _didReprint = false;
    _notify();
  }

  // -------------------------------------------------------------- cancelling ---

  /// Cancels a live bill and reloads it so the screen shows the new status.
  ///
  /// The business rules are not duplicated here: this calls [OrderRepository.cancelOrder],
  /// which re-reads the status inside its own transaction, refuses a bill that is missing or
  /// already cancelled, and stops any outstanding kitchen work. Stock is not returned and
  /// the tender is left as it was — the repository owns every one of those decisions.
  ///
  /// Returns true when the bill was cancelled. On failure the bill on screen is untouched
  /// and [cancelError] carries the reason. On success the whole bill is re-read, so the
  /// status, the lines and the now-closed refund state all come from the committed rows.
  ///
  /// Ignores a call made while one is already running, so a double tap cannot fire two.
  Future<bool> cancel({required String password, String? reason}) async {
    final Order? order = _order;
    if (_isCancelling || order == null) {
      return false;
    }

    _isCancelling = true;
    _cancelError = null;
    _notify();

    final Result<bool> authResult = await _managerAuthService.verifyPassword(password);
    if (authResult.isErr) {
      _isCancelling = false;
      _cancelError = 'Could not verify manager password.';
      _notify();
      return false;
    }
    if (!authResult.valueOrNull!) {
      _isCancelling = false;
      _cancelError = 'Incorrect manager password.';
      _notify();
      return false;
    }

    final Result<Order> outcome = await _orders.cancelOrder(
      order.id,
      cancellationReason: reason,
      authorizedBy: 'Manager', // Can be enhanced later with specific user IDs
    );
    final AppFailure? failure = outcome.failureOrNull;
    if (failure != null) {
      _isCancelling = false;
      _cancelError = failure.message;
      _notify();
      return false;
    }

    _didCancel = true;
    _isCancelling = false;
    // Re-read from storage rather than adjusted in memory, so the status and every figure
    // beside it are what is on disk.
    await load();
    _notify();
    return true;
  }

  /// Clears the cancellation failure notice, leaving the bill alone.
  void dismissCancelError() {
    if (_cancelError == null) {
      return;
    }
    _cancelError = null;
    _notify();
  }

  // --------------------------------------------------------------- internals ---

  /// Runs one reprint and turns the run into a sentence.
  ///
  /// Ignores a call made while one is in flight, so a double tap cannot put two copies of
  /// the same document on the queue. Beyond that there is nothing to guard: the run reads
  /// committed rows and writes none, so the worst a stray tap costs is paper.
  Future<bool> _reprint(
    Future<SalePrintRun> Function() send, {
    required String what,
    String? nothingToPrint,
  }) async {
    if (_isReprinting || _order == null) {
      return false;
    }

    _isReprinting = true;
    _reprintMessage = null;
    _didReprint = false;
    _notify();

    final SalePrintRun run = await send();
    _isReprinting = false;

    if (run.isEmpty) {
      _reprintMessage =
          nothingToPrint ?? 'There was nothing to print for this bill.';
      _notify();
      return false;
    }

    if (run.hasFailure) {
      // The printer's own words, prefixed with which document did not come out. The bill
      // itself is untouched and stays on screen behind this.
      _reprintMessage =
          '$what could not be printed. '
          '${run.failureReason ?? 'The printer did not respond.'}';
      _notify();
      return false;
    }

    _didReprint = true;
    _reprintMessage = '$what sent to the printer.';
    _notify();
    return true;
  }

  /// Re-reads the refund figures after a successful reversal.
  ///
  /// Deliberately not fatal. The refund has committed by the time this runs, so a read that
  /// fails here must not be reported as a refund that failed — that would be the one lie
  /// this screen could tell that costs money twice. The success stands and the figures are
  /// left as they were.
  Future<void> _reloadRefundable() async {
    final Result<RefundableBill?> refreshed = await _refunds.loadRefundable(
      _orderId,
    );
    final RefundableBill? bill = refreshed.valueOrNull;
    if (bill != null) {
      _refundable = bill;
    }
  }

  Future<Customer?> _customerFor(String? customerId) async {
    if (customerId == null) {
      return null;
    }
    final Result<Customer?> found = await _customers.findById(customerId);
    return found.fold<Customer?>(
      onOk: (Customer? customer) => customer,
      onErr: (AppFailure _) => null,
    );
  }

  /// Reports a read that failed, showing no part of the bill.
  ///
  /// Half a bill is worse than none: a subtotal beside lines that failed to load is a
  /// document nobody should be reading numbers off.
  void _fail(String message) {
    _errorMessage = message;
    _order = null;
    _lines = const <BillLineSnapshot>[];
    _tenders = const <Payment>[];
    _customer = null;
    // Cleared too, so no refund action can be offered against figures that failed to read.
    _refundable = null;
    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
