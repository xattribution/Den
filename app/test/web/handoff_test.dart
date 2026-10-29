// Runs in a real browser: flutter test --platform chrome test/web
@TestOn('browser')
library;

import 'package:den_app/platform/web/handoff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

/// The link Safari keeps for the Home Screen app, in a real page's cookies (handoff.dart).
void main() {
  setUp(Handoff.debugReset);

  test('kept in Safari, taken once by the Home Screen app, then gone', () {
    Handoff.keep('/join/maple-river-canoe-tiger');
    expect(web.document.cookie, contains('den_handoff='));
    expect(Handoff.take(standalone: false), isNull, reason: 'Safari keeps it for the Home Screen app');
    expect(Handoff.take(standalone: true), '/join/maple-river-canoe-tiger');
    expect(web.document.cookie, isNot(contains('den_handoff=%2F')), reason: 'cleared once taken');
    Handoff.debugReset();
    expect(Handoff.take(standalone: true), isNull);
  });

  test('only once per start, and only a route', () {
    Handoff.keep('/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6');
    expect(Handoff.take(standalone: true), '/setup/ABCD-EFGH/h7q2kx4m9pa3tbv6');
    Handoff.keep('/join/maple-river-canoe-tiger');
    expect(Handoff.take(standalone: true), isNull, reason: 'the first start took its link already');
    Handoff.debugReset();
    Handoff.keep('https://elsewhere.example/');
    expect(Handoff.take(standalone: true), isNull);
  });
}
