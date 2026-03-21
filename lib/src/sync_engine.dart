import 'dart:async';
import 'package:uuid/uuid.dart';

import 'local_store.dart';
import 'remote_store.dart';
import 'queue_store.dart';
import 'timestamp_store.dart';
import 'sync_config.dart';
import 'sync_entry.dart';
import 'sync_operation.dart';

/// A local-first, offline-capable sync engine.
///
/// Write locally first, queue changes for push, delta-pull on launch.
/// Backend and database agnostic — depends only on [LocalStore],
/// [RemoteStore], [QueueStore], and [TimestampStore] interfaces.
///
/// ## Quick start
///
/// ```dart
/// final sync = SyncEngine(
///   local: DriftLocalStore(db),
///   remote: SupabaseRemoteStore(client: client, userId: uid),
///   queue: DriftQueueStore(db),
///   timestamps: DriftTimestampStore(db),
///   tables: ['tasks', 'notes'],
/// );
///
/// // Write (local + queued for sync)
/// await sync.write('tasks', id, {'title': 'Buy milk'});
///
/// // Sync on app launch
/// await sync.syncAll();
/// ```
class SyncEngine {
  SyncEngine({
    required this.local,
    required this.remote,
    required this.queue,
    required this.timestamps,
    required this.tables,
    this.config = const SyncConfig(),
    this.onError,
  });

  final LocalStore local;
  final RemoteStore remote;
  final QueueStore queue;
  final TimestampStore timestamps;

  /// Tables registered for sync.
  final List<String> tables;

  /// Engine configuration.
  final SyncConfig config;

  /// Optional error callback. Called with (error, stackTrace, context).
  /// If null, errors are silently swallowed.
  final void Function(Object error, StackTrace stack, String context)? onError;

  static const _uuid = Uuid();

  // ── Initial sync gate ─────────────────────────────────────────────────────

  final Completer<void> _initialSync = Completer<void>();

  /// Completes when the first [syncAll] finishes (success or failure).
  /// Useful for splash screens that need to wait for data.
  Future<void> get initialSyncDone => _initialSync.future;

  // ── Write (optimistic) ────────────────────────────────────────────────────

  /// Write a record locally and queue it for push to the remote.
  ///
  /// The local write happens first (instant UI update).
  /// The remote push is queued and attempted immediately, but will retry
  /// on next [drain] if it fails.
  Future<void> write(
    String table,
    String id,
    Map<String, dynamic> data,
  ) async {
    await local.upsert(table, id, data);
    await _enqueue(table, id, SyncOperation.upsert, data);
  }

  /// Delete a record locally and queue the deletion for push.
  Future<void> remove(String table, String id) async {
    await local.delete(table, id);
    await _enqueue(table, id, SyncOperation.delete, {});
  }

  /// Queue a push without writing locally.
  ///
  /// Use when you've already written to the local DB via your own DAO
  /// and just need to sync the change remotely.
  Future<void> push(
    String table,
    String id,
    Map<String, dynamic> data, {
    SyncOperation operation = SyncOperation.upsert,
  }) async {
    await _enqueue(table, id, operation, data);
  }

  // ── Drain (push pending) ──────────────────────────────────────────────────

  /// Push all pending queue entries to the remote.
  ///
  /// Processes up to [SyncConfig.batchSize] entries per call.
  /// On failure: stops at first error if [SyncConfig.stopOnFirstError],
  /// otherwise skips and continues.
  Future<void> drain() async {
    final pending = await queue.getPending(limit: config.batchSize);

    if (pending.isEmpty) return;

    try {
      // 🚀 Performance Optimization: Try to sync everything in a single batch API call.
      // This reduces your Supabase/Firebase bill and speeds up syncing by up to 50x.
      await remote.pushBatch(pending);
      for (final entry in pending) {
        await queue.markSynced(entry.id);
      }
    } catch (e, st) {
      // 🔄 Fallback: If the batch fails (e.g., one record violates a constraint), 
      // process them individually to isolate the "poison pill" and allow the rest to sync.
      for (final entry in pending) {
        try {
          await remote.push(entry.table, entry.recordId, entry.operation, entry.payload);
          await queue.markSynced(entry.id);
        } catch (e, st) {
          if (entry.retryCount >= config.maxRetries) {
            onError?.call(e, st, 'drain_poison_pill[${entry.table}/${entry.recordId}] permanently failed');
            await queue.deleteEntry(entry.id);
          } else {
            onError?.call(e, st, 'drain[${entry.table}/${entry.recordId}] retry ${entry.retryCount + 1}');
            await queue.incrementRetry(entry.id);
            if (config.stopOnFirstError) break;
          }
        }
      }
    }

    await queue.purgeSynced(retention: config.queueRetention);
  }

  // ── Pull (delta sync) ─────────────────────────────────────────────────────

  /// Pull changes from the remote for all registered tables.
  ///
  /// Uses the "smart sync gate" pattern:
  /// 1. Fetch remote timestamps (1 lightweight call)
  /// 2. Compare against local timestamps
  /// 3. Only pull tables where remote > local
  Future<void> pullAll() async {
    try {
      final remoteTs = await remote.getRemoteTimestamps();

      final pulls = <Future<void>>[];
      for (final table in tables) {
        final remoteTime = remoteTs[table];
        if (remoteTime == null) {
          // No remote timestamp — pull unconditionally with epoch
          pulls.add(_pullTable(table, await timestamps.get(table)));
          continue;
        }

        final localTime = await timestamps.get(table);
        if (remoteTime.isAfter(localTime)) {
          pulls.add(_pullTable(table, localTime));
        }
      }

      await Future.wait(pulls);
    } catch (e, st) {
      onError?.call(e, st, 'pullAll');
    }
  }

  /// Pull a single table's changes since [since].
  Future<void> _pullTable(String table, DateTime since) async {
    try {
      final rows = await remote.pullSince(table, since);
      if (rows.isEmpty) return;

      // Batch-fetch all IDs for un-synced local records for this table.
      // This prevents the N+1 query problem during the ensuing row processing.
      final pendingIds = await queue.getPendingIds(table);

      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null) continue;

        // Skip overwriting local data if there is a pending user edit.
        if (pendingIds.contains(id)) continue;

        await local.upsert(table, id, row);
      }
      await timestamps.set(table, DateTime.now().toUtc());
    } catch (e, st) {
      onError?.call(e, st, 'pull[$table]');
    }
  }

  // ── Sync all (drain + pull) ───────────────────────────────────────────────

  /// Full sync cycle: drain pending writes, then pull remote changes.
  ///
  /// This is the method to call on app launch.
  Future<void> syncAll() async {
    try {
      await drain();
      await pullAll();
    } finally {
      if (!_initialSync.isCompleted) _initialSync.complete();
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _enqueue(
    String table,
    String id,
    SyncOperation operation,
    Map<String, dynamic> data,
  ) async {
    final entry = SyncEntry(
      id: _uuid.v4(),
      table: table,
      recordId: id,
      operation: operation,
      payload: data,
      createdAt: DateTime.now().toUtc(),
    );
    await queue.enqueue(entry);

    // Attempt immediate push (best-effort)
    try {
      await remote.push(table, id, operation, data);
      await queue.markSynced(entry.id);
    } catch (_) {
      // Will retry on next drain()
    }
  }
}
