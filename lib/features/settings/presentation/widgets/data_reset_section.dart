import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/data_reset_controller.dart';
import 'settings_notices.dart';

/// The Data section on the Settings screen.
///
/// Offers one action: physically remove bills, the menu, orders, kitchen slips,
/// held carts, customers, inventory, expenses and the upload queue, from this
/// till and from the cloud. A JSON backup of SQLite and RTDB is written first.
/// Login, outlet details, printer binding and the manager password stay.
///
/// Renders nothing when no [DataResetController] has been provided, so a screen
/// shown outside the full application shell is never forced to wire one up.
class DataResetSection extends StatelessWidget {
  const DataResetSection({super.key});

  @override
  Widget build(BuildContext context) {
    final DataResetController? controller = context
        .watch<DataResetController?>();
    if (controller == null) {
      return const SizedBox.shrink();
    }

    final ThemeData theme = Theme.of(context);

    return SettingsSection(
      title: 'Data',
      description:
          'Remove bills, the menu, orders and reports from this till and from '
          'the cloud. A backup is written first. The sign-in, outlet details '
          'and printer stay.',
      children: <Widget>[
        Text(
          'Last backup: ${_formatTimestamp(controller.lastBackupAt)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Last cleared: ${_formatTimestamp(controller.lastClearedAt)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (controller.hasError) ...<Widget>[
          Text(
            controller.errorMessage!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (controller.isCleared) ...<Widget>[
          Text(
            'Till data cleared. Login and settings are unchanged.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (controller.downloadError != null) ...<Widget>[
          Text(
            controller.downloadError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (controller.downloadedTo != null) ...<Widget>[
          Text(
            'Backup copied to ${controller.downloadedTo}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: controller.canDownload
                ? controller.downloadLastBackup
                : null,
            child: Text(
              controller.isDownloading
                  ? 'Copying backup…'
                  : 'Download last backup',
            ),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Clear till data'),
          subtitle: const Text(
            'Writes a backup, then deletes bills, the menu, orders, kitchen '
            'slips, held bills, customers, inventory, expenses and reports '
            'from this device and from the cloud. Turn the switch on, then '
            'confirm. Sign-in and settings are not deleted.',
          ),
          value: controller.isClearing,
          onChanged: controller.canClear
              ? (bool enabled) {
                  if (enabled) {
                    unawaited(_confirmAndClear(context, controller));
                  }
                }
              : null,
        ),
      ],
    );
  }

  static String _formatTimestamp(DateTime? at) {
    if (at == null) {
      return 'Never';
    }
    final DateTime utc = at.toUtc();
    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.day} ${months[utc.month - 1]} ${utc.year}, '
        '${two(utc.hour)}:${two(utc.minute)} UTC';
  }

  static Future<void> _confirmAndClear(
    BuildContext context,
    DataResetController controller,
  ) async {
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('Clear till data?'),
              content: const Text(
                'A backup of this till and the cloud will be written first. '
                'Then bills, the menu, orders, kitchen slips, held bills, '
                'customers, inventory, expenses and reports will be deleted '
                'from this device and from the cloud. The sign-in, outlet '
                'details and printer stay. This cannot be undone.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Clear data'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (confirmed) {
      await controller.clear();
    }
  }
}
