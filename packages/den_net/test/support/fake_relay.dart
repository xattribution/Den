import 'dart:convert';

import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory relay mailbox behind package:http's MockClient.
class FakeRelay {
  final Map<String, List<List<int>>> blobs = {};
  final Map<String, List<int>> cursors = {};

  /// Mailbox ids read, in order.
  final List<String> reads = [];
  var _next = 1;

  late final http.Client client = MockClient((request) async {
    final segments = request.url.pathSegments;
    if (segments.length != 2 || segments[0] != 'mailbox') return http.Response('{}', 404);
    final id = segments[1];
    if (request.method == 'POST') {
      (blobs[id] ??= []).add(request.bodyBytes);
      (cursors[id] ??= []).add(_next++);
      return http.Response(jsonEncode({'cursor': cursors[id]!.last}), 200);
    }
    reads.add(id);
    final after = int.parse(request.url.queryParameters['after'] ?? '0');
    final items = <Map<String, Object?>>[];
    final list = blobs[id] ?? const [];
    for (var i = 0; i < list.length; i++) {
      if (cursors[id]![i] > after) items.add({'c': cursors[id]![i], 'b': b64e(list[i])});
    }
    return http.Response(
      jsonEncode({'items': items, 'next': items.isEmpty ? after : items.last['c'], 'more': false}),
      200,
    );
  });
}
