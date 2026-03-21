import 'package:drift/drift.dart';

/// Raw SQL to create the sync timestamps table.
///
/// Use this in your Drift migration if adding the [DynosSyncTimestampsTable]
/// class to `@DriftDatabase(tables: [...])` doesn't work cross-package:
///
/// ```dart
/// await customStatement(kSyncTimestampsCreateSql);
/// ```
const kSyncTimestampsCreateSql = '''
  CREATE TABLE IF NOT EXISTS dynos_sync_timestamps (
    table_name TEXT NOT NULL PRIMARY KEY,
    last_synced_at INTEGER NOT NULL
  )
''';

/// Drift table for storing per-table sync timestamps.
///
/// Add this to your `@DriftDatabase(tables: [...])` annotation
/// alongside [DynosSyncQueueTable].
///
/// **Note:** Drift's code generator may not resolve this table when imported
/// from an external package. If you see "not understood by drift" warnings,
/// use [kSyncTimestampsCreateSql] in your migration instead.
class DynosSyncTimestampsTable extends Table {
  @override
  String get tableName => 'dynos_sync_timestamps';

  TextColumn get tableName_ => text().named('table_name')();
  DateTimeColumn get lastSyncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {tableName_};
}
