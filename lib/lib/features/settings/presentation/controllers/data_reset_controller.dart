import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../billing/presentation/controllers/billing_controller.dart';
import '../../domain/models/setting_keys.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/operational_data_wiper.dart';
import '../../domain/services/till_backup_store.dart';

/// Where a data-clear attempt stands.
enum DataResetStatus {
  /// Nothing in flight.
  idle,

  /// The wipe is writing.
  clearing,

  /// The last wipe committed.
  cleared,

  /// The last wipe failed. [DataResetController.errorMessage] says why.
  error,
}

/// Owns the Settings "clear till data" action.
///
/// The widgets confirm; this class writes. A failed wipe leaves every table as it
/// was, because the repository transaction rolls back, and the live cart is only
/// emptied after the write commits.
class DataResetController extends ChangeNotifier {
  DataResetController({
    required OperationalDataWiper wiper,
    required BillingController billing,
    required SettingsRepository settings,
    required TillBackupStore backups,
  }) : _wiper = wiper,
       _billing = billing,
       _settings = settings,
       _backups = backups {
    unawaited(load());
  }

  final OperationalDataWiper _wiper;
  final BillingController _billing;
  final SettingsRepository _settings;
  final TillBackupStore _backups;

  DataResetStatus _status = DataResetStatus.idle;
  String? _errorMessage;
  DateTime? _lastBackupAt;
  DateTime? _lastClearedAt;
  String? _lastBackupPath;
  bool _isDownloading = false;
  String? _downloadError;
  String? _downloadedTo;
  bool _isDisposed = false;

  DataResetStatus get status => _status;

  bool get isClearing => _status == DataResetStatus.clearing;

  bool get isCleared => _status == DataResetStatus.cleared;

  bool get hasError => _errorMessage != null;

  String? get errorMessage => _errorMessage;

  DateTime? get lastBackupAt => _lastBackupAt;

  DateTime? get lastClearedAt => _lastClearedAt;

  bool get hasBackup =>
      _lastBackupPath != null && _lastBackupPath!.isNotEmpty;

  bool get isDownloading => _isDownloading;

  String? get downloadError => _downloadError;

  String? get downloadedTo => _downloadedTo;

  /// True when the button should start a wipe.
  bool get canClear => !isClearing && !isDownloading;

  bool get canDownload => hasBackup && !isClearing && !isDownloading;

  /// Reads the last backup and last clear timestamps from settings.
  Future<void> load() async {
    final Map<String, String?> stored =
        (await _settings.readAll()).valueOrNull ?? const <String, String?>{};
    _lastBackupAt = _parseMillis(stored[SettingKeys.lastBackupAt]);
    _lastClearedAt = _parseMillis(stored[SettingKeys.lastClearedAt]);
    _lastBackupPath = stored[SettingKeys.lastBackupPath];
    _notify();
  }

  /// Removes operational data. Returns true when the till is empty of it.
  Future<bool> clear() async {
    if (!canClear) {
      return false;
    }

    _status = DataResetStatus.clearing;
    _errorMessage = null;
    _downloadError = null;
    _downloadedTo = null;
    _notify();

    final Result<void> result = await _wiper.clearOperationalData();
    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _status = DataResetStatus.error;
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    _billing.clearCart();
    await _billing.loadMenu();
    await load();

    _status = DataResetStatus.cleared;
    _notify();
    return true;
  }

  /// Copies the last backup into the user's Downloads folder.
  Future<void> downloadLastBackup() async {
    final String? path = _lastBackupPath;
    if (path == null || path.isEmpty || !canDownload) {
      return;
    }

    _isDownloading = true;
    _downloadError = null;
    _downloadedTo = null;
    _notify();

    final Result<String> result = await _backups.copyToDownloads(path);
    _isDownloading = false;
    if (result.isErr) {
      _downloadError = result.failureOrNull!.message;
    } else {
      _downloadedTo = result.valueOrNull;
    }
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }

  static DateTime? _parseMillis(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final int? millis = int.tryParse(raw);
    if (millis == null) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }
}
