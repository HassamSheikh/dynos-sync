import 'package:test/test.dart';
import 'package:dynos_sync/dynos_sync.dart';

// ─── Test helpers ────────────────────────────────────────────────────────────

class InMemoryLocalStore implements LocalStore {
  final data = <String, Map<String, dynamic>>{};
  @override
  Future<void> upsert(String t, String id, Map<String, dynamic> d) async =>
      data['$t:$id'] = d;
  @override
  Future<void> delete(String t, String id) async => data.remove('$t:$id');
  @override
  Future<void> clearAll(List<String> tables) async => data.clear();
}

class InMemoryQueueStore implements QueueStore {
  final _queue = <SyncEntry>[];
  List<SyncEntry> get allEntries => List.unmodifiable(_queue);
  @override
  Future<void> enqueue(SyncEntry e) async => _queue.add(e);
  @override
  Future<List<SyncEntry>> getPending({int limit = 50, DateTime? now}) async =>
      _queue.where((e) => e.isPending).take(limit).toList();
  @override
  Future<Set<String>> getPendingIds(String t) async => _queue
      .where((e) => e.table == t && e.isPending)
      .map((e) => e.recordId)
      .toSet();
  @override
  Future<List<SyncEntry>> getPendingEntries(String t, String id) async => _queue
      .where((e) => e.table == t && e.recordId == id && e.isPending)
      .toList();
  @override
  Future<bool> hasPending(String t, String id) async =>
      _queue.any((e) => e.table == t && e.recordId == id && e.isPending);
  @override
  Future<void> markSynced(String id) async {
    final i = _queue.indexWhere((e) => e.id == id);
    if (i != -1 && _queue[i].syncedAt == null) {
      _queue[i] = _queue[i].copyWith(syncedAt: DateTime.now().toUtc());
    }
  }

  @override
  Future<void> incrementRetry(String id) async {}
  @override
  Future<void> setNextRetryAt(String id, DateTime nextRetryAt) async {}
  @override
  Future<void> deleteEntry(String id) async =>
      _queue.removeWhere((e) => e.id == id);
  @override
  Future<void> purgeSynced(
          {Duration retention = const Duration(days: 30)}) async =>
      _queue.removeWhere((e) => !e.isPending);
  @override
  Future<void> clearAll() async => _queue.clear();
}

class InMemoryTimestampStore implements TimestampStore {
  final _map = <String, DateTime>{};
  @override
  Future<DateTime> get(String t) async =>
      _map[t] ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  @override
  Future<void> set(String t, DateTime ts) async => _map[t] = ts;
}

class TrackingRemoteStore implements RemoteStore {
  final pushCalls = <({
    String table,
    String id,
    SyncOperation op,
    Map<String, dynamic> data
  })>[];

  @override
  Future<void> push(String table, String id, SyncOperation op,
      Map<String, dynamic> data) async {
    pushCalls.add((table: table, id: id, op: op, data: Map.from(data)));
  }

  @override
  Future<void> pushBatch(List<SyncEntry> entries) async {
    for (final e in entries) {
      await push(e.table, e.recordId, e.operation, e.payload);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> pullSince(
          String table, DateTime since) async =>
      [];
  @override
  Future<Map<String, DateTime>> getRemoteTimestamps() async => {};
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  group('SyncOperation.patch', () {
    test('patch operation is queued via push() with partial payload', () async {
      final remote = TrackingRemoteStore();
      final queue = InMemoryQueueStore();

      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: remote,
        queue: queue,
        timestamps: InMemoryTimestampStore(),
        tables: ['suggested_workouts'],
      );

      final partialData = {
        'used_at': '2026-03-22T12:00:00Z',
        'exercises_kept': 5,
      };

      await engine.push(
        'suggested_workouts',
        'sw-1',
        partialData,
        operation: SyncOperation.patch,
      );

      // Verify the queue entry has the patch operation
      final entries = queue.allEntries;
      expect(entries, hasLength(1));
      expect(entries.first.operation, SyncOperation.patch);
      expect(entries.first.payload, partialData);
      expect(entries.first.recordId, 'sw-1');

      // Verify the remote received a patch push
      expect(remote.pushCalls, hasLength(1));
      expect(remote.pushCalls.first.op, SyncOperation.patch);
      expect(remote.pushCalls.first.data, partialData);

      engine.dispose();
    });

    test('patch sends only partial fields, not the full record', () async {
      final remote = TrackingRemoteStore();

      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: remote,
        queue: InMemoryQueueStore(),
        timestamps: InMemoryTimestampStore(),
        tables: ['workouts'],
      );

      // Only updating 2 fields, not the entire row
      await engine.push(
        'workouts',
        'w-1',
        {'status': 'completed', 'finished_at': '2026-03-22T14:00:00Z'},
        operation: SyncOperation.patch,
      );

      final call = remote.pushCalls.first;
      expect(call.op, SyncOperation.patch);
      expect(call.data.keys, containsAll(['status', 'finished_at']));
      // Must NOT contain fields that weren't provided
      expect(call.data.containsKey('name'), isFalse);
      expect(call.data.containsKey('created_at'), isFalse);
      expect(call.data.length, 2);

      engine.dispose();
    });

    test('drain processes patch entries correctly', () async {
      final remote = TrackingRemoteStore();
      final queue = InMemoryQueueStore();

      // Queue a patch entry directly
      await queue.enqueue(SyncEntry(
        id: 'entry-1',
        table: 'tasks',
        recordId: 't-1',
        operation: SyncOperation.patch,
        payload: {'priority': 'high'},
        createdAt: DateTime.now().toUtc(),
      ));

      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: remote,
        queue: queue,
        timestamps: InMemoryTimestampStore(),
        tables: ['tasks'],
      );

      await engine.drain();

      // Verify the remote received the patch
      expect(remote.pushCalls, hasLength(1));
      expect(remote.pushCalls.first.op, SyncOperation.patch);
      expect(remote.pushCalls.first.data, {'priority': 'high'});

      engine.dispose();
    });

    test('batch with mixed upsert, delete, and patch operations', () async {
      final remote = TrackingRemoteStore();
      final queue = InMemoryQueueStore();

      // Enqueue mixed operations
      await queue.enqueue(SyncEntry(
        id: 'e1',
        table: 'tasks',
        recordId: 't-1',
        operation: SyncOperation.upsert,
        payload: {'id': 't-1', 'title': 'New task', 'done': false},
        createdAt: DateTime.now().toUtc(),
      ));

      await queue.enqueue(SyncEntry(
        id: 'e2',
        table: 'tasks',
        recordId: 't-2',
        operation: SyncOperation.patch,
        payload: {'done': true, 'finished_at': '2026-03-22T15:00:00Z'},
        createdAt: DateTime.now().toUtc(),
      ));

      await queue.enqueue(SyncEntry(
        id: 'e3',
        table: 'tasks',
        recordId: 't-3',
        operation: SyncOperation.delete,
        payload: {},
        createdAt: DateTime.now().toUtc(),
      ));

      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: remote,
        queue: queue,
        timestamps: InMemoryTimestampStore(),
        tables: ['tasks'],
      );

      await engine.drain();

      // All 3 operations should have been pushed
      expect(remote.pushCalls, hasLength(3));

      final ops = remote.pushCalls.map((c) => c.op).toList();
      expect(ops, contains(SyncOperation.upsert));
      expect(ops, contains(SyncOperation.patch));
      expect(ops, contains(SyncOperation.delete));

      // Verify patch has only partial data
      final patchCall =
          remote.pushCalls.firstWhere((c) => c.op == SyncOperation.patch);
      expect(patchCall.data,
          {'done': true, 'finished_at': '2026-03-22T15:00:00Z'});
      expect(patchCall.id, 't-2');

      engine.dispose();
    });

    test('patch via write() respects PII masking via sensitiveFields',
        () async {
      final remote = TrackingRemoteStore();
      final local = InMemoryLocalStore();

      final engine = SyncEngine(
        local: local,
        remote: remote,
        queue: InMemoryQueueStore(),
        timestamps: InMemoryTimestampStore(),
        tables: ['profiles'],
        config: const SyncConfig(sensitiveFields: ['email']),
      );

      // write() and push() both apply PII masking via _maskPayload().
      await engine.write('profiles', 'p-1', {
        'email': 'new@email.com',
        'display_name': 'Updated',
      });

      final call = remote.pushCalls.first;
      expect(call.data['email'], '[REDACTED]');
      expect(call.data['display_name'], 'Updated');

      // Local store also receives masked data
      expect(local.data['profiles:p-1']!['email'], '[REDACTED]');

      engine.dispose();
    });

    test('patch respects payload size limit', () async {
      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: TrackingRemoteStore(),
        queue: InMemoryQueueStore(),
        timestamps: InMemoryTimestampStore(),
        tables: ['tasks'],
        config: const SyncConfig(maxPayloadBytes: 100),
      );

      expect(
        () => engine.push(
          'tasks',
          't-1',
          {'blob': 'x' * 200},
          operation: SyncOperation.patch,
        ),
        throwsA(isA<PayloadTooLargeException>()),
      );

      engine.dispose();
    });

    test('patch respects RLS check', () async {
      final engine = SyncEngine(
        local: InMemoryLocalStore(),
        remote: TrackingRemoteStore(),
        queue: InMemoryQueueStore(),
        timestamps: InMemoryTimestampStore(),
        tables: ['tasks'],
        userId: 'user-A',
      );

      expect(
        () => engine.push(
          'tasks',
          't-1',
          {'user_id': 'user-B', 'status': 'hacked'},
          operation: SyncOperation.patch,
        ),
        throwsA(
          predicate<Exception>((e) => e.toString().contains('[RLS_Bypass]')),
        ),
      );

      engine.dispose();
    });

    test('default RemoteStore.pushBatch handles patch via individual push',
        () async {
      final pushCalls = <({
        String table,
        String id,
        SyncOperation op,
        Map<String, dynamic> data
      })>[];

      final remote = _DefaultBatchRemote(pushCalls);

      final entries = [
        SyncEntry(
          id: 'e1',
          table: 'tasks',
          recordId: 't-1',
          operation: SyncOperation.patch,
          payload: {'done': true},
          createdAt: DateTime.now().toUtc(),
        ),
      ];

      await remote.pushBatch(entries);

      expect(pushCalls, hasLength(1));
      expect(pushCalls.first.op, SyncOperation.patch);
    });
  });
}

/// Tests the default pushBatch implementation in RemoteStore (loops push).
class _DefaultBatchRemote extends RemoteStore {
  _DefaultBatchRemote(this.pushCalls);
  final List<
      ({
        String table,
        String id,
        SyncOperation op,
        Map<String, dynamic> data
      })> pushCalls;

  @override
  Future<void> push(String table, String id, SyncOperation op,
      Map<String, dynamic> data) async {
    pushCalls.add((table: table, id: id, op: op, data: Map.from(data)));
  }

  // pushBatch uses the default implementation from RemoteStore

  @override
  Future<List<Map<String, dynamic>>> pullSince(
          String table, DateTime since) async =>
      [];
  @override
  Future<Map<String, DateTime>> getRemoteTimestamps() async => {};
}
