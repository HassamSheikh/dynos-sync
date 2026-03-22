<p align="center">
  <img src="assets/logo.svg" alt="dynos.fit logo" width="320px">
</p>

# dynos_sync

**Production-grade offline-first sync engine for Dart & Flutter.**
Built by the team at [**dynos.fit**](https://dynos.fit) to power high-concurrency workout synchronization.

[![Pub.dev](https://img.shields.io/pub/v/dynos_sync)](https://pub.dev/packages/dynos_sync)
[![Pub Points](https://img.shields.io/pub/points/dynos_sync)](https://pub.dev/packages/dynos_sync/score)
[![MIT License](https://img.shields.io/badge/license-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Security Audit: 130 Tests](https://img.shields.io/badge/Security_Audit-130/130_PASS-2DD4A8)](doc/security_audit.md)
[![Performance: 50k+ writes/sec](https://img.shields.io/badge/Performance-50k+_writes/sec-blueviolet)](#performance)

---

## What it does

`dynos_sync` sits between your local database and remote backend. Every write goes to the local DB first, gets queued for sync, and drains to the server when connectivity allows. On launch, it delta-pulls only what changed. Conflicts are resolved automatically.

```
Flutter App  -->  SyncEngine  -->  Local DB (Drift/SQLite)
                      |
                      +--->  Sync Queue  -->  Remote API (Supabase/REST)
```

**Database and backend agnostic.** Plug in any local store, any remote API, any queue backend via clean interfaces.

---

## Features

| Category | What you get |
|---|---|
| **Offline-first writes** | `write()` persists locally + queues for sync in one atomic call |
| **Delta sync** | `pullAll()` compares timestamps, only fetches tables with changes |
| **Conflict resolution** | Last-write-wins, server-wins, client-wins, or custom callback |
| **Runtime table registration** | `addTable()` / `removeTable()` after engine is running |
| **PII redaction** | Sensitive fields masked with `[REDACTED]` before storage and push |
| **Row-Level Security** | Local RLS gate blocks writes with mismatched `user_id` |
| **Exponential backoff** | Failed pushes retry with 2^n delays, capped at `maxBackoff` |
| **Poison pill isolation** | Permanently failing entries are dropped after `maxRetries` |
| **Batch push** | `drain()` pushes up to `batchSize` entries per cycle |
| **Auth expiry handling** | `AuthExpiredException` emits `SyncAuthRequired` event, stops drain |
| **Cross-user isolation** | `logout()` wipes queue, local data, and timestamps |
| **Event stream** | Broadcast stream of typed events for UI/logging integration |
| **Background isolate** | `IsolateSyncEngine` wraps sync in a dedicated isolate |
| **Payload size limits** | Rejects payloads exceeding `maxPayloadBytes` |
| **Drain lock** | Prevents concurrent drain operations |

---

## Installation

```yaml
dependencies:
  dynos_sync: ^0.1.2
```

---

## Quick start

### 1. Create the engine

```dart
final sync = SyncEngine(
  local: DriftLocalStore(db),
  remote: SupabaseRemoteStore(client: client, userId: () => uid),
  queue: DriftQueueStore(db),
  timestamps: DriftTimestampStore(db),
  tables: ['tasks', 'notes'],
  userId: uid,
  config: const SyncConfig(
    batchSize: 50,
    sensitiveFields: ['password', 'ssn'],
    conflictStrategy: ConflictStrategy.lastWriteWins,
  ),
);
```

### 2. Write data

```dart
await sync.write('tasks', id, {
  'id': id,
  'title': 'Buy milk',
  'updated_at': DateTime.now().toUtc().toIso8601String(),
});
```

### 3. Sync on app launch

```dart
await sync.syncAll();          // drain pending + pull remote changes
await sync.initialSyncDone;    // wait in splash screen
```

### 4. Add tables at runtime

```dart
await sync.addTable('categories');              // pulls immediately
await sync.addTable('tags', pull: false);       // register only
sync.removeTable('deprecated_table');           // stop syncing
```

### 5. Logout

```dart
await sync.logout();  // wipes queue, local data, timestamps
```

---

## API reference

### SyncEngine

| Method | Description |
|---|---|
| `write(table, id, data)` | Write locally + queue for sync |
| `remove(table, id)` | Delete locally + queue deletion |
| `push(table, id, data, {operation})` | Queue sync without local write (for custom DAOs) |
| `drain()` | Push all pending queue entries to remote |
| `pullAll()` | Delta-pull changes from remote for all registered tables |
| `syncAll()` | Full cycle: `drain()` then `pullAll()` |
| `addTable(table, {pull})` | Register a new table at runtime, optionally pull immediately |
| `removeTable(table)` | Unregister a table from sync |
| `logout()` | Wipe all local sync state (queue, data, timestamps) |
| `dispose()` | Close the event stream |

| Property | Type | Description |
|---|---|---|
| `tables` | `List<String>` | Currently registered tables (unmodifiable) |
| `events` | `Stream<SyncEvent>` | Broadcast stream of sync lifecycle events |
| `isDraining` | `bool` | Whether `drain()` is currently executing |
| `initialSyncDone` | `Future<void>` | Completes after first `syncAll()` finishes |
| `userId` | `String?` | Current authenticated user for RLS checks |
| `config` | `SyncConfig` | Engine configuration |

### SyncConfig

| Parameter | Default | Description |
|---|---|---|
| `batchSize` | `50` | Max entries to drain per cycle |
| `queueRetention` | `30 days` | How long to keep synced entries before purging |
| `stopOnFirstError` | `true` | Stop drain on first failure vs skip and continue |
| `maxRetries` | `3` | Retries before dropping a poison pill entry |
| `sensitiveFields` | `[]` | Field names to mask with `[REDACTED]` |
| `useExponentialBackoff` | `true` | Enable 2^n retry delays |
| `conflictStrategy` | `lastWriteWins` | How to resolve local vs remote conflicts |
| `onConflict` | `null` | Custom conflict resolver (required when strategy is `custom`) |
| `maxPayloadBytes` | `1 MB` | Max payload size before rejection |
| `maxBackoff` | `60s` | Cap on exponential backoff duration |

### Events

| Event | Fields | When |
|---|---|---|
| `SyncDrainComplete` | `timestamp` | After `drain()` finishes |
| `SyncPullComplete` | `timestamp`, `table`, `rowCount` | After pulling a table |
| `SyncAuthRequired` | `timestamp`, `error` | Auth token expired during sync |
| `SyncConflict` | `timestamp`, `table`, `recordId`, `localVersion`, `remoteVersion`, `resolvedVersion`, `strategyUsed` | Conflict resolved |
| `SyncPoisonPill` | `timestamp`, `entry` | Entry permanently dropped |
| `SyncRetryScheduled` | `timestamp`, `entry`, `nextRetryAt` | Retry scheduled with backoff |
| `SyncError` | `timestamp`, `error`, `context` | Non-fatal error during sync |

### Exceptions

| Exception | When |
|---|---|
| `AuthExpiredException` | Remote returns 401/403 |
| `PayloadTooLargeException` | Payload exceeds `maxPayloadBytes` |
| `RlsViolationException` | Pulled row has wrong `user_id` |
| `SyncRemoteException` | Remote returns an error response |
| `SyncDeserializationException` | Failed to parse remote response |

### Store interfaces

Implement these to plug in your database and backend:

```dart
abstract class LocalStore {
  Future<void> upsert(String table, String id, Map<String, dynamic> data);
  Future<void> delete(String table, String id);
  Future<void> clearAll(List<String> tables);
}

abstract class RemoteStore {
  Future<void> push(String table, String id, SyncOperation op, Map<String, dynamic> data);
  Future<void> pushBatch(List<SyncEntry> entries);  // default: loops push()
  Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since);
  Future<Map<String, DateTime>> getRemoteTimestamps();
}

abstract class QueueStore { /* enqueue, getPending, markSynced, ... */ }
abstract class TimestampStore { /* get, set */ }
```

**Bundled adapters:** `DriftLocalStore`, `DriftQueueStore`, `DriftTimestampStore`, `SupabaseRemoteStore`.

---

## Performance

Benchmarked with in-memory stores on standard hardware:

| Operation | 10k records | 100k records |
|---|---|---|
| **Bulk write** | ~130ms | ~1,400ms |
| **Queue drain** | ~2ms | ~3ms |
| **Delta pull** | < 1ms | ~3ms |
| **PII masking overhead** | ~4ms | ~44ms |

---

## Security

The engine passes a **130-test security audit** across 12 categories:

- HIPAA & health data compliance (PHI masking, audit trail, session timeout)
- Cross-user data isolation (full wipe on logout)
- Injection prevention (SQL, NoSQL, XSS, path traversal stored as literals)
- Auth & RLS enforcement (local user_id gate, auth expiry events)
- Conflict resolution integrity (deterministic, all strategies tested)
- Flood resilience (100k parallel writes, drain lock)
- OWASP Mobile Top 10 coverage
- GDPR compliance (right to erasure, data minimization)

See [Security Audit Report](doc/security_audit.md) for details.

---

## Documentation

- [Architecture](doc/architecture.md) -- sync protocol, write path, pull path, security gates
- [Security Audit](doc/security_audit.md) -- 130-test audit across 12 categories
- [API example](example/example.dart) -- complete Drift + Supabase setup
- [Security Policy](SECURITY.md) -- vulnerability reporting

---

## License

MIT -- see [LICENSE](LICENSE).

*Built by the [dynos.fit](https://dynos.fit) team.*
