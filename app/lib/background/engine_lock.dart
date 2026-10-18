import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';

/// One Den engine per process. The app and a background refresh both open this device's change
/// log, and two engines writing it at once could give two changes the same counter. Whoever
/// holds the lock owns the engine; a background refresh that finds the app holding it asks the
/// app to refresh instead of opening a second engine.
///
/// The lock is a port registered under [name] with the process-wide [IsolateNameServer], so it
/// spans the app's isolate and the background task's engine. A holder that died without
/// releasing it no longer answers a ping, and the next caller takes the lock over.
class EngineLock {
  EngineLock._(this._port) {
    _port.listen(_onMessage);
  }

  /// The [IsolateNameServer] name of the engine's holder.
  static const name = 'den.engine';

  /// How long a ping waits before the holder counts as gone.
  static Duration pingTimeout = const Duration(milliseconds: 1500);

  final ReceivePort _port;
  bool _released = false;

  /// What the holder does when a background refresh asks: plan reminders again and bring in the
  /// phone's calendars, with the engine it already has open.
  Future<void> Function()? onRefresh;

  /// Takes the lock if nobody alive holds it; null when someone does.
  static Future<EngineLock?> tryAcquire() async {
    final port = ReceivePort();
    if (IsolateNameServer.registerPortWithName(port.sendPort, name)) return EngineLock._(port);
    if (await _holderAnswers()) {
      port.close();
      return null;
    }
    IsolateNameServer.removePortNameMapping(name);
    if (IsolateNameServer.registerPortWithName(port.sendPort, name)) return EngineLock._(port);
    port.close();
    return null;
  }

  /// Takes the lock for the app, waiting up to [wait] for a background refresh that holds it to
  /// finish. After that the app takes it regardless: the app must start.
  static Future<EngineLock> acquire({Duration wait = const Duration(seconds: 40)}) async {
    final until = DateTime.now().add(wait);
    while (true) {
      final lock = await tryAcquire();
      if (lock != null) return lock;
      if (DateTime.now().isAfter(until)) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    debugPrint('A background refresh held the engine too long; the app takes it over.');
    IsolateNameServer.removePortNameMapping(name);
    final port = ReceivePort();
    IsolateNameServer.registerPortWithName(port.sendPort, name);
    return EngineLock._(port);
  }

  /// Asks the holder to refresh and waits for it to finish, up to [timeout]. False when no
  /// holder answered.
  static Future<bool> askHolderToRefresh({Duration timeout = const Duration(seconds: 25)}) async {
    final reply = await _ask('refresh', timeout);
    return reply == 'done';
  }

  static Future<bool> _holderAnswers() async => await _ask('ping', pingTimeout) == 'pong';

  static Future<Object?> _ask(String verb, Duration timeout) async {
    final holder = IsolateNameServer.lookupPortByName(name);
    if (holder == null) return null;
    final reply = ReceivePort();
    try {
      holder.send([verb, reply.sendPort]);
      return await reply.first.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      reply.close();
    }
  }

  Future<void> _onMessage(Object? message) async {
    if (message is! List || message.length != 2 || message[1] is! SendPort) return;
    final reply = message[1] as SendPort;
    switch (message[0]) {
      case 'ping':
        reply.send('pong');
      case 'refresh':
        try {
          await onRefresh?.call();
        } on Object catch (e) {
          debugPrint('Refreshing for the background task failed: $e');
        }
        reply.send('done');
    }
  }

  /// Gives the engine up.
  void release() {
    if (_released) return;
    _released = true;
    final mine = IsolateNameServer.lookupPortByName(name) == _port.sendPort;
    if (mine) IsolateNameServer.removePortNameMapping(name);
    _port.close();
  }
}
