import 'sync_operation.dart';
import 'sync_entry.dart';

/// Interface for the remote backend (Supabase, Firebase, custom REST, etc.).
///
/// Implement this to connect the sync engine to your server.
abstract class RemoteStore {
  /// Push a single record to the remote.
  Future<void> push(
    String table,
    String id,
    SyncOperation operation,
    Map<String, dynamic> data,
  );

  /// Push multiple records to the remote in optimized batches.
  ///
  /// The default implementation falls back to individual [push] calls.
  /// Override in backend-specific subclasses (e.g. [SupabaseRemoteStore])
  /// to use batch APIs for better performance.
  Future<void> pushBatch(List<SyncEntry> entries) async {
    for (final entry in entries) {
      await push(entry.table, entry.recordId, entry.operation, entry.payload);
    }
  }

  /// Pull all records from [table] updated after [since].
  ///
  /// Return an empty list if nothing changed.
  Future<List<Map<String, dynamic>>> pullSince(String table, DateTime since);

  /// Get the last-modified timestamp for each synced table from the remote.
  ///
  /// Used for the "smart sync gate" — compare remote timestamps against
  /// local timestamps to skip unchanged tables entirely.
  ///
  /// Return a map of `{ tableName: lastModified }`.
  /// Tables not present in the map will be pulled unconditionally.
  Future<Map<String, DateTime>> getRemoteTimestamps();
}
