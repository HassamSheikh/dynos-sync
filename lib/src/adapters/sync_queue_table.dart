import 'package:drift/drift.dart';

/// Drift table definition for the sync queue.
///
/// Add this to your `@DriftDatabase(tables: [...])` annotation.
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
