import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../settings/presentation/widgets/settings_notices.dart';
import '../../../settings/presentation/widgets/settings_text_field.dart';
import '../../domain/models/paper_width.dart';
import '../../domain/models/printer_connection.dart';
import '../../domain/models/printer_status.dart';
import '../controllers/printer_controller.dart';

/// Which printer this terminal prints on, whether it can be reached, and a test page.
///
/// ## What is on screen
///
/// A status row that states the truth about this terminal, the binding itself — on or off,
/// USB or network, where it is, what roll it takes — a Save for that binding, and a Test
/// Print. Nothing here lays a document out: that is the Printing section beside it, which
/// changes bytes rather than destinations.
///
/// ## Why Test Print is here and not on a bill
///
/// It is the only way to check a printer without spending a real sale on it, and the only
/// way to discover a wrong column count before a customer is handed a receipt with the
/// total wrapped onto a second line. It goes through the same print service, the same
/// encoder and the same printer as a receipt, so what it proves is about the real path.
///
/// ## It never claims success it did not have
///
/// The status row and the test result are both rendered from what the printer reported.
/// On this build no transport adapter ships, so a correctly configured printer still
/// reports that it cannot be reached — and the wording says exactly that rather than
/// implying a cable fault. This widget contains no fallback that would turn that into a
/// tick.
class PrinterSetupSection extends StatelessWidget {
  const PrinterSetupSection({super.key});

  @override
  Widget build(BuildContext context) {
    final PrinterController controller = context.watch<PrinterController>();

    return SettingsSection(
      title: 'Printer',
      description:
          'The device bills and kitchen slips are sent to. Saving a printer '
          'stores where it is; it does not connect to it.',
      children: <Widget>[
        _StatusRow(controller: controller),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print bills and kitchen slips'),
          subtitle: const Text(
            'Turned off, nothing is sent to a printer and no printing failure '
            'is reported at the end of a bill.',
          ),
          value: controller.isEnabled,
          onChanged: (bool value) => controller.setEnabled(isEnabled: value),
        ),
        const SizedBox(height: 8),
        if (controller.isEnabled) ..._binding(context, controller),
        _TestPrintRow(controller: controller),
        if (controller.hasError) ...<Widget>[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.error_outline,
            message: controller.errorMessage!,
            colour: Theme.of(context).colorScheme.error,
          ),
        ],
        const SizedBox(height: 8),
        _SaveRow(controller: controller),
      ],
    );
  }

  /// The fields that describe where the printer is.
  ///
  /// Shown only when printing is on, and the transport-specific fields only once a
  /// transport is chosen. An IP address field beside a USB printer is a field somebody
  /// will fill in.
  List<Widget> _binding(BuildContext context, PrinterController controller) {
    return <Widget>[
      SettingsChoiceField(
        label: 'Connection',
        helper:
            'How this terminal reaches the printer. USB is the usual choice '
            'for a printer on the same counter.',
        error: controller.transportError,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final PrinterTransport transport in PrinterTransport.values)
              ChoiceChip(
                label: Text(transport.label),
                selected: controller.transport == transport,
                onSelected: (bool _) => controller.selectTransport(transport),
              ),
          ],
        ),
      ),
      if (controller.isNetworked) ...<Widget>[
        SettingsTextField(
          label: 'IP address or host name',
          helper:
              'Where the printer answers on the local network. Printing does '
              'not use the internet, so this stays reachable when the line is '
              'down.',
          value: controller.address,
          error: controller.addressError,
          onChanged: controller.editAddress,
        ),
        SettingsTextField(
          label: 'Port',
          hint: '${PrinterEndpoint.defaultLanPort}',
          helper:
              'Leave blank to use ${PrinterEndpoint.defaultLanPort}, which is '
              'what network ESC/POS printers listen on.',
          value: controller.port,
          error: controller.portError,
          digitsOnly: true,
          onChanged: controller.editPort,
        ),
      ],
      if (controller.isUsb)
        SettingsTextField(
          label: 'Device name',
          helper:
              'Optional. Leave blank when there is one printer on the bus, '
              'which is the ordinary case.',
          value: controller.deviceName,
          onChanged: controller.editDeviceName,
        ),
      SettingsTextField(
        label: 'Printer name',
        helper:
            'Optional, and printed nowhere. It is used in messages, so a '
            'problem reads as a printer rather than as an address.',
        value: controller.label,
        error: controller.labelError,
        onChanged: controller.editLabel,
      ),
      SettingsChoiceField(
        label: 'Paper',
        helper:
            'The roll the printer takes. 80mm is the same thing as 3-inch and '
            'is what this outlet uses; it decides how many characters fit on a '
            'line.',
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final PaperWidth width in PaperWidth.values)
              ChoiceChip(
                label: Text('${width.label} · ${width.characterColumns} cols'),
                selected: controller.paperWidth == width,
                onSelected: (bool _) => controller.selectPaperWidth(width),
              ),
          ],
        ),
      ),
    ];
  }
}

/// What is true about the printer right now, in two lines.
///
/// The headline is the state and the line under it is what to do about it. Both come from
/// [PrinterStatus], so the screen cannot phrase the situation differently from the way the
/// print service reports it.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // Rebuilt as the printer's connection changes, so an indicator does not sit on a
    // state from before the cable was plugged in. The controller supplies the current
    // value first, so there is no frame without a status.
    return StreamBuilder<PrinterConnectionState>(
      stream: controller.connectionStates,
      builder: (BuildContext context, AsyncSnapshot<PrinterConnectionState> _) {
        final PrinterStatus status = controller.status;
        final (IconData icon, Color colour) = switch (status) {
          PrinterStatus(canPrint: true) => (
            Icons.print_outlined,
            AppColors.success,
          ),
          PrinterStatus(isEnabled: false) => (
            Icons.print_disabled_outlined,
            theme.colorScheme.onSurfaceVariant,
          ),
          _ => (Icons.print_disabled_outlined, theme.colorScheme.error),
        };

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: colour),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      status.headline,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colour,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The Test Print action, and what the last one did.
class _TestPrintRow extends StatelessWidget {
  const _TestPrintRow({required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? message = controller.testMessage;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            // Offered even with nothing configured. Pressing it is the fastest way for
            // the operator to be told why nothing prints, and it answers honestly.
            onPressed: controller.isTesting ? null : controller.testPrint,
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(
              controller.isTesting ? 'Printing test page…' : 'Test print',
            ),
          ),
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: 12),
          _Notice(
            icon: controller.didTestSucceed
                ? Icons.check_circle_outline
                : Icons.print_disabled_outlined,
            message: message,
            colour: controller.didTestSucceed
                ? AppColors.success
                : theme.colorScheme.error,
            onDismiss: controller.dismissTestResult,
          ),
        ],
      ],
    );
  }
}

/// Save for the printer binding alone.
class _SaveRow extends StatelessWidget {
  const _SaveRow({required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (controller.isDirty && !controller.isSaving) ...<Widget>[
          TextButton(
            onPressed: controller.discardChanges,
            child: const Text('Discard printer changes'),
          ),
          const SizedBox(width: 8),
        ],
        const Spacer(),
        FilledButton.icon(
          onPressed: controller.canSave ? controller.save : null,
          icon: const Icon(Icons.save_outlined),
          label: Text(controller.isSaving ? 'Saving printer…' : 'Save printer'),
        ),
      ],
    );
  }
}

/// One coloured line of fact, optionally dismissible.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.message,
    required this.colour,
    this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color colour;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
        ),
        if (onDismiss != null)
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}
