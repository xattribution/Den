@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:den_core/den_core.dart';
import 'support/test.dart';

import 'support/fixture.dart';

/// Reads server-sent events from the hub.
class SseClient {
  SseClient._(this._response) {
    _sub = _response.transform(utf8.decoder).transform(const LineSplitter()).listen(_line, onDone: () => _done.complete());
  }

  static Future<SseClient> open(Uri url, String token) async {
    final client = HttpClient();
    final request = await client.getUrl(url);
    request.headers.set('authorization', 'Bearer $token');
    request.headers.set('accept', 'text/event-stream');
    final response = await request.close();
    final sse = SseClient._(response)
      ..status = response.statusCode
      ..contentType = response.headers.value('content-type')
      .._client = client;
    return sse;
  }

  final HttpClientResponse _response;
  late final StreamSubscription<String> _sub;
  late final HttpClient _client;
  final Completer<void> _done = Completer();
  final StreamController<(String, Map<String, Object?>, String?)> _events = StreamController.broadcast();
  final List<(String, Map<String, Object?>, String?)> received = [];
  final List<String> lines = [];
  int? status;
  String? contentType;
  String _event = '';
  String? _id;
  final List<String> _data = [];

  void _line(String line) {
    lines.add(line);
    if (line.isEmpty) {
      if (_data.isNotEmpty) {
        final e = (_event, (jsonDecode(_data.join('\n')) as Map).cast<String, Object?>(), _id);
        received.add(e);
        _events.add(e);
      }
      _event = '';
      _id = null;
      _data.clear();
      return;
    }
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final name = colon < 0 ? line : line.substring(0, colon);
    final value = colon < 0 ? '' : line.substring(colon + 1).trimLeft();
    if (name == 'event') _event = value;
    if (name == 'data') _data.add(value);
    if (name == 'id') _id = value;
  }

  Future<(String, Map<String, Object?>, String?)> next(String event, {Duration timeout = const Duration(seconds: 10)}) {
    final have = received.where((e) => e.$1 == event).toList();
    if (have.isNotEmpty) {
      received.remove(have.first);
      return Future.value(have.first);
    }
    return _events.stream.firstWhere((e) => e.$1 == event).timeout(timeout).then((e) {
      received.remove(e);
      return e;
    });
  }

  Future<void> get done => _done.future;

  Future<void> close() async {
    await _sub.cancel();
    _client.close(force: true);
  }
}

/// Lets the hub's 250 ms change batch from earlier writes go out.
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 400));

void main() {
  late HubFixture f;
  setUpAll(() async => f = await HubFixture.start());
  tearDownAll(() => f.stop());

  test('opens with retry and hello, then says what changed after a write', () async {
    final token = await f.token(scopes: {Scope.read, Scope.lists}, label: 'Kitchen');
    await settle();
    final sse = await SseClient.open(f.base.resolve('/api/v1/stream'), token);
    addTearDown(sse.close);
    expect(sse.status, 200);
    expect(sse.contentType, 'text/event-stream; charset=utf-8');
    final hello = await sse.next('hello');
    expect(sse.lines.first, 'retry: 5000');
    expect(hello.$2['hub'], f.hubDen.deviceId);
    expect(hello.$2['time_ms'], isA<int>());
    final groceries = f.phone.lists.firstWhere((l) => l.list.title == 'Groceries').list.id;
    await f.call('POST', '/api/v1/lists/$groceries/items', token: token, body: {'text': 'Basil'});
    final changed = await sse.next('changed');
    expect(changed.$2['types'], ['item']);
    expect((changed.$2['records'] as List).single, containsPair('type', 'item'));
    expect(changed.$2['via'], 'Kitchen');
    expect(changed.$2['actor'], f.id('Alex'), reason: 'the token acts as the parent who made it');
    expect(changed.$3, matches(RegExp(r'^\d{13}-[0-9a-f]{4}-')));
  });

  test('changes synced from a phone arrive too, and a kid never hears of private ones', () async {
    final leo = f.id('Leo');
    final kidToken = await f.token(member: leo, label: 'Leo');
    final parentToken = await f.token(label: 'Parents');
    await settle();
    final kid = await SseClient.open(f.base.resolve('/api/v1/stream'), kidToken);
    final parent = await SseClient.open(f.base.resolve('/api/v1/stream'), parentToken);
    addTearDown(kid.close);
    addTearDown(parent.close);
    await kid.next('hello');
    await parent.next('hello');
    await f.phone.addEvent(title: 'Surprise party planning', start: 1, end: 2, audience: Audience.parents);
    await f.toHub();
    final p = await parent.next('changed');
    expect(p.$2['types'], ['event']);
    expect((p.$2['records'] as List).single, containsPair('space', 'p'));
    expect(p.$2['actor'], f.id('Alex'));
    await f.phone.addEvent(title: 'Family movie', start: 1, end: 2);
    await f.toHub();
    final k = await kid.next('changed');
    expect((k.$2['records'] as List).single, containsPair('space', 'f'));
    expect(kid.received.where((e) => e.$1 == 'changed'), isEmpty, reason: 'the private event never showed up');
  });

  test('a revoked token gets goodbye and the stream closes', () async {
    final token = await f.token(label: 'Short lived');
    final sse = await SseClient.open(f.base.resolve('/api/v1/stream'), token);
    addTearDown(sse.close);
    await sse.next('hello');
    await f.phone.revokeConnection(f.phone.connections.firstWhere((c) => c.label == 'Short lived').id);
    await f.toHub();
    final bye = await sse.next('goodbye');
    expect(bye.$2, {'reason': 'token_revoked'});
    await sse.done.timeout(const Duration(seconds: 5));
    final again = await f.call('GET', '/api/v1/stream', token: token);
    expect(again.status, 401);
  });

  test('errors before the stream starts are JSON', () async {
    final noRead = await f.token(scopes: {Scope.lists}, label: 'No read');
    final r = await f.call('GET', '/api/v1/stream', token: noRead);
    expect(r.status, 403);
    expect(r.error['code'], 'insufficient_scope');
  });
}
