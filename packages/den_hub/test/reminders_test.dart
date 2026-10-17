@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Records Home Assistant notify calls and ntfy publishes; fails the first [failFirst] calls.
class FakeNotifier {
  FakeNotifier._(this.server);
  final HttpServer server;
  final List<(String, Map<String, Object?>, String?)> calls = [];
  int failFirst = 0;
  int attempts = 0;

  static Future<FakeNotifier> start() async {
    final n = FakeNotifier._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    n.server.listen((request) async {
      n.attempts++;
      final body = (jsonDecode(await utf8.decodeStream(request)) as Map).cast<String, Object?>();
      if (n.failFirst > 0) {
        n.failFirst--;
        request.response.statusCode = 500;
      } else {
        n.calls.add((request.uri.path, body, request.headers.value('authorization')));
      }
      await request.response.close();
    });
    return n;
  }

  Uri get url => Uri.parse('http://127.0.0.1:${server.port}');
}

void main() {
  test('reminders go to Home Assistant and ntfy once, private ones without details', () async {
    final notifier = await FakeNotifier.start();
    addTearDown(() => notifier.server.close(force: true));
    final dir = await Directory.systemTemp.createTemp('den_hub_reminders');
    addTearDown(() => dir.delete(recursive: true));
    final f = await HubFixture.start(
      dataDir: dir.path,
      configure: (c) => HubConfig(
        port: 0,
        host: c.host,
        mdns: false,
        dataDir: c.dataDir,
        log: c.log,
        homeAssistantUrl: notifier.url,
        homeAssistantToken: 'ha-long-lived',
        reminderInterval: const Duration(hours: 1),
        notify: {
          'Zoe': MemberNotify(homeAssistantService: 'mobile_app_zoe', ntfyTopic: '${notifier.url}/den-zoe'),
          'alex': MemberNotify(ntfyTopic: '${notifier.url}/den-alex'),
        },
      ),
    );
    addTearDown(f.stop);
    final now = DateTime.now().millisecondsSinceEpoch;
    final soon = now + 2 * 60000 + 1500;
    await f.phone.addEvent(title: 'Piano recital', start: soon, end: soon + 3600000, assignees: [f.id('Zoe')], location: 'Hall B', reminders: [2]);
    await f.phone.addEvent(title: 'Surprise party plans', start: soon, end: soon + 3600000, assignees: [f.id('Alex')], reminders: [2], audience: Audience.parents);
    await f.toHub();
    notifier.failFirst = 1;
    await f.hub.reminders.tick();
    await eventually(() => notifier.calls.length >= 3, timeout: const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(seconds: 1));

    final ha = notifier.calls.where((c) => c.$1 == '/api/services/notify/mobile_app_zoe').toList();
    expect(ha, hasLength(1));
    expect(ha.single.$2['title'], 'Piano recital');
    expect(ha.single.$2['message'], contains('Hall B'));
    expect(ha.single.$3, 'Bearer ha-long-lived');
    final ntfy = notifier.calls.where((c) => c.$1 == '/').toList();
    expect(ntfy.map((c) => c.$2['topic']).toSet(), {'den-zoe', 'den-alex'});
    final alex = ntfy.firstWhere((c) => c.$2['topic'] == 'den-alex').$2;
    expect(alex, {'topic': 'den-alex', 'title': 'Den', 'message': 'A reminder from Den'});
    expect(notifier.attempts, notifier.calls.length + 1, reason: 'one failure, retried once');

    await f.hub.reminders.tick();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(notifier.calls, hasLength(3), reason: 'each reminder goes out once');
    await f.hub.stop();
    final again = await DenHub.start(f.hubDen, f.hub.config);
    await again.reminders.tick();
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(notifier.calls, hasLength(3), reason: 'sent keys survive a restart');
    await again.stop();
  });
}
