# Security Audit Report

`dynos_sync` is subjected to a **130-test security audit** across 12 categories before every release. This document describes what is tested and why.

Test file: [`test/dynos_sync_total_audit_test.dart`](../test/dynos_sync_total_audit_test.dart)

---

## Audit summary

| Category | Tests | Severity coverage |
|---|---|---|
| 1. HIPAA & Health Data Compliance | 1--12 | 6 CRITICAL, 3 HIGH, 2 MEDIUM, 1 LOW |
| 2. Data Leak Testing | 13--25 | 2 CRITICAL, 4 HIGH, 4 MEDIUM, 3 LOW |
| 3. Injection & Input Validation | 26--37 | 2 CRITICAL, 4 HIGH, 5 MEDIUM, 1 LOW |
| 4. Authentication & Authorization | 38--47 | 4 CRITICAL, 2 HIGH, 2 MEDIUM, 2 LOW |
| 5. Conflict Resolution Integrity | 48--56 | 3 CRITICAL, 3 HIGH, 2 MEDIUM, 1 LOW |
| 6. Flood Testing & Performance | 57--75 | 3 CRITICAL, 5 HIGH, 7 MEDIUM, 4 LOW |
| 7. Cryptographic Validation | 76--83 | Structural (engine delegates crypto) |
| 8. Race Conditions & Concurrency | 84--91 | 2 CRITICAL, 3 HIGH, 2 MEDIUM, 1 LOW |
| 9. Chaos Engineering & Edge Cases | 92--107 | 4 CRITICAL, 4 HIGH, 6 MEDIUM, 2 LOW |
| 10. Denial of Service & Abuse | 108--114 | 1 CRITICAL, 3 HIGH, 2 MEDIUM, 1 LOW |
| 11. OWASP Mobile Top 10 | 115--124 | Maps to OWASP M1--M10 |
| 12. GDPR & Data Sovereignty | 125--130 | 2 CRITICAL, 2 HIGH, 1 MEDIUM, 1 LOW |

**Total: 130 tests, 0 failures required for release.**

---

## Category details

### 1. HIPAA & Health Data Compliance (Tests 1--12)

Tests that the engine can safely handle protected health information:

- **PII masking** -- `sensitiveFields` are replaced with `[REDACTED]` before any data reaches the queue, local store, remote, or error logs
- **Audit trail** -- the event stream emits typed events for every push, pull, conflict, and deletion
- **Data retention** -- `logout()` destroys all user data across queue, local store, and timestamps
- **Session timeout** -- `AuthExpiredException` surfaces a `SyncAuthRequired` event for re-auth
- **De-identification** -- up to 18 HIPAA Safe Harbor identifiers can be masked via `sensitiveFields`
- **Structural** -- engine has no filesystem access, no UI widgets, no temp files (delegates to stores)

### 2. Data Leak Testing (Tests 13--25)

Tests every channel through which data could escape:

- **Cross-user isolation** -- after logout, zero records from the previous user exist in queue, local store, or timestamps. Drain after logout pushes zero records.
- **Payload inspection** -- pushed payloads contain only user-provided fields, no device metadata injected
- **Error log scrubbing** -- `onError` callbacks receive masked payloads, never raw sensitive values
- **Event masking** -- `SyncPoisonPill` and `SyncError` events contain masked payloads when `sensitiveFields` is configured
- **Structural** -- engine uses no SharedPreferences, no MethodChannel, no clipboard, no Realtime subscriptions

### 3. Injection & Input Validation (Tests 26--37)

Tests that malicious input cannot exploit the engine:

- **SQL injection** -- 7 injection vectors (`'; DROP TABLE`, `UNION SELECT`, `OR '1'='1'`, etc.) stored as literal strings
- **NoSQL injection** -- `$gt`, `$ne`, `$regex`, `$where` operator patterns stored as literal map keys
- **XSS** -- `<script>`, `<img onerror>`, `<svg onload>`, `javascript:` URIs stored verbatim (engine doesn't render)
- **Path traversal** -- `../../../etc/passwd`, UNC paths, URL-encoded traversals stored as literals
- **Oversized payloads** -- 50MB payload triggers `PayloadTooLargeException`
- **Null bytes** -- survive round-trip through queue and local store
- **Unicode** -- emoji, RTL, ZWJ sequences, combining marks, surrogate pairs survive JSON round-trip
- **Integer overflow** -- max/min int64 values stored correctly (Dart uses 64-bit integers)
- **Deep nesting** -- 100 levels of nested JSON handled without stack overflow
- **Malformed server response** -- `FormatException` emits `SyncError`, doesn't crash

### 4. Authentication & Authorization (Tests 38--47)

Tests auth boundaries:

- **Token expiry mid-drain** -- `AuthExpiredException` stops drain, emits `SyncAuthRequired`, preserves remaining entries
- **RLS enforcement** -- write with mismatched `user_id`/`owner_id` throws `[RLS_Bypass]` exception
- **RLS on pull** -- pulled rows with wrong `user_id` are skipped with `RlsViolationException`
- **Drain lock** -- prevents concurrent drain calls (acts as rate limiter)
- **No infinite retry** -- auth failures stop immediately, don't loop
- **Post-logout purge** -- queue, local data, and timestamps all wiped
- **Privilege escalation** -- `sensitiveFields` can mask fields like `isAdmin`, `role`, `permissions`

### 5. Conflict Resolution Integrity (Tests 48--56)

Tests that conflicts never silently destroy data:

- **LWW correctness** -- both directions tested (remote newer wins, local newer wins)
- **DELETE vs UPDATE** -- local delete always wins over remote update
- **Server-wins / Client-wins** -- explicitly tested strategies
- **Custom resolver** -- `onConflict` callback receives both versions, returned value is used
- **Rapid-fire conflicts** -- 100 conflicting updates to the same record resolved deterministically
- **Conflict events** -- `SyncConflict` event carries `localVersion`, `remoteVersion`, `resolvedVersion`, `strategyUsed`
- **No-timestamp fallback** -- when `updated_at` is missing, falls back to `serverWins`

### 6. Flood Testing & Performance (Tests 57--75)

Stress tests at 10x-1000x expected load:

- **10K write throughput** -- completes in < 5 seconds
- **100K write throughput** -- completes without OOM
- **Drain throughput** -- 1K/10K/50K queue drain completes
- **Memory bounded** -- 100 write-drain cycles don't accumulate unbounded queue entries
- **Drain lock under pressure** -- 100+ concurrent drain calls, lock prevents overlap
- **Concurrent writes during sync** -- no data corruption when writing while draining
- **Exponential backoff** -- delays verified to increase (2s, 4s, 8s...) with cap
- **Timeout handling** -- remote timeouts handled gracefully, no hang

### 7. Cryptographic Validation (Tests 76--83)

Structural tests confirming that cryptographic concerns are delegated:

- Engine has no encryption implementation -- delegates to `LocalStore` (SQLCipher), `RemoteStore` (HTTPS)
- No API keys, secrets, or credentials in engine code
- No token comparison (no timing attack surface)
- TLS enforcement delegated to HTTP client in `RemoteStore`

### 8. Race Conditions & Concurrency (Tests 84--91)

- **Double-drain prevention** -- drain lock is a boolean flag, second call returns immediately
- **Atomic write ordering** -- `_enqueue()` runs before `local.upsert()`
- **Event stream safety** -- broadcast stream supports multiple listeners
- **Subscription cleanup** -- `dispose()` closes the stream controller
- **No deadlock** -- drain lock is a simple boolean, not a mutex

### 9. Chaos Engineering & Edge Cases (Tests 92--107)

Production failure scenarios:

- **App killed mid-sync** -- queue entry survives remote failure
- **Empty server response** -- engine handles gracefully, emits `SyncPullComplete` with `rowCount: 0`
- **Disk full** -- `ThrowingLocalStore` surfaces error, queue entry preserved
- **UTC timestamps** -- all `SyncEntry.createdAt` timestamps are UTC
- **30-day offline** -- 1500 queued records all drain when connectivity returns
- **Extra/missing remote fields** -- engine upserts whatever the remote returns
- **Partial batch failure** -- batch fails, fallback to individual push, some succeed
- **Year 2038** -- Dart `DateTime` is 64-bit, no overflow
- **Leap second** -- engine doesn't crash on edge-case timestamps

### 10. Denial of Service & Abuse (Tests 108--114)

- **No sync loops** -- `pullAll()` doesn't enqueue, so pull-push cycles can't loop
- **Queue bomb** -- drain processes only `batchSize` per call, not the entire queue
- **Rapid login/logout** -- 1000 cycles, queue clears each time, no resource leak
- **Stale workers** -- `dispose()` closes the event stream, no further events
- **Payload limits** -- `maxPayloadBytes` enforced before any write

### 11. OWASP Mobile Top 10 (Tests 115--124)

Explicit mapping to OWASP Mobile Top 10 (2024):

| OWASP | Engine posture |
|---|---|
| M1 -- Credential Storage | Engine stores no credentials. Delegates to secure storage. |
| M2 -- Supply Chain | 4 dependencies: `uuid`, `meta`, `drift`, `supabase` |
| M3 -- Authentication | No passwords stored. Uses opaque `userId`. |
| M4 -- Input Validation | Payload passed through as `Map<String,dynamic>`, validated by `jsonEncode` |
| M5 -- Communication | Delegated to `RemoteStore` (Supabase uses HTTPS) |
| M6 -- Privacy | `sensitiveFields` provides selective masking |
| M7 -- Binary Protections | No secrets in source code |
| M8 -- Security Defaults | Default config: empty sensitiveFields, 1MB payload limit, 3 retries |
| M9 -- Data Storage | Delegated to `LocalStore`, no direct filesystem access |
| M10 -- Cryptography | Delegated to stores and HTTP client |

### 12. GDPR & Data Sovereignty (Tests 125--130)

- **Right to Erasure (Art. 17)** -- `logout()` destroys all data across queue, local, timestamps
- **Data portability (Art. 20)** -- data readable via `LocalStore` and `QueueStore` interfaces
- **Data minimization** -- `sensitiveFields` masks unnecessary fields before sync
- **Consent tracking** -- `addTable()` enables progressive table registration as consent is granted
- **Data residency** -- `RemoteStore` endpoint is configurable per region
- **Transfer logging** -- event stream provides audit trail for all sync operations

---

## Pass criteria

Every release must:

1. Pass all 130 tests in `test/dynos_sync_total_audit_test.dart`
2. Pass all existing tests (66 tests across 7 other test files)
3. Zero `dart analyze` errors or warnings
4. Verified compatibility with Drift and Supabase adapters

---

*Secured by [dynos.fit](https://dynos.fit)*
