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
}
