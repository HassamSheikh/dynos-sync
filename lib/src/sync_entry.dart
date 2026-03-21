import 'sync_operation.dart';

/// A single queued sync operation waiting to be pushed to the remote.
class SyncEntry {
  const SyncEntry({
    required this.id,
    required this.table,
    required this.recordId,
    required this.operation,
    required this.payload,
    required this.createdAt,
    this.syncedAt,
    this.retryCount = 0,
  });

  final String id;
  final String table;
  final String recordId;
  final SyncOperation operation;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final DateTime? syncedAt;
  final int retryCount;

  bool get isPending => syncedAt == null;
}
