/// Interface for persisting per-table sync timestamps locally.
///
/// Used to track when each table was last synced, so delta pulls
/// only fetch what changed.
abstract class TimestampStore {
  /// Get the last sync time for a table. Returns epoch if never synced.
  Future<DateTime> get(String table);

  /// Save the sync time for a table.
  Future<void> set(String table, DateTime timestamp);
}

/// In-memory timestamp store.
///
/// **WARNING:** Do not use this in production! It resets on app launch,
/// which will cause a full data pull (`pullSince` from epoch) every time.
/// Use [DriftTimestampStore] or implement your own persistent store.
class InMemoryTimestampStore implements TimestampStore {
  final _timestamps = <String, DateTime>{};

  @override
  Future<DateTime> get(String table) async =>
      _timestamps[table] ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  @override
  Future<void> set(String table, DateTime timestamp) async =>
      _timestamps[table] = timestamp;
}
