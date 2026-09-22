import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A text field in the settings form.
///
/// ## Why the field owns no state
///
/// The value lives on `SettingsController`. This widget owns a `TextEditingController`
/// for the cursor and calls [onChanged] on every keystroke, which is what lets a failed
/// save leave the typing untouched: the draft was never in the widget tree, so nothing
/// is lost when the tree rebuilds.
///
/// [value] is pushed back into the field only when it disagrees with what is displayed,
/// which happens once — after a save, when the stored form of a value differs from what
/// was typed, for example a GSTIN entered with caps lock off. Assigning unconditionally
/// would move the cursor to the end of the line on every keystroke.
class SettingsTextField extends StatefulWidget {
  const SettingsTextField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.error,
    this.hint,
    this.maxLines = 1,
    this.digitsOnly = false,
    super.key,
  });

  final String label;

  /// What the setting means, and what happens when it is left blank.
  final String? helper;

  /// Why the value is refused, if it is.
  final String? error;

  final String? hint;

  final String value;

  final ValueChanged<String> onChanged;

  /// Lines the field grows to. An address is two; everything else is one.
  final int maxLines;

  /// Restricts entry to digits.
  ///
  /// Used for the printer's column, line and dot counts. Not used for a telephone
  /// number: an outlet's number may legitimately carry a `+`, a space or a bracket, and
  /// stripping those would print a number that cannot be dialled.
  final bool digitsOnly;

  @override
  State<SettingsTextField> createState() => _SettingsTextFieldState();
}

class _SettingsTextFieldState extends State<SettingsTextField> {
  late final TextEditingController _field = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(SettingsTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _field.text) {
      _field.text = widget.value;
    }
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: _field,
        onChanged: widget.onChanged,
        maxLines: widget.maxLines,
        keyboardType: widget.digitsOnly
            ? TextInputType.number
            : (widget.maxLines > 1
                  ? TextInputType.multiline
                  : TextInputType.text),
        inputFormatters: widget.digitsOnly
            ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
            : null,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          helperText: widget.helper,
          helperMaxLines: 3,
          errorText: widget.error,
          errorMaxLines: 3,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
