import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/money/money_display.dart';
import '../../../customers/domain/models/customer_phone.dart';
import '../../../customers/domain/repositories/customer_repository.dart';
import '../../../inventory/domain/repositories/inventory_deduction_repository.dart';
import '../../../printing/domain/services/print_service.dart';
import '../../../settings/domain/active_pos_settings.dart';
import '../../../settings/domain/models/pos_settings.dart';
import '../../domain/models/gst_rate.dart';
import '../../domain/repositories/checkout_repository.dart';
import '../controllers/billing_controller.dart';
import '../controllers/checkout_controller.dart';
import '../widgets/bill_summary_panel.dart';
import '../widgets/checkout_confirm_step.dart';
import '../widgets/checkout_payment_step.dart';
import '../widgets/checkout_review_step.dart';
import '../widgets/checkout_success_step.dart';

/// Settlement, pushed full screen over the billing shell.
///
/// ## Why it is a route rather than a pane
///
/// The three-pane billing layout stays exactly as it was, underneath. Taking money is a
/// short, linear, interruptible task with an ordinary back button, which is what a route
/// gives for free, and the cashier returns to the same screen they left.
///
/// ## Where the cart comes from
///
/// The [CheckoutController] is created here and takes the billing cart as it stands at
/// the moment this route is pushed. That snapshot is immutable, so nothing in this flow
/// can edit the bill, and abandoning the flow leaves the live cart untouched. The live
/// cart is cleared only through `onSettled`, which fires after the write commits.
class CheckoutScreen extends StatelessWidget {
  const CheckoutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<CheckoutController>(
      create: (BuildContext context) {
        final BillingController billing = context.read<BillingController>();
        return CheckoutController(
          cart: billing.cart,
          checkoutRepository: context.read<CheckoutRepository>(),
          customerRepository: context.read<CustomerRepository>(),
          inventoryDeductionRepository: context
              .read<InventoryDeductionRepository>(),
          printService: context.read<PrintService>(),
          onSettled: billing.clearCart,
          // The outlet's configured default, read from the copy the bootstrap loaded
          // rather than from the settings table: a widget cannot await a query while it
          // builds, and a bill is not worth a loading state. Nullable on purpose, so a
          // test that pumps this screen on its own does not have to provide it and still
          // gets the same takeaway default the flow has always opened on.
          initialOrderType:
              context.read<ActivePosSettings?>()?.settings.defaultOrderType ??
              PosSettings.fallbackOrderType,
          // The rate in force, read from the same in-memory copy for the same reason: a
          // widget cannot await a query while it builds. Read once, here, so the rate
          // cannot move under a bill that is part-way through settlement, and stamped onto
          // the order when it commits.
          //
          // Nullable on purpose. A test that pumps this screen on its own gets
          // `GstRate.zero`, which is also what an outlet that has configured no rate gets:
          // no tax line, exactly as before this step.
          taxRate:
              context.read<ActivePosSettings?>()?.settings.gstRate ??
              GstRate.zero,
          printKitchenSlip:
              context.read<ActivePosSettings?>()?.settings.printKitchenSlip ??
              true,
          askCustomerDetails:
              context.read<ActivePosSettings?>()?.settings.askCustomerDetails ??
              true,
        );
      },
      child: const _CheckoutView(),
    );
  }
}

class _CheckoutView extends StatelessWidget {
  const _CheckoutView();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final bool isWide =
        MediaQuery.sizeOf(context).width >= AppConstants.wideLayoutBreakpoint;
    final bool showSummary = isWide && controller.step != CheckoutStep.success;

    return PopScope(
      // A write is in flight. Leaving now would abandon the screen that reports
      // whether the money was taken.
      canPop: !controller.isSubmitting,
      child: Scaffold(
        appBar: AppBar(
          title: Text(controller.step.label),
          leading: controller.previousStep == null && controller.isSettled
              ? null
              : BackButton(onPressed: () => _back(context, controller)),
          automaticallyImplyLeading: false,
        ),
        body: Row(
          children: <Widget>[
            Expanded(child: _StepBody(onDone: () => _leave(context))),
            if (showSummary) ...<Widget>[
              const VerticalDivider(width: 1),
              SizedBox(
                width: BillSummaryPanel.width,
                child: BillSummaryPanel(
                  cart: controller.cart,
                  totals: controller.totals,
                  customerName: controller.trimmedCustomerName.isEmpty
                      ? null
                      : controller.trimmedCustomerName,
                  customerPhone: controller.isCustomerPhoneComplete
                      ? CustomerPhone.forDisplay(
                          controller.normalisedCustomerPhone!,
                        )
                      : (controller.hasCustomerPhone
                            ? controller.customerPhone
                            : null),
                  customerAddress: controller.trimmedCustomerAddress.isEmpty
                      ? null
                      : controller.trimmedCustomerAddress,
                ),
              ),
            ],
          ],
        ),
        bottomNavigationBar: controller.step == CheckoutStep.success
            ? null
            : const _CheckoutActionBar(),
      ),
    );
  }

  /// Steps back through the flow, and leaves it at the first step.
  static void _back(BuildContext context, CheckoutController controller) {
    if (controller.isSubmitting) {
      return;
    }
    if (!controller.goBack()) {
      _leave(context);
    }
  }

  static void _leave(BuildContext context) => Navigator.of(context).pop();
}

class _StepBody extends StatelessWidget {
  const _StepBody({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final CheckoutStep step = context.select<CheckoutController, CheckoutStep>(
      (CheckoutController controller) => controller.step,
    );

    return switch (step) {
      CheckoutStep.review => const CheckoutReviewStep(),
      CheckoutStep.payment => const CheckoutPaymentStep(),
      CheckoutStep.confirm => const CheckoutConfirmStep(),
      CheckoutStep.success => CheckoutSuccessStep(onDone: onDone),
    };
  }
}

/// The one forward action for the current step, with the amount on it.
///
/// A single primary button per step, disabled until the step is complete, so there is
/// never a question about what happens next or why it will not.
class _CheckoutActionBar extends StatelessWidget {
  const _CheckoutActionBar();

  @override
  Widget build(BuildContext context) {
    final CheckoutController controller = context.watch<CheckoutController>();
    final ThemeData theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Payable',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          controller.amountPayable.formatted,
                          style: theme.textTheme.titleLarge,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  _PrimaryAction(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({required this.controller});

  final CheckoutController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.isSubmitting) {
      return const FilledButton(
        onPressed: null,
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    return switch (controller.step) {
      CheckoutStep.review => FilledButton.icon(
        onPressed: controller.canProceedToPayment
            ? controller.goToPayment
            : null,
        icon: const Icon(Icons.arrow_forward),
        label: const Text('Take payment'),
      ),
      CheckoutStep.payment => FilledButton.icon(
        onPressed: controller.canProceedToConfirm
            ? controller.goToConfirm
            : null,
        icon: const Icon(Icons.arrow_forward),
        label: const Text('Review payment'),
      ),
      CheckoutStep.confirm => FilledButton.icon(
        onPressed: controller.canSubmit ? controller.submit : null,
        icon: const Icon(Icons.check),
        label: Text('Charge ${controller.amountPayable.formatted}'),
      ),
      CheckoutStep.success => const SizedBox.shrink(),
    };
  }
}
