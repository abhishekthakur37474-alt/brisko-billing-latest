import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../customers/domain/models/customer.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../customers/domain/repositories/customer_repository.dart';
import '../../../inventory/domain/models/order_inventory_deduction.dart';
import '../../../inventory/domain/repositories/inventory_deduction_repository.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../payments/domain/models/payment_method.dart';
import '../../../printing/domain/models/sale_print_run.dart';
import '../../../printing/domain/services/print_service.dart';
import '../../domain/models/bill_discount.dart';
import '../../domain/models/bill_settlement.dart';
import '../../domain/models/bill_totals.dart';
import '../../domain/models/cart.dart';
import '../../domain/models/cash_tender.dart';
import '../../domain/models/gst_rate.dart';
import '../../domain/repositories/checkout_repository.dart';

/// Where the cashier is in the settlement flow.
enum CheckoutStep {
  /// Check the lines, the order type and the customer.
  review,

  /// Choose how it is being paid and, for cash, count the tender.
  payment,

  /// Last look before the money is taken.
  confirm,

  /// Settled. The order number exists and the cart is gone.
  success;

  String get label => switch (this) {
    CheckoutStep.review => 'Review bill',
    CheckoutStep.payment => 'Payment',
    CheckoutStep.confirm => 'Confirm payment',
    CheckoutStep.success => 'Bill settled',
  };
}

/// Drives settlement: review, tender, confirm, persist.
///
/// ## The cart is a snapshot
///
/// [cart] is the immutable cart handed over when checkout opened. It is not the live
/// billing cart, so nothing the cashier does here can edit the bill mid-settlement,
/// and backing out of the flow leaves the original untouched. The live cart is only
/// cleared through [onSettled], and only after the write has committed.
///
/// ## Money
///
/// Every amount is a [Money] in integer paise, including the cash keyed in, which is
/// accumulated digit by digit through [CashTender]. Nothing in this file reads an
/// amount out of a text field or converts one to a floating point value.
///
/// ## Submitting once
///
/// [submit] is guarded twice over. It refuses to run while a write is in flight or once
/// the bill is settled, and the [BillSettlement] it builds is cached, so a retry after a
/// failure carries the same order, line and payment ids. Even if the guard were
/// defeated, the second write would land on the same rows rather than create a second
/// bill.
///
/// ## The discount and the GST rate
///
/// The discount is entered here, on the review step, because it is a decision about this
/// bill taken at the moment of settling it. The GST rate is not entered at all: it is
/// handed in from the outlet's configuration when this controller is built, held for the
/// life of the flow, and copied onto the order. A rate change part-way through a bill
/// cannot move the figure the cashier is looking at.
///
/// Every figure comes from [totals], which is a [BillTotals] rebuilt through the one
/// authoritative calculation each time the discount moves. The cash keypad's target and
/// the amount on the Charge button read the same value, and [submit] rebuilds it once more
/// from the same cart and the same two inputs, so the row written cannot differ from the
/// amount shown.
class CheckoutController extends ChangeNotifier {
  CheckoutController({
    required Cart cart,
    required this._checkoutRepository,
    required this._customerRepository,
    required this._inventoryDeductionRepository,
    required this._printService,
    required this._onSettled,
    OrderType initialOrderType = OrderType.takeaway,
    GstRate taxRate = GstRate.zero,
    bool printKitchenSlip = true,
    bool askCustomerDetails = true,
  }) : _cart = cart,
       _orderType = initialOrderType,
       _taxRate = taxRate,
       _printKitchenSlip = printKitchenSlip,
       _askCustomerDetails = askCustomerDetails,
       _totals = BillTotals.forCart(cart: cart, taxRate: taxRate),
       _cashTender = CashTender(
         payable: BillTotals.forCart(cart: cart, taxRate: taxRate).total,
       );

  /// Digits in the stored form of a phone number.
  ///
  /// Kept here as well as on [CustomerPhone] because the screen reads it, and the rule
  /// itself lives in one place.
  static const int phoneDigits = CustomerPhone.digits;

  final Cart _cart;
  final CheckoutRepository _checkoutRepository;
  final CustomerRepository _customerRepository;
  final InventoryDeductionRepository _inventoryDeductionRepository;
  final PrintService _printService;
  final VoidCallback _onSettled;

  /// The rate this bill is charged at, fixed when the flow opened.
  ///
  /// Not settable. A cashier does not choose a tax rate at the counter; the outlet
  /// configures one in Settings and every bill taken afterwards carries it.
  final GstRate _taxRate;

  /// Whether a kitchen slip is sent to the printer after this sale.
  ///
  /// Starts from Settings when the flow opened. The cashier can change it on this
  /// bill; the slip is still written either way.
  bool _printKitchenSlip;

  /// Whether this bill asks for a name and phone, and prints both on the receipt.
  ///
  /// Read from Settings when the flow opened, so a change mid-settlement cannot
  /// drop fields the cashier has already filled.
  final bool _askCustomerDetails;

  /// The current money block. Replaced whole whenever the discount moves.
  BillTotals _totals;

  /// The discount rule in force, as parsed from what has been typed.
  ///
  /// [BillDiscount.none] until something is entered, and back to none when the field is
  /// cleared. A value that cannot be read leaves this at its last good state and reports
  /// itself through [discountProblem], so a half-typed figure never silently changes the
  /// amount charged.
  BillDiscount _discount = BillDiscount.none;

  /// Which rule the operator is entering. Percentage by default, which is the common case.
  BillDiscountType _discountType = BillDiscountType.percentage;

  /// What has been typed, exactly as typed.
  ///
  /// Held as text rather than as a number so that `12.` mid-entry is a state the field can
  /// be in without the bill total flickering, and so a value that is not a discount is
  /// reported beside the field instead of being rounded into one.
  String _discountEntry = '';

  /// True once the operator has opened the discount control.
  ///
  /// Distinct from "a discount of zero": the control is closed on a bill nobody is
  /// discounting, so the review step is not carrying a field that almost always stays
  /// empty.
  bool _isDiscountOpen = false;

  CheckoutStep _step = CheckoutStep.review;

  /// Which type the flow opened on, until the cashier changes it.
  ///
  /// Takeaway unless the outlet has configured a different default in Settings. A default
  /// only decides which of the four is already selected; every one of them stays
  /// available on the review step, because the type is a fact about the order rather
  /// than a preference.
  OrderType _orderType;
  String _customerName = '';
  String _customerPhone = '';
  String _customerAddress = '';
  String _notes = '';
  PaymentMethod? _paymentMethod;
  CashTender _cashTender;
  String _reference = '';

  bool _isSubmitting = false;
  String? _errorMessage;
  Order? _settledOrder;

  bool _isDisposed = false;

  bool _isPrinting = false;
  SalePrintRun? _printRun;

  OrderInventoryDeduction? _deduction;
  String? _inventoryMessage;

  /// Fixed once built, so a retry cannot write a second bill.
  BillSettlement? _settlement;

  /// The customer already on file for the number entered, if there is one.
  ///
  /// A read, never a write. It exists so the cashier can see they are serving somebody
  /// the outlet already knows before taking the money, which is the moment that is
  /// useful. The customer record for a new number is created by settlement, not here.
  Customer? _knownCustomer;

  // ------------------------------------------------------------------- state ---

  CheckoutStep get step => _step;

  /// The bill being settled. Immutable for the lifetime of this controller.
  Cart get cart => _cart;

  /// The money block for this bill: subtotal, discount, taxable amount, GST and total.
  ///
  /// The single source of every figure the flow shows, and the same value [submit] writes.
  BillTotals get totals => _totals;

  /// Amount to collect.
  Money get amountPayable => _totals.total;

  // ---------------------------------------------------------------- discount ---

  /// The GST rate this bill is being charged at.
  GstRate get taxRate => _taxRate;

  /// True when the outlet has configured a rate, so the bill carries a tax line.
  bool get isTaxCharged => _taxRate.isCharged;

  /// True when the discount control is open on the review step.
  bool get isDiscountOpen => _isDiscountOpen;

  /// Which rule the operator is entering.
  BillDiscountType get discountType => _discountType;

  /// What has been typed into the discount field, exactly as typed.
  String get discountEntry => _discountEntry;

  /// The rule in force. [BillDiscount.none] when nothing is being taken off.
  BillDiscount get discount => _discount;

  /// `10%` or `₹100.00`, describing the rule currently applied.
  String get discountRuleLabel => _discount.label;

  /// True when a discount is actually reducing this bill.
  bool get hasDiscount => _totals.hasDiscount;

  /// What is wrong with the discount entered, or `null` when there is nothing to say.
  ///
  /// Silent on an empty field, because an empty discount field is the normal state of a
  /// bill rather than a mistake. Reports a value that cannot be read as a number, and a
  /// value that is a number but not a discount this bill can carry — over 100%, or more
  /// than the subtotal.
  String? get discountProblem {
    if (!_isDiscountOpen || _discountEntry.trim().isEmpty) {
      return null;
    }

    final BillDiscount? parsed = BillDiscount.tryParse(
      type: _discountType,
      value: _discountEntry,
    );
    if (parsed == null) {
      return switch (_discountType) {
        BillDiscountType.percentage =>
          'Enter a percentage between 0 and 100, for example 10 or 12.5.',
        BillDiscountType.amount =>
          'Enter an amount in rupees, for example 100 or 99.50.',
      };
    }

    return parsed.problemOn(_totals.subtotal);
  }

  /// True when the discount, if any, is one this bill may be settled with.
  bool get isDiscountAcceptable => discountProblem == null;

  OrderType get orderType => _orderType;

  /// Digits the cashier has entered, or empty for a walk-in.
  ///
  /// What was typed, not what will be stored. See [normalisedCustomerPhone].
  String get customerPhone => _customerPhone;

  /// The number as it will be stored, or `null` when what was entered is not usable.
  ///
  /// `null` covers both a half-typed number and one that cannot be made sense of. The
  /// difference is [hasCustomerPhone].
  String? get normalisedCustomerPhone =>
      CustomerPhone.tryNormalise(_customerPhone);

  /// The customer already on file for the entered number, or `null`.
  ///
  /// Populated by a lookup as the number is completed. `null` also means "not looked up
  /// yet" or "the lookup failed", so this drives a hint on screen and nothing else.
  Customer? get knownCustomer => _knownCustomer;

  /// True when the number entered belongs to a customer the outlet has already served.
  bool get isReturningCustomer => _knownCustomer != null;

  String get notes => _notes;

  PaymentMethod? get paymentMethod => _paymentMethod;

  /// Cash counted out. Only meaningful when [paymentMethod] is cash.
  CashTender get cashTender => _cashTender;

  /// Transaction reference for a non-cash payment. Optional.
  String get reference => _reference;

  bool get isSubmitting => _isSubmitting;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  // ---------------------------------------------------------------- printing ---
  //
  // Printing state is kept apart from settlement state on purpose. `errorMessage` is
  // about the sale and blocks it; nothing below blocks anything, because by the time
  // any of it is set the money is already collected and recorded.

  /// How the printing of this sale went, or `null` before it has been attempted.
  SalePrintRun? get printRun => _printRun;

  bool get isPrinting => _isPrinting;

  /// True when the bill is settled but a document did not reach the printer.
  bool get hasPrintFailure => _printRun?.hasFailure ?? false;

  /// True when there is a settled bill whose paperwork can be sent again.
  ///
  /// Offered from the moment the bill is on disk, whether the first attempt printed or
  /// not. Reprinting reads the committed sale and writes nothing, so there is no state in
  /// which it is unsafe — only one in which there is no order to read.
  bool get canReprint => _settledOrder != null && !_isPrinting;

  /// True when every document printed.
  bool get isPrinted => _printRun?.isComplete ?? false;

  /// The whole message for the cashier, leading with the fact that the money is safe.
  String? get printMessage => _printRun?.operatorMessage;

  // --------------------------------------------------------------- inventory ---
  //
  // Kept apart from settlement state for the same reason printing is, and for a
  // stronger version of the same reason. Nothing below can block the sale, because
  // everything below happens after the money is committed. A shelf that is short is a
  // stock figure for the owner to correct, not a reason to charge the customer again.

  /// How the stock deduction for this bill went, or `null` before it has been
  /// attempted.
  OrderInventoryDeduction? get deduction => _deduction;

  /// A note for the cashier about stock, or `null` when there is nothing to say.
  ///
  /// Set only when something needs reporting: the deduction failed, or the bill
  /// contained an item with no recipe. A successful deduction is silent, because the
  /// cashier has no decision to make about it.
  String? get inventoryMessage => _inventoryMessage;

  bool get hasInventoryNotice => _inventoryMessage != null;

  /// The settled order once the write has committed, otherwise `null`.
  Order? get settledOrder => _settledOrder;

  bool get isSettled => _settledOrder != null;

  /// Number printed on the bill, available only after settlement.
  String? get orderNumber => _settledOrder?.orderNumber;

  // ----------------------------------------------------------------- derived ---

  /// True when there is a bill worth settling at all.
  bool get hasBill => _cart.isNotEmpty && _totals.isPayable;

  /// True when a phone number must be entered before payment.
  ///
  /// Phone is optional. A half-typed number still has to be completed or cleared.
  bool get requiresCustomerPhone => false;

  /// True when checkout collects a name and phone, and the receipt prints both.
  bool get askCustomerDetails => _askCustomerDetails;

  /// True when a kitchen slip is sent to the printer after this sale.
  bool get printKitchenSlip => _printKitchenSlip;

  /// Turns kitchen-slip paper on or off for this bill.
  ///
  /// The ticket is still written for the kitchen board. This only decides whether
  /// paper comes out after settlement. Ignored once the bill is settled, because
  /// the print already ran with the choice that was in force then.
  void setPrintKitchenSlip({required bool isEnabled}) {
    if (_printKitchenSlip == isEnabled || isSettled) {
      return;
    }
    _printKitchenSlip = isEnabled;
    notifyListeners();
  }

  bool get hasCustomerPhone => _customerPhone.isNotEmpty;

  String get customerName => _customerName;

  String get trimmedCustomerName => _customerName.trim();

  bool get hasCustomerName => trimmedCustomerName.isNotEmpty;

  String get customerAddress => _customerAddress;

  String get trimmedCustomerAddress => _customerAddress.trim();

  bool get hasCustomerAddress => trimmedCustomerAddress.isNotEmpty;

  /// True when this bill is a delivery and therefore needs an address.
  bool get requiresCustomerAddress => _orderType == OrderType.delivery;

  /// True when what has been entered reduces to a number that can be stored.
  bool get isCustomerPhoneComplete => normalisedCustomerPhone != null;

  /// True when the customer fields this bill requires have been filled.
  ///
  /// When Settings asks for customer details, a name is required and the phone is
  /// optional. When it does not, a walk-in is acceptable — but a half-typed number
  /// still blocks, because filing the bill under a stranger is worse than leaving
  /// it unnamed.
  ///
  /// Delivery always needs an address, even when customer details are otherwise
  /// optional: a pizza leaving the outlet has to reach a door.
  bool get isCustomerAcceptable {
    if (hasCustomerPhone && !isCustomerPhoneComplete) {
      return false;
    }
    if (requiresCustomerAddress && !hasCustomerAddress) {
      return false;
    }
    if (!_askCustomerDetails) {
      return true;
    }
    return hasCustomerName;
  }

  /// What is wrong with the number entered, or `null` when there is nothing to say.
  ///
  /// Phone is optional, so a blank field is fine. Anything that cannot be stored
  /// says what is wanted instead, because the alternative — a silently shortened
  /// number — files the bill under a stranger.
  String? get customerPhoneProblem {
    if (!hasCustomerPhone) {
      return null;
    }
    return isCustomerPhoneComplete ? null : CustomerPhone.requirement;
  }

  /// What is wrong with the name entered, or `null` when there is nothing to say.
  String? get customerNameProblem {
    if (hasCustomerName) {
      return null;
    }
    return _askCustomerDetails ? 'A name is needed for every order.' : null;
  }

  /// What is wrong with the address entered, or `null` when there is nothing to say.
  String? get customerAddressProblem {
    if (hasCustomerAddress) {
      return null;
    }
    return requiresCustomerAddress
        ? 'An address is needed for a delivery order.'
        : null;
  }

  /// True when the review step is complete enough to take payment.
  ///
  /// A discount that cannot be read blocks the step rather than being ignored. Carrying on
  /// with the last good total while a refused figure sits on screen is how a customer gets
  /// charged an amount nobody agreed to.
  bool get canProceedToPayment =>
      hasBill && isCustomerAcceptable && isDiscountAcceptable;

  /// True when the cash counted covers the bill, or the method is not cash.
  bool get isTenderSufficient {
    if (_paymentMethod != PaymentMethod.cash) {
      return true;
    }
    return _cashTender.isSufficient;
  }

  /// Change owed back. Zero for a non-cash payment or a short tender.
  Money get changeDue =>
      _paymentMethod == PaymentMethod.cash ? _cashTender.change : Money.zero;

  /// True when the payment step is complete.
  bool get canProceedToConfirm =>
      canProceedToPayment && _paymentMethod != null && isTenderSufficient;

  /// True when the money may be taken and the bill written.
  bool get canSubmit => canProceedToConfirm && !_isSubmitting && !isSettled;

  /// The step [goBack] would move to, or `null` when there is nowhere to go.
  ///
  /// `null` at [CheckoutStep.review] means the flow is at its start and the screen
  /// should leave. `null` at [CheckoutStep.success] means the bill is settled and
  /// there is nothing to go back to.
  CheckoutStep? get previousStep => switch (_step) {
    CheckoutStep.review => null,
    CheckoutStep.payment => CheckoutStep.review,
    CheckoutStep.confirm => CheckoutStep.payment,
    CheckoutStep.success => null,
  };

  // ----------------------------------------------------------------- intents ---

  void selectOrderType(OrderType type) {
    if (_orderType == type || isSettled) {
      return;
    }
    _orderType = type;
    _invalidateSettlement();
    notifyListeners();
  }

  /// Opens the discount control, or closes it and removes any discount.
  ///
  /// Closing removes rather than hides. A discount left applied behind a collapsed control
  /// would be a reduction on the bill with nothing on screen explaining it, which is the
  /// one thing a discount must never be.
  void setDiscountOpen({required bool isOpen}) {
    if (_isDiscountOpen == isOpen || isSettled) {
      return;
    }
    _isDiscountOpen = isOpen;
    if (!isOpen) {
      _discountEntry = '';
      _applyDiscount(BillDiscount.none);
      return;
    }
    notifyListeners();
  }

  /// Switches between a percentage and a flat amount.
  ///
  /// The entry is cleared, because `10` means ten percent under one rule and ten rupees
  /// under the other. Carrying the digits across would silently change what the customer
  /// is given.
  void selectDiscountType(BillDiscountType type) {
    if (_discountType == type || isSettled) {
      return;
    }
    _discountType = type;
    _discountEntry = '';
    _applyDiscount(BillDiscount.none);
  }

  /// Records what has been typed into the discount field, and recalculates the bill.
  ///
  /// A value that cannot be read leaves the applied discount where it was and surfaces
  /// through [discountProblem]; the step will not advance until it is corrected. A value
  /// that reads but is refused for this bill — over 100%, or more than the subtotal — is
  /// likewise not applied. Clearing the field removes the discount.
  void editDiscount(String value) {
    if (_discountEntry == value || isSettled) {
      return;
    }
    _discountEntry = value;

    final BillDiscount? parsed = BillDiscount.tryParse(
      type: _discountType,
      value: value,
    );

    if (parsed == null || parsed.problemOn(_totals.subtotal) != null) {
      // Not applied. The figure on the button stays the last one that was valid, and the
      // step is blocked, so nothing can be charged against a discount that was refused.
      _invalidateSettlement();
      notifyListeners();
      return;
    }

    _applyDiscount(parsed);
  }

  /// Removes the discount and empties the field, leaving the control open.
  void clearDiscount() {
    if (isSettled) {
      return;
    }
    _discountEntry = '';
    _applyDiscount(BillDiscount.none);
  }

  /// Number of qualifying medium pizzas for the Friday BOGO offer.
  int get qualifyingMediumPizzas => _cart.fridayMediumPizzaUnitPrices.length;

  /// Number of free medium pizzas available under the Friday BOGO offer.
  int get fridayBogoFreeQuantity => qualifyingMediumPizzas ~/ 2;

  /// Calculates and applies the Friday BOGO offer (Buy 1 Get 1 Free on medium pizzas).
  void applyFridayOffer() {
    if (isSettled) {
      return;
    }
    if (DateTime.now().weekday != DateTime.friday) {
      return;
    }
    
    final int freeCount = fridayBogoFreeQuantity;
    if (freeCount < 1) {
      return;
    }

    final List<Money> unitPrices = _cart.fridayMediumPizzaUnitPrices;
    // Sort from lowest to highest.
    unitPrices.sort((Money a, Money b) => a.compareTo(b));
    
    // Sum the cheapest `freeCount` pizzas to determine the discount amount.
    Money discountAmount = Money.zero;
    for (int i = 0; i < freeCount; i++) {
      discountAmount += unitPrices[i];
    }
    
    _discountType = BillDiscountType.amount;
    _discountEntry = discountAmount.toDecimalString();
    
    // Set the control open so the user sees the discount field populated
    _isDiscountOpen = true;

    final BillDiscount discount = BillDiscount.amount(discountAmount);
    if (discount.problemOn(_totals.subtotal) != null) {
      // In case the discount is somehow invalid (e.g. exceeds subtotal)
      return;
    }
    _applyDiscount(discount);
  }

  /// Records the customer's phone number, keeping only the digits.
  ///
  /// Punctuation and spaces are stripped, because a number pasted as `+91 98765 43210`
  /// is the number the cashier meant and refusing it at the till would be pedantry. What
  /// is *not* done is shortening: the digits are kept as entered, up to the length of a
  /// full international number, and whether they amount to a usable phone number is
  /// answered by [isCustomerPhoneComplete].
  ///
  /// The distinction matters. Keeping the first ten digits of `+91 90000 00001` would
  /// produce `9190000000`, a real number belonging to somebody else, and file the bill
  /// against them. Refusing it tells the cashier to look again.
  void setCustomerPhone(String value) {
    final String digits = CustomerPhone.digitsOf(value);

    if (_customerPhone == digits || isSettled) {
      return;
    }
    _customerPhone = digits;
    // A different number is a different customer, so any record found for the old one
    // is stale.
    _knownCustomer = null;
    _invalidateSettlement();
    notifyListeners();

    unawaited(_lookUpCustomer(digits));
  }

  void setCustomerName(String value) {
    if (_customerName == value || isSettled) {
      return;
    }
    _customerName = value;
    _invalidateSettlement();
    notifyListeners();
  }

  void setCustomerAddress(String value) {
    if (_customerAddress == value || isSettled) {
      return;
    }
    _customerAddress = value;
    _invalidateSettlement();
    notifyListeners();
  }

  void setNotes(String value) {
    if (_notes == value || isSettled) {
      return;
    }
    _notes = value;
    _invalidateSettlement();
    notifyListeners();
  }

  void selectPaymentMethod(PaymentMethod method) {
    if (_paymentMethod == method || isSettled) {
      return;
    }
    _paymentMethod = method;
    // A method change resets the counted cash: leaving ₹500 on screen after
    // switching to UPI and back would show a tender nobody put down.
    _cashTender = CashTender(payable: amountPayable);
    _reference = '';
    _invalidateSettlement();
    notifyListeners();
  }

  void setReference(String value) {
    if (_reference == value || isSettled) {
      return;
    }
    _reference = value;
    _invalidateSettlement();
    notifyListeners();
  }

  /// One keypad press. Ignored unless cash is the chosen method.
  void appendTenderDigit(int digit) =>
      _updateTender((CashTender tender) => tender.appendDigit(digit));

  void removeTenderDigit() =>
      _updateTender((CashTender tender) => tender.removeLastDigit());

  void clearTender() => _updateTender((CashTender tender) => tender.cleared());

  /// Sets the tender to the exact amount payable.
  void tenderExact() => _updateTender((CashTender tender) => tender.exact());

  /// Adds a note the customer handed over.
  void addTenderNote(Money note) =>
      _updateTender((CashTender tender) => tender.addNote(note));

  void goToPayment() {
    if (_step != CheckoutStep.review || !canProceedToPayment) {
      return;
    }
    _step = CheckoutStep.payment;
    _errorMessage = null;
    notifyListeners();
  }

  void goToConfirm() {
    if (_step != CheckoutStep.payment || !canProceedToConfirm) {
      return;
    }
    _step = CheckoutStep.confirm;
    _errorMessage = null;
    notifyListeners();
  }

  /// Steps back one stage. Returns false when there is nowhere to go, which is the
  /// screen's signal to leave the flow.
  ///
  /// Going back never touches the bill: the cart is a snapshot and the tender is kept,
  /// so a cashier who wants to check a line before taking the money loses nothing.
  bool goBack() {
    final CheckoutStep? previous = previousStep;
    if (previous == null) {
      return false;
    }
    _step = previous;
    _errorMessage = null;
    notifyListeners();
    return true;
  }

  /// Dismisses a failure message without leaving the confirm step.
  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    notifyListeners();
  }

  /// Takes the money: writes the bill, its payment, its kitchen slip and, when a number
  /// was taken, its customer — all in one transaction.
  ///
  /// Does nothing when the bill is not ready, when a write is already in flight, or
  /// when the bill is already settled. On success the live cart is cleared through
  /// `onSettled` and the flow moves to [CheckoutStep.success]. On failure nothing at all
  /// was persisted — not even the customer record — the cart is untouched, and the same
  /// settlement can be submitted again.
  Future<void> submit() async {
    if (!canSubmit) {
      return;
    }

    _isSubmitting = true;
    _errorMessage = null;
    _notify();

    final BillSettlement settlement = _settlement ??= BillSettlement.fromCart(
      cart: _cart,
      orderType: _orderType,
      paymentMethod: _paymentMethod!,
      // The two inputs to the money block, handed on so the settlement recomputes exactly
      // the figures on screen rather than being told the answer. The rate is the one this
      // flow opened with, which is what gets stamped onto the bill.
      discount: _discount,
      taxRate: _taxRate,
      // The number, not a customer id. The repository resolves it inside the settlement
      // transaction, so a failed sale cannot leave a customer behind and a retry cannot
      // create a second one.
      customerName: _customerName.trim().isEmpty ? null : _customerName.trim(),
      customerPhone: normalisedCustomerPhone,
      customerAddress: requiresCustomerAddress && _customerAddress.trim().isNotEmpty
          ? _customerAddress.trim()
          : null,
      reference: _referenceOrNull,
      notes: _notesOrNull,
    );

    // The settlement rebuilt the money block from the same cart and the same two inputs, so
    // it must have arrived at the same figures. Checked rather than assumed, because this is
    // the last point before the amount becomes the customer's receipt: if the two ever
    // disagreed, the cashier would have confirmed one number and the till would hold
    // another. Refused rather than reconciled — there is no correct way to pick a winner.
    if (settlement.totals != _totals) {
      _settlement = null;
      _errorMessage =
          'This bill was not settled: the amount recalculated at settlement '
          'does not match the ${_totals.total.toDecimalString()} confirmed. '
          'Check the bill and try again.';
      _isSubmitting = false;
      _notify();
      return;
    }

    final Result<Order> result = await _checkoutRepository.settle(settlement);

    result.fold<void>(
      onOk: (Order order) {
        _settledOrder = order;
        _step = CheckoutStep.success;
        // Only now, and only once the write has committed.
        _onSettled();
      },
      onErr: (AppFailure failure) => _errorMessage = failure.message,
    );

    _isSubmitting = false;
    _notify();

    // Strictly after the commit, and deliberately after the success step is already
    // on screen. The sale is finished at this point whatever the printer or the shelf
    // does.
    if (_settledOrder != null) {
      await _print();
      await _deductStock();
    }
  }

  /// Dismisses the stock note, leaving the settled bill on screen.
  ///
  /// Clears a message, not a record. The deduction row stays exactly as it is, so a
  /// bill whose stock was not taken off remains on the owner's list in Inventory even
  /// after the cashier has moved on. That is the point of writing it down.
  void dismissInventoryNotice() {
    if (_inventoryMessage == null) {
      return;
    }
    _inventoryMessage = null;
    notifyListeners();
  }

  /// Sends the receipt and the kitchen slip again, for the documents that failed.
  ///
  /// Prints; it does not settle. The bill is already on disk, so this cannot produce a
  /// second order, payment or kitchen slip, and the cashier can press it as many times
  /// as the printer needs.
  Future<void> retryPrinting() async {
    final SalePrintRun? run = _printRun;
    if (run == null || !run.hasFailure || _isPrinting) {
      return;
    }

    _isPrinting = true;
    _notify();

    _printRun = await _printService.retry(run);
    _isPrinting = false;
    _notify();
  }

  /// Prints the customer's receipt again.
  ///
  /// For the copy that jammed, tore, or that the customer asked for after the first one
  /// went in the bin. Distinct from [retryPrinting], which re-sends only what failed:
  /// this sends the receipt whatever happened to it, and only the receipt, because
  /// re-cutting a kitchen slip for food that is already being cooked puts a second order
  /// into the pass.
  ///
  /// Rebuilt from the committed order, so it cannot disagree with the bill, and it writes
  /// nothing: no second order, no second payment, no second kitchen slip, no stock
  /// movement.
  Future<void> reprintReceipt() =>
      _reprint(() => _printService.reprintReceipt(_settledOrder!.id));

  /// Prints the order's kitchen slips again, and nothing else.
  ///
  /// For a slip lost between the counter and the pass. It raises no new ticket and does
  /// not disturb where the existing ones stand in pending → preparing → ready.
  Future<void> reprintKitchenSlips() =>
      _reprint(() => _printService.reprintKitchenSlips(_settledOrder!.id));

  /// Dismisses the printing notice, leaving the settled bill on screen.
  ///
  /// For the case where the cashier has decided the customer does not need paper. The
  /// sale is unaffected: this clears a message, not a record.
  void dismissPrintFailure() {
    if (_printRun == null || !_printRun!.hasFailure) {
      return;
    }
    _printRun = null;
    notifyListeners();
  }

  // --------------------------------------------------------------- internals ---

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Looks up whether the number entered is already on file.
  ///
  /// Read-only, and deliberately so: nothing is created until the bill settles. A
  /// failure is swallowed, because this only drives a hint. The counter can take the
  /// money whether or not the customer table could be read.
  ///
  /// The result is discarded if the number changed while the read was in flight, so a
  /// cashier typing quickly cannot be shown the customer for a number they have already
  /// moved past.
  Future<void> _lookUpCustomer(String enteredDigits) async {
    final String? normalised = CustomerPhone.tryNormalise(enteredDigits);
    if (normalised == null) {
      return;
    }

    final Result<Customer?> found = await _customerRepository.findByPhone(
      normalised,
    );

    if (_customerPhone != enteredDigits || isSettled) {
      return;
    }

    final Customer? customer = found.fold<Customer?>(
      onOk: (Customer? value) => value,
      onErr: (AppFailure _) => null,
    );
    if (customer == null) {
      return;
    }

    _knownCustomer = customer;
    if (customer.name != null && customer.name!.trim().isNotEmpty && _customerName.isEmpty) {
      _customerName = customer.name!.trim();
    }
    _notify();
  }

  /// Notifies unless the controller has already been disposed.
  ///
  /// The two things that happen after the money commits — printing and the stock
  /// deduction — can still be in flight when the cashier leaves the success screen and
  /// starts the next bill. Both are deliberately allowed to finish, because the bill is
  /// already written and their outcomes are recorded where they belong: the print run in
  /// the printer's own reporting, and the deduction durably in the database. Only the
  /// notification is dropped, since there is no longer a screen to tell.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }

  /// Prints the paperwork for the settled bill.
  ///
  /// Never touches [_errorMessage], [_settledOrder] or [_step]. A printer that is
  /// missing, jammed or unplugged must not make a settled bill look unsettled, so the
  /// outcome lands only in [_printRun].
  Future<void> _print() async {
    final Order? order = _settledOrder;
    if (order == null) {
      return;
    }

    _isPrinting = true;
    _notify();

    _printRun = await _printService.printSale(
      order.id,
      printKitchenSlip: _printKitchenSlip,
    );
    _isPrinting = false;
    _notify();
  }

  /// Sends paperwork for the settled bill again, and reports the outcome in [printRun].
  ///
  /// Shares [_isPrinting] and [_printRun] with the first attempt on purpose: there is one
  /// printer and one thing on screen saying how it is getting on, and a second set of
  /// fields would let the two disagree.
  ///
  /// Never touches [_errorMessage], [_settledOrder] or [_step], for the same reason
  /// [_print] does not. Nothing below can make a settled bill look unsettled.
  Future<void> _reprint(Future<SalePrintRun> Function() send) async {
    if (_settledOrder == null || _isPrinting) {
      return;
    }

    _isPrinting = true;
    _notify();

    _printRun = await send();
    _isPrinting = false;
    _notify();
  }

  /// Takes the bill's ingredients off the shelf.
  ///
  /// Never touches [_errorMessage], [_settledOrder] or [_step], for the same reason
  /// [_print] does not, and with less room for argument: this runs after the money is
  /// in the till and the bill is on disk. A recipe that cannot be fulfilled, a stock
  /// item somebody deleted, or a storage fault must not make a settled bill look
  /// unsettled. The outcome lands in [_deduction] and, only when there is something to
  /// say, in [_inventoryMessage].
  ///
  /// The repository has already recorded a failure durably by the time this returns,
  /// so nothing is lost when the cashier starts the next bill.
  Future<void> _deductStock() async {
    final Order? order = _settledOrder;
    if (order == null) {
      return;
    }

    final Result<OrderInventoryDeduction> result =
        await _inventoryDeductionRepository.deductForOrder(order.id);

    result.fold<void>(
      onOk: (OrderInventoryDeduction deduction) {
        _deduction = deduction;
        // Silent on a clean deduction. Reports only an item with no recipe, which is
        // the owner's cue to configure one.
        _inventoryMessage = deduction.operatorMessage;
      },
      onErr: (AppFailure failure) {
        // Deliberately not `errorMessage`: that field is about the sale, and the sale
        // succeeded.
        _inventoryMessage =
            'Bill ${order.orderNumber} is settled. Stock was not deducted: '
            '${failure.message}';
      },
    );

    _notify();
  }

  String? get _referenceOrNull {
    final String trimmed = _reference.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? get _notesOrNull {
    final String trimmed = _notes.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _updateTender(CashTender Function(CashTender tender) change) {
    if (_paymentMethod != PaymentMethod.cash || isSettled) {
      return;
    }
    final CashTender updated = change(_cashTender);
    if (updated == _cashTender) {
      return;
    }
    _cashTender = updated;
    notifyListeners();
  }

  /// Applies [discount] and rebuilds everything downstream of the total.
  ///
  /// One place, so the three things that have to move together always do: the money block,
  /// the target the cash keypad is counting towards, and the cached settlement. A discount
  /// applied without resetting the tender would leave ₹1,000 on screen as sufficient for a
  /// bill that is now ₹1,062, and the cashier would be told the customer had paid enough.
  ///
  /// The tender is cleared rather than carried over, for the same reason a payment method
  /// change clears it: cash the customer has not put down must not be shown as counted.
  void _applyDiscount(BillDiscount discount) {
    _discount = discount;
    _totals = BillTotals.forCart(
      cart: _cart,
      discount: discount,
      taxRate: _taxRate,
    );
    _cashTender = CashTender(payable: _totals.total);
    _invalidateSettlement();
    notifyListeners();
  }

  /// Drops a built settlement after an input changed.
  ///
  /// The settlement is a frozen copy of the bill and its tender. Once the order type,
  /// the customer or the payment method moves, that copy would write the wrong thing,
  /// so it is discarded and rebuilt on the next submit.
  void _invalidateSettlement() {
    if (isSettled) {
      return;
    }
    _settlement = null;
  }
}
