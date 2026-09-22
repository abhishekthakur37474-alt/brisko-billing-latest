import 'package:flutter/foundation.dart';

import '../../../../core/utils/result.dart';
import '../../domain/services/manager_auth_service.dart';

/// Where the manager-password screen stands.
enum ManagerPasswordStatus {
  /// Reading whether a password is already stored.
  loading,

  /// The form is ready.
  loaded,

  /// A save is in flight.
  saving,

  /// The last save committed, and the fields have been cleared.
  saved,

  /// Something failed. [ManagerPasswordController.errorMessage] says what.
  error,
}

/// Holds the Manager password form: whether one is set, the draft fields, and saving it.
///
/// The plaintext never leaves this controller except to [ManagerAuthService], which hashes
/// it and writes the hash. After a successful save the draft is wiped so a later glance at
/// the screen cannot recover what was typed.
class ManagerPasswordController extends ChangeNotifier {
  ManagerPasswordController({required ManagerAuthService auth}) : _auth = auth;

  static const int minLength = 4;

  final ManagerAuthService _auth;

  ManagerPasswordStatus _status = ManagerPasswordStatus.loading;
  bool _isPasswordSet = false;
  bool _loadFailed = false;
  String _currentPassword = '';
  String _newPassword = '';
  String _confirmPassword = '';
  String? _errorMessage;

  ManagerPasswordStatus get status => _status;

  bool get isPasswordSet => _isPasswordSet;

  bool get loadFailed => _loadFailed;

  String get currentPassword => _currentPassword;

  String get newPassword => _newPassword;

  String get confirmPassword => _confirmPassword;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  bool get isSaving => _status == ManagerPasswordStatus.saving;

  bool get isSaved => _status == ManagerPasswordStatus.saved;

  bool get canSave =>
      !isSaving &&
      !_loadFailed &&
      _newPassword.isNotEmpty &&
      _confirmPassword.isNotEmpty &&
      (!_isPasswordSet || _currentPassword.isNotEmpty);

  Future<void> load() async {
    _status = ManagerPasswordStatus.loading;
    _loadFailed = false;
    _errorMessage = null;
    notifyListeners();

    final Result<bool> result = await _auth.isPasswordSet();
    if (result.isErr) {
      _loadFailed = true;
      _errorMessage = result.failureOrNull!.message;
      _status = ManagerPasswordStatus.error;
      notifyListeners();
      return;
    }

    _isPasswordSet = result.valueOrNull ?? false;
    _status = ManagerPasswordStatus.loaded;
    notifyListeners();
  }

  void editCurrentPassword(String value) {
    _currentPassword = value;
    _clearOutcome();
  }

  void editNewPassword(String value) {
    _newPassword = value;
    _clearOutcome();
  }

  void editConfirmPassword(String value) {
    _confirmPassword = value;
    _clearOutcome();
  }

  /// Persists the new manager password.
  ///
  /// When one is already stored, the current password must match first. Returns true
  /// only after the hash has been written.
  Future<bool> save() async {
    if (isSaving || _loadFailed) {
      return false;
    }

    final String? validation = _validate();
    if (validation != null) {
      _errorMessage = validation;
      _status = ManagerPasswordStatus.error;
      notifyListeners();
      return false;
    }

    _status = ManagerPasswordStatus.saving;
    _errorMessage = null;
    notifyListeners();

    if (_isPasswordSet) {
      final Result<bool> verified = await _auth.verifyPassword(_currentPassword);
      if (verified.isErr) {
        _fail(verified.failureOrNull!.message);
        return false;
      }
      if (verified.valueOrNull != true) {
        _fail('Current manager password is incorrect.');
        return false;
      }
    }

    final Result<void> written = await _auth.setPassword(_newPassword);
    if (written.isErr) {
      _fail(written.failureOrNull!.message);
      return false;
    }

    _isPasswordSet = true;
    _currentPassword = '';
    _newPassword = '';
    _confirmPassword = '';
    _errorMessage = null;
    _status = ManagerPasswordStatus.saved;
    notifyListeners();
    return true;
  }

  String? _validate() {
    if (_isPasswordSet && _currentPassword.isEmpty) {
      return 'Enter the current manager password.';
    }
    if (_newPassword.isEmpty) {
      return 'Enter a new manager password.';
    }
    if (_newPassword.length < minLength) {
      return 'Use at least $minLength characters.';
    }
    if (_newPassword != _confirmPassword) {
      return 'New password and confirmation do not match.';
    }
    return null;
  }

  void _fail(String message) {
    _errorMessage = message;
    _status = ManagerPasswordStatus.error;
    notifyListeners();
  }

  void _clearOutcome() {
    if (_status == ManagerPasswordStatus.error ||
        _status == ManagerPasswordStatus.saved) {
      _errorMessage = null;
      _status = ManagerPasswordStatus.loaded;
    }
    notifyListeners();
  }
}
