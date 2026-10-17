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
  const MailboxRound({required this.received, required this.posted, required this.skipped});

  /// Changes read from mailboxes that this device didn't have.
  final int received;

  /// Changes posted.
  final int posted;

  /// Blobs that didn't open (another epoch, or junk).
  final int skipped;
}

/// Store-and-forward sync through a relay's mailboxes, for families with no hub online.
///
/// For every space this device holds a key for, it reads the space's mailbox from its last
/// cursor, ingests changes it lacks (deduplicated by change id), then posts the changes from the
/// last [window] that the mailbox doesn't hold yet, sealed with the space key.
class MailboxSync {
  /// Creates a mailbox syncer for [node]'s den.
  MailboxSync({
    required this.node,
    required this.relay,
    SyncStateStore? state,
    this.epoch = 0,
    this.window = const Duration(days: 30),
    int Function()? now,
  })  : state = state ?? MemorySyncStateStore(),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The node that ingests and forwards what arrives.
  final SyncNode node;

  /// The relay's mailbox client.
  final RelayMailbox relay;

  /// Where cursors and mailbox contents are remembered.
  final SyncStateStore state;

  /// Space key epoch; mailbox ids change with it.
  final int epoch;

  /// How far back to post changes (the relay keeps blobs for 30 days).
  final Duration window;

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

  /// Reads and posts every space mailbox once.
  Future<MailboxRound> syncOnce() => _queue.run(() async {
        var received = 0;
        var posted = 0;
        var skipped = 0;
        final Set<String> spaces;
        try {
          spaces = _den.spacesForDevice(_den.deviceId);
        } on Object {
          return const MailboxRound(received: 0, posted: 0, skipped: 0);
        }
        for (final space in spaces) {
          final key = await _den.spaceKey(space);
          if (key == null) continue;
          final id = await mailboxId(key, epoch);
          final stateKey = 'mailbox:${_den.familyId}:$space:$epoch';
          final saved = await state.read(stateKey) ?? const {};
          var cursor = saved['cursor'] as int? ?? 0;
          final seen = _Seen.fromJson(asJsonObject(saved['seen']));

          final incoming = <Change>[];
          while (true) {
            final page = await relay.read(id, after: cursor);
            for (final entry in page.entries) {
              try {
                for (final c in await openChanges(entry.blob, key, space: space, epoch: epoch)) {
                  if (c.space == space && seen.add(c.device, c.counter)) incoming.add(c);
                }
              } on SealException {
                skipped++;
              }
            }
            cursor = page.next;
            if (!page.more || page.entries.isEmpty) break;
          }
          if (incoming.isNotEmpty) {
            await node.ingestExternal(incoming);
            received += incoming.length;
          }

          final cutoff = _now() - window.inMilliseconds;
          final outgoing = [
            for (final c in _den.changesSince(const {}, spaces: {space}))
              if (c.hlc.millis >= cutoff && !seen.contains(c.device, c.counter)) c,
          ];
          for (final batch in _batches(outgoing)) {
            await relay.append(id, await sealChanges(key, space: space, epoch: epoch, changes: batch));
            for (final c in batch) {
              seen.add(c.device, c.counter);
            }
            posted += batch.length;
          }
          await state.write(stateKey, {'cursor': cursor, 'seen': seen.toJson()});
        }
        return MailboxRound(received: received, posted: posted, skipped: skipped);
      });

  /// Leaves every space key [deviceId] is entitled to in its relay inbox, sealed to its X25519
  /// key and signed by this device. Returns how many were left.
  Future<int> deliverKeys(String deviceId) async {
    final device = _den.device(deviceId);
    if (device == null || !device.approved || device.revoked || device.xpub.isEmpty) {
      throw StateError('not an approved device');
    }
    final inbox = await deviceInboxId(device.xpub);
    var count = 0;
    for (final space in _den.spacesForDevice(deviceId)) {
      final key = await _den.spaceKey(space);
      if (key == null) continue;
      final envelope = await sealSpaceKey(
        sender: _den.keys,
        recipientDevice: deviceId,
        recipientXpub: device.xpub,
        grant: SpaceKeyGrant(space: space, epoch: epoch, key: Uint8List.fromList(key)),
      );
      await relay.append(inbox, utf8Bytes(jsonEncode(envelope)));
      count++;
    }
    return count;
  }

  /// Reads this device's relay inbox and stores space keys sealed to it by an approved parent's
  /// device. Envelopes from devices this replica doesn't know yet are retried next time.
  /// Returns how many keys were stored.
  Future<int> receiveKeys() => _queue.run(() async {
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
            final sender = from == null ? null : _den.device(from);
            if (envelope == null || from == null) {
              cursor = entry.cursor;
              continue;
            }
            if (sender == null) {
              blocked = true;
              break;
            }
            final owner = sender.member == null ? null : _den.member(sender.member!);
            if (sender.approved && !sender.revoked && owner != null && owner.isParent) {
              try {
                final grant = await openSpaceKey(envelope, recipient: _den.keys, senderPubkey: sender.pubkey);
                if (await _den.spaceKey(grant.space) == null) {
                  await _den.setSpaceKey(grant.space, grant.key);
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
      });

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
