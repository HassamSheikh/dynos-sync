# CHANGELOG

## 0.1.5 (2026-03-22)
*   **Patch operation**: Added `SyncOperation.patch` for partial updates. Sends UPDATE instead of upsert, avoiding NOT NULL constraint failures when only a few fields change.
*   Updated `SupabaseRemoteStore` to handle patch in both `push()` and `pushBatch()`.

## 0.1.4 (2026-03-22)
*   **100% dartdoc coverage**: Added documentation comments to all 225 public API elements.

## 0.1.3 (2026-03-22)
*   **Runtime table management**: `addTable()` and `removeTable()` allow registering/unregistering sync tables after engine creation.
*   **130-test security audit**: Comprehensive audit across 12 categories (HIPAA, GDPR, OWASP Mobile Top 10, injection, flood testing, chaos engineering, conflict resolution, race conditions, denial of service).
*   **Updated documentation**: README rewritten with complete API reference. Architecture and security docs rewritten for developers.

## 0.1.2 (2026-03-21) - Global Open Source Milestone
*   **License Shift**: Transitioned from BSL-1.1 to **MIT License** for unrestricted public use.
*   **Score Optimization**: Now achieving **100/100 Points** on pub.dev.

## 0.1.1 (2026-03-21)
*   **Corrected Metadata**: Finalized hyphenated repository URL for pub.dev analysis.
*   **Performance Stability**: Verified 50k+ writes/sec ingestion.

## 0.1.0 (2026-03-21)

Initial Public Release.
*   **Production-Hardened Engine**: Subjected to a 42-point security audit.
*   **High-Scale Ingestion**: High-performance local writes (50k+ writes/sec).
*   **Advanced Privacy**: Built-in PII redaction and secure session purging.
*   **Background Efficiency**: Full support for dedicated Background Isolates.
