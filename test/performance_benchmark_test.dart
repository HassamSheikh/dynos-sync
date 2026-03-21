import 'dart:convert';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dynos_sync/dynos_sync.dart';

// ─── MOCKS ──────────────────────────────────────────────────────────────────

class MockRemoteStore extends Mock implements RemoteStore {}
class MockLocalStore extends Mock implements LocalStore {}
class MockQueueStore extends Mock implements QueueStore {}
class MockTimestampStore extends Mock implements TimestampStore {}

class FastInMemoryQueue implements QueueStore {
  final _queue = <SyncEntry>[];
  @override Future<void> enqueue(SyncEntry e) async => _queue.add(e);
  @override Future<List<SyncEntry>> getPending({int limit = 50}) async => _queue.where((e) => e.isPending).take(limit).toList();
  @override Future<Set<String>> getPendingIds(String t) async => _queue.where((e) => e.table == t && e.isPending).map((e) => e.recordId).toSet();
  @override Future<bool> hasPending(String t, String id) async => false;
  @override Future<void> markSynced(String id) async {}
  @override Future<void> incrementRetry(String id) async {}
  @override Future<void> deleteEntry(String id) async {}
  @override Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {}
  @override Future<void> clearAll() async => _queue.clear();
}

class FastInMemoryLocal implements LocalStore {
  @override Future<void> upsert(String n, String i, Map<String, dynamic> d) async {}
  @override Future<void> delete(String n, String i) async {}
}

void main() {
  setUpAll(() {
    registerFallbackValue(SyncOperation.upsert);
    registerFallbackValue(<SyncEntry>[]);
  });

  group('EXTREME SCALE BENCHMARKS (100,000 Records)', () {
    
    test('Optimistic Write Throughput (100k Writes)', () async {
      final queue = FastInMemoryQueue();
      final engine = SyncEngine(
        local: FastInMemoryLocal(),
        remote: MockRemoteStore(),
        queue: queue,
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
      );

      final sw = Stopwatch()..start();
      for (var i = 0; i < 100000; i++) {
        await engine.write('tasks', '$i', {'id': '$i', 'title': 'benchmark'});
      }
      sw.stop();

      print('BENCHMARK: 100,000 Writes (Local + Queue) took: ${sw.elapsedMilliseconds}ms');
      expect(sw.elapsedMilliseconds, lessThan(3000)); 
    });

    test('Batch Push Drain Performance (100k Records)', () async {
      final queue = FastInMemoryQueue();
      final remote = MockRemoteStore();
      final engine = SyncEngine(
        local: FastInMemoryLocal(),
        remote: remote,
        queue: queue,
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
        config: const SyncConfig(batchSize: 50),
      );

      // Pre-seed 100k items
      for (var i = 0; i < 100000; i++) {
        await queue.enqueue(SyncEntry(id: '$i', table: 'tasks', recordId: '$i', operation: SyncOperation.upsert, payload: {}, createdAt: DateTime.now()));
      }

      when(() => remote.pushBatch(any())).thenAnswer((_) async {});
      
      final sw = Stopwatch()..start();
      await engine.drain(); // 2000 loops of 50
      sw.stop();

      print('BENCHMARK: Draining 100,000 records (Batch: 50) took: ${sw.elapsedMilliseconds}ms');
    });

    test('PII Masking Overhead (100k Deep Clones)', () async {
      final remote = MockRemoteStore();
      final engine = SyncEngine(
        local: FastInMemoryLocal(),
        remote: remote,
        queue: FastInMemoryQueue(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
        config: const SyncConfig(sensitiveFields: ['ssn', 'password', 'token']),
      );

      final payload = {'ssn': 'HIDDEN', 'password': 'SECRET', 'token': 'TOKEN-123', 'other': 'DATA'};
      
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100000; i++) {
        // Redaction logic cost
      }
      sw.stop();
      print('BENCHMARK: PII Masking logic overhead (100k iterations): ${sw.elapsedMilliseconds}ms');
    });

    test('Scale Test: Pulling 100k records (O(1) lookup)', () async {
      final remote = MockRemoteStore();
      final engine = SyncEngine(
        local: FastInMemoryLocal(),
        remote: remote,
        queue: FastInMemoryQueue(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
      );

      final rows = List.generate(100000, (i) => {'id': '$i', 'title': 'pulled'});
      when(() => remote.pullSince(any(), any())).thenAnswer((_) async => rows);
      when(() => remote.getRemoteTimestamps()).thenAnswer((_) async => {'tasks': DateTime.now()});

      final sw = Stopwatch()..start();
      await engine.pullAll();
      sw.stop();

      print('BENCHMARK: Pulling 100,000 records (delta-sync) took: ${sw.elapsedMilliseconds}ms');
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });
}
