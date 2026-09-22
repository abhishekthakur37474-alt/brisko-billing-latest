import '../../../../core/data/local/sqlite/row.dart';
import '../../../../core/data/local/sqlite/sqlite_tables.dart';
import '../../../../core/data/sync/sync_state.dart';
import '../../../../core/data/sync/syncable_entity.dart';
import '../../../../core/money/money.dart';

/// A recorded business expense.
class Expense implements SyncableEntity {
  const Expense({
    required this.id,
    required this.name,
    required this.amount,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
    this.syncState = SyncState.pending,
  });

  factory Expense.fromRow(Map<String, Object?> row) {
    return Expense(
      id: row.requireString(SyncColumns.id),
      name: row.requireString('name'),
      amount: Money.fromPaise(row.requireInt('amountPaise')),
      note: row.optionalString('note'),
      createdAt: row.requireDateTime(SyncColumns.createdAt),
      updatedAt: row.requireDateTime(SyncColumns.updatedAt),
      isDeleted: row.requireBool(SyncColumns.isDeleted),
      syncState: row.requireSyncState(SyncColumns.syncState),
    );
  }

  @override
  final String id;

  /// What the expense was for, e.g., "Vegetables", "Cleaning supplies".
  final String name;

  /// The cost of the expense.
  final Money amount;

  /// Optional detail.
  final String? note;

  final DateTime createdAt;

  @override
  final DateTime updatedAt;

  @override
  final bool isDeleted;

  @override
  final SyncState syncState;

  Expense copyWith({
    String? id,
    String? name,
    Money? amount,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncState? syncState,
  }) {
    return Expense(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'amountPaise': amount.paise,
      'note': note,
      'createdAt': createdAt.toUtc().millisecondsSinceEpoch,
      'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
      'isDeleted': isDeleted ? 1 : 0,
      'syncState': syncState.name,
    };
  }
}
