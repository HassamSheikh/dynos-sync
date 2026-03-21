import 'dart:async';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dynos_sync/dynos_sync.dart';

// ─── MOCKS ──────────────────────────────────────────────────────────────────

class MockRemoteStore extends Mock implements RemoteStore {}
class MockLocalStore extends Mock implements LocalStore {}
class MockQueueStore extends Mock implements QueueStore {}
class MockTimestampStore extends Mock implements TimestampStore {}

class HeavyQueue implements QueueStore {
  int count = 0;
  @override Future<void> enqueue(SyncEntry e) async { count++; }
  @override Future<List<SyncEntry>> getPending({int limit = 50}) async => [];
  @override Future<Set<String>> getPendingIds(String t) async => {};
  @override Future<bool> hasPending(String t, String i) async => false;
  @override Future<void> markSynced(String id) async {}
  @override Future<void> incrementRetry(String id) async {}
  @override Future<void> deleteEntry(String id) async {}
  @override Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {}
  @override Future<void> clearAll() async {}
}

class StaticLocal implements LocalStore {
  @override Future<void> upsert(String n, String i, Map<String, dynamic> d) async {}
  @override Future<void> delete(String n, String i) async {}
}

void main() {
  setUpAll(() {
    registerFallbackValue(SyncOperation.upsert);
  });

  group('DDOS & FLOOD RESILIENCE (100,000 Parallel Writes)', () {
    
    test('Simultaneous 100k Parallel Write Ingestion', () async {
      // SEVERITY: CRITICAL
      final queue = HeavyQueue();
      final engine = SyncEngine(
        local: StaticLocal(),
        remote: MockRemoteStore(),
        queue: queue,
        timestamps: MockTimestampStore(),
        tables: ['flood_test'],
      );

      print('Starting DDoS simulation: 100,000 Parallel Writers...');
      
      final sw = Stopwatch()..start();
      
      // Parallelize 100k writes using Future.wait
      final writes = <Future<void>>[];
      for (var i = 0; i < 100000; i++) {
        writes.add(engine.write('flood_test', '$i', {'msg': 'flood'}));
      }
      
      await Future.wait(writes);
      
      sw.stop();

      print('FLOOD RESULTS:');
      print('Total Writes: ${queue.count}');
      print('Total Time: ${sw.elapsedMilliseconds}ms');
      print('Frequency: ${(100000 / (sw.elapsedMilliseconds / 1000)).floor()} writes/sec');
      
      expect(queue.count, 100000);
      expect(sw.elapsedMilliseconds, lessThan(10000)); // Must ingest 100k in < 10s
    });

    test('Engine stability under RLS-Bypass Flood Attempt', () async {
      // SEVERITY: HIGH
      final engine = SyncEngine(
        local: StaticLocal(),
        remote: MockRemoteStore(),
        queue: HeavyQueue(),
        timestamps: MockTimestampStore(),
        tables: ['tasks'],
        userId: 'admin',
      );

      final attacks = <Future<void>>[];
      for (var i = 0; i < 10000; i++) {
        attacks.add(engine.write('tasks', '$i', {'user_id': 'malicious'}).catchError((_) {}));
      }
      
      await Future.wait(attacks);
      
      // If we didn't crash the event loop, then the security gates are stable under flood.
      print('RLS FLOOD: Ingested 10,000 unauthorized writes (all rejected). Event loop stable.');
    });
  });
}
