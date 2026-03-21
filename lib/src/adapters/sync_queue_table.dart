import 'package:drift/drift.dart';

/// Raw SQL to create the sync queue table.
///
/// Use this in your Drift migration if adding the [DynosSyncQueueTable]
/// class to `@DriftDatabase(tables: [...])` doesn't work cross-package:
///
/// ```dart
/// await customStatement(kSyncQueueCreateSql);
/// ```
const kSyncQueueCreateSql = '''
  CREATE TABLE IF NOT EXISTS dynos_sync_queue (
    id TEXT NOT NULL PRIMARY KEY,
    table_name TEXT NOT NULL,
    record_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    synced_at INTEGER,
    retry_count INTEGER NOT NULL DEFAULT 0
  )
''';

/// Drift table definition for the sync queue.
///
/// Add this to your `@DriftDatabase(tables: [...])` annotation.
///
/// **Note:** Drift's code generator may not resolve this table when imported
/// from an external package. If you see "not understood by drift" warnings,
/// use [kSyncQueueCreateSql] in your migration instead.
class DynosSyncQueueTable extends Table {
  @override
  String get tableName => 'dynos_sync_queue';

  TextColumn get id => text()();
  TextColumn get tableName_ => text().named('table_name')();
  TextColumn get recordId => text()();
  TextColumn get operation => text()();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get syncedAt => dateTime().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
