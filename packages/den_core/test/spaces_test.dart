import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestClock clock;
  late Den parent;
  late String dana;
  late String leo;
  late String maya;
  late Den leoTablet;
  late Den mayaPhone;

  const privateTitles = ['Surprise party for Leo', 'Therapy appointment', 'Maya diary', 'Gift ideas'];

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 6, 1, 15));
    parent = await foundFamily(clock);
    dana = parent.actor!.id;
    leo = await parent.addMember(name: 'Leo', role: Role.kid);
    maya = await parent.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen, grants: {Grant.events, Grant.lists});
    leoTablet = await joinDevice(parent, clock, member: leo, name: 'Leo tablet');
    mayaPhone = await joinDevice(parent, clock, member: maya, name: 'Maya phone', kind: DeviceKind.phone);

    final day = DateTime.utc(2026, 6, 2, 16).millisecondsSinceEpoch;
    await parent.addEvent(title: 'Soccer', start: day, end: day + 3600000, assignees: [leo]);
    final surprise = await parent.addEvent(
      title: 'Surprise party for Leo',
      start: day,
      end: day + 7200000,
      audience: Audience.parents,
    );
    await parent.updateEvent(surprise, {'location': 'Pizza place'});
    await parent.addEvent(title: 'Therapy appointment', start: day, end: day + 3600000, audience: Audience.justMe);
    final gifts = await parent.addList(title: 'Gift ideas', audience: Audience.parents);
    await parent.addItem(gifts, text: 'Bike helmet');
    await parent.addTokenConnection(label: 'Home Assistant', scopes: {Scope.read});
    await mayaPhone.addEvent(title: 'Maya diary', start: day, end: day + 60000, audience: Audience.justMe);
    await sync(mayaPhone, parent);
    await sync(parent, leoTablet);
    await sync(parent, mayaPhone);
  });

  test('a kid\'s device holds only the family space and their own', () {
    expect(parent.spacesForDevice(leoTablet.deviceId), {Space.family, Space.member(leo)});
    expect(parent.spacesForDevice(mayaPhone.deviceId), {Space.family, Space.member(maya)});
    expect(parent.spacesForDevice(parent.deviceId),
        {Space.family, Space.parents, Space.member(dana), Space.member(leo), Space.member(maya)});
  });

  test('changesSince for a kid never includes the parents\' or other people\'s spaces', () {
    final spaces = parent.spacesForDevice(leoTablet.deviceId);
    final sent = parent.changesSince({}, spaces: spaces);
    expect(sent.map((c) => c.space).toSet(), isNot(contains(Space.parents)));
    expect(sent.any((c) => c.space == Space.member(maya) || c.space == Space.member(dana)), isFalse);
    expect(leoTablet.changesSince({}).map((c) => c.space).toSet(), everyElement(isIn(spaces)));
  });

  test('a kid\'s history, search and calendar never show private titles', () {
    String everything(Den d) => [
          for (final h in d.history()) '${h.title} ${h.diffs.map((x) => '${x.before} ${x.after}').join(' ')}',
          for (final s in d.search('a')) s.title,
          for (final s in d.search('surprise')) s.title,
          for (final s in d.search('therapy')) s.title,
          for (final o in d.occurrences(0, 1 << 50)) o.title,
          for (final l in d.lists) l.list.title,
        ].join('\n');
    final leoSees = everything(leoTablet);
    for (final title in privateTitles) {
      expect(leoSees, isNot(contains(title)));
    }
    expect(leoSees, contains('Soccer'));
    expect(leoTablet.connections, isEmpty);
    final mayaSees = everything(mayaPhone);
    expect(mayaSees, contains('Maya diary'));
    expect(mayaSees, isNot(contains('Surprise party for Leo')));
    expect(mayaSees, isNot(contains('Therapy')));
    expect(mayaSees, isNot(contains('Bike helmet')));
  });

  test('parents see private items unless the family\'s oversight policy says not', () async {
    expect(parent.history().map((h) => h.title), contains('Maya diary'));
    await parent.updateFamily({
      'oversight': {maya: {'parentsSeePrivate': false}},
    });
    expect(parent.spacesForDevice(parent.deviceId), isNot(contains(Space.member(maya))));
    expect(parent.history().map((h) => h.title), isNot(contains('Maya diary')));
    expect(parent.search('diary'), isEmpty);
    expect(parent.spacesForDevice(mayaPhone.deviceId), contains(Space.member(maya)));
    final forged = await forge(
      parent.keys,
      counter: 999,
      millis: clock.now + 1000,
      type: RecordType.event,
      rid: 'peekintomayaspace',
      space: Space.member(maya),
      fields: {'title': 'Peek', 'start': 0, 'end': 1, 'tz': 'UTC'},
      actor: dana,
    );
    final result = await mayaPhone.ingest([...parent.changesSince(mayaPhone.versionVector), forged]);
    expect(result.invalid.keys, [forged.id]);
  });

  test('a hub holds every space but answers a kid\'s token with only what the kid may read', () async {
    final hub = await joinDevice(parent, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
    await sync(parent, hub);
    expect(hub.readableSpaces, containsAll([Space.parents, Space.member(maya)]));
    hub.actAs(leo, via: 'Leo\'s speaker');
    expect(hub.readableSpaces, {Space.family, Space.member(leo)});
    final titles = [for (final h in hub.history()) h.title, for (final o in hub.occurrences(0, 1 << 50)) o.title];
    for (final title in privateTitles) {
      expect(titles, isNot(contains(title)));
    }
  });

  test('shared displays hold only the family space; unapproved devices hold nothing', () async {
    final display = await joinDevice(parent, clock, mode: DeviceMode.shared, name: 'Kitchen', kind: DeviceKind.display);
    expect(parent.spacesForDevice(display.deviceId), {Space.family});
    display.actAs(dana);
    expect(display.readableSpaces, {Space.family});
    expect(display.history().map((h) => h.title), isNot(contains('Surprise party for Leo')));
    final waiting = await joinDevice(parent, clock, member: leo, approve: false);
    expect(parent.spacesForDevice(waiting.deviceId), isEmpty);
    expect(parent.changesSince({}, spaces: parent.spacesForDevice(waiting.deviceId)), isEmpty);
  });

  test('moving an item to another audience moves it between spaces', () async {
    final day = DateTime.utc(2026, 6, 3, 16).millisecondsSinceEpoch;
    final id = await parent.addEvent(title: 'Planning meeting', start: day, end: day + 3600000);
    await sync(parent, leoTablet);
    expect(leoTablet.event(id), isNotNull);
    await parent.updateEvent(id, {'audience': Audience.parents, 'title': 'Planning the surprise'});
    expect(parent.event(id)!.space, Space.parents);
    expect(parent.event(id)!.title, 'Planning the surprise');
    await sync(parent, leoTablet);
    expect(leoTablet.event(id), isNull);
    expect(leoTablet.history().map((h) => h.title), isNot(contains('Planning the surprise')));
  });
}
