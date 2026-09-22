import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'database_factory_initializer.dart';
import 'sqlite_database.dart';

/// Sidecar files SQLite may keep next to [SqliteDatabase.fileName].
const List<String> _sqliteSidecarSuffixes = <String>[
  '-wal',
  '-shm',
  '-journal',
];

/// Folder name under the Windows per-user LocalAppData directory.
const String windowsAppFolderName = 'BriskoBilling';

/// Folder name under the Linux XDG data directory.
const String linuxAppFolderName = 'brisko_billing';

/// Relative path sqflite_common_ffi used before this class existed.
///
/// The FFI factory stores databases under the process working directory:
/// `{cwd}/.dart_tool/sqflite_common_ffi/databases`. On a till that is a
/// protected location (Program Files, a USB, a folder created by an
/// administrator) SQLite can still *read* the file and then fail every write
/// with SQLITE_READONLY — which is the banner "The local database is read-only."
String legacyFfiDatabasesDirectory(String currentDirectory) => p.join(
  currentDirectory,
  '.dart_tool',
  'sqflite_common_ffi',
  'databases',
);

/// Per-user directory that is writable without elevation.
///
/// Windows: `%LOCALAPPDATA%\BriskoBilling\databases`
/// (a `databases` subfolder, so it never collides with Flutter's `data\`
/// folder when the app itself is installed under LocalAppData).
/// Linux: `$XDG_DATA_HOME/brisko_billing` or `~/.local/share/brisko_billing`
///
/// sqflite-native platforms (macOS, iOS, Android) never call this: their plugin
/// already puts the file in the app's own databases folder.
String resolveWritableDatabasesDirectory({
  required Map<String, String> environment,
  required bool isWindows,
  String? fallbackDirectory,
}) {
  if (isWindows) {
    final String? localAppData = _nonEmpty(environment['LOCALAPPDATA']);
    if (localAppData != null) {
      return p.join(localAppData, windowsAppFolderName, 'databases');
    }
    final String? userProfile = _nonEmpty(environment['USERPROFILE']);
    if (userProfile != null) {
      return p.join(
        userProfile,
        'AppData',
        'Local',
        windowsAppFolderName,
        'databases',
      );
    }
  }

  final String? xdg = _nonEmpty(environment['XDG_DATA_HOME']);
  if (xdg != null) {
    return p.join(xdg, linuxAppFolderName);
  }
  final String? home = _nonEmpty(environment['HOME']);
  if (home != null) {
    return p.join(home, '.local', 'share', linuxAppFolderName);
  }

  final String fallback = fallbackDirectory ?? Directory.systemTemp.path;
  return p.join(fallback, linuxAppFolderName);
}

/// Creates the writable databases directory, copies a leftover FFI database
/// into it if this till has not moved yet, and points sqflite at it.
///
/// No-op on platforms where sqflite ships a native plugin, so macOS/iOS/
/// Android keep the path they already use.
///
/// Returns the directory it installed, or `null` when it left the native
/// factory untouched.
Future<String?> prepareWritableDatabasesPath({
  DatabaseHostPlatform? platform,
  Map<String, String>? environment,
  String? currentDirectory,
  bool? isWindows,
  DatabaseFactory? databaseFactoryOverride,
}) async {
  final DatabaseHostPlatform host = platform ?? DatabaseHostPlatform.current();
  if (host != DatabaseHostPlatform.requiresFfi) {
    return null;
  }

  final Map<String, String> env = environment ?? Platform.environment;
  final bool windows = isWindows ?? Platform.isWindows;
  final String cwd = currentDirectory ?? Directory.current.path;

  final String directory = resolveWritableDatabasesDirectory(
    environment: env,
    isWindows: windows,
    fallbackDirectory: cwd,
  );

  await Directory(directory).create(recursive: true);
  await migrateLegacySqliteFiles(
    fromDirectory: legacyFfiDatabasesDirectory(cwd),
    toDirectory: directory,
  );

  final DatabaseFactory dbFactory = databaseFactoryOverride ?? databaseFactory;
  await dbFactory.setDatabasesPath(directory);
  return directory;
}

/// Copies [SqliteDatabase.fileName] and any sidecar files from the old FFI
/// location into [toDirectory] when the destination does not already have a
/// database.
///
/// Bytes are written as a new file so a Windows read-only attribute on the
/// source (common after unzipping) is not preserved. The source is left in
/// place: a till must not lose its only copy of its bills if the copy later
/// needs to be compared.
Future<void> migrateLegacySqliteFiles({
  required String fromDirectory,
  required String toDirectory,
}) async {
  final File destination = File(p.join(toDirectory, SqliteDatabase.fileName));
  if (destination.existsSync()) {
    return;
  }

  final File source = File(p.join(fromDirectory, SqliteDatabase.fileName));
  if (!source.existsSync()) {
    return;
  }

  await Directory(toDirectory).create(recursive: true);
  await _copyAsWritable(source, destination);

  for (final String suffix in _sqliteSidecarSuffixes) {
    final File sidecar = File(
      p.join(fromDirectory, '${SqliteDatabase.fileName}$suffix'),
    );
    if (!sidecar.existsSync()) {
      continue;
    }
    await _copyAsWritable(
      sidecar,
      File(p.join(toDirectory, '${SqliteDatabase.fileName}$suffix')),
    );
  }
}

Future<void> _copyAsWritable(File source, File destination) async {
  await destination.writeAsBytes(await source.readAsBytes(), flush: true);
}

String? _nonEmpty(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return value;
}
