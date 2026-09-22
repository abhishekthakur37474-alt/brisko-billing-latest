import 'package:flutter/material.dart';

/// Brand colour inputs for the application theme.
///
/// These are seeds and accents only. Widgets should read colours from
/// `Theme.of(context).colorScheme` rather than referencing this class directly,
/// so that light and dark modes both stay correct.
class AppColors {
  const AppColors._();

  /// Primary brand seed. Material 3 derives the full colour scheme from this.
  static const Color brandSeed = Color(0xFFC62828);

  /// Semantic accent used for successful/settled states, for example a paid
  /// bill or a completed sync.
  static const Color success = Color(0xFF2E7D32);

  /// Semantic accent used for pending states, for example an unsynced bill
  /// waiting in the outbox.
  static const Color pending = Color(0xFFEF6C00);
}
