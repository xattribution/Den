// Parental controls as sync serves them: a sitter's device past their last day gets nothing
// more, and a teen's "Just me" items reach parents' devices once parents may see them.
@Timeout(Duration(seconds: 60))
library;

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

import 'support/channels.dart';
import 'support/fake_relay.dart';
import 'support/family.dart';

void main() {
  test('a sitter\'s device past their last day is told so and gets nothing more', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final sam = await fam.founder.addMember(name: 'Sam', role: Role.guest);
    await fam.founder.updateMember(sam, {'until': '2999-12-31'});
    final samPhone = await fam.approvedDevice(member: sam, name: 'Sam phone');
    final parentNode = SyncNode(fam.founder);
    final samNode = SyncNode(samPhone);
    addTearDown(() => Future.wait([parentNode.close(), samNode.close()]));

    final first = await link(parentNode, samNode);
    await first.live;
    await converge([fam.founder, samPhone]);

    // The day passes while they are connected: the session ends at the next change.
    await fam.founder.updateMember(sam, {'until': '2020-01-01'});
    await eventually(() => first.session.isClosed);
    expect(first.closeReason, contains('access-ended'));
    expect(fam.founder.device(samPhone.deviceId)!.revoked, isFalse, reason: 'nobody removed it yet; sync just stops');

    // Connecting again is refused at once, and nothing new reaches it.
    final list = await fam.founder.addList(title: 'Groceries');
    final again = await link(parentNode, samNode);
    await eventually(() => again.session.isClosed);
    expect(again.closeReason, contains('access-ended'));
    expect(samPhone.list(list), isNull);
  });

  test('a teen\'s "Just me" items reach a parent\'s device through the hub once parents may see them', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final maya = await fam.founder.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen, grants: {Grant.events});
    await fam.founder.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
    final hub = await fam.approvedDevice(mode: DeviceMode.hub, kind: DeviceKind.hub, name: 'Hub');
    final mayaPhone = await fam.approvedDevice(member: maya, name: 'Maya phone');
    final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
    final phoneNode = SyncNode(fam.founder);
    final hubNode = SyncNode(hub);
    final mayaNode = SyncNode(mayaPhone);
    final laptopNode = SyncNode(laptop);
    addTearDown(() => Future.wait([phoneNode.close(), hubNode.close(), mayaNode.close(), laptopNode.close()]));

    // The hub learns the family from the parent's phone, which keeps a session open with it.
    await (await link(phoneNode, hubNode)).live;
    await (await link(hubNode, mayaNode)).live;
    await converge([fam.founder, hub, mayaPhone]);

    final diary = await mayaPhone.addEvent(title: 'Call Jess', start: at(16), end: at(17), audience: Audience.justMe);
    await eventually(() => hub.event(diary) != null);
    final toLaptop = await link(hubNode, laptopNode);
    await toLaptop.live;
    await eventually(() => laptop.family != null && laptop.member(maya) != null);
    expect(laptop.spacesForDevice(laptop.deviceId), isNot(contains(Space.member(maya))));
    expect(laptop.event(diary), isNull);

    await fam.founder.updateFamily({'oversight.$maya': {'parentsSeePrivate': true}});
    await eventually(() => laptop.event(diary) != null);
    expect(laptop.event(diary)!.title, 'Call Jess');
    expect(await laptop.spaceKey(Space.member(maya)), await hub.spaceKey(Space.member(maya)));
    expect(laptop.privacyChange(maya)!.parentsSee, isTrue);
  });
  test('without a hub, the teen\'s device hands parents the key and posts what is older than the mailbox keeps', () async {
    if (await skipUnlessDenCore()) return;
    final fam = await TestFamily.create();
    final maya = await fam.founder.addMember(name: 'Maya', role: Role.kid, tier: Tier.teen, grants: {Grant.events});
    final mayaPhone = await fam.approvedDevice(member: maya, name: 'Maya phone');
    final phoneNode = SyncNode(fam.founder);
    final mayaNode = SyncNode(mayaPhone);
    addTearDown(() => Future.wait([phoneNode.close(), mayaNode.close()]));
    // Each device meets the parent's phone once, then they share only the relay.
    Future<void> meet(SyncNode node) async {
      final peer = await link(phoneNode, node);
      await peer.live;
      await peer.close();
    }

    await meet(mayaNode);
    await fam.founder.updateFamily({'oversight.$maya': {'parentsSeePrivate': false}});
    final laptop = await fam.approvedDevice(member: fam.parent, kind: DeviceKind.desktop, name: 'Pat laptop');
    final laptopNode = SyncNode(laptop);
    addTearDown(laptopNode.close);
    await meet(laptopNode);
    expect(await laptop.spaceKey(Space.member(maya)), isNull);
    final diary = await mayaPhone.addEvent(title: 'Call Jess', start: at(16), end: at(17), audience: Audience.justMe);

    final relay = FakeRelay();
    final url = Uri.parse('https://relay.test');
    // Maya's phone runs 60 days later: her item is older than the mailbox keeps.
    var later = DateTime.now().add(const Duration(days: 60)).millisecondsSinceEpoch;
    final mayaMail = MailboxSync(node: mayaNode, relay: RelayMailbox(url, client: relay.client), now: () => later);
    final phoneMail = MailboxSync(node: phoneNode, relay: RelayMailbox(url, client: relay.client));
    final laptopMail = MailboxSync(node: laptopNode, relay: RelayMailbox(url, client: relay.client));
    await phoneMail.syncOnce();
    await mayaMail.syncOnce();
    await laptopMail.syncOnce();
    expect(mayaPhone.family!.parentsSeePrivate(maya), isFalse);
    expect(laptop.event(diary), isNull);

    await fam.founder.updateFamily({'oversight.$maya': {'parentsSeePrivate': true}});
    await phoneMail.syncOnce();
    later += 60000;
    final round = await mayaMail.syncOnce();
    expect(round.keysDelivered, 2, reason: 'both of Pat\'s devices');
    await laptopMail.syncOnce();
    await laptopMail.syncOnce();
    expect(laptop.event(diary)?.title, 'Call Jess');
    expect(laptop.privacyChange(maya)!.parentsSee, isTrue);

    // Once is enough.
    expect((await mayaMail.syncOnce()).keysDelivered, 0);
  });
}
