import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'sqlite_database.dart';
import 'sqlite_databases_path.dart';

/// Evidence about where SQLite keeps its file and why a write may be refused.
///
/// "The local database is read-only." is a symptom with several causes that look
/// identical from the exception alone: the file may sit under a protected folder
/// (Program Files, a read-only USB, an admin-extracted directory), it may carry
/// Windows' read-only attribute, the current user may lack write permission on
/// the folder, or the FFI factory may still be using its working-directory
/// default. This records the facts needed to tell those apart so the cause can
/// be seen rather than guessed.
///
/// Nothing here may break start-up: every probe and every write is guarded, and
/// a failure is swallowed. A startup snapshot and every read-only failure are
/// appended to a log file the operator can send back, and printed to the debug
/// console while developing.
class SqliteDiagnostics {
  const SqliteDiagnostics._();

  static const String logFileName = 'sqlite_diagnostics.log';

  /// Records a full snapshot of the database path setup at start-up.
  ///
  /// Call once, after the writable database path has been installed and before
  /// anything opens the database.
  static Future<void> captureStartup() async {
    final String cwd = Directory.current.path;
    final Map<String, String> env = Platform.environment;
    final String? dbPath = await _safeDatabasesPath();
    final String logPath = await _safeLogPath();

    final StringBuffer out = StringBuffer()
      ..writeln(
        '==== SQLite diagnostics '
        '${DateTime.now().toUtc().toIso8601String()} ====',
      )
      ..writeln(
        'os             : ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}',
      )
      ..writeln('executable     : ${Platform.resolvedExecutable}')
      ..writeln('working dir    : $cwd')
      ..writeln('LOCALAPPDATA   : ${env['LOCALAPPDATA'] ?? '<unset>'}')
      ..writeln('USERPROFILE    : ${env['USERPROFILE'] ?? '<unset>'}')
      ..writeln('databases path : ${dbPath ?? '<unavailable>'}')
      ..writeln(
        'database file  : '
        '${dbPath == null ? '<unavailable>' : p.join(dbPath, SqliteDatabase.fileName)}',
      )
      ..writeln('log file       : $logPath');

    // The folder the FFI factory used before the writable-path fix. If the
    // database still lives here, the running build predates that fix.
    final String legacyDir = legacyFfiDatabasesDirectory(cwd);
    out
      ..writeln()
      ..writeln('-- legacy (working-dir) location --')
      ..writeln('legacy dir     : $legacyDir')
      ..write(await _describeDirectory(legacyDir))
      ..write(await _describeFile(p.join(legacyDir, SqliteDatabase.fileName)));

    if (dbPath != null) {
      out
        ..writeln()
        ..writeln('-- configured location --')
        ..write(await _describeDirectory(dbPath))
        ..write(await _describeFile(p.join(dbPath, SqliteDatabase.fileName)));
    }

    await _write(out.toString());
  }

  /// Records a labelled event plus, when reachable, a fresh path snapshot.
  ///
  /// Used at the moment a read-only failure is mapped, so the log holds the
  /// state of the file and folder at the time of the failure rather than only
  /// at start-up.
  static Future<void> record(
    String event, {
    Map<String, Object?> details = const <String, Object?>{},
  }) async {
    final StringBuffer out = StringBuffer()
      ..writeln(
        '---- $event ${DateTime.now().toUtc().toIso8601String()} ----',
      );
    details.forEach((String key, Object? value) {
      out.writeln('  $key: $value');
    });

    final String? dbPath = await _safeDatabasesPath();
    if (dbPath != null) {
      out.writeln('  databases path: $dbPath');
      out
        ..write(await _describeDirectory(dbPath))
        ..write(
          await _describeFile(p.join(dbPath, SqliteDatabase.fileName)),
        );
    }

    await _write(out.toString());
  }

  static Future<String?> _safeDatabasesPath() async {
    try {
      return await getDatabasesPath();
    } catch (_) {
      return null;
    }
  }

  static Future<String> _describeDirectory(String path) async {
    final Directory dir = Directory(path);
    final StringBuffer out = StringBuffer();
    out.writeln('  exists       : ${dir.existsSync()}');
    out.writeln('  writable     : ${await _probeDirectory(dir)}');
    if (Platform.isWindows) {
      out.write(await _runCommand('attrib', <String>[path], label: '  attrib'));
      out.write(
        await _runCommand('icacls', <String>[path], label: '  icacls'),
      );
    }
    return out.toString();
  }

  static Future<String> _describeFile(String path) async {
    final File file = File(path);
    final StringBuffer out = StringBuffer();
    out.writeln('  file exists  : ${file.existsSync()}');
    if (file.existsSync()) {
      try {
        out.writeln('  file size    : ${file.lengthSync()}');
      } catch (_) {}
      out.writeln('  file writable: ${await _probeFile(file)}');
      if (Platform.isWindows) {
        out.write(
          await _runCommand('attrib', <String>[path], label: '  attrib'),
        );
        out.write(
          await _runCommand('icacls', <String>[path], label: '  icacls'),
        );
      }
    }
    return out.toString();
  }

  /// Creates and deletes a probe file, proving the folder accepts writes.
  static Future<bool> _probeDirectory(Directory dir) async {
    try {
      if (!dir.existsSync()) {
        return false;
      }
      final File probe = File(p.join(dir.path, '.brisko_write_probe'));
      await probe.writeAsString('probe', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the file for append and closes it, proving it accepts writes.
  static Future<bool> _probeFile(File file) async {
    try {
      final RandomAccessFile handle = await file.open(mode: FileMode.append);
      await handle.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _runCommand(
    String executable,
    List<String> arguments, {
    required String label,
  }) async {
    try {
      final ProcessResult result = await Process.run(executable, arguments);
      final String text = '${result.stdout}'.trim();
      return text.isEmpty ? '' : '$label: $text\n';
    } catch (_) {
      return '';
    }
  }

  static Future<String> _safeLogPath() async {
    try {
      return await _logFilePath();
    } catch (_) {
      return '<unavailable>';
    }
  }

  /// A writable place for the log, living wherever the database should live.
  static Future<String> _logFilePath() async {
    final String? localAppData = Platform.environment['LOCALAPPDATA'];
    final String base = (localAppData == null || localAppData.isEmpty)
        ? Directory.systemTemp.path
        : p.join(localAppData, windowsAppFolderName);
    await Directory(base).create(recursive: true);
    return p.join(base, logFileName);
  }

  static Future<void> _write(String text) async {
    debugPrint(text);
    try {
      final File log = File(await _logFilePath());
      await log.writeAsString(text, mode: FileMode.append, flush: true);
    } catch (_) {
      // Diagnostics must never break start-up or a write path.
    }
  }
}
