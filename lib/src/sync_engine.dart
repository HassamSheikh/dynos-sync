import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';

import 'local_store.dart';
import 'remote_store.dart';
import 'queue_store.dart';
import 'timestamp_store.dart';
import 'sync_config.dart';
import 'sync_entry.dart';
import 'sync_operation.dart';
import 'sync_event.dart';
import 'sync_exceptions.dart';
import 'conflict_strategy.dart';

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
    required List<String> tables,
    this.userId,
    this.config = const SyncConfig(),
    this.onError,
  }) : _tables = List<String>.of(tables);

  final LocalStore local;
  final RemoteStore remote;
  final QueueStore queue;
  final TimestampStore timestamps;

  final List<String> _tables;

  /// Tables registered for sync (unmodifiable view).
  List<String> get tables => List<String>.unmodifiable(_tables);

  /// Register a new table for sync at runtime.
  ///
  /// Returns `true` if the table was added, `false` if already registered.
  /// Optionally pulls remote data for the table immediately when [pull] is
  /// `true` (the default).
  Future<bool> addTable(String table, {bool pull = true}) async {
    if (_tables.contains(table)) return false;
    _tables.add(table);
    if (pull) {
      final since = await timestamps.get(table);
      await _pullTable(table, since);
    }
    return true;
  }

  /// Unregister a table so it is no longer included in [pullAll] / [logout].
  ///
  /// Returns `true` if the table was removed, `false` if it was not registered.
  bool removeTable(String table) => _tables.remove(table);

  /// Engine configuration.
  final SyncConfig config;

  /// Current authenticated user ID.
  /// If provided, [write] operations will be checked for RLS-misMatch
  /// before being queued.
  final String? userId;

  /// Optional error callback. Called with (error, stackTrace, context).
  /// If null, errors are silently swallowed.
  final void Function(Object error, StackTrace stack, String context)? onError;

  static const _uuid = Uuid();

  // ── Event Stream ──────────────────────────────────────────────────────────

  final StreamController<SyncEvent> _eventController =
      StreamController<SyncEvent>.broadcast();

  /// Stream of sync lifecycle events.
  Stream<SyncEvent> get events => _eventController.stream;

  void _emit(SyncEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  /// Release resources held by this engine.
  void dispose() {
    _eventController.close();
  }

  // ── Drain Lock ────────────────────────────────────────────────────────────

  bool _draining = false;

  /// Whether [drain] is currently executing.
  bool get isDraining => _draining;

  // ── Helpers ───────────────────────────────────────────────────────────────

  Map<String, dynamic> _maskPayload(Map<String, dynamic> data) {
    if (config.sensitiveFields.isEmpty) return data;
    final masked = Map<String, dynamic>.from(data);
    for (final field in config.sensitiveFields) {
      if (masked.containsKey(field)) {
        masked[field] = '[REDACTED]';
      }
    }
    return masked;
  }

  /// Extract an `updated_at` timestamp from a data map.
  DateTime? _extractTimestamp(Map<String, dynamic> data) {
    final value = data['updated_at'];
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return null;
  }

  /// Validate that a payload does not exceed [SyncConfig.maxPayloadBytes].
  void _validatePayloadSize(Map<String, dynamic> data) {
    final bytes = utf8.encode(jsonEncode(data)).length;
    if (bytes > config.maxPayloadBytes) {
      throw PayloadTooLargeException(
          bytes: bytes, limit: config.maxPayloadBytes);
    }
  }

  // ── Initial sync gate ─────────────────────────────────────────────────────

  final Completer<void> _initialSync = Completer<void>();

  /// Completes when the first [syncAll] finishes (success or failure).
  /// Useful for splash screens that need to wait for data.
  Future<void> get initialSyncDone => _initialSync.future;

  // ── Write (optimistic) ────────────────────────────────────────────────────

  /// Write a record locally and queue it for push to the remote.
  ///
  /// Local write runs first so a failed upsert never leaves an orphaned
  /// queue entry.  If `local.upsert` throws, no entry is enqueued and the
  /// caller receives the error.
  Future<void> write(
    String table,
    String id,
    Map<String, dynamic> data,
  ) async {
    // 🛡️ Scrub PII before anything else
    final maskedData = _maskPayload(data);

    // Validate payload size after scrubbing (just in case)
    _validatePayloadSize(maskedData);

    // 1. Write locally first — fail fast before touching the queue
    await local.upsert(table, id, maskedData);

    // 2. Queue it for remote push (includes RLS check)
    await _enqueue(table, id, SyncOperation.upsert, maskedData);
  }

  /// Delete a record locally and queue the deletion for push.
  ///
  /// Local delete runs first so a failed delete never leaves an orphaned
  /// queue entry.
  Future<void> remove(String table, String id) async {
    // 1. Remove locally first — fail fast before touching the queue
    await local.delete(table, id);

    // 2. Queue deletion for remote push
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
    // Validate payload size before anything
    _validatePayloadSize(data);

    await _enqueue(table, id, operation, data);
  }

  // ── Drain (push pending) ──────────────────────────────────────────────────

  /// Push all pending queue entries to the remote.
  ///
  /// Processes up to [SyncConfig.batchSize] entries per call.
  /// On failure: stops at first error if [SyncConfig.stopOnFirstError],
  /// otherwise skips and continues.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;

    try {
      final pending = await queue.getPending(
        limit: config.batchSize,
        now: DateTime.now().toUtc(),
      );

      if (pending.isEmpty) return;

      try {
        // Try to sync everything in a single batch API call.
        await remote.pushBatch(pending);
        for (final entry in pending) {
          await queue.markSynced(entry.id);
        }
      } on AuthExpiredException catch (e) {
        _emit(SyncAuthRequired(
          timestamp: DateTime.now().toUtc(),
          error: e,
        ));
        return;
      } catch (_) {
        // Fallback: If the batch fails, process individually to isolate
        // the "poison pill" and allow the rest to sync.
        for (final entry in pending) {
          try {
            await remote.push(
              entry.table,
              entry.recordId,
              entry.operation,
              entry.payload,
            );
            await queue.markSynced(entry.id);
          } on AuthExpiredException catch (e) {
            _emit(SyncAuthRequired(
              timestamp: DateTime.now().toUtc(),
              error: e,
            ));
            return;
          } catch (e, st) {
            if (entry.retryCount >= config.maxRetries) {
              onError?.call(
                e,
                st,
                'drain_poison_pill[${entry.table}/${entry.recordId}] permanently failed',
              );
              _emit(SyncPoisonPill(
                timestamp: DateTime.now().toUtc(),
                entry: entry,
              ));
              await queue.deleteEntry(entry.id);
            } else {
              final masked = _maskPayload(entry.payload);
              onError?.call(
                e,
                st,
                'drain[${entry.table}/${entry.recordId}] payload: $masked retry ${entry.retryCount + 1}',
              );
              _emit(SyncError(
                timestamp: DateTime.now().toUtc(),
                error: e,
                context:
                    'drain[${entry.table}/${entry.recordId}] retry ${entry.retryCount + 1}',
              ));

              // Per-entry backoff
              final backoffSeconds = math.min(
                math.pow(2, entry.retryCount + 1).toInt(),
                config.maxBackoff.inSeconds,
              );
              final nextRetry =
                  DateTime.now().toUtc().add(Duration(seconds: backoffSeconds));

              await queue.incrementRetry(entry.id);
              await queue.setNextRetryAt(entry.id, nextRetry);

              _emit(SyncRetryScheduled(
                timestamp: DateTime.now().toUtc(),
                entry: entry,
                nextRetryAt: nextRetry,
              ));

              if (config.stopOnFirstError) break;
            }
          }
        }
      }

      await queue.purgeSynced(retention: config.queueRetention);
    } finally {
      _draining = false;
      _emit(SyncDrainComplete(timestamp: DateTime.now().toUtc()));
    }
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
    } on AuthExpiredException catch (e) {
      _emit(SyncAuthRequired(
        timestamp: DateTime.now().toUtc(),
        error: e,
      ));
    } catch (e, st) {
      onError?.call(e, st, 'pullAll');
      _emit(SyncError(
        timestamp: DateTime.now().toUtc(),
        error: e,
        context: 'pullAll',
      ));
    }
  }

  /// Pull a single table's changes since [since].
  Future<void> _pullTable(String table, DateTime since) async {
    try {
      final rows = await remote.pullSince(table, since);
      if (rows.isEmpty) {
        _emit(SyncPullComplete(
          timestamp: DateTime.now().toUtc(),
          table: table,
          rowCount: 0,
        ));
        return;
      }

      // Batch-fetch all IDs for un-synced local records for this table.
      final pendingIds = await queue.getPendingIds(table);

      var upsertedCount = 0;
      for (final row in rows) {
        final id = row['id']?.toString();
        if (id == null) continue;

        // RLS pull validation
        if (userId != null) {
          final rowOwner = (row['user_id'] ?? row['owner_id'])?.toString();
          if (rowOwner != null && rowOwner != userId) {
            _emit(SyncError(
              timestamp: DateTime.now().toUtc(),
              error: RlsViolationException(recordId: id, rowOwner: rowOwner),
              context: 'rls_violation[$table/$id]',
            ));
            continue;
          }
        }

        // Conflict resolution instead of blind skip
        if (pendingIds.contains(id)) {
          await _resolveConflict(table, id, row);
          upsertedCount++;
          continue;
        }

        await local.upsert(table, id, row);
        upsertedCount++;
      }

      await timestamps.set(table, DateTime.now().toUtc());

      _emit(SyncPullComplete(
        timestamp: DateTime.now().toUtc(),
        table: table,
        rowCount: upsertedCount,
      ));
    } catch (e, st) {
      onError?.call(e, st, 'pull[$table]');
      _emit(SyncError(
        timestamp: DateTime.now().toUtc(),
        error: e,
        context: 'pull[$table]',
      ));
    }
  }

  // ── Conflict Resolution ───────────────────────────────────────────────────

  Future<void> _resolveConflict(
    String table,
    String id,
    Map<String, dynamic> remoteRow,
  ) async {
    final localEntries = await queue.getPendingEntries(table, id);
    final localEntry = localEntries.isNotEmpty ? localEntries.first : null;

    // If local entry is a DELETE operation: delete wins (skip remote update)
    if (localEntry != null && localEntry.operation == SyncOperation.delete) {
      _emit(SyncConflict(
        timestamp: DateTime.now().toUtc(),
        table: table,
        recordId: id,
        localVersion: localEntry.payload,
        remoteVersion: remoteRow,
        resolvedVersion: localEntry.payload,
        strategyUsed: ConflictStrategy.clientWins,
      ));
      return;
    }

    final localPayload = localEntry?.payload ?? <String, dynamic>{};
    Map<String, dynamic> resolved;
    ConflictStrategy strategyUsed = config.conflictStrategy;

    switch (config.conflictStrategy) {
      case ConflictStrategy.lastWriteWins:
        final localTs = _extractTimestamp(localPayload);
        final remoteTs = _extractTimestamp(remoteRow);

        if (localTs != null && remoteTs != null) {
          if (localTs.isAfter(remoteTs)) {
            resolved = localPayload;
          } else {
            resolved = remoteRow;
          }
        } else {
          // No timestamps available — server wins as safe default
          resolved = remoteRow;
          strategyUsed = ConflictStrategy.serverWins;
        }
        break;

      case ConflictStrategy.serverWins:
        resolved = remoteRow;
        break;

      case ConflictStrategy.clientWins:
        resolved = localPayload;
        break;

      case ConflictStrategy.custom:
        resolved = await config.onConflict!(table, id, localPayload, remoteRow);
        break;
    }

    _emit(SyncConflict(
      timestamp: DateTime.now().toUtc(),
      table: table,
      recordId: id,
      localVersion: localPayload,
      remoteVersion: remoteRow,
      resolvedVersion: resolved,
      strategyUsed: strategyUsed,
    ));

    // Upsert the winner locally
    await local.upsert(table, id, resolved);

    // If server won, delete local queue entries for this record
    final serverWon = identical(resolved, remoteRow);
    if (serverWon) {
      for (final entry in localEntries) {
        await queue.deleteEntry(entry.id);
      }
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

  /// Wipe all local sync state (queue and timestamps).
  ///
  /// **CRITICAL:** Call this on logout to prevent "Cross-User Isolation" leaks,
  /// where one user's unsynced data might be pushed under the next user's session.
  Future<void> logout() async {
    await queue.clearAll();
    await local
        .clearAll(tables); // 🛡️ Category 1: Purge local identity context
    for (final table in tables) {
      await timestamps.set(
        table,
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    }
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  Future<void> _enqueue(
    String table,
    String id,
    SyncOperation operation,
    Map<String, dynamic> data,
  ) async {
    // Row-Level Security (RLS) local bypass check
    if (userId != null) {
      final ownerId = data['user_id'] ?? data['owner_id'];
      if (ownerId != null && ownerId != userId) {
        throw Exception(
          'Security Error: [RLS_Bypass] row owner ($ownerId) does not match authenticated user ($userId)',
        );
      }
    }

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
    } on AuthExpiredException catch (e) {
      _emit(SyncAuthRequired(
        timestamp: DateTime.now().toUtc(),
        error: e,
      ));
    } catch (_) {
      // Will retry on next drain()
    }
  }
}
