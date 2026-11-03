import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Links with other families (FamilyLink): a parent makes one and says what goes to the other
/// family; the hub says how it went and keeps what's shared in step.
void main() {
  late TestClock clock;
  late Den phone;
  late Den hub;
  late String leo;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 11, 3, 10));
    phone = await foundFamily(clock);
    leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big, grants: {Grant.lists});
    hub = await joinDevice(phone, clock, mode: DeviceMode.hub, name: 'Hub', kind: DeviceKind.hub);
  });

  test('a parent links, shares the calendar and a list, and the hub says how it went', () async {
    final groceries = await phone.addList(title: 'Groceries', kind: ListKind.shopping);
    final id = await phone.addFamilyLink();
    expect(phone.familyLink(id)!.status, LinkStatus.waiting);
    await phone.shareWithFamily(id, Shared.calendar, ShareLevel.see);
    await phone.shareWithFamily(id, groceries, ShareLevel.edit);
    await sync(phone, hub);
    await hub.noteFamilyLink(id, {
      'status': LinkStatus.linked.name,
      'name': 'Smith',
      'peer': 'abcdefghijklmnop',
      'theirs': {Shared.calendar: 'edit'},
    });
    await sync(hub, phone);
    final link = phone.familyLink(id)!;
    expect(link.status, LinkStatus.linked);
    expect(link.name, 'Smith');
    expect(link.share, {Shared.calendar: ShareLevel.see, groceries: ShareLevel.edit});
    expect(link.theirs, {Shared.calendar: ShareLevel.edit});
    await phone.shareWithFamily(id, groceries, null);
    expect(phone.familyLink(id)!.share, {Shared.calendar: ShareLevel.see});
    await phone.endFamilyLink(id);
    expect(phone.familyLink(id)!.status, LinkStatus.ended);
  });

  test('only a parent decides what goes to another family; the hub only reports', () async {
    final id = await phone.addFamilyLink();
    await sync(phone, hub);
    await expectLater(hub.shareWithFamily(id, Shared.calendar, ShareLevel.edit), throwsA(isA<PermissionDenied>()));
    await expectLater(hub.addFamilyLink(), throwsA(isA<PermissionDenied>()));
    final tablet = await joinDevice(phone, clock, member: leo, name: 'Leo\'s tablet');
    await sync(phone, tablet);
    await expectLater(tablet.shareWithFamily(id, Shared.calendar, ShareLevel.see), throwsA(isA<PermissionDenied>()));
    // Acting for an app, the hub doesn't report either.
    hub.actAs(null, via: 'Home Assistant');
    await expectLater(hub.noteFamilyLink(id, {'status': LinkStatus.linked.name}), throwsA(isA<PermissionDenied>()));
  });

  test('the hub writes another family\'s shared list and items as they are, marked with the link', () async {
    final id = await phone.addFamilyLink();
    await sync(phone, hub);
    final made = await hub.writeLinked(RecordType.list, 'theirgrocerylist', Space.family,
        {'title': 'Smith groceries', 'kind': 'shopping', 'link': id});
    await hub.writeLinked(RecordType.item, 'theirmilkitem000', Space.family,
        {'list': 'theirgrocerylist', 'text': 'Milk', 'checked': false});
    expect(made.type, RecordType.list);
    await sync(hub, phone);
    final list = phone.list('theirgrocerylist')!;
    expect(list.list.link, id);
    expect(list.items.single.text, 'Milk');
    // Leo checks it off here, like any list.
    final tablet = await joinDevice(phone, clock, member: leo, name: 'Leo\'s tablet');
    await sync(phone, tablet);
    await tablet.setItemChecked('theirmilkitem000', true);
    expect(tablet.list('theirgrocerylist')!.items.single.checked, isTrue);
    await expectLater(hub.writeLinked(RecordType.chore, 'x', Space.family, {'title': 'x'}), throwsA(isA<InvalidInput>()));
  });
}
