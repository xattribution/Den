import 'change.dart';

/// Where a device keeps its change log and its private metadata (family id, change counter,
/// space keys). Device signing keys are stored by the app in the platform keychain, not here.
abstract class DenStorage {
  /// Every change this device holds, in any order.
  Future<List<Change>> loadChanges();

  /// Appends changes durably before returning.
  Future<void> appendChanges(List<Change> changes);

  /// Device-private metadata, or null on first run.
  Future<Map<String, Object?>?> loadMeta();

  Future<void> saveMeta(Map<String, Object?> meta);

  /// Removes every change and the metadata, as when a device leaves its family.
  Future<void> clear();
}

/// Storage that also keeps a snapshot: what the change log materializes to, which [Den.open]
/// starts from instead of replaying every change. Den writes it now and then as the log grows
/// and owns its format: a snapshot it can't use (another format, damaged, or not matching the
/// log) is ignored and written again. [DenStorage.clear] removes it with everything else.
///
/// Persistent storage implements this; [MemoryStorage] doesn't, since nothing outlives it.
abstract interface class SnapshotStorage {
  /// The snapshot last saved, or null.
  Future<String?> loadSnapshot();

  /// Replaces the snapshot. A crash part way leaves the old one or the new one, never a mix; a
  /// lost snapshot only means the next open replays the log.
  Future<void> saveSnapshot(String snapshot);
}

/// In-memory storage for tests and browsers that sync on load.
class MemoryStorage implements DenStorage {
  final List<Change> _changes = [];
  Map<String, Object?>? _meta;

  @override
  Future<List<Change>> loadChanges() async => List.of(_changes);

  @override
  Future<void> appendChanges(List<Change> changes) async => _changes.addAll(changes);

  @override
  Future<Map<String, Object?>?> loadMeta() async => _meta == null ? null : Map.of(_meta!);

  @override
  Future<void> saveMeta(Map<String, Object?> meta) async => _meta = Map.of(meta);

  @override
  Future<void> clear() async {
    _changes.clear();
    _meta = null;
  }
}
