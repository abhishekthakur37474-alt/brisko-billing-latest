import 'package:flutter/foundation.dart';

import '../../../../core/error/app_failure.dart';
import '../../../../core/utils/entity_id.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/inventory_item.dart';
import '../../domain/models/order_inventory_deduction.dart';
import '../../domain/models/stock_movement.dart';
import '../../domain/models/stock_movement_type.dart';
import '../../domain/models/stock_unit.dart';
import '../../domain/repositories/inventory_deduction_repository.dart';
import '../../domain/repositories/inventory_repository.dart';

/// Holds the stock screen: the items, which are low, and which bills still owe a
/// deduction.
///
/// ## Nothing here is invented
///
/// Every figure comes from the repository. An outlet that has entered no stock items
/// sees none, which is the truthful thing to show on the day it is installed. There are
/// no sample ingredients, no example quantities and no placeholder history anywhere in
/// this file.
///
/// ## Failure
///
/// Nothing throws. A repository failure becomes [errorMessage] and the list falls back
/// to empty, so a storage fault is something the operator reads rather than a red box
/// where the stock list should be.
class InventoryController extends ChangeNotifier {
  InventoryController({
    required InventoryRepository inventoryRepository,
    required InventoryDeductionRepository deductionRepository,
  }) : _inventory = inventoryRepository,
       _deductions = deductionRepository;

  final InventoryRepository _inventory;
  final InventoryDeductionRepository _deductions;

  List<InventoryItem> _items = const <InventoryItem>[];
  List<OrderInventoryDeduction> _failedDeductions =
      const <OrderInventoryDeduction>[];
  List<OrderInventoryDeduction> _unconfiguredDeductions =
      const <OrderInventoryDeduction>[];

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _errorMessage;
  bool _isDisposed = false;

  /// Set while a write is in flight, so the form that started it can disable its own
  /// button without locking the whole screen.
  bool _isSaving = false;

  /// Bills whose retry is in flight, disabled individually rather than as a group.
  final Set<String> _retrying = <String>{};

  /// The item whose ledger is open, and its movements.
  String? _historyItemId;
  List<StockMovement> _history = const <StockMovement>[];
  bool _isLoadingHistory = false;

  // ------------------------------------------------------------------- state ---

  /// Every live, active stock item in name order.
  List<InventoryItem> get items => _items;

  bool get isLoading => _isLoading;

  /// True once a read has finished, successfully or not. Distinguishes "no stock
  /// items entered yet" from "not read yet".
  bool get hasLoaded => _hasLoaded;

  String? get errorMessage => _errorMessage;

  bool get hasError => _errorMessage != null;

  bool get isSaving => _isSaving;

  /// True when the screen has been read and holds nothing.
  bool get isEmpty => _hasLoaded && _items.isEmpty;

  /// Items at or below their threshold, in the same order as [items].
  List<InventoryItem> get lowStockItems =>
      _items.where((InventoryItem item) => item.isLow).toList(growable: false);

  int get lowStockCount => lowStockItems.length;

  bool get hasLowStock => lowStockCount > 0;

  /// Settled bills whose stock was not taken off the shelf. The owner's work list.
  List<OrderInventoryDeduction> get failedDeductions => _failedDeductions;

  bool get hasFailedDeductions => _failedDeductions.isNotEmpty;

  /// Settled bills that sold something with no recipe configured.
  List<OrderInventoryDeduction> get unconfiguredDeductions =>
      _unconfiguredDeductions;

  bool get hasUnconfiguredDeductions => _unconfiguredDeductions.isNotEmpty;

  bool isRetrying(String orderId) => _retrying.contains(orderId);

  /// The item whose ledger is open, or `null`.
  String? get historyItemId => _historyItemId;

  /// The open item's movements, newest first.
  List<StockMovement> get history => _history;

  bool get isLoadingHistory => _isLoadingHistory;

  /// The item with [id], or `null` if it is not in the loaded list.
  InventoryItem? itemById(String id) {
    for (final InventoryItem item in _items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  // ----------------------------------------------------------------- reading ---

  /// Replaces the screen's contents from storage.
  ///
  /// Ignores a call made while a read is already running, so a double tap on refresh
  /// cannot interleave two reads and discard the later one's result.
  Future<void> load() async {
    if (_isLoading) {
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    final Result<List<InventoryItem>> items = await _inventory.loadItems();

    items.fold<void>(
      onOk: (List<InventoryItem> value) => _items = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        // Not the stale list: balances shown beside an error message would invite
        // someone to order against them.
        _items = const <InventoryItem>[];
      },
    );

    // The two deduction lists are secondary. A failure reading them is reported, but
    // it does not blank the stock list, which is what the operator came for.
    final Result<List<OrderInventoryDeduction>> failed = await _deductions
        .loadFailedDeductions();
    _failedDeductions = failed.valueOrNull ?? const <OrderInventoryDeduction>[];

    final Result<List<OrderInventoryDeduction>> unconfigured = await _deductions
        .loadUnconfiguredDeductions();
    _unconfiguredDeductions =
        unconfigured.valueOrNull ?? const <OrderInventoryDeduction>[];

    _isLoading = false;
    _hasLoaded = true;
    _notify();
  }

  Future<void> refresh() => load();

  void dismissError() {
    if (_errorMessage == null) {
      return;
    }
    _errorMessage = null;
    _notify();
  }

  // ------------------------------------------------------------------ writing ---

  /// Creates a stock item with an opening balance of zero.
  ///
  /// Zero on purpose. Whatever is already on the shelf is entered afterwards as stock
  /// in, so the balance has a ledger row explaining it from the very first gram. An
  /// item created with a balance out of nowhere would be the one figure in the system
  /// with no history behind it.
  ///
  /// Returns true when it was created. On failure the message is in [errorMessage] and
  /// the form stays open with what the operator typed.
  Future<bool> createItem({
    required String name,
    required StockUnit unit,
    required int minimumQuantityMilli,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    return _write(
      () => _inventory.saveItem(
        InventoryItem(
          id: EntityId.generate(prefix: 'inv'),
          name: name.trim(),
          unit: unit,
          minimumQuantityMilli: minimumQuantityMilli,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
  }

  /// Edits an item's name, unit or threshold.
  ///
  /// The balance is carried across untouched, because it belongs to the ledger. The
  /// repository refuses a save that would change it, and this is the call that keeps
  /// this screen on the right side of that rule.
  Future<bool> updateItem(
    InventoryItem item, {
    required String name,
    required StockUnit unit,
    required int minimumQuantityMilli,
  }) {
    return _write(
      () => _inventory.saveItem(
        item.copyWith(
          name: name.trim(),
          unit: unit,
          minimumQuantityMilli: minimumQuantityMilli,
          updatedAt: DateTime.now().toUtc(),
        ),
      ),
    );
  }

  /// Records a manual movement against an item.
  ///
  /// [quantityMilli] is thousandths of the item's unit, and is signed only for an
  /// adjustment. The repository decides whether the movement is legal — it is the only
  /// thing that can check the balance and write in the same transaction — so a refusal
  /// such as wasting more than the shelf holds arrives here as [errorMessage].
  Future<bool> recordMovement({
    required InventoryItem item,
    required StockMovementType type,
    required int quantityMilli,
    String? reason,
  }) {
    final String? trimmed = reason?.trim();
    final String? note = trimmed == null || trimmed.isEmpty ? null : trimmed;

    return _write(
      () => switch (type) {
        StockMovementType.stockIn => _inventory.stockIn(
          inventoryItemId: item.id,
          quantityMilli: quantityMilli,
          reason: note,
        ),
        StockMovementType.adjustment => _inventory.adjust(
          inventoryItemId: item.id,
          quantityMilli: quantityMilli,
          reason: note,
        ),
        StockMovementType.wastage => _inventory.recordWastage(
          inventoryItemId: item.id,
          quantityMilli: quantityMilli,
          reason: note,
        ),
        StockMovementType.stockOut => _inventory.stockOut(
          inventoryItemId: item.id,
          quantityMilli: quantityMilli,
          reason: note,
        ),
        // Not offered by the screen: a sale movement is written by settlement from a
        // recipe, and letting it be raised by hand would record consumption that no
        // bill accounts for.
        StockMovementType.sale => Future<Result<StockMovement>>.value(
          const Err<StockMovement>(
            ValidationFailure(
              'A sale is recorded by settling a bill, not by hand',
            ),
          ),
        ),
      },
    );
  }

  /// Soft-deletes an item.
  ///
  /// Refused by the repository while a recipe still uses it, which arrives here as
  /// [errorMessage] naming what to do about it.
  Future<bool> deleteItem(InventoryItem item) =>
      _write(() => _inventory.deleteItem(item.id));

  /// Tries again to take a settled bill's stock off the shelf.
  ///
  /// The usual sequence is that a delivery was never recorded, the owner records it,
  /// and then presses this. Retrying is safe however many times it is pressed: a bill
  /// already deducted deducts nothing more.
  Future<void> retryDeduction(OrderInventoryDeduction deduction) async {
    if (_retrying.contains(deduction.orderId)) {
      return;
    }

    _retrying.add(deduction.orderId);
    _errorMessage = null;
    _notify();

    final Result<OrderInventoryDeduction> result = await _deductions
        .deductForOrder(deduction.orderId);
    _retrying.remove(deduction.orderId);

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _notify();
      return;
    }

    // Re-read rather than patch in place: balances moved, and the stored rows are the
    // truth about by how much.
    await load();
  }

  // ------------------------------------------------------------------ history ---

  /// Opens an item's ledger.
  Future<void> openHistory(String inventoryItemId) async {
    _historyItemId = inventoryItemId;
    _history = const <StockMovement>[];
    _isLoadingHistory = true;
    _notify();

    final Result<List<StockMovement>> result = await _inventory.loadMovements(
      inventoryItemId,
    );

    // Ignored if the operator has already closed it or opened another item's ledger.
    if (_historyItemId != inventoryItemId) {
      return;
    }

    result.fold<void>(
      onOk: (List<StockMovement> value) => _history = value,
      onErr: (AppFailure failure) {
        _errorMessage = failure.message;
        _history = const <StockMovement>[];
      },
    );

    _isLoadingHistory = false;
    _notify();
  }

  void closeHistory() {
    if (_historyItemId == null) {
      return;
    }
    _historyItemId = null;
    _history = const <StockMovement>[];
    _isLoadingHistory = false;
    _notify();
  }

  // ---------------------------------------------------------------- internals ---

  /// Runs a write, then re-reads. Returns true when it succeeded.
  ///
  /// Every write goes through here so that the loading flag, the error message and the
  /// reload after a change are handled identically. Re-reading rather than mutating the
  /// list in place means the screen always shows stored balances, which is the only
  /// thing it is allowed to claim.
  Future<bool> _write(Future<Result<Object?>> Function() action) async {
    if (_isSaving) {
      return false;
    }

    _isSaving = true;
    _errorMessage = null;
    _notify();

    final Result<Object?> result = await action();
    _isSaving = false;

    final AppFailure? failure = result.failureOrNull;
    if (failure != null) {
      _errorMessage = failure.message;
      _notify();
      return false;
    }

    await load();

    // Refreshes an open ledger too, so recording stock in while looking at the
    // history shows the new row rather than leaving it a step behind.
    final String? open = _historyItemId;
    if (open != null) {
      await openHistory(open);
    }
    return true;
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  /// Notifies unless the controller has already been disposed.
  ///
  /// A read or a write can still be in flight when the operator navigates away, and
  /// notifying a disposed notifier is an error.
  void _notify() {
    if (_isDisposed) {
      return;
    }
    notifyListeners();
  }
}
