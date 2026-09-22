import 'dart:io';

// sqflite_common_ffi re-exports the global `databaseFactory` alongside the FFI factory
// and initialiser, so this one import covers both the symbol we assign and the values we
// assign to it.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Installs the SQLite `databaseFactory` that suits the current platform, once, at
/// start-up and before any database is opened.
///
/// ## Why this exists
///
/// sqflite drives every query in the application, but it does not carry its own SQLite
/// engine everywhere. On Android, iOS and macOS it ships a native plugin, and the global
/// [databaseFactory] is wired up for us by the plugin registrant. On **Windows and Linux
/// there is no such plugin**: the global factory is left null, and the first call to
/// `openDatabase` throws
///
/// > Bad state: databaseFactory not initialized
///
/// The fix sqflite documents is to use `sqflite_common_ffi`, which carries the desktop
/// SQLite engine and exposes [databaseFactoryFfi]. This installs it — but only where it
/// is needed, so the platforms sqflite already covers keep their native factory untouched.
///
/// ## Contract
///
/// Call [initializeDatabaseFactory] exactly once, from the bootstrap, before the first
/// `SqliteDatabase.open()`. It is idempotent: repeated calls on a platform that needs FFI
/// re-install the same factory harmlessly, and on the platforms sqflite covers it does
/// nothing at all.
///
/// The platform check and the FFI installer are injectable so the behaviour can be tested
/// off the platform it targets, exactly as [PlatformThermalPrinterFactory] does for the
/// printer transports.

/// The platforms whose database factory needs installing, reduced to the distinction that
/// actually matters: whether sqflite ships a native plugin for this OS or not.
enum DatabaseHostPlatform {
  /// Android, iOS or macOS: sqflite's native plugin already installs a
  /// [databaseFactory], so nothing more is needed.
  sqfliteNative,

  /// Windows or Linux: sqflite has no plugin, so the FFI factory must be installed or
  /// `openDatabase` throws "databaseFactory not initialized".
  requiresFfi;

  /// The classification for the platform this build is running on right now.
  ///
  /// Windows and Linux require the FFI factory. Everything else — Android, iOS and
  /// macOS — is covered by sqflite's own plugin and is left alone.
  static DatabaseHostPlatform current() {
    if (Platform.isWindows || Platform.isLinux) {
      return DatabaseHostPlatform.requiresFfi;
    }
    return DatabaseHostPlatform.sqfliteNative;
  }
}

/// Installs the FFI `databaseFactory`: initialises the desktop engine and points
/// sqflite's global API at it. Split out and injectable so [initializeDatabaseFactory]
/// can be driven for the Windows path in a test without a Windows machine.
void installFfiDatabaseFactory() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Ensures a usable [databaseFactory] is installed for [platform], before any database is
/// opened.
///
/// On [DatabaseHostPlatform.requiresFfi] (Windows and Linux) it installs the FFI factory
/// through [installFfi]. On [DatabaseHostPlatform.sqfliteNative] it does nothing, leaving
/// the native plugin's factory in place, which is what preserves the existing macOS and
/// iOS behaviour exactly.
///
/// Returns true when it installed the FFI factory, false when it left the native one in
/// place — useful to tests and to a caller that wants to log which path it took.
///
/// [platform] and [installFfi] default to the real platform and the real installer; both
/// are injectable for testing.
bool initializeDatabaseFactory({
  DatabaseHostPlatform? platform,
  void Function() installFfi = installFfiDatabaseFactory,
}) {
  final DatabaseHostPlatform resolved =
      platform ?? DatabaseHostPlatform.current();

  switch (resolved) {
    case DatabaseHostPlatform.requiresFfi:
      installFfi();
      return true;
    case DatabaseHostPlatform.sqfliteNative:
      return false;
  }
}
