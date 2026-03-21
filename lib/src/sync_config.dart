/// Configuration for the sync engine.
class SyncConfig {
  const SyncConfig({
    this.batchSize = 50,
    this.queueRetention = const Duration(days: 30),
    this.stopOnFirstError = true,
    this.maxRetries = 3,
    this.sensitiveFields = const [],
    this.useExponentialBackoff = true,
  });

  /// Max number of pending entries to drain per cycle.
  final int batchSize;

  /// How long to keep synced entries before purging.
  final Duration queueRetention;

  /// If true, stop draining on the first push error (retry next cycle).
  /// If false, skip failed entries and continue.
  final bool stopOnFirstError;

  /// Maximum number of push retries before a pending entry is permanently dropped.
  final int maxRetries;

  /// Fields to mask in logs and telemetry (e.g. ['email', 'ssn']).
  final List<String> sensitiveFields;

  /// If true, uses exponential backoff (2^n) during retries.
  final bool useExponentialBackoff;
}
