import 'dart:convert';
import 'package:drift/drift.dart';
import '../queue_store.dart';
import '../sync_entry.dart';
import '../sync_operation.dart';

/// [QueueStore] implementation backed by a Drift [DynosSyncQueueTable].
///
/// Requires [DynosSyncQueueTable] to be registered in your Drift database.
class DriftQueueStore implements QueueStore {
  const DriftQueueStore(this._db);

  final GeneratedDatabase _db;

  @override
  Future<void> enqueue(SyncEntry entry) async {
    await _db.customStatement(
      'INSERT INTO dynos_sync_queue (id, table_name, record_id, operation, payload, created_at, retry_count) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        entry.id,
        entry.table,
        entry.recordId,
        entry.operation.name,
        jsonEncode(entry.payload),
        entry.createdAt.millisecondsSinceEpoch,
        entry.retryCount,
      ],
    );
  }

  @override
  Future<List<SyncEntry>> getPending({int limit = 50}) async {
    final rows = await _db.customSelect(
      'SELECT * FROM dynos_sync_queue WHERE synced_at IS NULL '
      'ORDER BY created_at ASC LIMIT ?',
      variables: [Variable.withInt(limit)],
    ).get();

    return rows.map(_mapRow).toList();
  }

  @override
  Future<bool> hasPending(String table, String id) async {
    final rows = await _db.customSelect(
      'SELECT COUNT(1) AS c FROM dynos_sync_queue '
      'WHERE table_name = ? AND record_id = ? AND synced_at IS NULL',
      variables: [Variable.withString(table), Variable.withString(id)],
    ).get();
    return rows.first.read<int>('c') > 0;
  }

  @override
  Future<Set<String>> getPendingIds(String table) async {
    final rows = await _db.customSelect(
      'SELECT record_id FROM dynos_sync_queue WHERE table_name = ? AND synced_at IS NULL',
      variables: [Variable.withString(table)],
    ).get();
    return rows.map((r) => r.read<String>('record_id')).toSet();
  }

  @override
  Future<void> markSynced(String id) async {
    await _db.customStatement(
      'UPDATE dynos_sync_queue SET synced_at = ? WHERE id = ?',
      [DateTime.now().toUtc().millisecondsSinceEpoch, id],
    );
  }

  @override
  Future<void> incrementRetry(String id) async {
    await _db.customStatement(
      'UPDATE dynos_sync_queue SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  @override
  Future<void> deleteEntry(String id) async {
    await _db.customStatement(
      'DELETE FROM dynos_sync_queue WHERE id = ?',
      [id],
    );
  }

  @override
  Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {
    final cutoff = DateTime.now().toUtc().subtract(retention).millisecondsSinceEpoch;
    await _db.customStatement(
      'DELETE FROM dynos_sync_queue WHERE synced_at IS NOT NULL AND synced_at < ?',
      [cutoff],
    );
  }

  @override
  Future<void> clearAll() async {
    await _db.customStatement('DELETE FROM dynos_sync_queue');
  }

  SyncEntry _mapRow(QueryRow row) {
    return SyncEntry(
      id: row.read<String>('id'),
      table: row.read<String>('table_name'),
      recordId: row.read<String>('record_id'),
      operation: SyncOperation.values.byName(row.read<String>('operation')),
      payload: jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('created_at'),
        isUtc: true,
      ),
      syncedAt: row.readNullable<int>('synced_at') != null
          ? DateTime.fromMillisecondsSinceEpoch(
              row.read<int>('synced_at'),
              isUtc: true,
            )
          : null,
      retryCount: row.read<int>('retry_count'),
    );
  }
}
