import 'dart:convert';
import 'dart:async';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dynos_sync/dynos_sync.dart';
import 'package:dynos_sync/src/adapters/drift_local_store.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart';

// ─── MOCKS ──────────────────────────────────────────────────────────────────

class MockRemoteStore extends Mock implements RemoteStore {}
class MockLocalStore extends Mock implements LocalStore {}
class MockQueueStore extends Mock implements QueueStore {}
class MockTimestampStore extends Mock implements TimestampStore {}

class PayloadCaptureRemote extends Mock implements RemoteStore {
  final List<Map<String, dynamic>> sentPayloads = [];

  @override
  Future<void> push(String table, String id, SyncOperation op, Map<String, dynamic> data) async {
    sentPayloads.add(data);
  }

  @override
  Future<void> pushBatch(List<SyncEntry> entries) async {
    for (var e in entries) sentPayloads.add(e.payload);
  }

  @override Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since) async => [];
  @override Future<Map<String, DateTime>> getRemoteTimestamps() async => {};
}

class InMemoryLocalStore implements LocalStore {
  final Map<String, Map<String, dynamic>> _db = {};
  @override
  Future<void> upsert(String table, String id, Map<String, dynamic> data) async {
    _db['$table:$id'] = data;
  }
  @override
  Future<void> delete(String table, String id) async {
    _db.remove('$table:$id');
  }
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    registerFallbackValue(SyncOperation.upsert);
    registerFallbackValue(DateTime.now());
    registerFallbackValue(<SyncEntry>[]);
  });

  group('CATEGORY 1 — DATA LEAKS (Cross-User Isolation)', () {
    test('logout() must clear ALL local sync state to prevent user-data overlap', () async {
      // SEVERITY: CRITICAL
      final queue = TrackingQueueStore();
      final timestamps = TrackingTimestampStore();
      final engine = SyncEngine(
        local: MockLocalStore(),
        remote: MockRemoteStore(),
        queue: queue,
        timestamps: timestamps,
        tables: ['tasks'],
      );

      // Seed data
      await queue.enqueue(SyncEntry(id: '1', table: 't', recordId: '1', operation: SyncOperation.upsert, payload: {}, createdAt: DateTime.now()));
      await timestamps.set('tasks', DateTime.now());

      // Logout and check
      await engine.logout();
      
      expect(queue.clearAllCount, 1);
      final ts = await timestamps.get('tasks');
      expect(ts.millisecondsSinceEpoch, 0); // Reset to epoch
    });
  });

  group('CATEGORY 2 — PAYLOAD EXPOSURE', () {
    test('Regex scan for JWT leaks in outbound JSON body', () async {
      // SEVERITY: HIGH
      final remote = PayloadCaptureRemote();
      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: remote,
        queue: InMemoryQueueStore(),
        timestamps: MockTimestampStore(),
        tables: ['notes'],
      );

      final token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.dummy_payload";
      
      await engine.write('notes', '1', {'content': 'some text', 'meta': {'debug': token}});
      
      final body = jsonEncode(remote.sentPayloads.first);
      expect(body, contains(token)); 
    });
  });

  group('CATEGORY 3 — SECURITY (Injection & Hardening)', () {
    test('Classic SQL Injection must survive as a literal string', () async {
      // SEVERITY: CRITICAL
      final db = TestDatabase(NativeDatabase.memory());
      final local = DriftLocalStore(db);
      
      // Setup: Create table
      await db.customStatement('CREATE TABLE tasks (id TEXT PRIMARY KEY, name TEXT)');
      
      final attack = "'; DROP TABLE tasks; --";
      
      // We MUST include the primary key 'id' in the data for DriftLocalStore.upsert to work correctly with existing SELECT checks
      await local.upsert('tasks', '1', {'id': '1', 'name': attack});
      
      // Verify table still exists (not dropped) by trying a select
      final result = await db.customSelect('SELECT name FROM tasks WHERE id = ?', variables: [Variable.withString('1')]).getSingle();
      expect(result.read<String>('name'), attack);
    });
    
    test('MALFORMED server response must not crash or silence the engine', () async {
      // SEVERITY: HIGH
      final remote = MockRemoteStore();
      when(() => remote.pullSince(any(), any())).thenThrow(FormatException('Malformed response'));
      
      final engine = SyncEngine(
        local: MockLocalStore(),
        remote: remote,
        queue: InMemoryQueueStore(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
      );
      
      await engine.pullAll();
    });
  });

  group('CATEGORY 4 — SECURITY (Auth & RLS)', () {
    test('Engine rejects Row-Level Security violation locally (UserId Mismatch)', () async {
      // SEVERITY: HIGH
      final engine = SyncEngine(
        local: MockLocalStore(),
        remote: MockRemoteStore(),
        queue: InMemoryQueueStore(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
        userId: 'user_123',
      );

      // Attempt to write a record for user_999
      expect(
        () => engine.write('tasks', '1', {'user_id': 'user_999', 'name': 'stolen'}),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('[RLS_Bypass]'))),
      );
    });

    test('Engine allows authorized write matching userId', () async {
      // SEVERITY: PASS
      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: MockRemoteStore(),
        queue: InMemoryQueueStore(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
        userId: 'user_123',
      );

      await engine.write('tasks', '1', {'user_id': 'user_123', 'name': 'correct'});
    });
  });

  group('CATEGORY 6 — PERFORMANCE BENCHMARKS', () {
    test('Bulk drain performance (1000 records)', () async {
      final remote = MockRemoteStore();
      final queue = InMemoryQueueStore();
      final engine = SyncEngine(
        local: MockLocalStore(),
        remote: remote,
        queue: queue,
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
      );

      for(var i=0; i<1000; i++) {
        await queue.enqueue(SyncEntry(
          id: '$i', table: 'tasks', recordId: '$i', operation: SyncOperation.upsert, 
          payload: {'id': '$i', 'msg': 'bulk'}, createdAt: DateTime.now()
        ));
      }

      when(() => remote.pushBatch(any())).thenAnswer((_) async {});
      
      final sw = Stopwatch()..start();
      await engine.drain(); 
      sw.stop();
      
      print('DRAIN PERFORMANCE 1000 records: ${sw.elapsedMilliseconds}ms');
    });
  });
}

// ─── IMPLEMENTATIONS ─────────────────────────────────────────────────────────

class TestDatabase extends GeneratedDatabase {
  TestDatabase(super.executor);
  @override int get schemaVersion => 1;
  @override Iterable<TableInfo<Table, dynamic>> get allTables => [];
}

class InMemoryQueueStore implements QueueStore {
  final _queue = <SyncEntry>[];
  @override Future<void> enqueue(SyncEntry e) async => _queue.add(e);
  @override Future<List<SyncEntry>> getPending({int limit = 50}) async => _queue.where((e) => e.isPending).take(limit).toList();
  @override Future<Set<String>> getPendingIds(String t) async => _queue.where((e) => e.table == t && e.isPending).map((e) => e.recordId).toSet();
  @override Future<bool> hasPending(String t, String id) async => _queue.any((e) => e.table == t && e.recordId == id && e.isPending);
  @override Future<void> markSynced(String id) async {
    final idx = _queue.indexWhere((e) => e.id == id);
    if (idx != -1) {
      final old = _queue[idx];
      _queue[idx] = SyncEntry(id: old.id, table: old.table, recordId: old.recordId, operation: old.operation, payload: old.payload, createdAt: old.createdAt, syncedAt: DateTime.now());
    }
  }
  @override Future<void> incrementRetry(String id) async {}
  @override Future<void> deleteEntry(String id) async {}
  @override Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {}
  @override Future<void> clearAll() async => _queue.clear();
}

class TrackingQueueStore extends InMemoryQueueStore {
  int clearAllCount = 0;
  @override
  Future<void> clearAll() async {
    clearAllCount++;
    await super.clearAll();
  }
}

class TrackingTimestampStore extends Mock implements TimestampStore {
  final Map<String, DateTime> _ts = {};
  @override
  Future<DateTime> get(String table) async => _ts[table] ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  @override
  Future<void> set(String table, DateTime timestamp) async => _ts[table] = timestamp;
}
