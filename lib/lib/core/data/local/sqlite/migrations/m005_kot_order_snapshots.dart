import 'package:sqflite/sqflite.dart';

import '../sqlite_tables.dart';
import 'migration.dart';

/// Makes a kitchen slip readable on its own, and gives its lines their options.
///
/// ## What was missing
///
/// Version 1 recorded a slip as an order id, a slip number and a status. That is
/// enough to know a slip exists, but not enough to hand to a kitchen: the order
/// number the counter shouts out and the order type that decides how the food is
/// plated both lived only on the order, and a slip line could not say that the pizza
/// wanted extra cheese.
///
/// So the order number, the order type and the order's note are copied onto the slip
/// as snapshots, and `kot_item_options` is added to hold the customisations. The
/// board now reads slips without touching the orders table, and never touches the
/// menu.
///
/// ## The defaults on the added columns
///
/// SQLite requires a non-null default when adding a `NOT NULL` column, so the two
/// text columns are added with an empty-string default and then filled from the
/// parent order in the same migration. Every existing row has a parent, because
/// `kot_records.orderId` is a foreign key into `orders`, so no row is left holding
/// the placeholder. The default exists only to satisfy the `ALTER TABLE` and is
/// never written by the application, which always supplies both values.
class M005KotOrderSnapshots implements Migration {
  const M005KotOrderSnapshots();

  @override
  int get version => 5;

  @override
  String get description => 'KOT order snapshots and slip line options';

  @override
  Future<void> migrate(DatabaseExecutor db) async {
    for (final String statement in _statements) {
      await db.execute(statement);
    }
  }

  static const List<String> _statements = <String>[
    '''
    ALTER TABLE ${SqliteTables.kotRecords}
      ADD COLUMN orderNumber TEXT NOT NULL DEFAULT ''
    ''',
    '''
    ALTER TABLE ${SqliteTables.kotRecords}
      ADD COLUMN orderType TEXT NOT NULL DEFAULT ''
    ''',
    '''
    ALTER TABLE ${SqliteTables.kotRecords}
      ADD COLUMN notes TEXT
    ''',

    // Real values for slips that already exist. Correlated on the foreign key, so
    // each slip takes the number and type of the bill it was raised against rather
    // than an invented one.
    '''
    UPDATE ${SqliteTables.kotRecords}
    SET
      orderNumber = COALESCE(
        (
          SELECT ${SqliteTables.orders}.orderNumber
          FROM ${SqliteTables.orders}
          WHERE ${SqliteTables.orders}.id = ${SqliteTables.kotRecords}.orderId
        ),
        orderNumber
      ),
      orderType = COALESCE(
        (
          SELECT ${SqliteTables.orders}.orderType
          FROM ${SqliteTables.orders}
          WHERE ${SqliteTables.orders}.id = ${SqliteTables.kotRecords}.orderId
        ),
        orderType
      ),
      notes = (
        SELECT ${SqliteTables.orders}.notes
        FROM ${SqliteTables.orders}
        WHERE ${SqliteTables.orders}.id = ${SqliteTables.kotRecords}.orderId
      )
    ''',

    // Drives the kitchen board, which reads the three active states oldest first.
    '''
    CREATE INDEX idx_kot_records_status
      ON ${SqliteTables.kotRecords} (status, isDeleted, createdAt)
    ''',

    // optionNameSnapshot is a copy taken at the moment of sale, like every other
    // snapshot on a slip. No price column: the kitchen is told what to put on the
    // pizza, and what it cost is recorded against the bill line instead.
    '''
    CREATE TABLE ${SqliteTables.kotItemOptions} (
      ${SyncColumns.definition},
      kotItemId TEXT NOT NULL,
      optionNameSnapshot TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (kotItemId) REFERENCES ${SqliteTables.kotItems} (id)
        ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE INDEX idx_kot_item_options_item
      ON ${SqliteTables.kotItemOptions} (kotItemId, isDeleted)
    ''',
  ];
}
