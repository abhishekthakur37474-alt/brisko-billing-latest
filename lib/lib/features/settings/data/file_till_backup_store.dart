import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../../core/error/app_failure.dart';
import '../../../core/utils/result.dart';
import '../domain/models/till_backup.dart';
import '../domain/services/till_backup_store.dart';

/// JSON files next to the database, plus a copy into Downloads on request.
class FileTillBackupStore implements TillBackupStore {
  FileTillBackupStore({String? directoryPath, String? downloadsPath})
    : _directoryPath = directoryPath,
      _downloadsPath = downloadsPath;

  final String? _directoryPath;
  final String? _downloadsPath;

  @override
  Future<Result<TillBackup>> save({
    required DateTime createdAt,
    required Map<String, Object?> sqlite,
    required Map<String, Object?> rtdb,
    String? restaurantId,
  }) async {
    try {
      final String dirPath = _directoryPath ??
          p.join(await getDatabasesPath(), 'backups');
      await Directory(dirPath).create(recursive: true);
      final String stamp = _fileStamp(createdAt.toUtc());
      final String filePath = p.join(dirPath, 'brisko-till-$stamp.json');
      final Map<String, Object?> payload = <String, Object?>{
        'createdAt': createdAt.toUtc().toIso8601String(),
        'restaurantId': restaurantId,
        'sqlite': sqlite,
        'rtdb': rtdb,
      };
      await File(filePath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
      return Ok<TillBackup>(
        TillBackup(
          createdAt: createdAt.toUtc(),
          filePath: filePath,
          restaurantId: restaurantId,
        ),
      );
    } on Object catch (error) {
      return Err<TillBackup>(
        LocalStorageFailure(
          'Could not write the till backup.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<String>> copyToDownloads(String sourcePath) async {
    try {
      final File source = File(sourcePath);
      if (!source.existsSync()) {
        return const Err<String>(
          LocalStorageFailure('The backup file is no longer on this till.'),
        );
      }
      final String? downloads = _downloadsPath ?? _defaultDownloadsPath();
      if (downloads == null) {
        return const Err<String>(
          LocalStorageFailure('Could not find the Downloads folder.'),
        );
      }
      await Directory(downloads).create(recursive: true);
      final String destination = p.join(downloads, p.basename(sourcePath));
      await source.copy(destination);
      return Ok<String>(destination);
    } on Object catch (error) {
      return Err<String>(
        LocalStorageFailure(
          'Could not copy the backup to Downloads.',
          cause: error,
        ),
      );
    }
  }

  static String _fileStamp(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }

  static String? _defaultDownloadsPath() {
    if (Platform.isWindows) {
      final String? user = Platform.environment['USERPROFILE'];
      if (user != null && user.isNotEmpty) {
        return p.join(user, 'Downloads');
      }
    }
    final String? home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, 'Downloads');
    }
    return null;
  }
}
