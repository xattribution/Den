import 'package:den_net/den_net.dart';
import 'package:test/test.dart';

/// One parser for every link Den makes, whatever it arrives in.
void main() {
  test('an invite to a family: the link, the route, the message, or the words', () {
    final link = DenLink.parse('https://den.example.com/#/join/maple-river-canoe-tiger')!;
    expect(link.kind, DenLinkKind.family);
    expect(link.words, 'maple river canoe tiger');
    expect(link.hub.toString(), 'https://den.example.com');
    expect(link.route, '/join/maple-river-canoe-tiger');
    expect(link.link().toString(), 'https://den.example.com/join/maple-river-canoe-tiger');

    expect(DenLink.parse('/join/maple-river-canoe-tiger')!.words, 'maple river canoe tiger');
    const message = 'Zoe, join The Carters on Den: https://den.example.com:8443/#/join/maple-river-canoe-tiger\n\n'
        'If Den asks for a code, type: maple river canoe tiger';
    final inMessage = DenLink.parse(message)!;
    expect(inMessage.hub.toString(), 'https://den.example.com:8443');
    expect(inMessage.words, 'maple river canoe tiger');
    // A messaging app that dropped the link still leaves the words.
    final noLink = DenLink.parse(message.replaceFirst(RegExp(r'https://\S+'), 'the link'))!;
    expect(noLink.words, 'maple river canoe tiger');
    expect(noLink.hub, isNull);
    expect(DenLink.parse(' Maple, river  canoe-tiger ')!.words, 'maple river canoe tiger');
    expect(DenLink.parse('Pick up milk on the way home'), isNull);
  });

  test('a group, a setup link and a recovery code, each its own kind', () {
    final group = DenLink.parse('https://den.example.com/#/group/maple-river-canoe-tiger')!;
    expect(group.kind, DenLinkKind.group);
    expect(group.words, 'maple river canoe tiger');

    final setup = DenLink.parse('https://den.example.com/#/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6')!;
    expect(setup.kind, DenLinkKind.setup);
    expect(setup.code, 'ABCD-EFGH');
    expect(setup.hubDevice, 'h7q2kx4m9pa3tbv6');
    expect(setup.route, '/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6');
    expect(DenLink.parse('/setup/abcdefgh/h7q2kx4m9pa3tbv6')!.code, 'ABCD-EFGH');
    expect(DenLink.parse('/setup/ABC/x'), isNull);

    final recover = DenLink.parse('https://den.example.com/#/recover/maple-river-canoe-tiger')!;
    expect(recover.kind, DenLinkKind.recover);
  });
}
