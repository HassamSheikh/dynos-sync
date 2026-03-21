# dynos_sync

A local-first, offline-capable sync engine for Dart & Flutter apps.

**Write locally. Sync when ready. Never lose data.**

dynos_sync handles the hard parts of offline-first architecture: queueing writes for later, delta-syncing only what changed, retrying on failure, and coordinating splash-screen loading. It works with any local database and any remote backend.

## Install

```yaml
dependencies:
  dynos_sync: ^0.1.0
```

Three import paths, one package:

```dart
import 'package:dynos_sync/dynos_sync.dart';     // core engine + interfaces
import 'package:dynos_sync/drift.dart';           // Drift adapters (optional)
import 'package:dynos_sync/supabase.dart';        // Supabase adapter (optional)
```

## Quick Start

### 2. Add sync tables to your Drift database

```dart
import 'package:dynos_sync_drift/dynos_sync_drift.dart';

@DriftDatabase(tables: [
  // ... your app tables ...
  DynosSyncQueueTable,
  DynosSyncTimestampsTable,
])
class AppDatabase extends _$AppDatabase {
  // ...
}
```

### 3. Create the sync engine

```dart
import 'package:dynos_sync/dynos_sync.dart';
import 'package:dynos_sync_drift/dynos_sync_drift.dart';
import 'package:dynos_sync_supabase/dynos_sync_supabase.dart';

final sync = SyncEngine(
  local: DriftLocalStore(db),
  remote: SupabaseRemoteStore(
    client: Supabase.instance.client,
    userId: currentUser.id,
    tableTimestampKeys: {
      'tasks': 'tasks_at',
      'notes': 'notes_at',
    },
  ),
  queue: DriftQueueStore(db),
  timestamps: DriftTimestampStore(db),
  tables: ['tasks', 'notes'],
);
```

### 4. Use it

```dart
// Write a record (local + queued for sync)
await sync.write('tasks', taskId, {
  'id': taskId,
  'title': 'Buy milk',
  'done': false,
  'updated_at': DateTime.now().toIso8601String(),
});

// Or: write to your own DAO, then just push
await db.taskDao.save(task);
await sync.push('tasks', task.id, task.toJson());

// Delete a record
await sync.remove('tasks', taskId);

// Sync on app launch (drain pending + pull changes)
await sync.syncAll();

// Wait for initial sync (splash screens)
await sync.initialSyncDone;

// Manual drain (push pending writes)
await sync.drain();

// Manual pull (fetch remote changes)
await sync.pullAll();
```

## How It Works

### Write Flow (Optimistic)

```
Your App                    dynos_sync                  Remote
────────                    ──────────                  ──────
save(task)              →   1. Write to local DB
                            2. Queue in sync_queue
                            3. Try immediate push    →  Supabase/Firebase/API
                            4. If push fails:
                               stays in queue
                               (retry on next drain)
```

The user sees changes instantly. The sync happens in the background.

### Sync Flow (Delta)

```
App Launch              →   syncAll()
                            ├── drain()
                            │   └── pushBatch() – Push entire queue in 1-2 API calls
                            └── pullAll()
                                ├── getRemoteTimestamps()  →  1 lightweight query
                                ├── Compare remote vs local timestamps
                                └── Only pull tables where remote > local
                                    ├── getPendingIds(table) → 1 local query (O(1) lookup)
                                    └── pullSince(table, lastSync)
```

If nothing changed since last sync: **1 API call, 0 data transferred.**

### Queue Lifecycle

```
enqueue → [pending] → push succeeds → [synced] → purge after 30 days
                    → push fails    → [pending] → retry on next drain()
```

## Architecture

### Core Interfaces

Implement these for your stack:

```dart
/// Your local database (Drift, Hive, Isar, Floor, raw SQLite)
abstract class LocalStore {
  Future<void> upsert(String table, String id, Map<String, dynamic> data);
  Future<void> delete(String table, String id);
}

/// Your remote backend (Supabase, Firebase, Appwrite, custom REST)
abstract class RemoteStore {
  Future<void> push(String table, String id, SyncOperation op, Map<String, dynamic> data);
  Future<void> pushBatch(List<SyncEntry> entries);
  Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since);
  Future<Map<String, DateTime>> getRemoteTimestamps();
}

/// Sync queue storage (provided by dynos_sync_drift, or implement your own)
abstract class QueueStore {
  Future<void> enqueue(SyncEntry entry);
  Future<List<SyncEntry>> getPending({int limit = 50});
  Future<Set<String>> getPendingIds(String table);
  Future<void> markSynced(String id);
  Future<void> purgeSynced({Duration retention = const Duration(days: 30)});
}

/// Per-table timestamp tracking (provided by dynos_sync_drift)
abstract class TimestampStore {
  Future<DateTime> get(String table);
  Future<void> set(String table, DateTime timestamp);
}
```

### Provided Adapters

**Drift (SQLite):**
- `DriftLocalStore` — upsert/delete via raw SQL on any Drift database
- `DriftQueueStore` — queue backed by `dynos_sync_queue` table
- `DriftTimestampStore` — timestamps backed by `dynos_sync_timestamps` table

**Supabase:**
- `SupabaseRemoteStore` — push via `.upsert()`/`.delete()`, pull via `.select().gt('updated_at', since)`

### Configuration

```dart
final sync = SyncEngine(
  // ...stores...
  config: SyncConfig(
    batchSize: 50,                           // max entries per drain cycle
    queueRetention: Duration(days: 30),      // purge synced entries after 30 days
    stopOnFirstError: true,                  // stop drain on first push failure
    maxRetries: 3,                           // drop poison-pill entries after 3 retries
  ),
  onError: (error, stack, context) {
    logger.error('Sync error in $context', error, stack);
  },
);
```

## Smart Sync Gate

The "sync gate" minimizes API calls on launch:

1. `getRemoteTimestamps()` fetches a single lightweight row from your `sync_status` table
2. Each timestamp column represents the last change time for a table
3. The engine compares remote timestamps against locally stored timestamps
4. **Only tables where `remote > local` get pulled**

For this to work, your backend needs:
- A `sync_status` table with one row per user
- Trigger-maintained `timestamptz` columns per synced table
- Pass the column mapping via `tableTimestampKeys`

Without it, the engine falls back to pulling all tables every sync (still delta — only rows with `updated_at > lastSync`).

## Custom Adapters

### Firebase Example

```dart
class FirebaseRemoteStore implements RemoteStore {
  final FirebaseFirestore _fs;

  @override
  Future<void> push(String table, String id, SyncOperation op, Map<String, dynamic> data) async {
    final ref = _fs.collection(table).doc(id);
    switch (op) {
      case SyncOperation.upsert: await ref.set(data, SetOptions(merge: true));
      case SyncOperation.delete: await ref.delete();
    }
  }

  @override
  Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since) async {
    final snap = await _fs.collection(table)
        .where('updated_at', isGreaterThan: Timestamp.fromDate(since))
        .get();
    return snap.docs.map((d) => d.data()).toList();
  }

  @override
  Future<Map<String, DateTime>> getRemoteTimestamps() async {
    // Implement with your own sync_status document
    return {};
  }
}
```

### Hive Example

```dart
class HiveLocalStore implements LocalStore {
  @override
  Future<void> upsert(String table, String id, Map<String, dynamic> data) async {
    final box = await Hive.openBox(table);
    await box.put(id, data);
  }

  @override
  Future<void> delete(String table, String id) async {
    final box = await Hive.openBox(table);
    await box.delete(id);
  }
}
```

## Error Handling

```dart
final sync = SyncEngine(
  // ...
  config: SyncConfig(stopOnFirstError: true),
  onError: (error, stack, context) {
    // context examples: 'drain[tasks/abc-123]', 'pull[notes]', 'pullAll'
    Sentry.captureException(error, stackTrace: stack);
  },
);
```

- **Drain errors:** queue entries stay pending, retried next cycle. If they fail `maxRetries` times, they are permanently dropped and emit a `drain_poison_pill[...]` error context.
- **Pull errors:** individual table pull fails silently, other tables continue
- **Never throws** from `syncAll()`, `drain()`, or `pullAll()` — errors routed to `onError`

## License

MIT
