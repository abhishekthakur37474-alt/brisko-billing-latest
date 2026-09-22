import 'package:sqflite/sqflite.dart';

import 'm002_seed_menu.dart';
import 'migration.dart';

/// Loads the products, size variants and options from the supplied menu.
///
/// ## Why this is a separate version
///
/// Version 2 shipped when only the category names were known, so it seeded twelve
/// categories and nothing else. A terminal that already ran version 2 will never run
/// it again, so extending version 2 in place would have delivered the products to
/// fresh installs only, and left any existing terminal with an empty menu. Editing a
/// migration that has already run is the one thing migrations must not do.
///
/// This version therefore re-invokes the same seed routine. That is safe precisely
/// because the seed is idempotent: every insert is `INSERT OR IGNORE` against a
/// primary key derived from a fixed slug, so the twelve categories already present
/// are left alone and only the new product, variant and option rows are added.
///
/// A fresh install runs the seed twice, at version 2 and again here, and ends up with
/// exactly the same rows as an upgraded install. The seed tests assert that.
class M003SeedMenuProducts implements Migration {
  const M003SeedMenuProducts();

  @override
  int get version => 3;

  @override
  String get description =>
      'Seed menu products, size variants and options from the supplied menu';

  @override
  Future<void> migrate(DatabaseExecutor db) => M002SeedMenu.seed(db);
}
