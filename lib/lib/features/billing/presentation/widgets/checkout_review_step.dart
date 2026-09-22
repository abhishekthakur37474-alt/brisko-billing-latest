import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../core/money/money_display.dart';
import '../../../customers/domain/models/customer.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../domain/models/bill_discount.dart';
import '../controllers/checkout_controller.dart';

/// First step: confirm how the order reaches the customer, and who they are.
///
/// The lines and the money are on the bill summary beside this step, so nothing is
/// repeated here. What this step collects is the two things the cart cannot know.
class CheckoutReviewStep extends StatelessWidget {
  const CheckoutReviewStep({super.key});

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: <Widget>[
        Text('Order type', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _OrderTypeChoices(),
        if (controller.askCustomerDetails) ...<Widget>[
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              Text('Customer', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                'Required',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _CustomerInfoFields(),
        ],
        const SizedBox(height: 24),
        if (DateTime.now().weekday == DateTime.friday &&
            controller.qualifyingMediumPizzas > 0) ...<Widget>[
          if (controller.qualifyingMediumPizzas == 1)
            FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.local_offer),
              label: const Text('FRIDAY BOGO: Add 1 more Medium Pizza to get 1 FREE'),
              style: FilledButton.styleFrom(
                disabledBackgroundColor: theme.colorScheme.tertiaryContainer,
                disabledForegroundColor: theme.colorScheme.onTertiaryContainer,
              ),
            )
          else
            FilledButton.icon(
              onPressed: context.read<CheckoutController>().applyFridayOffer,
              icon: const Icon(Icons.local_offer),
              label: Text('FRIDAY BOGO: ${controller.fridayBogoFreeQuantity} Medium Pizza(s) FREE. Tap to apply.'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.tertiary,
                foregroundColor: theme.colorScheme.onTertiary,
              ),
            ),
          const SizedBox(height: 16),
        ],
        const _DiscountControl(),
        const SizedBox(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print kitchen slip'),
          subtitle: const Text(
            'Send a KOT to the printer after this sale. Turned off, the '
            'slip is still written for the kitchen board; only the paper '
            'is skipped.',
          ),
          value: controller.printKitchenSlip,
          onChanged: (bool value) => context
              .read<CheckoutController>()
              .setPrintKitchenSlip(isEnabled: value),
        ),
        const SizedBox(height: 24),
        Text('Note on the bill', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        const _NotesField(),
      ],
    );
  }
}

/// Bill-level discount: whether there is one, how it is expressed, and how much.
///
/// ## Why it is here
///
/// A discount is a decision about one bill, taken as it is settled, so it belongs on the
/// step where the bill is reviewed rather than on the menu screen. The figures it moves —
/// subtotal, discount, taxable amount, GST, total — are all on the bill summary beside this
/// step, updating as the value is typed, so the cashier can see what they are giving away
/// before taking any money.
///
/// ## Closed by default
///
/// Most bills carry no discount, so the control is a switch with nothing behind it until it
/// is turned on. Turning it off removes the discount rather than hiding it: a reduction on a
/// bill with nothing on screen explaining it is the one state this must never be in.
///
/// ## Nothing is calculated here
///
/// The field reports each keystroke to the controller, which parses it once and rebuilds the
/// money block through `BillTotals`. This widget reads back the amount and the problem
/// message. There is no arithmetic and no parsing in this file.
class _DiscountControl extends StatelessWidget {
  const _DiscountControl();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('Discount', style: theme.textTheme.titleSmall),
            const Spacer(),
            Switch(
              value: controller.isDiscountOpen,
              onChanged: (bool isOpen) => context
                  .read<CheckoutController>()
                  .setDiscountOpen(isOpen: isOpen),
            ),
          ],
        ),
        if (!controller.isDiscountOpen)
          Text(
            'No discount on this bill.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else ...<Widget>[
          const SizedBox(height: 8),
          SegmentedButton<BillDiscountType>(
            segments: <ButtonSegment<BillDiscountType>>[
              for (final BillDiscountType type in BillDiscountType.values)
                ButtonSegment<BillDiscountType>(
                  value: type,
                  label: Text('${type.label} ${type.unit}'),
                ),
            ],
            selected: <BillDiscountType>{controller.discountType},
            onSelectionChanged: (Set<BillDiscountType> selection) => context
                .read<CheckoutController>()
                .selectDiscountType(selection.first),
          ),
          const SizedBox(height: 12),
          const _DiscountField(),
          const SizedBox(height: 8),
          _DiscountEffect(controller: controller),
        ],
      ],
    );
  }
}

/// Says what the discount currently entered is taking off, in rupees.
///
/// A percentage is not a figure anybody can check at a glance, so the amount it comes to is
/// stated outright. Read from the totals the controller calculated, never worked out here.
class _DiscountEffect extends StatelessWidget {
  const _DiscountEffect({required this.controller});

  final CheckoutController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (!controller.hasDiscount) {
      return Text(
        'Nothing is taken off yet.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final String taxNote = controller.isTaxCharged
        ? ' GST is then charged on '
              '${controller.totals.taxableAmount.formatted}.'
        : '';

    return Text(
      '${controller.discountRuleLabel} off: '
      '${controller.totals.discount.formatted}.$taxNote',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.primary,
      ),
    );
  }
}

/// The discount value, held by the controller and echoed here.
///
/// Digits and one decimal point are all the field accepts, so a letter or a second point
/// cannot reach the parser. Whether what is left amounts to a discount this bill can carry
/// is the controller's answer, shown as the error text.
class _DiscountField extends StatefulWidget {
  const _DiscountField();

  @override
  State<_DiscountField> createState() => _DiscountFieldState();
}

class _DiscountFieldState extends State<_DiscountField> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: context.read<CheckoutController>().discountEntry,
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();

    // The controller is the source of truth. It clears the entry when the rule changes or
    // the discount is removed, so the field is corrected back to what it actually holds.
    if (_field.text != controller.discountEntry) {
      _field.value = TextEditingValue(
        text: controller.discountEntry,
        selection: TextSelection.collapsed(
          offset: controller.discountEntry.length,
        ),
      );
    }

    final bool isPercentage =
        controller.discountType == BillDiscountType.percentage;

    return TextField(
      controller: _field,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        // Digits and at most one decimal point. Not a validation — the controller still
        // refuses anything that is not a discount — but it keeps the field from holding
        // characters that could never become one.
        FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
      ],
      decoration: InputDecoration(
        labelText: isPercentage ? 'Discount percentage' : 'Discount amount',
        hintText: isPercentage ? '10' : '100',
        prefixText: isPercentage ? null : '\u20B9 ',
        suffixText: isPercentage ? '%' : null,
        errorText: controller.discountProblem,
        helperText: isPercentage
            ? 'Taken off the subtotal. Up to 100%.'
            : 'Taken off the subtotal. No more than the subtotal itself.',
      ),
      onChanged: context.read<CheckoutController>().editDiscount,
    );
  }
}

class _OrderTypeChoices extends StatelessWidget {
  const _OrderTypeChoices();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final OrderType type in OrderType.values)
          ChoiceChip(
            label: Text(type.label),
            selected: controller.orderType == type,
            onSelected: (bool _) =>
                context.read<CheckoutController>().selectOrderType(type),
          ),
      ],
    );
  }
}

/// Phone entry, which is how the counter identifies a returning customer.
///
/// The controller keeps the digits of whatever is typed and decides whether they amount
/// to a usable number. It does not shorten anything to fit, so a number that cannot be
/// stored is reported here rather than quietly turned into a different one.
class _CustomerInfoFields extends StatefulWidget {
  const _CustomerInfoFields();

  @override
  State<_CustomerInfoFields> createState() => _CustomerInfoFieldsState();
}

class _CustomerInfoFieldsState extends State<_CustomerInfoFields> {
  late final TextEditingController _phoneField;
  late final TextEditingController _nameField;

  @override
  void initState() {
    super.initState();
    _phoneField = TextEditingController(
      text: context.read<CheckoutController>().customerPhone,
    );
    _nameField = TextEditingController(
      text: context.read<CheckoutController>().customerName,
    );
  }

  @override
  void dispose() {
    _phoneField.dispose();
    _nameField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();

    // The controller is the source of truth: it strips anything that is not a digit,
    // so the field is corrected back to what was actually accepted.
    if (_phoneField.text != controller.customerPhone) {
      _phoneField.value = TextEditingValue(
        text: controller.customerPhone,
        selection: TextSelection.collapsed(
          offset: controller.customerPhone.length,
        ),
      );
    }
    if (_nameField.text != controller.customerName) {
      _nameField.value = TextEditingValue(
        text: controller.customerName,
        selection: TextSelection.collapsed(
          offset: controller.customerName.length,
        ),
      );
    }

    final String? phoneProblem = controller.hasCustomerPhone
        ? controller.customerPhoneProblem
        : null;
    final String? nameProblem = controller.customerName.isNotEmpty
        ? controller.customerNameProblem
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          controller: _nameField,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Customer name',
            hintText: 'Name on the bill',
            prefixIcon: const Icon(Icons.person_outline),
            errorText: nameProblem,
            helperText: 'Needed for every order.',
          ),
          onChanged: context.read<CheckoutController>().setCustomerName,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _phoneField,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Phone number',
            hintText: '${CustomerPhone.digits} digits',
            prefixIcon: const Icon(Icons.phone_outlined),
            errorText: phoneProblem,
            helperText: 'Optional.',
          ),
          onChanged: context.read<CheckoutController>().setCustomerPhone,
        ),
        if (controller.isReturningCustomer) ...<Widget>[
          const SizedBox(height: 8),
          _ReturningCustomerNote(customer: controller.knownCustomer!),
        ],
      ],
    );
  }
}

/// Says that this number is already on file.
///
/// A hint, not a gate. It is here because knowing the person at the counter has been
/// before is worth a glance, and because it tells the cashier the number they typed is
/// the one they meant. Nothing about the sale depends on it.
class _ReturningCustomerNote extends StatelessWidget {
  const _ReturningCustomerNote({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? name = customer.name?.trim();

    return Row(
      children: <Widget>[
        Icon(
          Icons.how_to_reg_outlined,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name == null || name.isEmpty
                ? 'Returning customer'
                : 'Returning customer: $name',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

class _NotesField extends StatefulWidget {
  const _NotesField();

  @override
  State<_NotesField> createState() => _NotesFieldState();
}

class _NotesFieldState extends State<_NotesField> {
  late final TextEditingController _field;

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(
      text: context.read<CheckoutController>().notes,
    );
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _field,
      maxLines: 2,
      decoration: const InputDecoration(
        labelText: 'Note',
        hintText: 'Anything that should appear on the bill',
      ),
      onChanged: context.read<CheckoutController>().setNotes,
    );
  }
}
