import 'package:flutter/material.dart';

import '../../domain/models/menu_category.dart';
import '../controllers/menu_management_controller.dart';

/// The form for creating or renaming a category.
///
/// A category has only a name to edit here. Its order is changed with the up and down
/// controls on the list, and it is switched on or off with the toggle, so neither is
/// duplicated as a field.
class MenuCategoryEditor extends StatefulWidget {
  const MenuCategoryEditor({
    required this.controller,
    this.category,
    super.key,
  });

  /// Opens the form. Returns true when something was saved.
  static Future<bool> show(
    BuildContext context, {
    required MenuManagementController controller,
    MenuCategory? category,
  }) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) =>
          MenuCategoryEditor(controller: controller, category: category),
    );
    return saved ?? false;
  }

  final MenuManagementController controller;

  /// The category being renamed, or `null` when creating one.
  final MenuCategory? category;

  @override
  State<MenuCategoryEditor> createState() => _MenuCategoryEditorState();
}

class _MenuCategoryEditorState extends State<MenuCategoryEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.category?.name ?? '',
  );

  String? _validation;

  bool get _isNew => widget.category == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? repositoryError = widget.controller.errorMessage;

    return AlertDialog(
      title: Text(_isNew ? 'Add category' : 'Rename category'),
      content: SizedBox(
        width: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'The section as it appears at the counter',
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_validation != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                _validation!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_validation == null && repositoryError != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                repositoryError,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.controller.isSaving ? null : _save,
          child: Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _validation = 'Give the category a name.');
      return;
    }
    setState(() => _validation = null);

    final MenuCategory? existing = widget.category;
    final bool saved = existing == null
        ? await widget.controller.createCategory(name)
        : await widget.controller.renameCategory(existing, name);

    if (saved && mounted) {
      Navigator.of(context).pop(true);
    }
  }
}
