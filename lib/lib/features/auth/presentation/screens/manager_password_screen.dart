import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../settings/presentation/widgets/settings_notices.dart';
import '../../domain/services/manager_auth_service.dart';
import '../controllers/manager_password_controller.dart';

/// Sets or changes the manager password used to authorise bill cancellation.
///
/// The password is hashed before it is stored. The hash is written to Realtime
/// Database directly and cached locally for offline use. Nothing on this screen
/// is printed or shown in plaintext after a save.
class ManagerPasswordScreen extends StatelessWidget {
  const ManagerPasswordScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ManagerPasswordController>(
      create: (BuildContext context) {
        final ManagerPasswordController controller = ManagerPasswordController(
          auth: context.read<ManagerAuthService>(),
        );
        unawaited(controller.load());
        return controller;
      },
      child: const _ManagerPasswordView(),
    );
  }
}

class _ManagerPasswordView extends StatelessWidget {
  const _ManagerPasswordView();

  @override
  Widget build(BuildContext context) {
    final ManagerPasswordController controller = context
        .watch<ManagerPasswordController>();

    if (controller.status == ManagerPasswordStatus.loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Reading manager password status…'),
        ),
      );
    }

    if (controller.loadFailed) {
      return SettingsErrorView(
        message: controller.errorMessage ?? 'Could not read manager password.',
        onRetry: controller.load,
      );
    }

    return const _ManagerPasswordForm();
  }
}

class _ManagerPasswordForm extends StatefulWidget {
  const _ManagerPasswordForm();

  @override
  State<_ManagerPasswordForm> createState() => _ManagerPasswordFormState();
}

class _ManagerPasswordFormState extends State<_ManagerPasswordForm> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ManagerPasswordController controller = context
        .read<ManagerPasswordController>();
    if (!controller.canSave) {
      return;
    }
    final bool saved = await controller.save();
    if (!saved || !mounted) {
      return;
    }
    _current.clear();
    _next.clear();
    _confirm.clear();
  }

  @override
  Widget build(BuildContext context) {
    final ManagerPasswordController controller = context
        .watch<ManagerPasswordController>();
    final ThemeData theme = Theme.of(context);
    final bool saving = controller.isSaving;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Manager password',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      controller.isPasswordSet
                          ? 'A manager password is already set. Enter the '
                                'current one to change it. This password is '
                                'asked for when a bill is cancelled.'
                          : 'No manager password is set yet. Set one here. '
                                'It is asked for when a bill is cancelled.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (controller.isPasswordSet) ...<Widget>[
                      _PasswordField(
                        controller: _current,
                        label: 'Current password',
                        enabled: !saving,
                        obscure: _obscureCurrent,
                        onToggleObscure: () => setState(
                          () => _obscureCurrent = !_obscureCurrent,
                        ),
                        onChanged: controller.editCurrentPassword,
                      ),
                      const SizedBox(height: 12),
                    ],
                    _PasswordField(
                      controller: _next,
                      label: 'New password',
                      enabled: !saving,
                      obscure: _obscureNew,
                      onToggleObscure: () =>
                          setState(() => _obscureNew = !_obscureNew),
                      onChanged: controller.editNewPassword,
                    ),
                    const SizedBox(height: 12),
                    _PasswordField(
                      controller: _confirm,
                      label: 'Confirm new password',
                      enabled: !saving,
                      obscure: _obscureConfirm,
                      onToggleObscure: () =>
                          setState(() => _obscureConfirm = !_obscureConfirm),
                      onChanged: controller.editConfirmPassword,
                      onSubmitted: saving ? null : () => unawaited(_submit()),
                    ),
                    if (controller.hasError) ...<Widget>[
                      const SizedBox(height: 16),
                      _Notice(
                        message: controller.errorMessage!,
                        isError: true,
                      ),
                    ],
                    if (controller.isSaved) ...<Widget>[
                      const SizedBox(height: 16),
                      const _Notice(
                        message:
                            'Manager password saved. Use it to authorise '
                            'bill cancellation.',
                        isError: false,
                      ),
                    ],
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: controller.canSave
                            ? () => unawaited(_submit())
                            : null,
                        icon: saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_outline),
                        label: Text(
                          controller.isPasswordSet
                              ? 'Change password'
                              : 'Set password',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.controller,
    required this.label,
    required this.enabled,
    required this.obscure,
    required this.onToggleObscure,
    required this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: onSubmitted == null
          ? TextInputAction.next
          : TextInputAction.done,
      onChanged: onChanged,
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.lock_outline),
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
          onPressed: onToggleObscure,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colours = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colours.errorContainer : colours.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isError
              ? colours.onErrorContainer
              : colours.onPrimaryContainer,
        ),
      ),
    );
  }
}
