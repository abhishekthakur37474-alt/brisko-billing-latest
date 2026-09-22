import '../../../../core/utils/entity_id.dart';
import '../../../orders/domain/models/order.dart';
import '../../../orders/domain/models/order_item.dart';
import '../../../orders/domain/models/order_item_option.dart';
import 'kot_item.dart';
import 'kot_item_option.dart';
import 'kot_record.dart';
import 'kot_status.dart';

/// The rows of a kitchen slip, built and ready to be written.
///
/// ## Built from the order, never from the menu
///
/// [KitchenTicketDraft.fromOrder] takes the order rows that are about to be, or have
/// just been, persisted and copies their snapshots across. It has no access to a
/// menu repository, so it is structurally incapable of reconstructing what the
/// kitchen should cook from today's menu: the only names, sizes and options it can
/// write are the ones that were sold.
///
/// That is what keeps a slip honest after the menu moves on. Rename `Cheese Pizza`
/// or reprice a Medium next week and this slip still says what the customer ordered,
/// because the string was copied, not looked up.
///
/// ## Ids
///
/// Every id is allocated here, in one pass. Pass [kotId] to fix the slip's identity
/// from outside, which is what settlement does: the id is decided when the bill is
/// built, so a retry of the same bill can only ever write the same slip row.
class KitchenTicketDraft {
  KitchenTicketDraft({
    required this.record,
    required List<KotItem> items,
    required List<KotItemOption> itemOptions,
  }) : items = List<KotItem>.unmodifiable(items),
       itemOptions = List<KotItemOption>.unmodifiable(itemOptions);

  /// Copies [order] and its lines into a slip raised at [kotNumber].
  ///
  /// [items] and [itemOptions] are the order's own rows. Options are matched to
  /// their line by `orderItemId`, so an option belonging to another line cannot
  /// land on this one.
  ///
  /// [at] defaults to the order's own `createdAt`, which makes every row written by
  /// one settlement carry the same instant.
  factory KitchenTicketDraft.fromOrder({
    required Order order,
    required List<OrderItem> items,
    required List<OrderItemOption> itemOptions,
    required String kotNumber,
    String? kotId,
    DateTime? at,
  }) {
    final DateTime createdAt = (at ?? order.createdAt).toUtc();
    final String id = kotId ?? EntityId.generate(prefix: 'kot');

    final List<KotItem> slipLines = <KotItem>[];
    final List<KotItemOption> slipLineOptions = <KotItemOption>[];

    for (final OrderItem item in items) {
      final String kotItemId = EntityId.generate(prefix: 'kit');

      slipLines.add(
        KotItem(
          id: kotItemId,
          kotId: id,
          orderItemId: item.id,
          // Copied from the bill line, which itself copied them from the menu at
          // the moment of sale. Two copies deep from the menu, and no lookup.
          itemNameSnapshot: item.itemNameSnapshot,
          variantNameSnapshot: item.variantNameSnapshot,
          quantity: item.quantity,
          notes: item.notes,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );

      for (final OrderItemOption option in itemOptions) {
        if (option.orderItemId != item.id) {
          continue;
        }
        slipLineOptions.add(
          KotItemOption(
            id: EntityId.generate(prefix: 'kio'),
            kotItemId: kotItemId,
            optionNameSnapshot: option.optionNameSnapshot,
            quantity: option.quantity,
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
      }
    }

    return KitchenTicketDraft(
      record: KotRecord(
        id: id,
        orderId: order.id,
        orderNumber: order.orderNumber,
        kotNumber: kotNumber,
        orderType: order.orderType,
        // A new slip is always work the kitchen has not started.
        status: KotStatus.pending,
        notes: order.notes,
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
      items: slipLines,
      itemOptions: slipLineOptions,
    );
  }

  final KotRecord record;

  /// Slip lines, in bill order. Unmodifiable.
  final List<KotItem> items;

  /// Customisations on those lines. Unmodifiable.
  final List<KotItemOption> itemOptions;

  String get kotId => record.id;

  bool get hasLines => items.isNotEmpty;

  @override
  String toString() =>
      'KitchenTicketDraft(${record.kotNumber} for ${record.orderNumber}, '
      '${items.length} lines)';
}
