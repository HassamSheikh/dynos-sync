/// # dynos_sync — Complete Example
///
/// This example shows how to set up dynos_sync with Drift + Supabase
/// in a typical Flutter app.

// ignore_for_file: unused_local_variable

import 'package:dynos_sync/dynos_sync.dart';

// ─── Step 1: Define your Drift database ─────────────────────────────────────
//
// Add DynosSyncQueueTable and DynosSyncTimestampsTable to your database:
//
//   @DriftDatabase(tables: [
//     TasksTable,
//     NotesTable,
//     DynosSyncQueueTable,      // ← add this
//     DynosSyncTimestampsTable,  // ← add this
//   ])
//   class AppDatabase extends _$AppDatabase { ... }

// ─── Step 2: Create the sync engine (once at app start) ─────────────────────

SyncEngine createSyncEngine({
  required LocalStore local,
  required RemoteStore remote,
  required QueueStore queue,
  required TimestampStore timestamps,
}) {
  return SyncEngine(
    local: local,
    remote: remote,
    queue: queue,
    timestamps: timestamps,
    tables: ['tasks', 'notes', 'categories'],
    config: const SyncConfig(
      batchSize: 50,
      queueRetention: Duration(days: 30),
      stopOnFirstError: true,
      maxRetries: 3,
      sensitiveFields: ['ssn', 'password'], // 🛡️ [NEW] mask PII in error logs
      useExponentialBackoff: true, // 📶 [NEW] 2, 4, 8s retry delay
    ),
    onError: (error, stack, context) {
      print('Sync error [$context]: $error');
    },
  );
}

// ─── Step 3: Usage patterns ─────────────────────────────────────────────────

/// Pattern A: Let dynos_sync handle both local write and sync
Future<void> createTask(SyncEngine sync, String id, String title) async {
  await sync.write('tasks', id, {
    'id': id,
    'title': title,
    'done': false,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });
  // Done! Written locally + queued for remote push.
}

/// Pattern B: Write to your own DAO, then push via dynos_sync
Future<void> createTaskViaDao(
    SyncEngine sync, Map<String, dynamic> task) async {
  // Your own DAO handles the local write:
  // await db.taskDao.save(Task.fromJson(task));

  // Then just queue the remote push:
  await sync.push('tasks', task['id'] as String, task);
}

/// Pattern C: Delete a record
Future<void> deleteTask(SyncEngine sync, String id) async {
  await sync.remove('tasks', id);
  // Deleted locally + queued for remote deletion.
}

// ─── Step 4: App lifecycle ──────────────────────────────────────────────────

/// Call on app launch (e.g., in splash screen)
Future<void> onAppLaunch(SyncEngine sync) async {
  // This drains pending writes + pulls remote changes.
  // First call: pulls everything. Subsequent calls: only what changed.
  await sync.syncAll();
}

/// Call in splash screen to wait for data before showing home
Future<void> splashScreenWait(SyncEngine sync) async {
  await sync.initialSyncDone;
  // Safe to navigate to home — local DB is populated.
}

/// Call on pull-to-refresh
Future<void> onRefresh(SyncEngine sync) async {
  await sync.drain();
  await sync.pullAll();
}

// ─── Step 5: Session Termination ────────────────────────────────────────────

/// Call when the user logs out.
///
/// **CRITICAL SECURITY STEP:** This purges the local sync queue and resets
/// timestamps to ensure User A's data doesn't leak into User B's session.
Future<void> onUserLogout(SyncEngine sync) async {
  await sync.logout();
}

// ─── Step 6: Runtime Table Registration ──────────────────────────────────────

/// Add tables to sync after engine is already running.
/// Useful for progressive consent or feature flags.
Future<void> registerNewTable(SyncEngine sync) async {
  // Register and immediately pull remote data
  await sync.addTable('categories');

  // Register without pulling (will pull on next syncAll)
  await sync.addTable('tags', pull: false);

  // Stop syncing a table
  sync.removeTable('deprecated_table');
}

// ─── Step 7: Background Isolate Offloading ──────────────────────────────────

/// For massive datasets (10k+ rows), run the sync in a background isolate.
/// This ensures the primary UI thread remains silky smooth (60/120 FPS).
Future<void> runHeavySync(SyncEngine sync) async {
  final hardened = IsolateSyncEngine(sync);
  await hardened.syncAllInBackground();
}

// ─── Full setup with Drift + Supabase ───────────────────────────────────────
//
// import 'package:dynos_sync_drift/dynos_sync_drift.dart';
// import 'package:dynos_sync_supabase/dynos_sync_supabase.dart';
//
// final db = AppDatabase();
// final client = Supabase.instance.client;
//
// final sync = SyncEngine(
//   local: DriftLocalStore(db),
//   remote: SupabaseRemoteStore(
//     client: client,
//     userId: client.auth.currentUser!.id,
//     tableTimestampKeys: {
//       'tasks': 'tasks_at',
//       'notes': 'notes_at',
//       'categories': 'categories_at',
//     },
//   ),
//   queue: DriftQueueStore(db),
//   timestamps: DriftTimestampStore(db),
//   tables: ['tasks', 'notes', 'categories'],
// );
//
// // In splash screen:
// await sync.syncAll();
// await sync.initialSyncDone;
// navigateToHome();

void main() {
  print('See code comments for usage examples.');
}
