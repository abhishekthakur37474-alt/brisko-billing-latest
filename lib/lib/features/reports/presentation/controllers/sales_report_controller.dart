import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/date_range.dart';
import '../../domain/models/item_sales_row.dart';
import '../../domain/models/payment_mix.dart';
import '../../domain/models/report_period.dart';
import '../../domain/models/sales_bill.dart';
import '../../domain/models/sales_summary.dart';
import '../../domain/repositories/sales_report_repository.dart';

/// Holds the Reports screen: which dates are being looked at, and what was sold in them.
///
/// ## What it does not contain
///
/// SQL, and any knowledge that SQLite exists. Every figure comes from
/// [SalesReportRepository], which aggregates in the database. This class chooses a date
/// range, asks four questions about it, and holds the answers.
///
/// It also contains no menu access, deliberately and permanently. A report of what was
/// sold is a report of what was charged, and the only place that is recorded is the
/// persisted bill.
///
/// ## The clock
///
/// "Today" is decided by [clock], which defaults to the real one and is injected by
/// tests. Nothing below calls `DateTime.now()`. A report whose boundaries depended on an
/// unmockable clock could not be tested at all except by luck of the hour the suite ran.
///
/// ## Failure
///
/// Nothing throws. A read that fails clears every figure and sets [errorMessage], which
/// the screen renders in place with a retry. Clearing rather than keeping is the point: a
/// gross sales figure sitting above a message saying the item report could not be read is
/// a number somebody will quote.
class SalesReportController extends ChangeNotifier {
  SalesReportController({
    required SalesReportRepository reportRepository,
    DateTime Function()? clock,
  }) : _reports = reportRepository,
       _clock = clock ?? DateTime.now {
    // The counter opens this screen to ask about today, so that is what is selected
    // before any read runs. Resolved through the injected clock like every other date
    // in this class.
    _range = DateRange.day(_clock());
  }

  final SalesReportRepository _reports;
  final DateTime Function() _clock;

  ReportPeriod _period = ReportPeriod.today;
  late DateRange _range;

  SalesSummary _summary = SalesSummary.empty;
  PaymentMix _paymentMix = PaymentMix.empty();
  List<ItemSalesRow> _itemSales = const <ItemSalesRow>[];
  List<SalesBill> _bills = const <SalesBill>[];

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // ------------------------------------------------------------------ filter ---

  /// The date filter in force.
  ReportPeriod get period => _period;

  /// The local days being reported on.
  DateRange get range => _range;

  // ------------------------------------------------------------------- state ---

  /// The money and the counts for [range].
  SalesSummary get summary => _summary;

  /// Takings for [range] split by tender method.
  PaymentMix get paymentMix => _paymentMix;

  /// What was sold in [range], best-selling by value first.
  List<ItemSalesRow> get itemSales => _itemSales;

  /// The settled bills in [range], newest first.
  List<SalesBill> get bills => _bills;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the read finished and nothing was sold in the range.
  ///
  /// A real and common answer — a quiet morning, or a terminal on its first day — so it
  /// is reported as itself rather than as an error or as a screen of zeroes.
  bool get isEmpty => _hasLoaded && !hasError && _summary.isEmpty;

  // ----------------------------------------------------------------- filters ---

  /// Switches to [period] and reads it.
  ///
  /// Ignores [ReportPeriod.custom], which has no dates of its own: the screen calls
  /// [selectCustomRange] once the operator has chosen them. Ignoring rather than
  /// clearing means tapping "Custom" and then dismissing the date picker leaves the
  /// previous report on screen instead of blanking it.
  Future<void> selectPeriod(ReportPeriod period) async {
    final DateRange? resolved = period.resolve(_clock());
    if (resolved == null) {
      return;
    }
    if (period == _period && resolved == _range) {
      return;
    }
    _period = period;
    _range = resolved;
    await load();
  }

  /// Reports on the local days from [firstDay] to [lastDay], both included.
  ///
  /// The two are whole days, not instants: a range chosen as the 3rd to the 5th includes
  /// everything taken on the 5th. See [DateRange].
  Future<void> selectCustomRange({
    required DateTime firstDay,
    required DateTime lastDay,
  }) async {
    _period = ReportPeriod.custom;
    _range = DateRange.spanning(firstInstant: firstDay, lastInstant: lastDay);
    await load();
  }

  // ----------------------------------------------------------------- reading ---

  /// Reads the four reports for the selected range.
  ///
  /// Ignores a call made while a read is already running, so a double tap on retry
  /// cannot interleave two reads and leave one range's bills beside another's totals.
  /// Where the range changed during a read, the loop below notices and reads again
  /// rather than publishing figures for dates nobody is looking at any more.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    while (true) {
      // Pinned for the duration of one pass, so all four figures describe the same
      // dates even if the operator taps another chip midway.
      final DateRange requested = _range;

      if (!await _read(requested)) {
        // The read failed and has already reported itself.
        return;
      }
      if (_range == requested) {
        break;
      }
    }

    _finish();
  }

  Future<void> retry() => load();

  /// Re-reads the current range, for after a bill has been settled elsewhere.
  Future<void> refresh() => load();

  /// Runs the four reads for [requested], returning false if one failed.
  ///
  /// Sequential rather than concurrent: they share one SQLite connection, so running
  /// them together would serialise anyway, and in order the first failure stops the rest
  /// instead of producing four messages about one fault.
  Future<bool> _read(DateRange requested) async {
    final Result<SalesSummary> summary = await _reports.loadSummary(requested);
    final AppFailure? summaryFailure = summary.failureOrNull;
    if (summaryFailure != null) {
      _fail(summaryFailure.message);
      return false;
    }

    final Result<PaymentMix> mix = await _reports.loadPaymentMix(requested);
    final AppFailure? mixFailure = mix.failureOrNull;
    if (mixFailure != null) {
      _fail(mixFailure.message);
      return false;
    }

    final Result<List<ItemSalesRow>> items = await _reports.loadItemSales(
      requested,
    );
    final AppFailure? itemFailure = items.failureOrNull;
    if (itemFailure != null) {
      _fail(itemFailure.message);
      return false;
    }

    final Result<List<SalesBill>> bills = await _reports.loadBills(requested);
    final AppFailure? billFailure = bills.failureOrNull;
    if (billFailure != null) {
      _fail(billFailure.message);
      return false;
    }

    _summary = summary.valueOrNull!;
    _paymentMix = mix.valueOrNull!;
    _itemSales = items.valueOrNull!;
    _bills = bills.valueOrNull!;
    return true;
  }

  // --------------------------------------------------------------- internals ---

  /// Reports a read that failed, showing no figures at all.
  void _fail(String message) {
    _errorMessage = message;
    _clear();
    _finish();
  }

  void _clear() {
    _summary = SalesSummary.empty;
    _paymentMix = PaymentMix.empty();
    _itemSales = const <ItemSalesRow>[];
    _bills = const <SalesBill>[];
  }

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
