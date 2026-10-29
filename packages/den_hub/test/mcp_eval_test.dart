/// Replays the key flows of an assistant's end-to-end test of Den's MCP server against a live hub
/// (MCP-EVAL, numbered as that report numbers them), over HTTP the way a client calls it.
@Timeout(Duration(minutes: 3))
library;

import 'package:den_core/den_core.dart';

import 'support/fixture.dart';
import 'support/test.dart';

void main() {
  late HubFixture f;
  setUp(() async => f = await HubFixture.start());
  tearDown(() => f.stop());

  final sessions = <String, String>{};
  var id = 0;

  /// Calls tool [name] over MCP with [token] (a session per token), answering its result.
  Future<Map<String, Object?>> tool(String token, String name, Map<String, Object?> args) async {
    var session = sessions[token];
    if (session == null) {
      final init = await f.call('POST', '/mcp', token: token, body: {
        'jsonrpc': '2.0',
        'id': ++id,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'grok', 'version': '1'}},
      });
      session = sessions[token] = init.headers['mcp-session-id']!;
    }
    final r = await f.call('POST', '/mcp',
        token: token,
        headers: {'mcp-session-id': session},
        body: {
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': args},
        });
    expect(r.status, 200, reason: r.text);
    return (r.body['result'] as Map).cast<String, Object?>();
  }

  String text(Map<String, Object?> result) => ((result['content'] as List).single as Map)['text'] as String;
  Map<String, Object?> data(Map<String, Object?> result) => (result['structuredContent'] as Map).cast<String, Object?>();
  bool failed(Map<String, Object?> result) => result['isError'] == true;

  /// [tool], saying yes when it asks first.
  Future<Map<String, Object?>> yes(String token, String name, Map<String, Object?> args) async {
    final first = await tool(token, name, args);
    final confirm = data(first)['confirm'];
    if (confirm is! Map) return first;
    return tool(token, name, {...args, 'confirm': confirm['token']});
  }

  String today() => f.hubDen.todayDate();
  String later(int days) {
    final d = DateTime.parse('${today()}T00:00:00Z').add(Duration(days: days));
    return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
  }

  /// The first Tuesday or Thursday (Soccer practice) at least [after] days away.
  String soccerDay(int after) {
    for (var i = after;; i++) {
      final d = later(i);
      final w = DateTime.parse('${d}T00:00:00Z').weekday;
      if (w == DateTime.tuesday || w == DateTime.thursday) return d;
    }
  }

  test('#1 add_from_text adds over MCP and REST for a connection acting as a parent, and fails saying why', () async {
    final token = await f.token(scopes: {Scope.read, Scope.calendar, Scope.chores, Scope.lists}, label: 'GrokBot');
    final r = await tool(token, 'add_from_text', {'text': 'Haircut for Leo next Friday at 3', 'include_unsure': true});
    expect(failed(r), isFalse, reason: text(r));
    expect(text(r), startsWith('Added'));
    final added = (data(r)['added'] as List).cast<Map>().single;
    expect(f.hubDen.event(added['id'] as String)!.assignees, [f.id('Leo')]);
    expect(f.hubDen.history(type: RecordType.event).first.actorName, 'Alex', reason: 'it acts as the parent who made it');

    final rest = await f.call('POST', '/api/v1/actions/add_from_text', token: token, body: {'text': 'popcorn and apple juice'});
    expect(rest.status, 200, reason: rest.text);
    expect(((rest.body['result'] as Map)['added'] as List), isNotEmpty);

    final nothing = await tool(token, 'add_from_text', {'text': 'zzzz qqqq'});
    expect(failed(nothing), isTrue);
    expect(text(nothing), contains('othing'));
  });

  test('#2 undo after a preview still takes the change back', () async {
    final token = await f.token(scopes: {Scope.read, Scope.lists}, label: 'GrokBot');
    final added = await tool(token, 'add_items', {'list': 'Groceries', 'items': ['Butter']});
    final receipt = (data(added)['receipt'] as Map)['id'] as String;
    expect(text(added), contains('[receipt $receipt'), reason: '#15: text-only clients can undo it');
    final preview = await tool(token, 'undo', {'receipt': receipt, 'preview': true});
    expect(text(preview), startsWith('Nothing changed yet'));
    final undone = await tool(token, 'undo', {'receipt': receipt});
    expect(failed(undone), isFalse, reason: text(undone));
    expect(f.hubDen.lists.firstWhere((l) => l.list.title == 'Groceries').items.map((i) => i.text), isNot(contains('Butter')));
  });

  test('#3 a series split by "this and following" is still used by name', () async {
    final token = await f.token(scopes: {Scope.read, Scope.calendar}, label: 'GrokBot');
    final split = soccerDay(8);
    final moved = await yes(token, 'update_event', {
      'event': 'Soccer practice',
      'occurrence': split,
      'scope': 'following',
      'start': '${split}T16:30',
      'end': '${split}T18:00',
    });
    expect(failed(moved), isFalse, reason: text(moved));
    expect(f.hubDen.events.where((e) => e.title == 'Soccer practice'), hasLength(2));
    final ride = await tool(token, 'set_ride', {'event': 'Soccer practice', 'occurrence': later(28), 'leg': 'to', 'driver': 'me'});
    expect(failed(ride), isFalse, reason: text(ride));
    expect(text(ride), contains('Alex is driving Leo to Soccer practice'));
    expect(text(ride), contains('4:30 PM'));
    final next = await tool(token, 'set_ride', {'event': 'Soccer practice', 'leg': 'from', 'driver': 'Priya'});
    expect(failed(next), isFalse, reason: text(next));
  });

  test('#4 a kid\'s connection can\'t approve its own reward; a parent who asked can\'t approve either', () async {
    final parent = await f.token(scopes: {Scope.read, Scope.points}, label: 'GrokBot');
    await tool(parent, 'adjust_points', {'person': 'Leo', 'delta': 80, 'reason': 'Saved up'});
    final kid = await f.token(scopes: {Scope.read, Scope.points}, member: f.id('Leo'), label: 'Leo\'s helper');
    final asked = await tool(kid, 'request_reward', {'reward': r'$5'});
    expect(failed(asked), isFalse, reason: text(asked));
    final request = data(asked)['request_id'] as String;
    final self = await tool(kid, 'decide_reward_request', {'request': request, 'approve': true});
    expect(failed(self), isTrue);
    expect(text(self), startsWith('Den didn\'t allow that'));

    final onBehalf = await tool(parent, 'request_reward', {'reward': r'$5', 'person': 'Leo'});
    final second = data(onBehalf)['request_id'] as String;
    final own = await tool(parent, 'decide_reward_request', {'request': second, 'approve': true});
    expect(failed(own), isTrue);
    expect(text(own), contains('asked for this, so someone else needs to approve it'));
    final theirs = await tool(parent, 'decide_reward_request', {'request': request, 'approve': true});
    expect(failed(theirs), isFalse, reason: text(theirs));
  });

  test('#5 a connection whose person lives elsewhere is told which zone "today" and times are in', () async {
    final token = await f.phone.addTokenConnection(label: 'Owner in Hawaii', scopes: {Scope.read}, tz: 'Pacific/Honolulu');
    await f.toHub();
    final today = await tool(token, 'get_overview', {});
    expect(text(today), startsWith('Today in Chicago: '));
    final history = await tool(token, 'get_history', {'limit': 2});
    expect(text(history), endsWith('Times are Honolulu time.'));
    final family = await tool(token, 'get_family', {});
    expect(data(family)['me_timezone'], 'Pacific/Honolulu');
    final plain = await f.token(scopes: {Scope.read}, label: 'At home');
    expect(text(await tool(plain, 'get_overview', {})), isNot(startsWith('Today in')));
  });

  test('#6 a kid as the driver is refused, and one driver in two places is a gap', () async {
    final token = await f.token(scopes: {Scope.read, Scope.calendar}, label: 'GrokBot');
    final kid = await tool(token, 'set_ride', {'event': 'Swim lesson', 'leg': 'to', 'driver': 'Maya'});
    expect(failed(kid), isTrue);
    expect(text(kid), contains('Maya can\'t drive'));

    final day = soccerDay(2);
    final piano = await tool(token, 'create_event', {
      'title': 'Piano',
      'start': '${day}T17:00',
      'people': ['Maya'],
      'location': 'Music school',
      'rides': [
        {'leg': 'to', 'driver': 'nobody'},
      ],
    });
    expect(failed(piano), isFalse, reason: text(piano));
    await tool(token, 'set_ride', {'event': 'Soccer practice', 'occurrence': day, 'leg': 'to', 'driver': 'Priya'});
    final ride = await tool(token, 'set_ride', {'event': 'Piano', 'leg': 'to', 'driver': 'Priya'});
    expect(text(ride), contains('Note: Priya is driving two places at once'), reason: text(ride));
    final overview = await tool(token, 'get_overview', {'date': day});
    expect(text(overview), contains('Needs someone: Priya is driving two places at once'));
    expect((data(overview)['gaps'] as List).cast<Map>().map((g) => g['kind']), contains('driver_busy'));
  });

  test('#21 a connection approved before connections acted as someone acts as the parent who approved it', () async {
    const secret = 'den_legacy_connection_token_for_tests_0123456789';
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final fields = <String, Object?>{
      'label': 'Old script',
      'kind': ConnectionKind.token.name,
      'scopes': [Scope.read.name, Scope.lists.name],
      'member': null,
      'tokenHash': hashToken(secret),
      'client': null,
      'status': ConnectionStatus.active.name,
      'expires': null,
    };
    final alex = f.id('Alex');
    final unsigned = Change(
      id: '${f.phone.deviceId}:900000',
      space: Space.parents,
      hlc: Hlc(now, 0, f.phone.deviceId),
      type: RecordType.connection,
      rid: newId(),
      fields: fields,
      device: f.phone.deviceId,
      actor: alex,
      sig: '',
    );
    final change = Change(
      id: unsigned.id,
      space: unsigned.space,
      hlc: unsigned.hlc,
      type: unsigned.type,
      rid: unsigned.rid,
      fields: fields,
      device: unsigned.device,
      actor: alex,
      sig: await f.phone.keys.sign(unsigned.signedBytes),
    );
    expect((await f.hubDen.ingest([change])).invalid, isEmpty);
    final family = await tool(secret, 'get_family', {});
    expect(data(family)['me'], alex);
    final added = await tool(secret, 'add_items', {'list': 'Groceries', 'items': ['Butter']});
    expect(failed(added), isFalse, reason: text(added));
    expect(f.hubDen.history(type: RecordType.item).first.actorName, 'Alex');
  });
}
