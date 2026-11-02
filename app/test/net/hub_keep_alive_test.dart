import 'package:den_app/platform/sync/hub_keep_alive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('den/hub_service');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('on Android the hub service starts, updates its notification and stops over its channel', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final keepAlive = HubKeepAlive.platform(android: true);
    await keepAlive.start(keepAliveDetail(0));
    await keepAlive.update(keepAliveDetail(2));
    await keepAlive.stop();
    expect([for (final c in calls) c.method], ['start', 'update', 'stop']);
    expect(calls[0].arguments, {'text': 'No other devices are connected right now.'});
    expect(calls[1].arguments, {'text': '2 devices are connected.'});
    expect(calls[2].arguments, isEmpty);
  });

  test('a refused or missing service never stops the hub', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'denied'));
    await AndroidHubKeepAlive().start('x');
    messenger.setMockMethodCallHandler(channel, null);
    await AndroidHubKeepAlive().stop();
  });

  test('on a Mac it uses the same channel, so closing the window keeps the hub running', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final keepAlive = HubKeepAlive.platform(android: false, mac: true);
    await keepAlive.start('x');
    await keepAlive.stop();
    expect([for (final c in calls) c.method], ['start', 'stop']);
  });

  test('elsewhere it does nothing', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final keepAlive = HubKeepAlive.platform(android: false);
    await keepAlive.start('x');
    await keepAlive.stop();
    expect(calls, isEmpty);
  });

  test('the notification says how many devices are connected', () {
    expect(keepAliveDetail(0), 'No other devices are connected right now.');
    expect(keepAliveDetail(1), '1 device is connected.');
    expect(keepAliveDetail(5), '5 devices are connected.');
  });
}
