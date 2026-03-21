import 'package:test/test.dart';
import 'package:dynos_sync/dynos_sync.dart';
import 'package:dynos_sync/src/adapters/drift_local_store.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart';

// ─── 1. Security Test (SQL Injection Escaping) ──────────────────────────────

class MockDatabase extends GeneratedDatabase {
  MockDatabase() : super(NativeDatabase.memory());
  
  List<String> executedStatements = [];
  
  @override
  Future<void> customStatement(String statement, [List<dynamic>? variables]) async {
    executedStatements.add(statement);
    // Suppress error as tables don't actually exist
    try { await super.customStatement(statement, variables); } catch (_) {}
  }
  
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [];
}

void main() {
  group('Security Suite (SQL Injection)', () {
    test('DriftLocalStore escapes table and column names correctly', () async {
      final db = MockDatabase();
      final store = DriftLocalStore(db);
      
      final maliciousTable = 'tasks"); DROP TABLE users; --';
      final maliciousColumn = 'title", "malicious_col") VALUES ("hi", "ho"); --';
      
      await store.upsert(
        maliciousTable, 
        '1', 
        {maliciousColumn: 'value'}
      );
      
      final stmt = db.executedStatements.first;
      
      // Verify escaping by checking for double quotes (SQLite standard)
      // This is the proof that the malicious content is treated as a literal string
      expect(stmt, contains('"${maliciousTable.replaceAll('"', '""')}"'));
      expect(stmt, contains('"${maliciousColumn.replaceAll('"', '""')}"'));
      
      // Verify that after escaping, it's just one statement—no new injection starts outside quotes
      expect(stmt, startsWith('INSERT OR REPLACE INTO "tasks"'));
    });
  });

  group('Speed Suite (N+1 Botttleneck)', () {
    test('SyncEngine fetches pending IDs only once per table pull', () async {
      final local = MockLocalStore();
      final remote = ConstantRemoteStore();
      final queue = TrackingQueueStore();
      final timestamps = InMemoryTimestampStore();
      
      final engine = SyncEngine(
        local: local,
        remote: remote,
        queue: queue,
        timestamps: timestamps,
        tables: ['tasks'],
      );
      
      // Pull 100 rows
      await engine.pullAll();
      
      // getPendingIds should only be called once, even if 100 rows pulled
      expect(queue.getPendingIdsCallCount, 1);
    });
  });

  group('Persistence Suite (Atomic Order)', () {
    test('write() enqueues before attempting local upsert', () async {
      final queue = TrackingQueueStore();
      final local = FailingLocalStore(); // This fails the upsert
      
      final engine = SyncEngine(
        local: local,
        remote: SilentRemoteStore(), // To avoid best-effort push interference
        queue: queue,
        timestamps: InMemoryTimestampStore(),
        tables: ['tasks'],
      );
      
      // Attempt write. Local fails, but check if enqueue was called.
      try {
        await engine.write('tasks', '1', {'name': 'test'});
      } catch (_) {}
      
      // In our atomic reversal logic, we enqueue FIRST. 
      // If local.upsert fails, the entry is already in the queue.
      expect(queue.enqueueCount, 1);
    });
  });
}

// ─── Mock HELPERS ────────────────────────────────────────────────────────────

class MockLocalStore implements LocalStore {
  @override Future<void> upsert(String t, String id, Map<String, dynamic> d) async {}
  @override Future<void> delete(String t, String id) async {}
}

class FailingLocalStore implements LocalStore {
  @override
  Future<void> upsert(String t, String id, Map<String, dynamic> d) async {
    throw Exception('Local Database Write Failure');
  }
  @override Future<void> delete(String t, String id) async {}
}

class ConstantRemoteStore implements RemoteStore {
  @override
  Future<List<Map<String, dynamic>>> pullSince(String t, DateTime s) async {
    return List.generate(100, (i) => {'id': '$i', 'title': 'Task $i'});
  }
  @override Future<void> push(String t, String id, SyncOperation op, Map<String, dynamic> d) async {}
  @override Future<void> pushBatch(List<SyncEntry> e) async {}
  @override Future<Map<String, DateTime>> getRemoteTimestamps() async => {'tasks': DateTime.now()};
}

class SilentRemoteStore implements RemoteStore {
  @override Future<void> push(String t, String id, SyncOperation op, Map<String, dynamic> d) async {
    throw Exception('Silent push failure');
  }
  @override Future<void> pushBatch(List<SyncEntry> e) async {}
  @override Future<List<Map<String, dynamic>>> pullSince(String t, DateTime s) async => [];
  @override Future<Map<String, DateTime>> getRemoteTimestamps() async => {};
}

class TrackingQueueStore implements QueueStore {
  int getPendingIdsCallCount = 0;
  int enqueueCount = 0;

  @override
  Future<void> enqueue(SyncEntry entry) async {
    enqueueCount++;
  }

  @override
  Future<Set<String>> getPendingIds(String table) async {
    getPendingIdsCallCount++;
    return {};
  }

  @override Future<List<SyncEntry>> getPending({int limit = 50, DateTime? now}) async => [];
  @override Future<List<SyncEntry>> getPendingEntries(String t, String id) async => [];
  @override Future<bool> hasPending(String t, String id) async => false;
  @override Future<void> markSynced(String id) async {}
  @override Future<void> incrementRetry(String id) async {}
  @override Future<void> setNextRetryAt(String id, DateTime nextRetryAt) async {}
  @override Future<void> deleteEntry(String id) async {}
  @override Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {}
  @override Future<void> clearAll() async {}
}
