/// A local-first, offline-capable sync engine.
///
/// Backend and database agnostic — implement [LocalStore], [RemoteStore],
/// and [QueueStore] for your stack, or use the provided Drift and Supabase
/// adapters.
///
/// ```dart
/// import 'package:dynos_sync/dynos_sync.dart';           // core
/// import 'package:dynos_sync/drift.dart';                 // Drift adapters
/// import 'package:dynos_sync/supabase.dart';              // Supabase adapter
/// ```
library dynos_sync;

export 'src/sync_engine.dart';
export 'src/local_store.dart';
export 'src/remote_store.dart';
export 'src/queue_store.dart';
export 'src/sync_entry.dart';
export 'src/sync_operation.dart';
export 'src/sync_config.dart';
export 'src/timestamp_store.dart';
export 'src/isolate_sync_engine.dart';
