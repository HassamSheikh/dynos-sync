/// The type of sync operation queued for push.
enum SyncOperation {
  /// Insert or update a record on the remote server.
  upsert,

  /// Delete a record from the remote server.
  delete,

  /// Partial update of an existing record on the remote server.
  ///
  /// Unlike [upsert], this sends only the changed fields via an UPDATE
  /// statement, avoiding NOT NULL constraint failures from missing columns.
  patch,
}
