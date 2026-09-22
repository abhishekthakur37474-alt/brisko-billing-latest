import '../../../../core/utils/result.dart';
import '../models/till_backup.dart';

/// Writes and copies till backups on this machine.
abstract interface class TillBackupStore {
  /// Persists [sqlite] and [rtdb] snapshots as one JSON file.
  Future<Result<TillBackup>> save({
    required DateTime createdAt,
    required Map<String, Object?> sqlite,
    required Map<String, Object?> rtdb,
    String? restaurantId,
  });

  /// Copies [sourcePath] into the user's Downloads folder.
  Future<Result<String>> copyToDownloads(String sourcePath);
}
