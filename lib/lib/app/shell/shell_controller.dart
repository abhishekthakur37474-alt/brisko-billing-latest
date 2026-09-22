import 'package:flutter/foundation.dart';

import 'pos_section.dart';

/// Holds which POS section is currently on screen.
///
/// Navigation state lives in a controller rather than in widget state so that any
/// part of the application can move the user, for example a dashboard tile that
/// starts a new bill, without threading callbacks through the widget tree.
///
/// This is the state-management pattern used throughout the project: a
/// `ChangeNotifier` per concern, exposed with `provider`, holding no widgets and
/// no build logic.
class ShellController extends ChangeNotifier {
  ShellController({PosSection initialSection = PosSection.dashboard})
    : _section = initialSection;

  PosSection _section;

  PosSection get section => _section;

  /// Moves to [section]. No-op when already there, so redundant taps do not
  /// trigger a rebuild.
  void select(PosSection section) {
    if (_section == section) {
      return;
    }
    _section = section;
    notifyListeners();
  }
}
