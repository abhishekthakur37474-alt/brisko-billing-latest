import '../../../../core/utils/result.dart';

/// Clears operational till data while leaving the sign-in and configuration alone.
///
/// Bills, the menu, kitchen slips, held carts, customers, inventory, expenses and
/// the upload queue are removed. The settings table is not touched, so the
/// persisted session, outlet details, printer binding and manager password stay.
///
/// A clear first writes a JSON backup of SQLite and (when signed in) the RTDB
/// restaurant node, then physically empties both. Cloud data is not left behind
/// for the next pull to restore onto the empty till.
abstract interface class OperationalDataWiper {
  /// Backs up, then physically removes operational rows locally and in the cloud.
  ///
  /// Reports and the dashboard are derived from those rows, so they empty as a
  /// consequence. A failure before the local delete leaves previous data intact.
  Future<Result<void>> clearOperationalData();
}
