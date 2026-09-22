import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/held_bill.dart';
import '../../domain/models/held_bill_summary.dart';
import '../../domain/repositories/held_bill_repository.dart';

/// Drives the held-bills list: what is on the terminal, and resuming or cancelling one.
///
/// ## What it owns
///
/// The list is read from the repository, never patched in memory. Resuming or cancelling
/// a bill re-reads the list rather than removing a row from it, so the screen always shows
/// what storage holds — which is what makes a bill cancelled on another terminal disappear
/// here on the next action rather than lingering as a stale entry.
///
/// ## Resuming is two halves
///
/// This controller marks the bill resumed and hands the resumed [HeldBill] back to its
/// caller, which is the only thing that can put the cart onto the counter. Keeping the
/// billing cart out of here means the list has no opinion about the live bill beyond
/// whether one exists — [canResume] — which the screen sets from above.
///
/// ## Failures
///
/// A read that fails leaves [errorMessage] set and the list empty, so no stale entry is
/// left to act on. A resume or cancel that fails reports itself and re-reads, because the
/// most likely reason it failed is that the bill is no longer resumable — another terminal
/// got there first — and the freshly read list is the honest answer.
class HeldBillsController extends ChangeNotifier {
  HeldBillsController({required HeldBillRepository heldBillRepository})
    : _repository = heldBillRepository;

  final HeldBillRepository _repository;

  List<HeldBillSummary> _bills = const <HeldBillSummary>[];

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  /// Bills whose resume or cancel is in flight, so a row's buttons disable individually
  /// rather than locking the whole list.
  final Set<String> _busy = <String>{};

  // ------------------------------------------------------------------- state ---

  /// The held bills on the terminal, oldest first.
  List<HeldBillSummary> get bills => _bills;

  bool get isLoading => _isLoading;

  /// True once a read has finished, whether it succeeded or failed. Distinguishes "not
  /// read yet" from "read, and nothing is held".
  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the list was read and holds nothing.
  bool get isEmpty => _hasLoaded && !hasError && _bills.isEmpty;

  /// True while a specific bill's resume or cancel is being written.
  bool isBusy(String id) => _busy.contains(id);

  // ----------------------------------------------------------------- reading ---

  /// Reads the held bills from storage.
  ///
  /// Ignores a call made while a read is already running, so a double tap on retry cannot
  /// interleave two reads.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<HeldBillSummary>> result = await _repository
        .loadHeldBills();

    result.fold<void>(
      onOk: (List<HeldBillSummary> value) =>
          _bills = List<HeldBillSummary>.unmodifiable(value),
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        // Not the stale list: a bill shown beside a read failure would invite a resume
        // against a list that could not be trusted.
        _bills = const <HeldBillSummary>[];
      },
    );

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  /// The retry path for the error state.
  Future<void> retry() => load();

  // ------------------------------------------------------------------ writing ---

  /// Resumes the bill with [id], returning it whole on success or `null` on failure.
  ///
  /// On success the bill is marked resumed in storage and the returned [HeldBill] carries
  /// the cart to put back on the counter; the list is re-read so the resumed bill leaves
  /// it. On failure the message is in [errorMessage] and the list is re-read, because the
  /// usual cause is that the bill is no longer resumable.
  Future<HeldBill?> resume(String id) async {
    if (_busy.contains(id)) {
      return null;
    }

    _busy.add(id);
    _errorMessage = null;
    _notify();

    final Result<HeldBill> result = await _repository.resume(id);
    _busy.remove(id);

    final HeldBill? resumed = result.valueOrNull;
    if (resumed == null) {
      _errorMessage = result.failureOrNull?.message;
    }

    // Re-read either way: on success the bill has left the list, and on failure the list
    // is the truth about what is still there.
    await load();
    return resumed;
  }

  /// Cancels the bill with [id]. Returns true when it was cancelled.
  ///
  /// The row stays in storage, marked cancelled, so the abandonment is auditable; it just
  /// leaves this list. A failure reports itself and re-reads for the same reason resume
  /// does.
  Future<bool> cancel(String id) async {
    if (_busy.contains(id)) {
      return false;
    }

    _busy.add(id);
    _errorMessage = null;
    _notify();

    final Result<HeldBill> result = await _repository.cancel(id);
    _busy.remove(id);

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
    }

    await load();
    return failure == null;
  }

  // --------------------------------------------------------------- internals ---

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
}
