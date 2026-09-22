import 'models/pos_settings.dart';

/// The configuration this terminal is running with, held in memory.
///
/// ## Why the screens do not each read the table
///
/// Two things outside the Settings screen need a setting at the moment a widget is
/// built: settlement needs to know which order type to open on. A widget cannot await a
/// database read while it builds, so the alternatives were a screen that flickers
/// through a loading state before showing a bill, or a value read once at start-up and
/// kept.
///
/// This is that value. It is loaded by the bootstrap, before the first frame, and
/// replaced when the Settings screen saves — so a change takes effect on the next bill
/// rather than on the next launch, and no feature has to reach for the settings table
/// itself.
///
/// ## Not a cache
///
/// Nothing reads *through* it. The Settings screen loads from and saves to the
/// repository, which stays the only source of truth; this holds the result so that
/// checkout does not have to ask. If the two ever disagreed, the table would be right.
///
/// Plain, not a `ChangeNotifier`: the flows that read it construct a controller when
/// they open, so they pick up the current value without needing to be told it changed.
class ActivePosSettings {
  ActivePosSettings({this._settings = PosSettings.unconfigured});

  PosSettings _settings;

  /// The settings in force right now.
  PosSettings get settings => _settings;

  /// Replaces them, after a save has committed.
  ///
  /// Called only once the write has succeeded, so the value in memory is never ahead of
  /// the value on disk.
  void apply(PosSettings settings) {
    _settings = settings;
  }
}
