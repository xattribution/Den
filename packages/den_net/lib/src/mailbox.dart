import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:den_core/den_core.dart';

import 'relay_client.dart';
import 'relay_protocol.dart';
import 'seal.dart';
import 'sync.dart';
import 'util.dart';

final Xchacha20 _cipher = Xchacha20.poly1305Aead();
const int _blobVersion = 1;

/// A space's mailbox id for a key epoch: hex HMAC-SHA256(space key, `"mailbox:<epoch>"`).
/// Only devices holding the space key can find it; the relay sees an opaque id.
Future<String> mailboxId(List<int> spaceKey, int epoch) async =>
    hexEncode(await hmacSha256(spaceKey, utf8Bytes('mailbox:$epoch')));

/// A device's inbox on the relay, where sealed space keys are left for it: hex SHA-256 of a
/// label and its X25519 key.
Future<String> deviceInboxId(String xpub) async => hexEncode(await sha256(utf8Bytes('den/inbox/v1|$xpub')));

/// Seals signed [changes] for [space]'s mailbox: version byte, 24-byte random nonce, then
/// XChaCha20-Poly1305 under the space key over `{"v":1,"changes":[...]}`, with the space and
/// epoch as associated data.
Future<Uint8List> sealChanges(
  List<int> spaceKey, {
  required String space,
  required int epoch,
  required List<Change> changes,
}) async {
  final nonce = randomBytes(24);
  final box = await _cipher.encrypt(
    utf8Bytes(jsonEncode({'v': 1, 'changes': [for (final c in changes) c.toJson()]})),
    secretKey: SecretKey(List<int>.of(spaceKey)),
    nonce: nonce,
    aad: _aad(space, epoch),
  );
  return concatBytes([
    [_blobVersion],
    nonce,
    box.cipherText,
    box.mac.bytes,
  ]);
}

/// Opens a mailbox blob made by [sealChanges]. Throws [SealException] if it doesn't open under
/// this key, space and epoch.
Future<List<Change>> openChanges(
  List<int> blob,
  List<int> spaceKey, {
  required String space,
  required int epoch,
}) async {
  if (blob.length < 1 + 24 + 16 || blob[0] != _blobVersion) throw SealException('not a mailbox blob');
  final List<int> plain;
  try {
    plain = await _cipher.decrypt(
      SecretBox(
        blob.sublist(25, blob.length - 16),
        nonce: blob.sublist(1, 25),
        mac: Mac(blob.sublist(blob.length - 16)),
      ),
      secretKey: SecretKey(List<int>.of(spaceKey)),
      aad: _aad(space, epoch),
    );
  } on SecretBoxAuthenticationError {
    throw SealException('blob failed authentication');
  }
  try {
    final json = asJsonObject(jsonDecode(utf8.decode(plain)));
    final list = json?['changes'];
    if (list is! List) throw SealException('blob has no changes');
    return [for (final item in list) Change.fromJson(asJsonObject(item)!)];
  } on SealException {
    rethrow;
  } on Object {
    throw SealException('blob is malformed');
  }
}

Uint8List _aad(String space, int epoch) => utf8Bytes('den/mailbox/v1|$space|$epoch');

/// Durable key-value storage for sync bookkeeping (mailbox cursors and what each mailbox
/// holds). The app backs it with its own storage; [MemorySyncStateStore] is for tests.
abstract class SyncStateStore {
  /// The value under [key], or null.
  Future<Map<String, Object?>?> read(String key);

  /// Stores [value] under [key].
  Future<void> write(String key, Map<String, Object?> value);
}

/// In-memory [SyncStateStore].
class MemorySyncStateStore implements SyncStateStore {
  final Map<String, String> _values = {};

  @override
  Future<Map<String, Object?>?> read(String key) async {
    final raw = _values[key];
    return raw == null ? null : asJsonObject(jsonDecode(raw));
  }

  @override
  Future<void> write(String key, Map<String, Object?> value) async => _values[key] = jsonEncode(value);
}

/// What one [MailboxSync.syncOnce] did.
class MailboxRound {
  /// Creates a summary.
  const MailboxRound({
    required this.received,
    required this.posted,
    required this.skipped,
    this.keysStored = 0,
    this.keysDelivered = 0,
  });

  /// Changes read from mailboxes that this device didn't have.
  final int received;

  /// Changes posted.
  final int posted;

  /// Blobs that didn't open (junk, or sealed with a key this device doesn't hold).
  final int skipped;

  /// Space keys taken from this device's inbox.
  final int keysStored;

  /// Sealed space keys left in other devices' inboxes.
  final int keysDelivered;
}

/// Store-and-forward sync through a relay's mailboxes, for families with no hub online.
///
/// Each round, a device:
///
/// 1. takes space keys sealed to it from its inbox (from an approved parent's device);
/// 2. for every space it holds a key for, reads the mailbox of the current key epoch, and of
///    each older epoch until [drainWindow] after it first saw a newer one, so whatever devices
///    posted before they had the new key is still read; changes are deduplicated by id;
/// 3. on a parent's device, leaves a key epoch it made itself (a rotation after a revocation)
///    in the inbox of every other device that may hold the space;
/// 4. posts to the current epoch's mailbox the changes from the last [window] that mailbox
///    doesn't hold yet.
///
/// Key pushes to live sessions are held during the round, so keys that arrived with a
/// revocation are passed on only after the revocation itself has been ingested.
class MailboxSync {
  /// Creates a mailbox syncer for [node]'s den.
  MailboxSync({
    required this.node,
    required this.relay,
    SyncStateStore? state,
    this.window = const Duration(days: 30),
    this.drainWindow = const Duration(days: 30),
    int Function()? now,
  })  : state = state ?? MemorySyncStateStore(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The node that ingests and forwards what arrives.
  final SyncNode node;

  /// The relay's mailbox client.
  final RelayMailbox relay;

  /// Where cursors, what each mailbox holds and when epochs changed are remembered.
  final SyncStateStore state;

  /// How far back to post changes (the relay keeps blobs for 30 days).
  final Duration window;

  /// How long an older epoch's mailbox is still read after a newer epoch appears (the relay's
  /// blob lifetime, so nothing posted under the old key is missed).
  final Duration drainWindow;

  final int Function() _now;
  final SerialQueue _queue = SerialQueue();
  Timer? _timer;

  Den get _den => node.den;

  /// Runs [syncOnce] every [interval] until [stop].
  void start({Duration interval = const Duration(seconds: 30)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(syncOnce().then((_) {}, onError: (Object _) {})));
    unawaited(syncOnce().then((_) {}, onError: (Object _) {}));
  }

  /// Stops periodic syncing.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _queue.run(() async {});
  }

  /// Takes delivered keys, then reads and posts every space mailbox once.
  Future<MailboxRound> syncOnce() => _queue.run(() => node.withKeyPushHeld(() async {
            final keysStored = await _receiveKeys();
            var received = 0;
            var posted = 0;
            var skipped = 0;
            var delivered = 0;
            final Set<String> spaces;
            try {
              spaces = _den.spacesForDevice(_den.deviceId);
            } on Object {
              return MailboxRound(received: 0, posted: 0, skipped: 0, keysStored: keysStored);
            }
            for (final space in spaces.toList()..sort()) {
              final current = _den.spaceKeyEpoch(space);
              final currentKey = current == null ? null : await _den.spaceKey(space, epoch: current);
              if (current == null || currentKey == null) continue;
              final now = _now();
              final metaKey = 'epochs:${_den.familyId}:$space';
              final meta = await state.read(metaKey) ?? const {};
              final seenAt = <int, int>{
                for (final e in (asJsonObject(meta['seenAt']) ?? const {}).entries)
                  if (int.tryParse(e.key) != null && e.value is int) int.parse(e.key): e.value as int,
              };
              seenAt.putIfAbsent(current, () => now);

              // Read the current epoch's mailbox, then older ones still being drained.
              final epochs = <int, List<int>>{current: currentKey};
              for (var e = current - 1; e >= 0; e--) {
                final key = await _den.spaceKey(space, epoch: e);
                if (key == null) break;
                final newer = [
                  for (final s in seenAt.entries)
                    if (s.key > e) s.value,
                ];
                final since = newer.isEmpty ? now : newer.reduce((a, b) => a < b ? a : b);
                if (now - since > drainWindow.inMilliseconds) break;
                epochs[e] = key;
              }
              final ids = <String>{};
              final incoming = <Change>[];
              _Seen? currentSeen;
              String? currentId;
              int currentCursor = 0;
              for (final entry in epochs.entries) {
                final epoch = entry.key;
                final key = entry.value;
                final id = await mailboxId(key, epoch);
                final saved = await state.read('mailbox:$id');
                var cursor = saved?['cursor'] as int? ?? 0;
                var seen = _Seen.fromJson(asJsonObject(saved?['seen']));
                if (saved == null && epoch == current) {
                  // A new epoch's mailbox starts out knowing what the previous one holds, so the
                  // switch doesn't repost a month of changes that are still being drained.
                  final previous = current > 0 ? await _den.spaceKey(space, epoch: current - 1) : null;
                  if (previous != null) {
                    final before = await state.read('mailbox:${await mailboxId(previous, current - 1)}');
                    seen = _Seen.fromJson(asJsonObject(before?['seen']));
                  }
                }
                while (true) {
                  final page = await relay.read(id, after: cursor);
                  for (final blob in page.entries) {
                    try {
                      for (final c in await openChanges(blob.blob, key, space: space, epoch: epoch)) {
                        if (c.space != space) continue;
                        seen.add(c.device, c.counter);
                        if (ids.add(c.id)) incoming.add(c);
                      }
                    } on SealException {
                      skipped++;
                    }
                  }
                  cursor = page.next;
                  if (!page.more || page.entries.isEmpty) break;
                }
                if (epoch == current) {
                  currentSeen = seen;
                  currentId = id;
                  currentCursor = cursor;
                } else {
                  await state.write('mailbox:$id', {'cursor': cursor, 'seen': seen.toJson()});
                }
              }
              if (incoming.isNotEmpty) {
                final result = await node.ingestExternal(incoming);
                received += result?.added ?? 0;
              }

              var deliveredEpoch = meta['delivered'] as int? ?? -1;
              if (current > deliveredEpoch) {
                if (!node.learnedKey(space, current) && _den.owner?.isParent == true) {
                  delivered += await _deliver(space, current, currentKey);
                }
                deliveredEpoch = current;
              }

              final seen = currentSeen!;
              final cutoff = _now() - window.inMilliseconds;
              final outgoing = [
                for (final c in _den.changesSince(const {}, spaces: {space}))
                  if (c.hlc.millis >= cutoff && !seen.contains(c.device, c.counter)) c,
              ];
              for (final batch in _batches(outgoing)) {
                await relay.append(currentId!, await sealChanges(currentKey, space: space, epoch: current, changes: batch));
                for (final c in batch) {
                  seen.add(c.device, c.counter);
                }
                posted += batch.length;
              }
              await state.write('mailbox:$currentId', {'cursor': currentCursor, 'seen': seen.toJson()});
              await state.write(metaKey, {
                'seenAt': {for (final e in seenAt.entries) '${e.key}': e.value},
                'delivered': deliveredEpoch,
              });
            }
            return MailboxRound(
              received: received,
              posted: posted,
              skipped: skipped,
              keysStored: keysStored,
              keysDelivered: delivered,
            );
          }));

  /// Leaves the current key of every space [deviceId] may hold in its relay inbox, sealed to its
  /// X25519 key and signed by this device, with the key's epoch. Returns how many were left.
  Future<int> deliverKeys(String deviceId) async {
    final device = _den.device(deviceId);
    if (device == null || !device.approved || device.revoked || device.xpub.isEmpty) {
      throw StateError('not an approved device');
    }
    var count = 0;
    for (final space in _den.spacesForDevice(deviceId)) {
      final epoch = _den.spaceKeyEpoch(space);
      final key = epoch == null ? null : await _den.spaceKey(space, epoch: epoch);
      if (epoch == null || key == null) continue;
      await _sealTo(device, space, epoch, key);
      count++;
    }
    return count;
  }

  /// Reads this device's relay inbox and stores space keys (by epoch) sealed to it by an
  /// approved parent's device. Envelopes from devices this replica doesn't know yet are retried
  /// next time. Returns how many keys were stored.
  Future<int> receiveKeys() => _queue.run(() => node.withKeyPushHeld(_receiveKeys));

  Future<int> _deliver(String space, int epoch, List<int> key) async {
    var count = 0;
    for (final device in _den.devices) {
      if (device.id == _den.deviceId || !device.approved || device.revoked || device.xpub.isEmpty) continue;
      if (!_den.spacesForDevice(device.id).contains(space)) continue;
      await _sealTo(device, space, epoch, key);
      count++;
    }
    return count;
  }

  Future<void> _sealTo(Device device, String space, int epoch, List<int> key) async {
    final envelope = await sealSpaceKey(
      sender: _den.keys,
      recipientDevice: device.id,
      recipientXpub: device.xpub,
      grant: SpaceKeyGrant(space: space, epoch: epoch, key: Uint8List.fromList(key)),
    );
    await relay.append(await deviceInboxId(device.xpub), utf8Bytes(jsonEncode(envelope)));
  }

  Future<int> _receiveKeys() async {
    final inbox = await deviceInboxId(_den.keys.xpub);
    final stateKey = 'inbox:${_den.deviceId}';
    var cursor = (await state.read(stateKey))?['cursor'] as int? ?? 0;
    var stored = 0;
    var blocked = false;
    while (!blocked) {
      final page = await relay.read(inbox, after: cursor);
      for (final entry in page.entries) {
        final Map<String, Object?>? envelope;
        try {
          envelope = asJsonObject(jsonDecode(utf8.decode(entry.blob)));
        } on Object {
          cursor = entry.cursor;
          continue;
        }
        final from = envelope == null ? null : sealedSender(envelope);
        if (envelope == null || from == null) {
          cursor = entry.cursor;
          continue;
        }
        final sender = _den.device(from);
        if (sender == null) {
          blocked = true;
          break;
        }
        final owner = sender.member == null ? null : _den.member(sender.member!);
        if (sender.approved && !sender.revoked && owner != null && owner.isParent) {
          try {
            final grant = await openSpaceKey(envelope, recipient: _den.keys, senderPubkey: sender.pubkey);
            if (await _den.spaceKey(grant.space, epoch: grant.epoch) == null) {
              await _den.setSpaceKey(grant.space, grant.key, epoch: grant.epoch);
              node.noteLearnedKey(grant.space, grant.epoch);
              stored++;
            }
          } on SealException {
            // Forged or damaged; skip it.
          }
        }
        cursor = entry.cursor;
      }
      if (blocked || !page.more || page.entries.isEmpty) break;
    }
    await state.write(stateKey, {'cursor': cursor});
    return stored;
  }

  List<List<Change>> _batches(List<Change> changes) {
    final out = <List<Change>>[];
    var batch = <Change>[];
    var bytes = 0;
    const limit = maxRelayMessageBytes * 3 ~/ 4;
    for (final c in changes) {
      final size = jsonEncode(c.toJson()).length + 1;
      if (batch.isNotEmpty && bytes + size > limit) {
        out.add(batch);
        batch = [];
        bytes = 0;
      }
      batch.add(c);
      bytes += size;
    }
    if (batch.isNotEmpty) out.add(batch);
    return out;
  }
}

/// Counters seen in a mailbox, per author, as sorted inclusive ranges.
class _Seen {
  _Seen(this._ranges);

  factory _Seen.fromJson(Map<String, Object?>? json) {
    final ranges = <String, List<List<int>>>{};
    for (final entry in (json ?? const {}).entries) {
      final list = entry.value;
      if (list is! List) continue;
      ranges[entry.key] = [
        for (final r in list)
          if (r is List && r.length == 2 && r[0] is int && r[1] is int) [r[0] as int, r[1] as int],
      ];
    }
    return _Seen(ranges);
  }

  final Map<String, List<List<int>>> _ranges;

  bool contains(String author, int counter) {
    for (final r in _ranges[author] ?? const <List<int>>[]) {
      if (counter >= r[0] && counter <= r[1]) return true;
    }
    return false;
  }

  /// Adds a counter; false when it was already there.
  bool add(String author, int counter) {
    if (contains(author, counter)) return false;
    final list = _ranges[author] ??= [];
    if (list.isEmpty || counter > list.last[1] + 1) {
      list.add([counter, counter]);
      return true;
    }
    if (counter == list.last[1] + 1) {
      list.last[1] = counter;
      return true;
    }
    list.add([counter, counter]);
    list.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[];
    for (final r in list) {
      if (merged.isNotEmpty && r[0] <= merged.last[1] + 1) {
        if (r[1] > merged.last[1]) merged.last[1] = r[1];
      } else {
        merged.add([r[0], r[1]]);
      }
    }
    _ranges[author] = merged;
    return true;
  }

  Map<String, Object?> toJson() => {for (final e in _ranges.entries) e.key: e.value};
}
