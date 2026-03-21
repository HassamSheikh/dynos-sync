import 'package:dynos_sync/dynos_sync.dart';
import 'package:supabase/supabase.dart';

/// [RemoteStore] implementation using Supabase Postgrest.
///
/// Pushes records via `.upsert()` / `.delete()` and pulls via
/// `.select().gt('updated_at', since)`.
///
/// ## Sync Status Table
///
/// For the smart sync gate to work, your Supabase project needs a
/// `sync_status` table with one row per user and a `timestamptz` column
/// per synced table (e.g., `users_at`, `tasks_at`, `notes_at`).
///
/// These columns should be maintained by Supabase triggers that update
/// the timestamp whenever a row in the corresponding table changes.
///
/// If you don't have a `sync_status` table, [getRemoteTimestamps] returns
/// an empty map and all tables will be pulled on every sync.
class SupabaseRemoteStore implements RemoteStore {
  /// Creates a Supabase remote store.
  ///
  /// - [client]: Your Supabase client instance.
  /// - [userId]: Callback that returns the current authenticated user's ID.
  ///   Called on every sync cycle so it stays fresh across sign-out/sign-in.
  /// - [syncStatusTable]: Name of the sync status table (default: `sync_status`).
  /// - [tableTimestampKeys]: Maps table names to their `sync_status` column names.
  ///   Example: `{'users': 'users_at', 'tasks': 'tasks_at'}`.
  ///   Tables not in this map won't use the smart sync gate.
  const SupabaseRemoteStore({
    required this.client,
    required this.userId,
    this.syncStatusTable = 'sync_status',
    this.tableTimestampKeys = const {},
  });

  final SupabaseClient client;
  /// Returns the current user ID. Called per sync cycle to handle
  /// session expiry and account switches.
  final String Function() userId;
  final String syncStatusTable;

  /// Maps table names to their corresponding column in [syncStatusTable].
  final Map<String, String> tableTimestampKeys;

  @override
  Future<void> push(
    String table,
    String id,
    SyncOperation operation,
    Map<String, dynamic> data,
  ) async {
    switch (operation) {
      case SyncOperation.upsert:
        await client.from(table).upsert(data);
      case SyncOperation.delete:
        await client.from(table).delete().eq('id', id);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> pullSince(
    String table,
    DateTime since,
  ) async {
    final rows = await client
        .from(table)
        .select()
        .gt('updated_at', since.toIso8601String());
    return List<Map<String, dynamic>>.from(rows);
  }

  @override
  Future<Map<String, DateTime>> getRemoteTimestamps() async {
    if (tableTimestampKeys.isEmpty) return {};

    try {
      final rows = await client
          .from(syncStatusTable)
          .select()
          .eq('user_id', userId());

      if (rows.isEmpty) return {};

      final row = rows.first;
      final result = <String, DateTime>{};

      for (final entry in tableTimestampKeys.entries) {
        final value = row[entry.value];
        if (value != null) {
          result[entry.key] = DateTime.parse(value.toString()).toUtc();
        }
      }

      return result;
    } catch (e) {
      // Let exceptions bubble up so the SyncEngine can catch and log them,
      // avoiding a silent fallback to full-syncs.
      rethrow;
    }
  }
}
