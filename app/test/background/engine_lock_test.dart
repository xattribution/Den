import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:den_app/platform/background/engine_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    IsolateNameServer.removePortNameMapping(EngineLock.name);
    EngineLock.pingTimeout = const Duration(milliseconds: 150);
  });

  test('the first to take the engine holds it until it lets go', () async {
    final app = await EngineLock.tryAcquire();
    expect(app, isNotNull);
    expect(await EngineLock.tryAcquire(), isNull);

    app!.release();
    final next = await EngineLock.tryAcquire();
    expect(next, isNotNull);
    next!.release();
  });

  test('a background refresh that finds the app holding the engine asks it to refresh', () async {
    final app = await EngineLock.acquire();
    var refreshes = 0;
    app.onRefresh = () async => refreshes++;

    expect(await EngineLock.tryAcquire(), isNull);
    expect(await EngineLock.askHolderToRefresh(), isTrue);
    expect(refreshes, 1);
    app.release();
  });

  test('the holder answers even when its refresh fails', () async {
    final app = await EngineLock.acquire();
    app.onRefresh = () async => throw StateError('no network');
    expect(await EngineLock.askHolderToRefresh(), isTrue);
    app.release();
  });

  test('with nobody holding the engine, asking for a refresh gets no answer', () async {
    expect(await EngineLock.askHolderToRefresh(timeout: const Duration(milliseconds: 100)), isFalse);
  });

  test('a holder that ended without letting go is taken over', () async {
    final gone = ReceivePort();
    IsolateNameServer.registerPortWithName(gone.sendPort, EngineLock.name);
    gone.close();

    final lock = await EngineLock.tryAcquire();
    expect(lock, isNotNull);
    expect(IsolateNameServer.lookupPortByName(EngineLock.name), isNot(gone.sendPort));
    lock!.release();
  });

  test('the app waits for a background refresh to finish before opening the engine', () async {
    final background = (await EngineLock.tryAcquire())!;
    final started = DateTime.now();
    Future<void>.delayed(const Duration(milliseconds: 400), background.release);

    final app = await EngineLock.acquire(wait: const Duration(seconds: 5));
    expect(DateTime.now().difference(started), greaterThanOrEqualTo(const Duration(milliseconds: 350)));
    expect(await EngineLock.tryAcquire(), isNull);
    app.release();
  });

  test('letting go twice, or after a takeover, leaves the new holder alone', () async {
    final first = (await EngineLock.tryAcquire())!;
    final second = await EngineLock.acquire(wait: const Duration(milliseconds: 300));
    first.release();
    expect(await EngineLock.tryAcquire(), isNull);
    second.release();
    second.release();
    expect(await EngineLock.tryAcquire(), isNotNull);
  });
}
