# Architecture

This document describes the internals of `dynos_sync` -- how data flows through the engine, how conflicts are resolved, and how security is enforced.

---

## Overview

`dynos_sync` is a headless sync engine that coordinates between four pluggable stores:

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  LocalStore  │     │  QueueStore  │     │  RemoteStore  │
│  (Drift/SQL) │     │  (sync queue)│     │  (Supabase)   │
└──────┬───────┘     └──────┬───────┘     └───────┬───────┘
       │                    │                     │
       └────────────┬───────┘                     │
                    │                             │
              ┌─────┴──────┐                      │
              │ SyncEngine │──────────────────────┘
              └─────┬──────┘
                    │
              ┌─────┴──────────┐
              │ TimestampStore │
              └────────────────┘
```

The engine is **database and backend agnostic**. It depends only on abstract interfaces (`LocalStore`, `RemoteStore`, `QueueStore`, `TimestampStore`). Concrete implementations for Drift and Supabase are provided as adapters.

---

## Write path (optimistic)

Every call to `write(table, id, data)` follows this sequence:

```
1. _maskPayload()       →  Replace sensitiveFields with [REDACTED]
2. _validatePayloadSize →  Reject if > maxPayloadBytes
3. _enqueue()           →  RLS check → create SyncEntry → persist to QueueStore
4. remote.push()        →  Best-effort immediate push (fire-and-forget)
5. local.upsert()       →  Persist to local database
```

Key design decisions:
- **Queue before local write.** If the app is killed between steps 3 and 5, the queue entry survives for retry. This is the "atomic ordering" guarantee.
- **Best-effort push.** Step 4 tries to push immediately. If it succeeds, the entry is marked synced. If it fails (offline, auth expired), the entry stays pending for `drain()`.
- **PII masking happens first.** Sensitive fields are redacted before touching any store, so raw PII never reaches the queue, local DB, or remote.

### push() vs write()

`push(table, id, data)` queues a sync entry without writing locally. Use this when your own DAO handles the local write and you just need the remote sync.

### remove()

`remove(table, id)` queues a `SyncOperation.delete` entry and deletes from the local store.

---

## Drain path (push pending)

`drain()` pushes all pending queue entries to the remote:

```
1. Check _draining lock         →  Return immediately if already draining
2. queue.getPending(batchSize)  →  Fetch up to batchSize pending entries
3. remote.pushBatch(entries)    →  Try batch push
   ├─ Success                   →  Mark all as synced
   └─ Failure                   →  Fall back to individual push
4. Individual push loop:
   ├─ Success                   →  Mark synced
   ├─ AuthExpiredException      →  Emit SyncAuthRequired, stop
   └─ Other error:
       ├─ retryCount >= maxRetries  →  Drop entry (poison pill), emit SyncPoisonPill
       └─ retryCount < maxRetries   →  Increment retry, schedule backoff
5. queue.purgeSynced()          →  Clean up old synced entries
6. Emit SyncDrainComplete
```

**Drain lock:** A boolean flag prevents concurrent drain calls. If `drain()` is called while already draining, the second call returns immediately.

**Exponential backoff:** Failed entries get a `nextRetryAt` of `2^(retryCount+1)` seconds into the future, capped at `maxBackoff`. The entry is skipped by `getPending()` until that time passes.

**Poison pill isolation:** After `maxRetries` failures, the entry is permanently deleted from the queue and a `SyncPoisonPill` event is emitted. This prevents one bad record from blocking the entire queue.

---

## Pull path (delta sync)

`pullAll()` pulls remote changes for all registered tables:

```
1. remote.getRemoteTimestamps()     →  { table: lastModified } for each table
2. For each registered table:
   ├─ Compare remote timestamp vs local timestamp
   ├─ Skip if remote <= local (no changes)
   └─ _pullTable(table, localTimestamp)
3. _pullTable():
   a. remote.pullSince(table, since)  →  Fetch rows changed since timestamp
   b. For each row:
      ├─ RLS check: skip if row's user_id doesn't match engine's userId
      ├─ Conflict check: if row ID is in pending queue, resolve conflict
      └─ local.upsert(table, id, row)
   c. timestamps.set(table, now)
   d. Emit SyncPullComplete
```

**Smart sync gate:** Step 1 is a single lightweight call. If no tables have changed remotely, no data is pulled at all. This makes "check for updates" almost free.

---

## Conflict resolution

When a pulled row has the same ID as a pending local entry, the engine resolves the conflict based on `config.conflictStrategy`:

| Strategy | Behavior |
|---|---|
| `lastWriteWins` | Compare `updated_at` timestamps. Newer version wins. Falls back to `serverWins` if timestamps are missing. |
| `serverWins` | Remote version always wins. |
| `clientWins` | Local version always wins. |
| `custom` | Delegates to `config.onConflict(table, id, local, remote)` callback. |

Special case: **DELETE vs UPDATE.** If the local pending entry is a delete operation, the delete always wins regardless of strategy. The remote update is discarded.

After resolution:
- A `SyncConflict` event is emitted with both versions and the winner.
- The winner is upserted locally.
- If the server won, local queue entries for that record are deleted.

---

## Runtime table management

Tables can be added or removed after the engine is created:

```dart
await engine.addTable('categories');          // registers + pulls immediately
await engine.addTable('tags', pull: false);   // registers only
engine.removeTable('deprecated');             // stops syncing
```

`addTable()` returns `false` if the table is already registered. `removeTable()` returns `false` if the table was not registered.

---

## Security gates

The engine enforces multiple security layers:

### 1. PII masking

Fields listed in `config.sensitiveFields` are replaced with `[REDACTED]` in `_maskPayload()`. This runs before any write to queue, local store, or remote. Error logs via `onError` also receive masked payloads.

### 2. Row-Level Security (RLS)

**On write:** If `userId` is set and the payload contains `user_id` or `owner_id` that doesn't match, the write is rejected with an exception containing `[RLS_Bypass]`.

**On pull:** If a pulled row has `user_id` or `owner_id` that doesn't match the engine's `userId`, the row is skipped and a `SyncError` with `RlsViolationException` is emitted.

### 3. Payload size validation

Payloads are JSON-encoded and measured in bytes. If the size exceeds `config.maxPayloadBytes` (default 1 MB), a `PayloadTooLargeException` is thrown before any write occurs.

### 4. Auth expiry handling

When any remote operation throws `AuthExpiredException`, the engine:
- Stops the current drain immediately
- Emits a `SyncAuthRequired` event
- Does not retry (avoids infinite auth loops)

The app is expected to listen for `SyncAuthRequired` and trigger re-authentication.

---

## Event stream

`engine.events` is a broadcast `Stream<SyncEvent>`. Events are emitted for every significant operation:

| Event | Emitted when |
|---|---|
| `SyncDrainComplete` | `drain()` finishes (even if no entries were pending) |
| `SyncPullComplete` | A table's pull completes (includes `rowCount`) |
| `SyncAuthRequired` | Auth token expired during sync |
| `SyncConflict` | A conflict was resolved (includes both versions) |
| `SyncPoisonPill` | An entry was permanently dropped after max retries |
| `SyncRetryScheduled` | A failed entry was scheduled for backoff retry |
| `SyncError` | A non-fatal error occurred during sync |

Events are delivered as microtasks. If you need to assert on events immediately after an async operation, yield with `await Future<void>.delayed(Duration.zero)`.

---

## Logout and session isolation

`logout()` performs a full wipe:

```dart
await queue.clearAll();           // delete all pending and synced entries
await local.clearAll(tables);     // delete all local data for registered tables
for (final table in tables) {
  await timestamps.set(table, epoch);  // reset to 1970-01-01
}
```

This ensures that when a different user logs in on the same device, they start with a completely clean state. No data from the previous session survives in queue, local storage, or timestamps.

---

## Isolate support

`IsolateSyncEngine` wraps a `SyncEngine` and runs `syncAll()` in a background isolate:

```dart
final bg = IsolateSyncEngine(engine);
await bg.syncAllInBackground();
```

This keeps the UI thread free during heavy sync operations.

---

*Architecture by [dynos.fit](https://dynos.fit)*
