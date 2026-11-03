import 'package:den_actions/den_actions.dart' show readableSpacesFor;
import 'package:den_actions/times.dart';
import 'package:den_core/den_core.dart';
import 'package:shelf/shelf.dart';

import '../context.dart';
import '../feed_links.dart';
import '../http_util.dart';
import 'watch.dart';
import 'write.dart';

/// Calendar feeds out: `GET /ics/<secret>/family.ics` and `GET /ics/<secret>/<memberId>.ics`
/// (events assigned to that member, plus events for everyone unless `?everyone=0`). The secret
/// is a calendar link's ([HubFeedLinks]), which opens only its own file and holds what the
/// parent who made it may read. An API token doesn't open a feed: pasted into a calendar app or
/// service, it would be a key to the whole API sitting in someone else's settings.
///
/// A link for another family opens `GET /ics/<secret>/shared.ics`, which reads as the family,
/// not as its maker: the family's Everyone events with their full details, never Parents-only or
/// Just-me ones, and never events copied in from a Den feed (another family's share), so a
/// family's events neither come back to it nor travel on to a third family. Its UIDs are
/// `<eventId>@<familyId>.den`, so a hub subscribed to it can tell its own family's events apart.
/// It also opens `GET /ics/<secret>/watch` ([ShareWatchServer]).
///
/// Every feed answers with a weak ETag ([icsEtag]) and `304` to a conditional GET that names it.
class IcsExport {
  /// Creates the export for [hub], taking calendar links from [links].
  IcsExport(this.hub, {this.links}) {
    final l = links;
    if (l != null) watch = ShareWatchServer(hub, l, etag: () async => icsEtag(await _shared()));
  }

  /// Shared hub context.
  final HubContext hub;

  /// Calendar links, when the hub makes them.
  final HubFeedLinks? links;

  /// The watch streams of shared feeds, when the hub makes calendar links.
  ShareWatchServer? watch;

  /// Answers one feed request, or a shared feed's watch stream (`watch`).
  Future<Response> feed(Request request, String token, String file) async {
    if (!hub.ready) throw ApiError.notReady();
    hub.checkFailures(request);
    final link = links?.resolve(token);
    if (link == null) {
      hub.failed(request);
      throw ApiError.unauthorized('That calendar link no longer works. Make a new one in Den: Settings, Calendars.');
    }
    if (file == 'watch') {
      final w = watch;
      if (!link.shared || w == null) throw ApiError.notFound();
      return w.open(link);
    }
    if (!file.endsWith('.ics')) throw ApiError.notFound();
    // A calendar link opens the one feed it was made for.
    if (file != link.file) throw ApiError.notFound();
    final String text;
    if (link.shared) {
      text = await _shared();
    } else {
      final name = file.substring(0, file.length - 4);
      text = await hub.gate.run(link.member, 'Calendar link', () {
        final den = hub.den;
        String? person;
        if (name != 'family') {
          if (den.member(name) == null) throw ApiError.notFound(type: 'member', id: name);
          person = name;
        }
        final family = den.family?.name ?? 'Den';
        return _write(
          spaces: readableSpacesFor(den, link.member),
          person: person,
          everyone: request.url.queryParameters['everyone'] != '0',
          title: person == null ? family : '${den.member(person)!.name} ($family)',
        );
      });
    }
    final etag = icsEtag(text);
    final headers = {'etag': etag, 'cache-control': 'private, max-age=300'};
    if (etagMatches(request.headers['if-none-match'], etag)) return Response(304, headers: headers);
    return Response.ok(text, headers: {
      ...headers,
      'content-type': 'text/calendar; charset=utf-8',
      'content-disposition': 'inline; filename="$file"',
    });
  }

  /// The shared feed: Everyone events, none copied in from a Den feed or a linked family, read as
  /// the family.
  Future<String> _shared() => hub.gate.asHub(() {
        final den = hub.den;
        return _write(
          spaces: {if (den.spacesForDevice(den.deviceId).contains(Space.family)) Space.family},
          title: den.family?.name ?? 'Den',
          shared: true,
          uidDomain: sharedUidDomain(den.familyId!),
        );
      });

  /// The feed of the events in [spaces] (with [person], theirs, and everyone's unless not
  /// [everyone]); with [shared], none that came from a Den feed.
  String _write({
    required Set<String> spaces,
    required String title,
    String? person,
    bool everyone = true,
    bool shared = false,
    String uidDomain = legacyUidDomain,
  }) {
    final den = hub.den;
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
        if (spaces.contains(e.space) &&
            (person == null || e.assignees.contains(person) || (everyone && e.assignees.isEmpty)) &&
            !(shared && ((e.source.kind == 'ics' && isDenUid(e.source.ref)) || e.link != null)))
          IcsExportEvent(
            e,
            zone: zoneOfEvent(e, hub.zone),
            exceptions: exceptions['${e.space}|${e.id}'] ?? const [],
            category: e.category == null ? null : categories[e.category],
          ),
    ];
    return writeIcs(name: title, zone: hub.zone, events: events, now: hub.now(), uidDomain: uidDomain);
  }

  /// Closes the shared feeds' watch streams.
  Future<void> shutdown() async => watch?.shutdown();
}
