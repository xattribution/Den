import 'dart:async';
import 'dart:convert';

import 'package:den_net/relay_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';

class _Slot {
  _Slot(this.host, this.owner);
  final WebSocketChannel host;

  /// The client (see `clientKeyOf`) the host connected from.
  final String owner;
  WebSocketChannel? guest;
  Timer? expiry;
  StreamSubscription<dynamic>? hostSubscription;
}

/// One-shot pairing meeting points at `/rendezvous/<slot>?role=host|guest`.
///
/// A host (the inviting device) waits up to [RelayConfig.slotTtl]; the first guest is paired
/// with it, both get `{"t":"paired"}`, and messages are then forwarded unchanged until either
/// side closes. The slot is gone once used. A guest with no host waiting is refused.
class RendezvousSlots {
  /// Creates an empty set of slots.
  RendezvousSlots(this.config);

  /// Limits.
  final RelayConfig config;

  final Map<String, _Slot> _slots = {};

  /// Hosts waiting.
  int get count => _slots.length;

  /// Whether a host is waiting at [slot].
  bool hasHost(String slot) => _slots.containsKey(slot);

  /// Whether a new host from [client] may wait at [slot]: under the relay's cap and the client's
  /// share of it.
  bool canHost(String slot, {String client = ''}) =>
      !_slots.containsKey(slot) &&
      _slots.length < config.maxSlots &&
      _slots.values.where((s) => s.owner == client).length < config.maxSlotsPerClient;

  /// Parks a host socket from [client] at [slot].
  void host(WebSocketChannel socket, String slot, {String client = ''}) {
    if (!canHost(slot, client: client)) {
      unawaited(socket.sink.close(_slots.containsKey(slot) ? RelayClose.replaced : RelayClose.full));
      return;
    }
    final entry = _Slot(socket, client);
    _slots[slot] = entry;
    entry.expiry = Timer(config.slotTtl, () {
      if (identical(_slots[slot], entry)) _slots.remove(slot);
      if (entry.guest == null) unawaited(socket.sink.close(RelayClose.expired));
    });
    entry.hostSubscription = socket.stream.listen(
      (message) {
        final guest = entry.guest;
        if (guest == null || !_fits(message)) return;
        guest.sink.add(message);
      },
      onDone: () {
        entry.expiry?.cancel();
        if (identical(_slots[slot], entry)) _slots.remove(slot);
        unawaited(entry.guest?.sink.close());
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// Pairs a guest socket with the host waiting at [slot].
  void guest(WebSocketChannel socket, String slot) {
    final entry = _slots.remove(slot);
    if (entry == null) {
      unawaited(socket.sink.close(RelayClose.notFound));
      return;
    }
    entry.expiry?.cancel();
    entry.guest = socket;
    entry.host.sink.add(rendezvousPairedMessage);
    socket.sink.add(rendezvousPairedMessage);
    socket.stream.listen(
      (message) {
        if (_fits(message)) entry.host.sink.add(message);
      },
      onDone: () => unawaited(entry.host.sink.close()),
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  bool _fits(Object? message) {
    if (message is String) return utf8.encode(message).length <= config.maxMessageBytes;
    if (message is List<int>) return message.length <= config.maxMessageBytes;
    return false;
  }

  /// Closes every waiting host.
  void closeAll() {
    for (final entry in _slots.values.toList()) {
      entry.expiry?.cancel();
      unawaited(entry.host.sink.close(RelayClose.notFound));
    }
    _slots.clear();
  }
}
