import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The family's rules for the in-app assistant (`family.assistant`), and what History shows of
/// what it did.
void main() {
  late TestClock clock;
  late Den phone;
  late String dana;
  late String sam;
  late String leo;
  late String ivy;

  setUp(() async {
    clock = TestClock.at(DateTime.utc(2026, 10, 28, 15));
    phone = await foundFamily(clock, timezone: 'America/Chicago');
    dana = phone.actor!.id;
    sam = await phone.addMember(name: 'Sam', role: Role.parent);
    leo = await phone.addMember(name: 'Leo', role: Role.kid, tier: Tier.big);
    ivy = await phone.addMember(name: 'Ivy', role: Role.kid, tier: Tier.little);
  });

  test('the assistant is off until a parent turns it on', () {
    final policy = phone.family!.assistant;
    expect(policy, const AssistantPolicy());
    expect(policy.enabled, isFalse);
    expect(policy.kidDailyLimit, AssistantPolicy.defaultKidDailyLimit);
    expect(policy.budgetCents, AssistantPolicy.defaultBudgetCents);
    expect(policy.allows(phone.member(dana)!), isFalse);
  });

  test('a parent turns it on: parents are on, kids a parent picks, never a little one', () async {
    final chosen = AssistantPolicy(enabled: true, members: {leo, ivy}, kidDailyLimit: 10, budgetCents: 800);
    await phone.updateFamily({'assistant': chosen.toJson()});
    final policy = phone.family!.assistant;
    expect(policy, chosen);
    expect(policy.allows(phone.member(dana)!), isTrue);
    expect(policy.allows(phone.member(sam)!), isTrue, reason: 'every parent is on');
    expect(policy.allows(phone.member(leo)!), isTrue);
    expect(policy.allows(phone.member(ivy)!), isFalse, reason: 'little kids and pre-readers stay off');
    await expectLater(phone.updateFamily({'assistant': {'enabled': true, 'budgetCents': -1}}), throwsA(isA<InvalidInput>()));
    await expectLater(phone.updateFamily({'assistant': {'members': [leo]}}), throwsA(isA<InvalidInput>()),
        reason: 'it says whether it is on');
    final tablet = await joinDevice(phone, clock, member: sam, name: 'Sam tablet');
    await sync(phone, tablet);
    expect(tablet.family!.assistant, chosen, reason: 'it syncs like any family setting');
  });

  test('only a parent on their own device decides it', () async {
    final ownHub = await joinDevice(phone, clock, member: dana, mode: DeviceMode.hub, name: 'Dana phone (hub)');
    await sync(phone, ownHub);
    ownHub.actAs(dana, via: 'Claude');
    await expectLater(ownHub.updateFamily({'assistant': {'enabled': true}}), throwsA(isA<PermissionDenied>()),
        reason: 'an assistant acting through the hub can\'t switch on an AI or raise its budget');
    ownHub.actAs(null);
    final kidTablet = await joinDevice(phone, clock, member: leo, name: 'Leo tablet');
    await sync(phone, kidTablet);
    await expectLater(kidTablet.updateFamily({'assistant': {'enabled': true}}), throwsA(isA<PermissionDenied>()));
    final samPhone = await joinDevice(phone, clock, member: sam, name: 'Sam phone');
    await sync(phone, samPhone);
    await samPhone.updateFamily({'assistant': {'enabled': true}});
    await sync(samPhone, phone);
    expect(phone.family!.assistant.enabled, isTrue, reason: 'either parent, on their own phone');
  });

  test('what the assistant changes says so in History, on every device', () async {
    const assistant = CaptureOrigin(CaptureKind.assistant, reader: 'Claude');
    const photo = CaptureOrigin(CaptureKind.photo, reader: 'Claude');
    final list = await phone.attributed(assistant, () => phone.addList(title: 'Camping'));
    final tent = await phone.attributed(assistant, () => phone.addItem(list, text: 'Tent'));
    await phone.attributed(assistant, () => phone.setItemChecked(tent, true));
    await phone.attributed(assistant, () => phone.updateList(list, {'title': 'Camping trip'}));
    final stove = await phone.attributed(assistant, () => phone.addItem(list, text: 'Stove', from: photo));
    await phone.attributed(assistant, () => phone.removeItem(stove));
    final mine = await phone.addItem(list, text: 'Lantern');

    final history = phone.history();
    HistoryEntry entry(String rid, String verb) => history.firstWhere((e) => e.rid == rid && e.verb == verb);
    expect(entry(list, 'added').from, assistant);
    expect(entry(tent, 'added').from, assistant);
    expect(entry(tent, 'checked').from, assistant, reason: 'checking an item still reads as checking');
    expect(entry(list, 'changed').from, assistant);
    expect(entry(stove, 'added').from, photo, reason: 'a change that names its own source keeps it');
    expect(entry(stove, 'removed').from, isNull, reason: 'a removal carries nothing else');
    expect(entry(mine, 'added').from, isNull, reason: 'outside the assistant, nothing is marked');

    final tablet = await joinDevice(phone, clock, member: dana, name: 'Dana tablet');
    await sync(phone, tablet);
    expect(tablet.history().firstWhere((e) => e.rid == tent && e.verb == 'added').from, assistant);
  });
}
