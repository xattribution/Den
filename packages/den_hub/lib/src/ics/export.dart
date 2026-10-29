import 'package:den_actions/den_actions.dart' show readableSpacesFor;
import 'package:den_actions/times.dart';
import 'package:shelf/shelf.dart';

import '../context.dart';
import '../feed_links.dart';
import '../http_util.dart';
import 'write.dart';

/// Calendar feeds out: `GET /ics/<secret>/family.ics` and `GET /ics/<secret>/<memberId>.ics`
/// (events assigned to that member, plus events for everyone unless `?everyone=0`). The secret
/// is a calendar link's ([HubFeedLinks]), which opens only its own file and holds what the
/// parent who made it may read. An API token doesn't open a feed: pasted into a calendar app or
/// service, it would be a key to the whole API sitting in someone else's settings.
class IcsExport {
  /// Creates the export for [hub], taking calendar links from [links].
  IcsExport(this.hub, {this.links});

  /// Shared hub context.
  final HubContext hub;

  /// Calendar links, when the hub makes them.
  final HubFeedLinks? links;

  /// Answers one feed request.
  Future<Response> feed(Request request, String token, String file) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    final link = links?.resolve(token);
    if (link == null) {
      hub.failed(request);
      throw ApiError.unauthorized('That calendar link no longer works. Make a new one in Den: Settings, Calendars.');
    }
    if (!file.endsWith('.ics')) throw ApiError.notFound();
    // A calendar link opens the one feed it was made for.
    if (file != link.file) throw ApiError.notFound();
    final name = file.substring(0, file.length - 4);
    final member = link.member;
    final text = await hub.gate.run(member, 'Calendar link', () {
      final den = hub.den;
      final readable = readableSpacesFor(den, member);
      String? person;
      if (name != 'family') {
        if (den.member(name) == null) throw ApiError.notFound(type: 'member', id: name);
        person = name;
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
              (person == null || e.assignees.contains(person) || (everyone && e.assignees.isEmpty)))
            IcsExportEvent(
              e,
              zone: zoneOfEvent(e, hub.zone),
              exceptions: exceptions['${e.space}|${e.id}'] ?? const [],
              category: e.category == null ? null : categories[e.category],
            ),
      ];
      final family = den.family?.name ?? 'Den';
      final title = person == null ? family : '${den.member(person)!.name} ($family)';
      return writeIcs(name: title, zone: hub.zone, events: events, now: hub.now());
    });
    return Response.ok(text, headers: {
      'content-type': 'text/calendar; charset=utf-8',
      'cache-control': 'private, max-age=300',
      'content-disposition': 'inline; filename="$file"',
    });
  }
}
