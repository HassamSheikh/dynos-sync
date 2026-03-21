import 'package:test/test.dart';
import 'package:dynos_sync/dynos_sync.dart';

class MockLocalStore implements LocalStore {
  final data = <String, Map<String, dynamic>>{};
  
  @override
  Future<void> upsert(String table, String id, Map<String, dynamic> record) async {
    data['$table:$id'] = record;
  }
  
  @override
  Future<void> delete(String table, String id) async {
    data.remove('$table:$id');
  }
}

class BadRemoteStore implements RemoteStore {
  int pushAttempts = 0;
  
  @override
  Future<void> push(String table, String id, SyncOperation op, Map<String, dynamic> data) async {
    pushAttempts++;
    throw Exception('Simulated Backend Validation Error (Poison Pill)');
  }
  
  @override
  Future<void> pushBatch(List<SyncEntry> entries) async {
    // Force a failure to test the fallback logic
    throw Exception('Simulated Batch Failure');
  }
  
  @override
  Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since) async => [];
  
  @override
  Future<Map<String, DateTime>> getRemoteTimestamps() async => {};
}

class InMemoryQueueStore implements QueueStore {
  final _queue = <SyncEntry>[];

  @override
  Future<void> enqueue(SyncEntry entry) async {
    _queue.add(entry);
  }

  @override
  Future<List<SyncEntry>> getPending({int limit = 50, DateTime? now}) async {
    return _queue.where((e) {
      if (!e.isPending) return false;
      if (now != null && e.nextRetryAt != null && e.nextRetryAt!.isAfter(now)) return false;
      return true;
    }).take(limit).toList();
  }

  @override
  Future<bool> hasPending(String table, String id) async {
    return _queue.any((e) => e.table == table && e.recordId == id && e.isPending);
  }

  @override
  Future<Set<String>> getPendingIds(String table) async {
    return _queue
        .where((e) => e.table == table && e.isPending)
        .map((e) => e.recordId)
        .toSet();
  }

  @override
  Future<List<SyncEntry>> getPendingEntries(String table, String recordId) async {
    return _queue
        .where((e) => e.table == table && e.recordId == recordId && e.isPending)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> markSynced(String id) async {
    final index = _queue.indexWhere((e) => e.id == id);
    if (index != -1 && _queue[index].syncedAt == null) {
      _queue[index] = _queue[index].copyWith(syncedAt: DateTime.now().toUtc());
    }
  }

  @override
  Future<void> incrementRetry(String id) async {
    final index = _queue.indexWhere((e) => e.id == id);
    if (index != -1) {
      _queue[index] = _queue[index].copyWith(retryCount: _queue[index].retryCount + 1);
    }
  }

  @override
  Future<void> setNextRetryAt(String id, DateTime nextRetryAt) async {
    final index = _queue.indexWhere((e) => e.id == id);
    if (index != -1) {
      _queue[index] = _queue[index].copyWith(nextRetryAt: nextRetryAt);
    }
  }

  @override
  Future<void> deleteEntry(String id) async {
    _queue.removeWhere((e) => e.id == id);
  }

  @override
  Future<void> purgeSynced({Duration retention = const Duration(days: 30)}) async {
    _queue.removeWhere((e) => !e.isPending);
  }

  @override
  Future<void> clearAll() async => _queue.clear();
}

void main() {
  test('SyncEngine drops posion pill effectively after maxRetries is reached', () async {
    final local = MockLocalStore();
    final remote = BadRemoteStore();
    final queue = InMemoryQueueStore();
    final timestamps = InMemoryTimestampStore();
    
    final emittedErrors = <String>[];
    
    final engine = SyncEngine(
      local: local,
      remote: remote,
      queue: queue,
      timestamps: timestamps,
      tables: ['tasks'],
      config: const SyncConfig(
        maxRetries: 3,
        stopOnFirstError: true, // test that it breaks first 3 times, then clears it
      ),
      onError: (e, st, ctx) {
        emittedErrors.add(ctx);
      },
    );
    
    // Helper to reset nextRetryAt so the entry is eligible for the next drain
    Future<void> clearBackoff() async {
      final entries = await queue.getPending(now: DateTime.utc(9999));
      for (final e in entries) {
        await queue.setNextRetryAt(e.id, DateTime.utc(2000, 1, 1));
      }
    }

    // 1. Initial write
    await engine.write('tasks', '1', {'name': 'Poison'});

    // Assert 1 attempt was made synchronously
    expect(remote.pushAttempts, 1);

    // We should have 1 pending item
    var pending = await queue.getPending();
    expect(pending.length, 1);
    expect(pending.first.retryCount, 0); // Still 0 since we didn't use drain(), write raises background push exceptions silently

    // 2. Drain cycle 1
    await engine.drain();
    expect(remote.pushAttempts, 2);
    expect(emittedErrors.last, contains('retry 1'));

    // 3. Drain cycle 2 — clear backoff so entry is eligible
    await clearBackoff();
    await engine.drain();
    expect(remote.pushAttempts, 3);
    expect(emittedErrors.last, contains('retry 2'));

    // 4. Drain cycle 3
    await clearBackoff();
    await engine.drain();
    expect(remote.pushAttempts, 4);
    expect(emittedErrors.last, contains('retry 3'));

    // At this point, retryCount == 3 (maxRetries)
    // 5. Drain cycle 4 (Drop)
    await clearBackoff();
    await engine.drain();
    expect(remote.pushAttempts, 5);
    expect(emittedErrors.last, contains('permanently failed'));

    // Ensure the queue is now empty
    pending = await queue.getPending();
    expect(pending, isEmpty);
  });
}
