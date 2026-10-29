import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:den_core/den_core.dart';
import 'package:web/web.dart' as web;

/// Browsers keep the change log and this device's metadata in IndexedDB, so Den opens from the
/// Home Screen with the family already there and catches up with the hub after the first frame.
/// Where IndexedDB is unavailable (some private windows), the family lives in memory for the
/// visit and comes back from the hub; the device then joins again with fresh keys (see Boot).
/// The first family's database is `den`; each other family's is `den-<id>` ([name]).
Future<DenStorage> openDeviceStorage({String name = 'den'}) async {
  try {
    return await IndexedDbStorage.open(name: name);
  } on Object {
    return MemoryStorage();
  }
}

/// Deletes the database [name]: a family this device left. A connection still open to it (this
/// page's own engine) lets go when asked ([IndexedDbStorage.open] closes on `versionchange`).
Future<void> deleteDeviceStorage(String name) => IndexedDbStorage.delete(name);

/// [DenStorage] on IndexedDB: database `den`, object store `changes` (each change's JSON keyed
/// by its id, so storing one twice keeps one) and `meta` (one JSON document under `meta`, and the
/// engine's snapshot, which Den opens from instead of replaying the log, under `snapshot`).
/// Every write waits for its transaction to complete, which is IndexedDB's durability promise.
/// Transactions over the same stores run in the order they were made, so reads see every write
/// made before them without a lock of our own.
class IndexedDbStorage implements DenStorage, SnapshotStorage {
  IndexedDbStorage._(this._db);

  final web.IDBDatabase _db;

  static const _changes = 'changes';
  static const _meta = 'meta';
  static const _metaKey = 'meta';
  static const _snapshotKey = 'snapshot';

  /// Opens (creating on first use) the database [name]. Safari's first open on a fresh
  /// install has been seen to never answer, so a slow open is tried once more.
  static Future<IndexedDbStorage> open({String name = 'den'}) async {
    web.IDBDatabase db;
    try {
      db = await _open(name).timeout(const Duration(seconds: 4));
    } on TimeoutException {
      db = await _open(name).timeout(const Duration(seconds: 8));
    }
    // Another tab upgrading the database asks this one to let go.
    db.onversionchange = ((web.Event _) => db.close()).toJS;
    return IndexedDbStorage._(db);
  }

  static Future<web.IDBDatabase> _open(String name) {
    final request = web.window.indexedDB.open(name, 1);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_changes)) db.createObjectStore(_changes);
      if (!db.objectStoreNames.contains(_meta)) db.createObjectStore(_meta);
    }).toJS;
    return _result(request).then((result) => result as web.IDBDatabase);
  }

  /// Closes the database, for tests that open it again.
  void close() => _db.close();

  /// Deletes the database [name], waiting until it is gone (or the browser refused).
  static Future<void> delete(String name) {
    final done = Completer<void>();
    final request = web.window.indexedDB.deleteDatabase(name);
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    request.onerror = ((web.Event event) {
      event.preventDefault();
      if (!done.isCompleted) done.completeError(StateError(request.error?.message ?? "IndexedDB couldn't delete $name"));
    }).toJS;
    return done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }

  @override
  Future<List<Change>> loadChanges() async {
    final tx = _db.transaction(_changes.toJS, 'readonly');
    final raw = (await _result(tx.objectStore(_changes).getAll())).dartify();
    final changes = <Change>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! String) continue;
        try {
          final json = jsonDecode(item);
          if (json is Map) changes.add(Change.fromJson(json.cast<String, Object?>()));
        } on Object {
          // A record that doesn't read back is skipped; the hub still has it.
        }
      }
    }
    return changes;
  }

  @override
  Future<void> appendChanges(List<Change> changes) async {
    if (changes.isEmpty) return;
    final tx = _db.transaction(_changes.toJS, 'readwrite', web.IDBTransactionOptions(durability: 'strict'));
    final store = tx.objectStore(_changes);
    for (final c in changes) {
      store.put(jsonEncode(c.toJson()).toJS, c.id.toJS);
    }
    await _complete(tx);
  }

  @override
  Future<Map<String, Object?>?> loadMeta() async {
    final tx = _db.transaction(_meta.toJS, 'readonly');
    final raw = (await _result(tx.objectStore(_meta).get(_metaKey.toJS))).dartify();
    if (raw is! String) return null;
    try {
      final json = jsonDecode(raw);
      return json is Map ? json.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveMeta(Map<String, Object?> meta) async {
    final tx = _db.transaction(_meta.toJS, 'readwrite', web.IDBTransactionOptions(durability: 'strict'));
    tx.objectStore(_meta).put(jsonEncode(meta).toJS, _metaKey.toJS);
    await _complete(tx);
  }

  @override
  Future<String?> loadSnapshot() async {
    final tx = _db.transaction(_meta.toJS, 'readonly');
    final raw = (await _result(tx.objectStore(_meta).get(_snapshotKey.toJS))).dartify();
    return raw is String ? raw : null;
  }

  /// One put, so a write cut short leaves the old snapshot. Not `strict`: a snapshot lost to a
  /// crash only means the next open replays more of the log.
  @override
  Future<void> saveSnapshot(String snapshot) async {
    final tx = _db.transaction(_meta.toJS, 'readwrite');
    tx.objectStore(_meta).put(snapshot.toJS, _snapshotKey.toJS);
    await _complete(tx);
  }

  @override
  Future<void> clear() async {
    final tx = _db.transaction([_changes.toJS, _meta.toJS].toJS, 'readwrite');
    tx.objectStore(_changes).clear();
    tx.objectStore(_meta).clear();
    await _complete(tx);
  }

  static Future<JSAny?> _result(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event event) {
      // Handled here, so the failure doesn't also abort the transaction as an uncaught error.
      event.preventDefault();
      if (!done.isCompleted) done.completeError(StateError(request.error?.message ?? 'IndexedDB refused a request'));
    }).toJS;
    return done.future;
  }

  static Future<void> _complete(web.IDBTransaction tx) {
    final done = Completer<void>();
    void failed(web.Event _) {
      if (!done.isCompleted) done.completeError(StateError(tx.error?.message ?? "IndexedDB couldn't save"));
    }

    tx.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onerror = failed.toJS;
    tx.onabort = failed.toJS;
    return done.future;
  }
}
