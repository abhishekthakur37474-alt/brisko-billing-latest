import '../../../orders/domain/models/order_type.dart';
import 'kot_item.dart';
import 'kot_item_option.dart';
import 'kot_record.dart';
import 'kot_status.dart';

/// A kitchen slip assembled from its stored rows: the header, its lines, and the
/// customisations on each line.
///
/// Exists so the kitchen board receives one object it can render. The alternative
/// would be a screen holding three lists and matching them up by id, which is
/// joining, and joining is the repository's job.
///
/// Every value in here is a snapshot written when the slip was raised. Nothing in
/// this file, or in anything that renders it, reads the menu.
class KitchenTicket {
  const KitchenTicket({required this.record, required this.lines});

  final KotRecord record;

  /// Slip lines in the sequence the cashier entered them.
  final List<KitchenTicketLine> lines;

  String get id => record.id;

  String get kotNumber => record.kotNumber;

  /// Number the customer was given, as recorded on the slip.
  String get orderNumber => record.orderNumber;

  OrderType get orderType => record.orderType;

  KotStatus get status => record.status;

  /// When the slip was raised, in UTC. Render it in local time.
  DateTime get createdAt => record.createdAt;

  String? get notes => record.notes;

  bool get hasNotes => record.notes != null && record.notes!.isNotEmpty;

  /// Portions the kitchen has to make across every line.
  int get totalQuantity => lines.fold<int>(
    0,
    (int running, KitchenTicketLine line) => running + line.quantity,
  );

  /// The state the board may move this slip to, or `null` when it is finished.
  KotStatus? get nextStep => record.status.nextStep;
}

/// One line of a kitchen slip with its customisations attached.
class KitchenTicketLine {
  const KitchenTicketLine({required this.item, required this.options});

  final KotItem item;

  final List<KotItemOption> options;

  /// Product and size as they were sold, for example `Cheese Pizza (Medium)`.
  String get displayName => item.displayName;

  int get quantity => item.quantity;

  /// Preparation instruction on this line, if any.
  String? get notes => item.notes;

  bool get hasOptions => options.isNotEmpty;

  /// Customisation names in the order they were added, for example
  /// `Extra Cheese, Thin Crust`.
  String get optionSummary => options
      .map((KotItemOption option) => option.optionNameSnapshot)
      .join(', ');
}
