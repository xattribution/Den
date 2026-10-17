import 'dart:async';
import 'dart:convert';

import '../access.dart';
import 'server.dart';

/// Serves MCP over newline-delimited JSON-RPC (the stdio transport): one message per line in,
/// one response per line out. [access] is looked up for every message, so a revoked token stops
/// working mid-session. Returns when [input] ends.
Future<void> serveMcpStdio(
  McpServer server,
  Access? Function() access,
  Stream<List<int>> input,
  void Function(String line) output,
) async {
  await for (final line in input.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      output(jsonEncode(McpServer.errorResponse(null, RpcError.parse, 'Parse error')));
      continue;
    }
    final who = access();
    if (who == null) {
      final id = message is Map ? message['id'] : null;
      if (message is Map && message.containsKey('id')) {
        output(jsonEncode(McpServer.errorResponse(id, -32001, 'The token no longer works; make a new one in the Den app')));
      }
      continue;
    }
    final messages = message is List ? message : [message];
    final responses = <Map<String, Object?>>[];
    for (final m in messages) {
      final r = await server.handle(m, who);
      if (r != null) responses.add(r);
    }
    if (responses.isEmpty) continue;
    output(jsonEncode(message is List ? responses : responses.single));
  }
}
