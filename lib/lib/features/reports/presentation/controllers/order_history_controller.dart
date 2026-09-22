import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order_type.dart';
import '../../domain/models/bill_search_query.dart';
import '../../domain/models/date_range.dart';
import '../../domain/models/report_period.dart';
import '../../domain/models/sales_bill.dart';
import '../../domain/repositories/sales_report_repository.dart';

/// Holds the order-history search: the criteria the cashier has entered, and the settled
/// bills that match them.
///
/// ## What it is
///
/// A thin state holder over [SalesReportRepository.searchBills]. Every bill it returns is a
/// settled one — the same rule the reports use — so a cancelled or unsettled record never
/// appears. The criteria are held as their own fields so the screen can bind a text box to
/// each, and composed into a [BillSearchQuery] only when a search is run.
///
/// ## The date filter
///
/// [period] may be `null`, which means "any date": finding a bill by its number should not
/// be constrained to a week the cashier has to guess. It opens on [ReportPeriod.last7Days]
/// so the screen shows recent trade before anything is typed, which is the common case.
///
/// ## The clock
///
/// Injected, defaulting to the real one, so a period resolves to the same days in a test as
/// it does at the counter. Nothing here reads a clock directly.
class OrderHistoryController extends ChangeNotifier {
  OrderHistoryController({
    required SalesReportRepository reportRepository,
    DateTime Function()? clock,
  }) : _reports = reportRepository,
       _clock = clock ?? DateTime.now;

  /// The date filters the screen offers. `null` is "any date".
  static const List<ReportPeriod?> periods = <ReportPeriod?>[
    ReportPeriod.today,
    ReportPeriod.yesterday,
    ReportPeriod.last7Days,
    null,
  ];

  /// How many matches a search returns. A cashier scans a screenful, not a year.
  static const int limit = 100;

  final SalesReportRepository _reports;
  final DateTime Function() _clock;

  String _orderNumber = '';
  String _customerPhone = '';
  OrderType? _orderType;
  ReportPeriod? _period = ReportPeriod.last7Days;

  List<SalesBill> _results = const <SalesBill>[];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // ------------------------------------------------------------------- state ---

  String get orderNumber => _orderNumber;

  String get customerPhone => _customerPhone;

  OrderType? get orderType => _orderType;

  ReportPeriod? get period => _period;

  /// The matching bills, newest first.
  List<SalesBill> get results => _results;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when a search finished and nothing matched.
  bool get isEmpty => _hasLoaded && !hasError && _results.isEmpty;

  /// The current criteria, resolved to a query. Public so the screen can describe what is
  /// being searched, and so it reads exactly as the search that ran.
  BillSearchQuery get query {
    final ReportPeriod? period = _period;
    final DateRange? range = period?.resolve(_clock());
    return BillSearchQuery(
      orderNumber: _orderNumber,
      customerPhone: _customerPhone,
      range: range,
      orderType: _orderType,
    );
  }

  // ----------------------------------------------------------------- filters ---

  /// Records the bill-number term without searching. The screen searches on submit.
  void setOrderNumber(String value) {
    _orderNumber = value;
  }

  /// Records the phone term without searching. The screen searches on submit.
  void setCustomerPhone(String value) {
    _customerPhone = value;
  }

  /// Sets the order-type filter and searches, because a chip is a decision, not typing.
  Future<void> selectOrderType(OrderType? orderType) async {
    if (orderType == _orderType) {
      return;
    }
    _orderType = orderType;
    await search();
  }

  /// Sets the date filter and searches.
  Future<void> selectPeriod(ReportPeriod? period) async {
    if (period == _period) {
      return;
    }
    _period = period;
    await search();
  }

  // ----------------------------------------------------------------- reading ---

  /// Runs the search for the current criteria.
  ///
  /// Ignores a call made while one is already running, so a fast double submit cannot
  /// interleave two reads.
  Future<void> search() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<SalesBill>> found = await _reports.searchBills(
      query,
      limit: limit,
    );

    final AppFailure? failure = found.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _results = const <SalesBill>[];
      _finish();
      return;
    }

    _results = found.valueOrNull!;
    _finish();
  }

  Future<void> retry() => search();

  Future<void> load() => search();

  // --------------------------------------------------------------- internals ---

  void _finish() {
    _isLoading = false;
    _hasLoaded = true;
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
}
