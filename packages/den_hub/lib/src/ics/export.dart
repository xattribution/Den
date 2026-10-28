import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import '../access.dart';
import '../context.dart';
import '../http_util.dart';
import '../recurrence.dart';
import 'write.dart';

/// Calendar feeds out: `GET /ics/<token>/family.ics` and `GET /ics/<token>/<memberId>.ics`
/// (events assigned to that member, plus events for everyone unless `?everyone=0`). The token
/// in the path needs the read scope; the feed holds what that token may read.
class IcsExport {
  /// Creates the export for [hub].
  IcsExport(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// Answers one feed request.
  Future<Response> feed(Request request, String token, String file) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    final access = accessForToken(hub.den, token);
    if (access == null) {
      hub.failed(request);
      throw ApiError.unauthorized('That calendar link no longer works.');
    }
    if (!access.has(Scope.read)) throw ApiError.scope('read');
    if (!file.endsWith('.ics')) throw ApiError.notFound();
    final name = file.substring(0, file.length - 4);
    final text = await hub.gate.run(access.member, access.label, () {
      final den = hub.den;
      final readable = access.readable(den);
      String? member;
      if (name != 'family') {
        if (den.member(name) == null) throw ApiError.notFound(type: 'member', id: name);
        member = name;
      }
      final everyone = request.url.queryParameters['everyone'] != '0';
      final records = ((den.exportJson()['records'] as Map?)?['eventException'] as Map?) ?? const {};
      final exceptions = <String, List<IcsException>>{};
      for (final r in records.values) {
        if (r is! Map) continue;
        final f = (r['fields'] as Map?)?.cast<String, Object?>() ?? const {};
        final occurrence = f['occurrence'];
        if (occurrence is! int) continue;
        (exceptions['${r['space']}|${f['event']}'] ??= []).add(IcsException(
          occurrence,
          cancelled: f['cancelled'] == true,
          patch: ((f['patch'] as Map?) ?? const {}).cast<String, Object?>(),
        ));
      }
      final categories = {for (final c in den.categories) c.id: c.name};
      final events = [
        for (final e in den.events)
          if (readable.contains(e.space) &&
              (member == null || e.assignees.contains(member) || (everyone && e.assignees.isEmpty)))
            IcsExportEvent(
              e,
              zone: zoneOfEvent(e, hub.zone),
              exceptions: exceptions['${e.space}|${e.id}'] ?? const [],
              category: e.category == null ? null : categories[e.category],
            ),
      ];
      final family = den.family?.name ?? 'Den';
      final title = member == null ? family : '${den.member(member)!.name} ($family)';
      return writeIcs(name: title, zone: hub.zone, events: events, now: hub.now());
    });
    return Response.ok(text, headers: {
      'content-type': 'text/calendar; charset=utf-8',
      'cache-control': 'private, max-age=300',
      'content-disposition': 'inline; filename="$file"',
    });
  }
}
