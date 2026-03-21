import 'package:supabase/supabase.dart';
import '../remote_store.dart';
import '../sync_operation.dart';

/// [RemoteStore] implementation using Supabase Postgrest.
///
/// Pushes records via `.upsert()` / `.delete()` and pulls via
/// `.select().gt('updated_at', since)`.
///
/// ## Smart Sync Gate
///
/// For the sync gate to work, your Supabase project needs a
/// `sync_status` table with one row per user and a `timestamptz` column
/// per synced table (e.g., `users_at`, `tasks_at`).
///
/// These columns should be maintained by Supabase triggers.
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
  ///   Example: `{'tasks': 'tasks_at', 'notes': 'notes_at'}`.
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
      // Rethrow so SyncEngine can catch and route to onError,
      // avoiding a silent fallback to expensive full-syncs.
      rethrow;
    }
  }
}
