import 'package:den_app/net/den_network.dart';
import 'package:den_app/net/hub_api.dart';
import 'package:den_app/net/hub_client.dart';
import 'package:den_app/net/hub_connections.dart';
import 'package:den_app/screens/settings/connections_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/shots.dart';
import 'family_fakes.dart';

/// The hub's waiting sign-ins, answering at once.
class FakeSignIns implements HubConnections {
  FakeSignIns(this.waiting);

  final List<ConnectionRequest> waiting;
  final List<String> admitted = [];
  final List<String> declined = [];

  @override
  DenNetwork get network => throw UnimplementedError();

  @override
  Future<List<ConnectionRequest>> requests() async => [...waiting];

  @override
  Future<String?> admit(ConnectionRequest request) async {
    admitted.add(request.id);
    waiting.removeWhere((r) => r.id == request.id);
    return 'CONN1';
  }

  @override
  Future<void> decline(ConnectionRequest request) async {
    declined.add(request.id);
    waiting.removeWhere((r) => r.id == request.id);
  }
}

ConnectionRequest request(String id, String name, String host, String code) => ConnectionRequest(
      id: id,
      code: code,
      clientName: name,
      redirectHost: host,
      scopes: const ['read', 'calendar'],
      expires: demoNow.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('An app signing in waits for a parent to let it in, by the code its screen shows', (tester) async {
    final state = await demo(tester);
    final hub = FakeSignIns([request('q1', 'Claude', 'claude.ai', 'K7QP-M4XD'), request('q2', 'Helper', 'evil.example', 'ZZZZ-ZZZZ')]);
    await pumpScreen(tester, ConnectionsScreen(signIns: hub), state: state);
    await tester.pumpAndSettle();
    expect(find.text('Claude (claude.ai) wants to connect'), findsOneWidget);
    expect(find.text('Code K7QP-M4XD'), findsOneWidget);
    await matchShot('settings_connection_sign_in_phone');

    await tester.tap(find.text('Let Claude in'));
    await tester.pumpAndSettle();
    expect(hub.admitted, ['q1']);
    expect(find.text('Claude (claude.ai) wants to connect'), findsNothing);
    expect(find.text('Approve Claude below once it shows up.'), findsWidgets);

    await tester.tap(find.text('Decline').first);
    await tester.pumpAndSettle();
    expect(hub.declined, ['q2']);
    expect(find.textContaining('wants to connect'), findsNothing);
  });

  test("The hub's limits become words that say what to do", () {
    HubException error(int status, Map<String, Object?> body, [Map<String, String> headers = const {}]) =>
        hubError(http.Response('', status, headers: headers), body);

    final limited = error(429, {
      'error': {'code': 'rate_limited', 'message': 'Too many tries.', 'details': {'retry_after': 600}},
    });
    expect(limited.message, 'Too many tries from here. Try again in 10 minutes.');
    expect(limited.retryAfter, 600);
    expect(
      error(429, {'error': {'code': 'rate_limited'}}, {'retry-after': '30'}).message,
      'Too many tries from here. Try again in a minute.',
    );
    expect(error(429, {'error': {'code': 'busy', 'details': {'retry': true}}}).message, contains('Try again in a moment'));
    expect(error(408, {'error': {'code': 'timeout'}}).message, contains('better connection'));
    expect(error(413, {'error': {'code': 'too_large'}}).message, contains('smaller'));
    final closed = error(403, {
      'error': {'code': 'link_closed', 'message': 'A parent needs to open Add a device in Den first, on their phone. Then try again here.'},
    });
    expect(closed.code, 'link_closed');
    expect(closed.message, startsWith('A parent needs to open Add a device'));
    expect(waitWords(3600), 'an hour');
    expect(waitWords(7200), '2 hours');
  });
}
