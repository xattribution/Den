import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'config.dart';

/// An append the store refused because a cap was reached.
class StoreFull implements Exception {
  /// Creates the exception.
  StoreFull(this.reason);

  /// Which cap: `mailbox`, `mailboxes` or `relay`.
  final String reason;

  @override
  String toString() => 'StoreFull($reason)';
}

/// One blob read back.
class StoredBlob {
  /// Creates a blob view.
  const StoredBlob(this.cursor, this.bytes);

  /// The blob's cursor.
  final int cursor;

  /// The sealed bytes.
  final Uint8List bytes;
}

/// A page of blobs.
class MailboxSlice {
  /// Creates a page.
  const MailboxSlice(this.blobs, this.next, this.more);

  /// Blobs after the cursor asked for.
  final List<StoredBlob> blobs;

  /// The cursor to continue from.
  final int next;

  /// Whether more blobs remain.
  final bool more;
}

class _Entry {
  _Entry(this.cursor, this.created, this.offset, this.length);
  final int cursor;
  final int created;
  int offset;
  final int length;
}

class _Mailbox {
  _Mailbox(this.file);
  final File file;
  final List<_Entry> entries = [];
  int bytes = 0;
  int lastCursor = 0;
  Future<void> _tail = Future.value();

  Future<T> lock<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

const int _recordHeader = 8 + 8 + 4;

/// Mailboxes persisted under `<dataDir>/mailboxes/<id[0..2]>/<id>.box`, one append-only file
/// each: records of cursor (u64), creation time in ms (u64), length (u32), then the blob.
///
/// Cursors are `max(previous + 1, now_ms * 1000)`, so they keep increasing even after a
/// mailbox expires entirely and is created again. Blobs older than the TTL are swept by
/// rewriting the file without them.
class MailboxStore {
  /// Creates a store; call [open] before use.
  MailboxStore(this.config) : _root = Directory(p.join(config.dataDir, 'mailboxes'));

  /// Limits and clock.
  final RelayConfig config;

  final Directory _root;
  final Map<String, _Mailbox> _boxes = {};
  int _totalBytes = 0;

  /// Mailboxes held.
  int get mailboxCount => _boxes.length;

  /// Bytes held across every mailbox.
  int get totalBytes => _totalBytes;

  /// Loads every mailbox file, repairing a torn final record.
  Future<void> open() async {
    await _root.create(recursive: true);
    await for (final entity in _root.list(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.endsWith('.tmp')) {
        await entity.delete();
        continue;
      }
      if (!name.endsWith('.box')) continue;
      final id = name.substring(0, name.length - 4);
      final box = _Mailbox(entity);
      final raf = await entity.open();
      try {
        final length = await raf.length();
        var offset = 0;
        while (offset + _recordHeader <= length) {
          await raf.setPosition(offset);
          final header = await raf.read(_recordHeader);
          final data = ByteData.sublistView(header);
          final cursor = data.getUint64(0);
          final created = data.getUint64(8);
          final size = data.getUint32(16);
          if (offset + _recordHeader + size > length) break;
          box.entries.add(_Entry(cursor, created, offset + _recordHeader, size));
          box.bytes += size;
          box.lastCursor = cursor;
          offset += _recordHeader + size;
        }
        if (offset < length) {
          await raf.close();
          final w = await entity.open(mode: FileMode.append);
          await w.truncate(offset);
          await w.close();
        }
      } finally {
        try {
          await raf.close();
        } on FileSystemException {
          // Closed above after repairing.
        }
      }
      if (box.entries.isEmpty) {
        await entity.delete();
        continue;
      }
      _boxes[id] = box;
      _totalBytes += box.bytes;
    }
  }

  File _fileFor(String id) => File(p.join(_root.path, id.substring(0, 2), '$id.box'));

  /// Appends [blob] to mailbox [id] and returns its cursor. Throws [StoreFull] at a cap.
  Future<int> append(String id, List<int> blob) async {
    var box = _boxes[id];
    if (box == null) {
      if (_boxes.length >= config.maxMailboxes) throw StoreFull('mailboxes');
      box = _boxes[id] = _Mailbox(_fileFor(id));
    }
    final target = box;
    return target.lock(() async {
      if (target.entries.length >= config.maxMailboxEntries || target.bytes + blob.length > config.maxMailboxBytes) {
        throw StoreFull('mailbox');
      }
      if (_totalBytes + blob.length > config.maxTotalBytes) throw StoreFull('relay');
      final now = config.currentMillis();
      final cursor = target.lastCursor + 1 > now * 1000 ? target.lastCursor + 1 : now * 1000;
      final header = ByteData(_recordHeader)
        ..setUint64(0, cursor)
        ..setUint64(8, now)
        ..setUint32(16, blob.length);
      await target.file.parent.create(recursive: true);
      final raf = await target.file.open(mode: FileMode.append);
      final int offset;
      try {
        offset = await raf.length();
        await raf.writeFrom(header.buffer.asUint8List());
        await raf.writeFrom(blob);
        await raf.flush();
      } finally {
        await raf.close();
      }
      target.entries.add(_Entry(cursor, now, offset + _recordHeader, blob.length));
      target.bytes += blob.length;
      target.lastCursor = cursor;
      _totalBytes += blob.length;
      return cursor;
    }).whenComplete(() {
      if (target.entries.isEmpty && identical(_boxes[id], target)) _boxes.remove(id);
    });
  }

  /// Blobs in mailbox [id] after cursor [after], within the page limits.
  Future<MailboxSlice> read(String id, {int after = 0, int? limit}) async {
    final box = _boxes[id];
    if (box == null) return MailboxSlice(const [], after, false);
    return box.lock(() async {
      final maxEntries = (limit ?? config.readPageEntries).clamp(1, config.readPageEntries);
      final cutoff = config.currentMillis() - config.mailboxTtl.inMilliseconds;
      final pending = box.entries.where((e) => e.cursor > after && e.created >= cutoff).toList();
      final chosen = <_Entry>[];
      var bytes = 0;
      for (final e in pending) {
        if (chosen.length >= maxEntries) break;
        if (chosen.isNotEmpty && bytes + e.length > config.readPageBytes) break;
        chosen.add(e);
        bytes += e.length;
      }
      if (chosen.isEmpty) return MailboxSlice(const [], after, false);
      final raf = await box.file.open();
      try {
        final blobs = <StoredBlob>[];
        for (final e in chosen) {
          await raf.setPosition(e.offset);
          blobs.add(StoredBlob(e.cursor, await raf.read(e.length)));
        }
        return MailboxSlice(blobs, chosen.last.cursor, chosen.length < pending.length);
      } finally {
        await raf.close();
      }
    });
  }

  /// Removes blobs older than the TTL; returns how many were removed.
  Future<int> sweep() async {
    final cutoff = config.currentMillis() - config.mailboxTtl.inMilliseconds;
    var removed = 0;
    for (final entry in _boxes.entries.toList()) {
      final id = entry.key;
      final box = entry.value;
      removed += await box.lock(() async {
        final keep = box.entries.where((e) => e.created >= cutoff).toList();
        final dropped = box.entries.length - keep.length;
        if (dropped == 0) return 0;
        final droppedBytes = box.bytes - keep.fold<int>(0, (s, e) => s + e.length);
        if (keep.isEmpty) {
          if (await box.file.exists()) await box.file.delete();
          box.entries.clear();
          box.bytes = 0;
          _boxes.remove(id);
        } else {
          final tmp = File('${box.file.path}.tmp');
          final source = await box.file.open();
          final sink = await tmp.open(mode: FileMode.write);
          try {
            var offset = 0;
            for (final e in keep) {
              await source.setPosition(e.offset - _recordHeader);
              final record = await source.read(_recordHeader + e.length);
              await sink.writeFrom(record);
              e.offset = offset + _recordHeader;
              offset += record.length;
            }
            await sink.flush();
          } finally {
            await sink.close();
            await source.close();
          }
          await tmp.rename(box.file.path);
          box.entries
            ..clear()
            ..addAll(keep);
          box.bytes -= droppedBytes;
        }
        _totalBytes -= droppedBytes;
        return dropped;
      });
    }
    return removed;
  }
}
