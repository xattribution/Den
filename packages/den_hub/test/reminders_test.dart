@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:den_core/den_core.dart';
import 'package:den_hub/den_hub.dart';
import 'support/test.dart';

import 'support/fixture.dart';

/// A way reminders go out that remembers what it was handed.
class FakeSink implements ReminderSink {
  final List<ReminderDue> got = [];
  int failFirst = 0;

  @override
  bool get active => true;

  @override
  Future<void> remind(ReminderDue reminder) async {
    if (failFirst > 0) {
      failFirst--;
      throw StateError('down');
    }
    got.add(reminder);
  }
}

void main() {
  test('each reminder goes out once, a failing sink stops nothing, and sent keys survive a restart', () async {
    final dir = await Directory.systemTemp.createTemp('den_hub_reminders');
    addTearDown(() => dir.delete(recursive: true));
    final f = await HubFixture.start(
      dataDir: dir.path,
      configure: (c) => HubConfig(port: 0, host: c.host, mdns: false, dataDir: c.dataDir, log: c.log, reminderInterval: const Duration(hours: 1)),
    );
    addTearDown(f.stop);
    final broken = FakeSink()..failFirst = 1;
    final sink = FakeSink();
    f.hub.reminders.sinks
      ..add(broken)
      ..add(sink);
    final now = DateTime.now().millisecondsSinceEpoch;
    final soon = now + 2 * 60000 + 1500;
    await f.phone.addEvent(title: 'Piano recital', start: soon, end: soon + 3600000, assignees: [f.id('Zoe')], location: 'Hall B', reminders: [2]);
    await f.phone.addEvent(title: 'Surprise party plans', start: soon, end: soon + 3600000, assignees: [f.id('Alex')], reminders: [2], audience: Audience.parents);
    await f.toHub();
    await f.hub.reminders.tick();
    await eventually(() => sink.got.length >= 2, timeout: const Duration(seconds: 20));
    expect(sink.got.map((r) => r.title).toSet(), {'Piano recital', 'Surprise party plans'});
    expect(broken.got, hasLength(1), reason: 'its first failed, the next went through');

    await f.hub.reminders.tick();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(sink.got, hasLength(2), reason: 'each reminder goes out once');
    await f.hub.stop();
    final again = await DenHub.start(f.hubDen, f.hub.config);
    final later = FakeSink();
    again.reminders.sinks.add(later);
    await again.reminders.tick();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(later.got, isEmpty, reason: 'sent keys survive a restart');
    await again.stop();
  });
}
