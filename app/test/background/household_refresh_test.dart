// Background refresh on a device in several families: every family's engine catches up (each
// with its own connection settings), phone calendars come into the first family only, and the
// reminders are one budget across all of them.
import 'package:den_app/platform/background/background_refresh.dart';
import 'package:den_app/platform/storage/memberships.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reminders/fake_outlet.dart';

const _hour = 3600000;

/// Friday, October 16, 2026, 8 AM in Chicago.
int _clock() => DateTime.utc(2026, 10, 16, 13).millisecondsSinceEpoch;

Future<Den> _family(String name) async {
  final den = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _clock);
  await den.createFamily(
    familyName: name,
    timezone: 'America/Chicago',
    yourName: 'Grandma',
    marker: Marker.sky,
    animal: Animal.cat,
    deviceName: "Grandma's phone",
    deviceKind: DeviceKind.phone,
  );
  return den;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every family catches up, then one budget of reminders is planned across them', () async {
    final kotvas = await _family('Kotvas');
    final smith = await _family('Smith family');
    final smithLog = Membership(id: smith.familyId!, label: 'Smith family');
    final outlet = FakeOutlet();
    final connected = <String, Membership?>{};

    await BackgroundRefresh.logs(
      [
        RefreshLog(kotvas, log: Membership(id: kotvas.familyId!, primary: true)),
        RefreshLog(smith, log: smithLog),
      ],
      outlet: outlet,
      now: _clock,
      connect: (den, {log}) async {
        connected[den.family!.name] = log;
        // What each family changed while the phone slept.
        final start = _clock() + (den == kotvas ? 2 : 3) * _hour;
        await den.addEvent(title: den == kotvas ? 'Soccer' : 'Swim', start: start, end: start + _hour, reminders: const [30]);
        return () async {};
      },
    ).run();

    expect(connected.keys, unorderedEquals(['Kotvas', 'Smith family']));
    expect(connected['Smith family'], smithLog, reason: "the Smiths' own connection settings");
    expect(outlet.held.values.map((r) => r.title), unorderedEquals(['Kotvas: Soccer', 'Smith family: Swim']));
    final swim = outlet.held.values.firstWhere((r) => r.title.endsWith('Swim'));
    expect(swim.route, startsWith('/l/${smith.familyId}/event/'));
  });

  test('a family not let in yet is left out; one family alone plans as it always has', () async {
    final kotvas = await _family('Kotvas');
    final waiting = await Den.open(storage: MemoryStorage(), keys: await DeviceKeys.generate(), now: _clock);
    final outlet = FakeOutlet();
    final start = _clock() + 2 * _hour;
    await kotvas.addEvent(title: 'Soccer', start: start, end: start + _hour, reminders: const [30]);
    final connected = <Den>[];
    await BackgroundRefresh.logs(
      [RefreshLog(kotvas), RefreshLog(waiting, log: const Membership(id: 'waitingfamily'))],
      outlet: outlet,
      now: _clock,
      connect: (den, {log}) async {
        connected.add(den);
        return null;
      },
    ).run();
    expect(connected, [kotvas]);
    expect(outlet.held.values.map((r) => r.title), ['Soccer']);
  });
}
