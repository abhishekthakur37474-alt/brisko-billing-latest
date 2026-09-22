import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../auth/presentation/widgets/account_settings_section.dart';
import '../../../billing/domain/models/gst_rate.dart';
import '../../../cloud_sync/presentation/widgets/cloud_sync_settings_section.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../../printing/domain/models/print_profile.dart';
import '../../../printing/domain/models/print_settings.dart';
import '../../../printing/presentation/widgets/printer_setup_section.dart';
import '../../domain/models/pos_settings.dart';
import '../controllers/settings_controller.dart';
import 'data_reset_section.dart';
import 'settings_notices.dart';
import 'settings_text_field.dart';

/// The settings form: four sections and one Save.
///
/// ## Why one Save for the whole screen
///
/// The sections are saved together, in one transaction, because they are one
/// configuration. Saving each field as it is typed would put a half-entered GSTIN on the
/// next bill, and a Save per section would let the outlet end up with a new address above
/// an old GSTIN — two halves of two configurations, on a tax invoice.
///
/// ## Widgets dispatch, they do not decide
///
/// Nothing here validates, parses, trims or persists. Every control reports what the
/// operator did to [SettingsController] and reads back what to display, including which
/// message to show under which field. There is no SQL, no repository and no printer in
/// this file.
class SettingsForm extends StatelessWidget {
  const SettingsForm({super.key});

  /// Widest the form is allowed to get, in logical pixels.
  ///
  /// A counter display is wide, and a text field stretched across a 1600-pixel screen is
  /// slower to read than one that stops. Sized for a comfortable line of an address.
  static const BoxConstraints readableWidth = BoxConstraints(maxWidth: 720);

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: readableWidth,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                children: <Widget>[
                  if (controller.hasError) ...<Widget>[
                    SettingsSaveFailureBanner(
                      message: controller.errorMessage!,
                      onRetry: controller.isSaving ? null : controller.retry,
                    ),
                    const SizedBox(height: 16),
                  ],
                  const _BusinessSection(),
                  const SizedBox(height: 16),
                  const _TaxSection(),
                  const SizedBox(height: 16),
                  const _PosBehaviourSection(),
                  const SizedBox(height: 16),
                  const _ReceiptSection(),
                  const SizedBox(height: 16),
                  const _PrintingSection(),
                  const SizedBox(height: 16),
                  // Supplied by the printing module, and saved by its own controller.
                  // Everything above this line is one configuration written in one
                  // transaction by the Save below; the printer binding is a device, not
                  // part of that document, and has to be correctable and testable on its
                  // own.
                  const PrinterSetupSection(),
                  const SizedBox(height: 16),
                  // Cloud status and the manual sync. Provided by the app root, so
                  // it renders nothing on a screen shown outside the full shell.
                  const CloudSyncSettingsSection(),
                  const SizedBox(height: 16),
                  // The signed-in account and sign-out. Renders nothing on a local-only
                  // build or when signed out, and nothing outside the full shell.
                  const AccountSettingsSection(),
                  const SizedBox(height: 16),
                  // Clears bills, the menu, orders and reports. Login and outlet
                  // configuration are left alone. Saved by its own controller, not
                  // by the form Save, because it is a destruction rather than a
                  // configuration.
                  const DataResetSection(),
                ],
              ),
            ),
          ),
        ),
        const _SaveBar(),
      ],
    );
  }
}

/// Who the outlet is. Printed at the top of every bill.
class _BusinessSection extends StatelessWidget {
  const _BusinessSection();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    return SettingsSection(
      title: 'Business information',
      description:
          'Printed at the top of every customer bill. A field left blank is '
          'left off the bill rather than filled in for you.',
      children: <Widget>[
        SettingsTextField(
          label: 'Business name',
          hint: PosSettings.unconfigured.businessName ?? 'Brisko Pizza',
          helper: 'Left blank, bills are headed Brisko Pizza.',
          value: controller.businessName,
          onChanged: controller.editBusinessName,
        ),
        SettingsTextField(
          label: 'Address',
          helper:
              'Printed under the name, one line for each line you enter here. '
              'Left blank, no address line is printed.',
          value: controller.businessAddress,
          maxLines: 4,
          onChanged: controller.editBusinessAddress,
        ),
        SettingsTextField(
          label: 'Phone',
          helper:
              'The outlet’s own number, stored exactly as you type it. This is '
              'not a customer number, so a landline with an STD code is fine.',
          value: controller.businessPhone,
          onChanged: controller.editBusinessPhone,
        ),
        SettingsTextField(
          label: 'GSTIN',
          // Deliberately no example value. A greyed-out GSTIN in the field would be
          // indistinguishable at a glance from a configured one, and the number that
          // matters here belongs on a tax invoice.
          helper:
              'Optional. Entered, it is checked for the 15-character GSTIN '
              'structure and printed on the bill; left blank, no GSTIN line is '
              'printed.',
          value: controller.gstin,
          error: controller.gstinError,
          onChanged: controller.editGstin,
        ),
      ],
    );
  }
}

/// The GST rate charged on new bills.
///
/// ## Why a list rather than a field
///
/// The rate is picked from the handful of combined slabs a restaurant is put on, so a list
/// is both quicker at a counter and impossible to mistype. A free-text field would let
/// `1.8` be saved where `18` was meant, and the mistake would only surface on a customer's
/// bill.
///
/// ## What this section is careful to say
///
/// That the rate applies to new bills only, and that nothing here can reach a bill that has
/// already been issued. That is the fact an owner needs before they change a slab, and it is
/// true because settlement copies the rate onto the order.
///
/// No GST registration status is inferred from the GSTIN above. An outlet may hold a GSTIN
/// and still be on a scheme that charges nothing, so the rate is asked for outright rather
/// than assumed from another field.
class _TaxSection extends StatelessWidget {
  const _TaxSection();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    return SettingsSection(
      title: 'GST',
      description:
          'The combined GST rate charged on bills settled from now on. Bills '
          'already issued keep the rate they were charged at, so changing this '
          'never alters a bill you have given out.',
      children: <Widget>[
        SettingsChoiceField(
          label: 'GST rate',
          helper: controller.gstRate.isZero
              ? 'No GST is charged, and no tax line is printed on a bill.'
              : 'A bill is taxed on its subtotal after any discount, and the '
                    'receipt shows the ${controller.gstRate.label} split as '
                    'CGST and SGST.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final GstRate rate in GstRate.selectable)
                ChoiceChip(
                  label: Text(rate.label),
                  selected: controller.gstRate == rate,
                  onSelected: (bool _) => controller.selectGstRate(rate),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// How the till behaves during a shift.
class _PosBehaviourSection extends StatelessWidget {
  const _PosBehaviourSection();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    return SettingsSection(
      title: 'POS behaviour',
      description:
          'How settlement opens. Nothing here changes what a bill '
          'charges.',
      children: <Widget>[
        SettingsChoiceField(
          label: 'Default order type',
          helper:
              'Which type is already selected when checkout opens. The cashier '
              'can still pick any of the four on the review step.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final OrderType type in OrderType.values)
                ChoiceChip(
                  label: Text(type.label),
                  selected: controller.defaultOrderType == type,
                  onSelected: (bool _) =>
                      controller.selectDefaultOrderType(type),
                ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print kitchen slip'),
          subtitle: const Text(
            'Ask at the till whether a kitchen slip should print after a sale. '
            'Turned off, the slip is still written for the kitchen board; only '
            'the paper is skipped.',
          ),
          value: controller.printKitchenSlip,
          onChanged: (bool value) =>
              controller.setPrintKitchenSlip(isEnabled: value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ask customer name and phone'),
          subtitle: const Text(
            'Collect a name on checkout, with an optional phone, and print '
            'them on the customer bill. Turned off, walk-in bills skip those '
            'fields.',
          ),
          value: controller.askCustomerDetails,
          onChanged: (bool value) =>
              controller.setAskCustomerDetails(isEnabled: value),
        ),
      ],
    );
  }
}

/// What the bill says around the figures.
///
/// The header and footer are the operator's words, kept exactly as typed. Wrapping them
/// to the paper is the print encoder's job and happens at print time, so nothing is
/// shortened here.
class _ReceiptSection extends StatelessWidget {
  const _ReceiptSection();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();

    return SettingsSection(
      title: 'Receipt',
      description:
          'Extra lines on the customer bill, the review link its feedback QR '
          'points at, and the UPI address for on-screen payment. None of this '
          'changes an amount.',
      children: <Widget>[
        SettingsTextField(
          label: 'Receipt header',
          helper:
              'Printed under the business details, above the bill. Long text is '
              'wrapped to the paper when it prints.',
          value: controller.receiptHeader,
          onChanged: controller.editReceiptHeader,
        ),
        SettingsTextField(
          label: 'Receipt footer',
          helper:
              'Printed at the very bottom, for example a thank-you or a '
              'return policy.',
          value: controller.receiptFooter,
          onChanged: controller.editReceiptFooter,
        ),
        SettingsTextField(
          label: 'Feedback / Review URL',
          hint: 'https://…',
          helper:
              'The paid bill prints a “Rate us” QR pointing here, so a customer '
              'can leave a review. Left blank, no QR is printed: a QR pointing '
              'nowhere is worse than none.',
          value: controller.feedbackUrl,
          onChanged: controller.editFeedbackUrl,
        ),
        SettingsTextField(
          label: 'UPI address',
          hint: 'name@bank',
          helper:
              'The address the payment QR pays. Left blank, no QR is printed: '
              'a QR is a promise that scanning it pays this outlet, and there '
              'is no honest placeholder for that.',
          value: controller.upiVpa,
          onChanged: controller.editUpiVpa,
        ),
        SettingsTextField(
          label: 'UPI payee name',
          helper:
              'Shown in the customer’s UPI app. Left blank, the business '
              'name is used.',
          value: controller.upiPayeeName,
          onChanged: controller.editUpiPayeeName,
        ),
      ],
    );
  }
}

/// How a document is laid out on the roll.
///
/// Layout only. There is no device, no address and no port on this screen, because this
/// terminal has no printer connected and offering somewhere to type an IP address would
/// suggest otherwise. What is here changes the bytes the encoder produces, which is
/// exactly what can be got right before the hardware arrives.
class _PrintingSection extends StatelessWidget {
  const _PrintingSection();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();
    final PrintProfile profile = controller.activeProfile;

    return SettingsSection(
      title: 'Printing',
      description:
          'The layout every bill and kitchen slip is encoded for: '
          '${profile.paper.label} paper, ${profile.columns} columns. Choosing a '
          'layout does not connect a printer.',
      children: <Widget>[
        SettingsChoiceField(
          label: 'Font',
          helper:
              'Font A is 12 dots wide and Font B is 9, so the font decides how '
              'many characters fit on a line.',
          child: SegmentedButton<PrinterFont>(
            segments: <ButtonSegment<PrinterFont>>[
              for (final PrinterFont font in PrinterFont.values)
                ButtonSegment<PrinterFont>(
                  value: font,
                  label: Text(
                    '${font.label} · '
                    '${font.columnsOn(controller.capabilities.paperWidth)} cols',
                  ),
                ),
            ],
            selected: <PrinterFont>{controller.font},
            onSelectionChanged: (Set<PrinterFont> selection) =>
                controller.selectFont(selection.first),
          ),
        ),
        SettingsTextField(
          label: 'Columns',
          hint: '${controller.fontColumns}',
          helper:
              'Optional. Leave blank to use the ${controller.fontColumns} '
              'columns the font fits. Enter a number only when the test page’s '
              'ruler comes out wrapped, and enter what you counted.',
          value: controller.columnOverride,
          error: controller.columnOverrideError,
          digitsOnly: true,
          onChanged: controller.editColumnOverride,
        ),
        SettingsChoiceField(
          label: 'Cut',
          helper: 'How one document is separated from the next.',
          error: controller.cutError,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final PrintCut cut in PrintCut.values)
                ChoiceChip(
                  label: Text(cut.label),
                  selected: controller.cut == cut,
                  onSelected: (bool _) => controller.selectCut(cut),
                ),
            ],
          ),
        ),
        SettingsTextField(
          label: 'Feed before cut',
          helper:
              'Lines fed before cutting, from '
              '${PrintSettings.minFeedLinesBeforeCut} to '
              '${PrintSettings.maxFeedLinesBeforeCut}. The blade sits above the '
              'print head, so too few takes the total off the bottom of the '
              'bill.',
          value: controller.feedLinesBeforeCut,
          error: controller.feedLinesError,
          digitsOnly: true,
          onChanged: controller.editFeedLinesBeforeCut,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print QR codes on receipts'),
          subtitle: Text(
            controller.qrEnabledError ??
                'Drives the feedback “Rate us” QR. Turned off, the QR block is '
                    'left off the bill entirely rather than printed with '
                    'nothing under it.',
            style: controller.qrEnabledError == null
                ? null
                : TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          value: controller.isQrEnabled,
          onChanged: (bool value) => controller.setQrEnabled(isEnabled: value),
        ),
        const SizedBox(height: 8),
        SettingsTextField(
          label: 'QR module size',
          helper:
              'Dots per square of the symbol, from '
              '${PrintSettings.minQrModuleSize} to '
              '${PrintSettings.maxQrModuleSize}. Larger scans more easily and '
              'uses more paper.',
          value: controller.qrModuleSize,
          error: controller.qrModuleSizeError,
          digitsOnly: true,
          onChanged: controller.editQrModuleSize,
        ),
        SettingsChoiceField(
          label: 'QR error correction',
          helper:
              'Redundancy printed into the symbol, so it still scans off a '
              'scuffed roll. More redundancy means a larger symbol.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final QrErrorCorrection level in QrErrorCorrection.values)
                ChoiceChip(
                  label: Text(level.label),
                  selected: controller.qrErrorCorrection == level,
                  onSelected: (bool _) =>
                      controller.selectQrErrorCorrection(level),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Save, and what the last attempt did.
///
/// Pinned below the form rather than scrolling with it: the printer section is long, and
/// a Save the operator has to scroll to find is a Save they will forget to press.
class _SaveBar extends StatelessWidget {
  const _SaveBar();

  @override
  Widget build(BuildContext context) {
    final SettingsController controller = context.watch<SettingsController>();
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
                  Expanded(child: _SaveStatus(controller: controller)),
                  if (controller.isDirty && !controller.isSaving) ...<Widget>[
                    TextButton(
                      onPressed: controller.discardChanges,
                      child: const Text('Discard changes'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    onPressed: controller.canSave ? controller.save : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line saying where the last save got to.
///
/// Every state is a statement of fact. Nothing here claims a printer is connected, and
/// nothing claims a setting is stored until the write has committed.
class _SaveStatus extends StatelessWidget {
  const _SaveStatus({required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final (IconData icon, String message, Color colour) = switch (controller) {
      SettingsController(isSaving: true) => (
        Icons.hourglass_empty,
        'Saving…',
        theme.colorScheme.onSurfaceVariant,
      ),
      SettingsController(hasError: true) => (
        Icons.error_outline,
        'Not saved. Your changes are still here.',
        theme.colorScheme.error,
      ),
      SettingsController(isSaved: true) => (
        Icons.check_circle_outline,
        'Saved. New bills use these settings.',
        theme.colorScheme.primary,
      ),
      SettingsController(isDirty: true) => (
        Icons.edit_outlined,
        'Unsaved changes',
        theme.colorScheme.onSurfaceVariant,
      ),
      _ => (
        Icons.info_outline,
        'This Save covers the outlet’s details and the document layout. The '
            'printer itself is saved in the Printer section.',
        theme.colorScheme.onSurfaceVariant,
      ),
    };

    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}
