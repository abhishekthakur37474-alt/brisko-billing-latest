import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/result.dart';
import '../../../inventory/domain/models/inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../../reports/domain/models/date_range.dart';
import '../../../reports/domain/models/item_sales_row.dart';
import '../../../reports/domain/models/payment_mix.dart';
import '../../../reports/domain/models/report_period.dart';
import '../../../reports/domain/models/sales_bill.dart';
import '../../../reports/domain/models/sales_summary.dart';
import '../../../reports/domain/repositories/sales_report_repository.dart';

/// Holds the "Today" dashboard: what the outlet has taken so far, and what needs an eye
/// kept on it.
///
/// ## What it is, and what it is not
///
/// A read of figures already computed elsewhere. Every sales number comes from
/// [SalesReportRepository], which aggregates in SQLite; the low-stock list comes from
/// [InventoryRepository]. This class chooses a period, asks for those figures and holds
/// them. It contains no SQL, no menu access and no second way of counting a sale — the
/// definitions of discount, GST, refund and net are `SalesSummary`'s, so the dashboard and
/// the reports can never disagree.
///
/// ## The clock
///
/// "Today" is decided by [clock], which defaults to the real one and is injected by tests,
/// exactly as `SalesReportController` does it. Nothing here calls `DateTime.now()` directly.
///
/// ## The periods it offers
///
/// Three, from [ReportPeriod]: today, yesterday and the last seven days. The custom range
/// belongs on the Reports screen; a dashboard is opened to glance, not to investigate.
///
/// ## Failure
///
/// A failed sales read clears every figure and sets [errorMessage], which the screen renders
/// in place with a retry — a gross figure sitting above an error is a figure somebody quotes.
/// A failed low-stock read is treated differently: it is not fatal, because a stock warning
/// that could not be read must not blank out today's takings. The list is simply empty and
/// the rest of the dashboard stands.
class DashboardController extends ChangeNotifier {
  DashboardController({
    required SalesReportRepository reportRepository,
    required InventoryRepository inventoryRepository,
    DateTime Function()? clock,
  }) : _reports = reportRepository,
       _inventory = inventoryRepository,
       _clock = clock ?? DateTime.now {
    _range = DateRange.day(_clock());
  }

  /// How many best-selling items the dashboard shows. A glance, not the full report — the
  /// Item sales report is where the whole list lives.
  static const int topItemsLimit = 5;

  /// How many recent bills the dashboard shows. The order history is where the rest are.
  static const int recentBillsLimit = 8;

  /// The periods a dashboard offers, in the order they are shown. The custom range is a
  /// Reports-screen concern.
  static const List<ReportPeriod> periods = <ReportPeriod>[
    ReportPeriod.today,
    ReportPeriod.yesterday,
    ReportPeriod.last7Days,
  ];

  final SalesReportRepository _reports;
  final InventoryRepository _inventory;
  final DateTime Function() _clock;

  ReportPeriod _period = ReportPeriod.today;
  late DateRange _range;

  SalesSummary _summary = SalesSummary.empty;
  PaymentMix _paymentMix = PaymentMix.empty();
  List<ItemSalesRow> _topItems = const <ItemSalesRow>[];
  List<SalesBill> _recentBills = const <SalesBill>[];
  List<InventoryItem> _lowStock = const <InventoryItem>[];

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  // ------------------------------------------------------------------ filter ---

  /// The period in force.
  ReportPeriod get period => _period;

  /// The local days being shown.
  DateRange get range => _range;

  // ------------------------------------------------------------------- state ---

  /// The money and the counts for [range].
  SalesSummary get summary => _summary;

  /// Takings for [range] split by tender method.
  PaymentMix get paymentMix => _paymentMix;

  /// The best-selling items in [range], most valuable first.
  List<ItemSalesRow> get topItems => _topItems;

  /// The most recent settled bills in [range], newest first.
  List<SalesBill> get recentBills => _recentBills;

  /// Stock items at or below their reorder threshold, in name order.
  List<InventoryItem> get lowStock => _lowStock;

  bool get isLoading => _isLoading;

  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  /// True when the read finished and nothing was sold in the period.
  ///
  /// A quiet morning, or a terminal on its first day, is a real answer rather than an
  /// error. Keyed on the sales figures only: a period with no sales but a stock warning is
  /// not empty, because the warning still has to be shown.
  bool get isEmpty => _hasLoaded && !hasError && _summary.isEmpty;

  /// True when there is at least one stock item to warn about.
  bool get hasLowStock => _lowStock.isNotEmpty;

  // ----------------------------------------------------------------- filters ---

  /// Switches to [period] and reads it. Ignores a period with no resolvable range.
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

  // ----------------------------------------------------------------- reading ---

  /// Reads every figure the dashboard shows for the selected range.
  ///
  /// Ignores a call made while a read is already running, and, like the reports controller,
  /// reads again if the period changed midway rather than publishing figures for a period
  /// nobody is looking at any more.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    while (true) {
      final DateRange requested = _range;
      if (!await _read(requested)) {
        return;
      }
      if (_range == requested) {
        break;
      }
    }

    _finish();
  }

  Future<void> retry() => load();

  /// Re-reads the current period, for after a bill has been settled or refunded elsewhere.
  Future<void> refresh() => load();

  /// Runs the reads for [requested], returning false if a fatal one failed.
  ///
  /// Sequential, because they share one SQLite connection. The sales reads are fatal; the
  /// low-stock read is not, so a stock fault leaves the takings on screen.
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
      limit: topItemsLimit,
    );
    final AppFailure? itemFailure = items.failureOrNull;
    if (itemFailure != null) {
      _fail(itemFailure.message);
      return false;
    }

    final Result<List<SalesBill>> bills = await _reports.loadBills(
      requested,
      limit: recentBillsLimit,
    );
    final AppFailure? billFailure = bills.failureOrNull;
    if (billFailure != null) {
      _fail(billFailure.message);
      return false;
    }

    _summary = summary.valueOrNull!;
    _paymentMix = mix.valueOrNull!;
    _topItems = items.valueOrNull!;
    _recentBills = bills.valueOrNull!;
    // Deliberately last and deliberately not fatal: a stock warning that could not be read
    // must not hide the day's takings.
    _lowStock = await _readLowStock();
    return true;
  }

  Future<List<InventoryItem>> _readLowStock() async {
    final Result<List<InventoryItem>> low = await _inventory
        .loadLowStockItems();
    return low.valueOrNull ?? const <InventoryItem>[];
  }

  // --------------------------------------------------------------- internals ---

  void _fail(String message) {
    _errorMessage = message;
    _clear();
    _finish();
  }

  void _clear() {
    _summary = SalesSummary.empty;
    _paymentMix = PaymentMix.empty();
    _topItems = const <ItemSalesRow>[];
    _recentBills = const <SalesBill>[];
    _lowStock = const <InventoryItem>[];
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
