import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/customer_phone.dart';
import '../../domain/models/customer_summary.dart';
import '../../domain/repositories/customer_repository.dart';

/// Holds the customer list: who is on file, and what their bills add up to.
///
/// ## Nothing here is invented
///
/// Every row comes from the repository, and every figure on it was aggregated from
/// stored bills. A freshly installed terminal shows no customers, which is the truthful
/// thing to show before anybody has given their number. There are no sample customers,
/// no example phone numbers and no placeholder totals in this file.
///
/// ## Searching
///
/// The search box filters in the database rather than in memory, so it works on a list
/// longer than one screen. A digit-only query is matched against the phone number and
/// anything else against the name, which is what the counter actually types: they have
/// a phone number, and occasionally a name.
///
/// ## Failure
///
/// Nothing throws. A repository failure becomes [errorMessage] and the list falls back
/// to empty, so a storage fault is something the operator reads and can retry rather
/// than a red box where the customer list should be.
class CustomerDirectoryController extends ChangeNotifier {
  CustomerDirectoryController({required CustomerRepository customerRepository})
    : _customers = customerRepository;

  final CustomerRepository _customers;

  List<CustomerSummary> _results = const <CustomerSummary>[];
  String _query = '';

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  /// Which read is current. A slower earlier read cannot overwrite a later one's
  /// results, which is what would otherwise happen when the operator types quickly.
  int _generation = 0;

  // ------------------------------------------------------------------- state ---

  /// Customers matching the current query, most recent visit first.
  List<CustomerSummary> get results => _results;

  /// What the operator has typed into the search box.
  String get query => _query;

  bool get hasQuery => _query.trim().isNotEmpty;

  bool get isLoading => _isLoading;

  /// True once a read has finished, successfully or not.
  ///
  /// Distinguishes "no customers on file" from "not read yet", which is the difference
  /// between an honest empty state and a spinner that never went away.
  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the read finished and matched nothing.
  bool get isEmpty => _hasLoaded && !hasError && _results.isEmpty;

  /// True when the list is empty because nobody is on file at all, rather than because
  /// the search excluded everyone.
  bool get isEmptyDirectory => isEmpty && !hasQuery;

  /// True when the query looks like a complete phone number that matched nothing.
  ///
  /// Used to explain the empty result rather than leave it blank: a number with no
  /// record simply has not ordered here before, which is worth saying plainly.
  bool get isUnknownNumber => isEmpty && CustomerPhone.isValid(_query);

  // ----------------------------------------------------------------- reading ---

  /// Reads the list for the current query.
  Future<void> load() async {
    final int generation = ++_generation;

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<CustomerSummary>> result = await _customers.loadDirectory(
      query: hasQuery ? _query : null,
    );

    // A newer read has started. Its result is the one that belongs on screen.
    if (generation != _generation) {
      return;
    }

    result.fold<void>(
      onOk: (List<CustomerSummary> value) => _results = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        // Not the stale list. Customer totals shown beside an error message would
        // invite somebody to read a figure that may no longer be true.
        _results = const <CustomerSummary>[];
      },
    );

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  Future<void> refresh() => load();

  /// Applies a new search term and re-reads.
  ///
  /// Re-reads on every change rather than on submit. The query is one indexed `LIKE` on
  /// a single-outlet table, and a counter looking somebody up wants the list to narrow
  /// as they type rather than after they find the enter key.
  Future<void> search(String value) async {
    if (_query == value) {
      return;
    }
    _query = value;
    _notify();
    await load();
  }

  Future<void> clearSearch() => search('');

  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    _notify();
  }

  // --------------------------------------------------------------- internals ---

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Notifies unless the controller has already been disposed.
  ///
  /// A read can still be in flight when the operator navigates away, and notifying a
  /// disposed notifier is an error.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
