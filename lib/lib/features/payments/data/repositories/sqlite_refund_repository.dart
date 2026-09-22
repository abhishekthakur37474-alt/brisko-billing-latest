import 'package:sqflite/sqflite.dart';

import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_database.dart';
import '../../../../core/data/local/sqlite/sqlite_error_mapper.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/local/sqlite/sqlite_upsert.dart';
import '../../../../core/money/money.dart';
import '../../../../core/utils/result.dart';
import '../../../orders/domain/models/order_status.dart';
import '../../domain/models/payment_method.dart';
import '../../domain/models/refund.dart';
import '../../domain/models/refund_policy.dart';
import '../../domain/models/refund_request.dart';
import '../../domain/models/refundable_bill.dart';
import '../../domain/repositories/refund_repository.dart';

/// SQLite implementation of [RefundRepository].
///
/// ## One transaction, and the decision is inside it
///
/// Everything a refund is allowed to depend on is read inside the transaction that writes
/// it: the order's status and number, any reversal already recorded, and the bill's settled
/// tenders. Nothing is carried in from the screen except the request's identity, its amount
/// and its reason — and the amount is checked against what the transaction itself read
/// rather than trusted.
///
/// On the single SQLite connection this application uses, transactions are serialised. Two
/// cashiers tapping Refund at the same moment therefore resolve to one winner: the second
/// transaction reads the first one's committed row and is turned away. The unique index
/// `idx_refunds_order` is the backstop underneath that, so the invariant survives even if
/// this method's guard were changed.
///
/// ## Retrying versus trying again
///
/// A repeat of the *same* [RefundRequest] finds the row it wrote under its own id and
/// returns it, writing nothing. That is what makes a retry safe after a failure whose
/// outcome was never seen. A *different* request against a bill that already has a reversal
/// is refused, because that is a second refund rather than a repeat of the first.
///
/// ## Nothing else is written
///
/// One `INSERT`, into one table. The order row, its lines, its options, its customer link,
/// its kitchen slip and its original payment are all read-only here. `RefundPolicy` names
/// each of those as a decision rather than leaving it as code nobody wrote.
class SqliteRefundRepository implements RefundRepository {
  SqliteRefundRepository({required this._database});

  /// Tables a refund touches, woken once it commits.
  ///
  /// One table, because a refund writes one row. `payments` is deliberately absent: the
  /// tender is read and never written, so nothing watching it has anything new to see.
  static const List<String> _tables = <String>[SqliteTables.refunds];

  /// The status a tender must carry for its money to be refundable, and the status a
  /// committed refund is written at. Named once so the read and the write cannot drift.
  static final String _settledStatus = RefundPolicy.settledStatus.name;

  final SqliteDatabase _database;

  Database get _db => _database.database;

  // ----------------------------------------------------------------- reading ---

  @override
  Future<Result<RefundableBill?>> loadRefundable(String orderId) {
    return SqliteErrorMapper.guard<RefundableBill?>(() async {
      final List<Map<String, Object?>> orderRows = await _db.query(
        SqliteTables.orders,
        columns: <String>['status', 'orderNumber', 'totalAmountPaise'],
        where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
        whereArgs: <Object?>[orderId],
        limit: 1,
      );
      if (orderRows.isEmpty) {
        // Not a failure. A bill that is not on this terminal is a different thing to tell
        // the cashier than a storage fault, so the absence is returned as one.
        return null;
      }

      final List<Refund> written = await _refundsFor(_db, orderId);
      final List<_SettledTender> tenders = await _settledTendersFor(
        _db,
        orderId,
      );

      return _refundableFrom(
        orderId: orderId,
        orderRow: orderRows.first,
        written: written,
        tenders: tenders,
      );
    }, context: 'read what this bill can refund');
  }

  @override
  Future<Result<List<Refund>>> loadForOrder(String orderId) {
    return SqliteErrorMapper.guard<List<Refund>>(
      () => _refundsFor(_db, orderId),
      context: 'load the refunds',
    );
  }

  // ----------------------------------------------------------------- writing ---

  @override
  Future<Result<Refund>> refund(RefundRequest request) {
    return SqliteErrorMapper.guard<Refund>(() async {
      // Refused before the transaction opens, so a request that could never be honoured
      // writes nothing at all. It also cannot be checked inside the transaction: a guard
      // that returns without touching the database would deadlock it. See
      // [SqliteCheckoutRepository.settle].
      _reject(request);

      // Assigned inside the transaction and read after it commits, so what is returned is
      // what was written rather than what was intended.
      late String committedId;

      await _db.transaction((Transaction txn) async {
        final _RefundGuard guard = await _guard(txn, request);

        if (guard.repeatOfThisRequest != null) {
          // The same request, arriving again. Its row is already on disk, so the money has
          // already gone back exactly once. Nothing is written and the existing reversal is
          // reported as the outcome.
          committedId = guard.repeatOfThisRequest!.id;
          return;
        }

        final Refund reversal = Refund(
          id: request.id,
          orderId: request.orderId,
          // The tender the money goes back against, read in this transaction.
          paymentId: guard.tender.id,
          orderNumberSnapshot: guard.orderNumber,
          // Back the way it came in.
          paymentMethod: guard.tender.paymentMethod,
          amount: guard.refundable,
          reason: request.reason,
          status: RefundPolicy.completedRefundStatus,
          createdAt: request.requestedAt,
          updatedAt: request.requestedAt,
        );

        // Upsert on `id`, like every other write in this application. A repeat of this
        // request rewrites its own row rather than adding a second, and a collision on the
        // unique `orderId` index raises a constraint error instead of replacing the
        // reversal that holds it.
        await SqliteUpsert.run(txn, SqliteTables.refunds, reversal.toMap());

        committedId = reversal.id;
      });

      // After the commit, never inside it: a watcher that read the table mid transaction
      // would see a refund that might still roll back.
      _database.notifyTablesChanged(_tables);

      final List<Map<String, Object?>> rows = await _db.query(
        SqliteTables.refunds,
        where: '${SyncColumns.id} = ?',
        whereArgs: <Object?>[committedId],
        limit: 1,
      );
      if (rows.isEmpty) {
        // Cannot happen: the row was written or found inside a committed transaction.
        // Guarded so a caller never unwraps a null.
        throw StateError('The refund disappeared after being recorded.');
      }
      return Refund.fromRow(rows.first);
    }, context: 'refund this bill');
  }

  // --------------------------------------------------------------- internals ---

  /// Refuses a request the schema cannot refuse for us, before anything is written.
  ///
  /// Thrown rather than returned because this runs inside [SqliteErrorMapper.guard], which
  /// turns an [ArgumentError] into a `ValidationFailure` carrying the message. That keeps
  /// one exit path for every way a refund can fail, so the caller handles a meaningless
  /// request and a locked database the same way.
  static void _reject(RefundRequest request) {
    if (!request.hasAmount) {
      throw ArgumentError.value(
        request.amount.toDecimalString(),
        'amount',
        'A refund has to be for more than nothing.',
      );
    }
  }

  /// Re-decides the whole refund inside [txn], throwing the operator's refusal if it fails.
  ///
  /// Every value the write depends on comes from here, so the state the refund is checked
  /// against is the state it is applied to.
  Future<_RefundGuard> _guard(Transaction txn, RefundRequest request) async {
    final List<Map<String, Object?>> orderRows = await txn.query(
      SqliteTables.orders,
      columns: <String>['status', 'orderNumber'],
      where: '${SyncColumns.id} = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[request.orderId],
      limit: 1,
    );
    if (orderRows.isEmpty) {
      throw ArgumentError.value(
        request.orderId,
        'orderId',
        'That bill is no longer on this terminal.',
      );
    }

    final String orderNumber = orderRows.first.requireString('orderNumber');
    final OrderStatus status = orderRows.first.requireEnum<OrderStatus>(
      'status',
      OrderStatus.values,
      // A status written by a newer build reads as cancelled rather than as settled, so a
      // bill this build cannot account for is refused rather than quietly refunded.
      fallback: OrderStatus.cancelled,
    );

    final String? statusRefusal = RefundPolicy.refusalReason(status);
    if (statusRefusal != null) {
      throw ArgumentError.value(request.orderId, 'orderId', statusRefusal);
    }

    final List<Refund> written = await _refundsFor(txn, request.orderId);

    // A repeat of this very request. Recognised before the "already refunded" refusal,
    // because a retry is not a second refund.
    for (final Refund existing in written) {
      if (existing.id == request.id) {
        return _RefundGuard.repeat(existing);
      }
    }

    if (written.isNotEmpty) {
      final Money already = Money.sum(
        written.map((Refund refund) => refund.amount),
      );
      throw ArgumentError.value(
        request.orderId,
        'orderId',
        'This bill has already been refunded in full '
            '(${already.toDecimalString()} on bill $orderNumber).',
      );
    }

    final List<_SettledTender> tenders = await _settledTendersFor(
      txn,
      request.orderId,
    );
    if (tenders.isEmpty) {
      throw ArgumentError.value(
        request.orderId,
        'orderId',
        'No settled payment is recorded against bill $orderNumber, so there '
            'is nothing to refund.',
      );
    }
    if (tenders.length > 1 && !RefundPolicy.supportsSplitTender) {
      throw ArgumentError.value(
        tenders.length,
        'payments',
        'Bill $orderNumber was settled with more than one payment. Refunding '
            'a split payment is not supported on this terminal.',
      );
    }

    final _SettledTender tender = tenders.first;
    final Money refundable = tender.amount;
    if (!refundable.isPositive) {
      throw ArgumentError.value(
        refundable.toDecimalString(),
        'amount',
        'Nothing was collected on bill $orderNumber, so there is nothing to '
            'refund.',
      );
    }

    // The persisted figure decides, not the one the screen was showing. A request for more
    // than was taken is refused outright; a request for less is refused too, because this
    // step refunds whole bills and silently rounding the cashier's intent up to the full
    // amount would move money they did not ask to move.
    if (request.amount > refundable) {
      throw ArgumentError.value(
        request.amount.toDecimalString(),
        'amount',
        'Only ${refundable.toDecimalString()} was collected on bill '
            '$orderNumber, so ${request.amount.toDecimalString()} cannot be '
            'refunded.',
      );
    }
    if (request.amount < refundable) {
      throw ArgumentError.value(
        request.amount.toDecimalString(),
        'amount',
        'This terminal refunds a whole bill. Bill $orderNumber has '
            '${refundable.toDecimalString()} to refund, not '
            '${request.amount.toDecimalString()}.',
      );
    }

    return _RefundGuard.write(
      orderNumber: orderNumber,
      tender: tender,
      refundable: refundable,
    );
  }

  /// Every reversal against [orderId], oldest first.
  ///
  /// Takes a [DatabaseExecutor] so the caller can pass its own transaction, which is what
  /// makes the guard read and the write see the same state.
  static Future<List<Refund>> _refundsFor(
    DatabaseExecutor db,
    String orderId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.refunds,
      where: 'orderId = ? AND ${SyncColumns.isDeleted} = 0',
      whereArgs: <Object?>[orderId],
      // The rowid tiebreak matters for the same reason it does on bill lines: rows written
      // in the same millisecond share a createdAt, and ids carry random entropy.
      orderBy: '${SyncColumns.createdAt} ASC, rowid ASC',
    );
    return rows.map(Refund.fromRow).toList(growable: false);
  }

  /// The bill's settled tenders, earliest first.
  static Future<List<_SettledTender>> _settledTendersFor(
    DatabaseExecutor db,
    String orderId,
  ) async {
    final List<Map<String, Object?>> rows = await db.query(
      SqliteTables.payments,
      columns: <String>[SyncColumns.id, 'paymentMethod', 'amountPaise'],
      where: 'orderId = ? AND ${SyncColumns.isDeleted} = 0 AND status = ?',
      whereArgs: <Object?>[orderId, _settledStatus],
      orderBy: '${SyncColumns.createdAt} ASC, rowid ASC',
    );

    return rows
        .map(
          (Map<String, Object?> row) => _SettledTender(
            id: row.requireString(SyncColumns.id),
            paymentMethod: row.requireEnum<PaymentMethod>(
              'paymentMethod',
              PaymentMethod.values,
              fallback: PaymentMethod.other,
            ),
            // Straight out of an INTEGER column. No parsing, no rounding.
            amount: Money.fromPaise(row.requireInt('amountPaise')),
          ),
        )
        .toList(growable: false);
  }

  /// Assembles the read model from rows already fetched.
  static RefundableBill _refundableFrom({
    required String orderId,
    required Map<String, Object?> orderRow,
    required List<Refund> written,
    required List<_SettledTender> tenders,
  }) {
    final List<Refund> settled = written
        .where((Refund refund) => refund.isSettled)
        .toList(growable: false);

    return RefundableBill(
      orderId: orderId,
      orderNumber: orderRow.requireString('orderNumber'),
      orderStatus: orderRow.requireEnum<OrderStatus>(
        'status',
        OrderStatus.values,
        fallback: OrderStatus.cancelled,
      ),
      billTotal: Money.fromPaise(orderRow.requireInt('totalAmountPaise')),
      paidAmount: Money.sum(
        tenders.map((_SettledTender tender) => tender.amount),
      ),
      refundedAmount: Money.sum(settled.map((Refund refund) => refund.amount)),
      settledTenderCount: tenders.length,
      paymentMethod: tenders.isEmpty ? null : tenders.first.paymentMethod,
      existingRefund: written.isEmpty ? null : written.first,
    );
  }
}

/// A tender the bill actually collected, reduced to what a refund needs from it.
class _SettledTender {
  const _SettledTender({
    required this.id,
    required this.paymentMethod,
    required this.amount,
  });

  final String id;
  final PaymentMethod paymentMethod;
  final Money amount;
}

/// The outcome of re-deciding a refund inside the transaction.
///
/// Either "this request has already been honoured, here it is" or "go ahead, against this
/// tender, for this amount". A refusal never reaches here; it is thrown.
class _RefundGuard {
  const _RefundGuard._({
    this.repeatOfThisRequest,
    this._tender,
    this._orderNumber,
    this._refundable,
  });

  /// A repeat of the same request, whose reversal is already on disk.
  factory _RefundGuard.repeat(Refund existing) =>
      _RefundGuard._(repeatOfThisRequest: existing);

  /// A refund that should be written.
  factory _RefundGuard.write({
    required String orderNumber,
    required _SettledTender tender,
    required Money refundable,
  }) => _RefundGuard._(
    orderNumber: orderNumber,
    tender: tender,
    refundable: refundable,
  );

  final Refund? repeatOfThisRequest;
  final _SettledTender? _tender;
  final String? _orderNumber;
  final Money? _refundable;

  String get orderNumber => _orderNumber!;

  _SettledTender get tender => _tender!;

  Money get refundable => _refundable!;
}
