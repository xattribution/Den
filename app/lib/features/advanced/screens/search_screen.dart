import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/family_reads.dart';
import '../../../app/navigation.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../calendar/calendar.dart';
import '../words/history_words.dart';

/// Search (Today's header, the iPad sidebar, ⌘F): what you type finds people, events, chores,
/// lists and list items by name, place or note, as you type, grouped by kind. One tap opens a
/// result; Return opens the first. Nothing found offers History, where what was removed or
/// renamed still is.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.query});
  final String? query;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// The kinds of result, in the order they show, with their headings.
const Map<String, String> searchKinds = {
  RecordType.member: 'People',
  RecordType.event: 'Events',
  RecordType.chore: 'Chores',
  RecordType.list: 'Lists',
  RecordType.item: 'On lists',
  RecordType.reward: 'Rewards',
  RecordType.goal: 'Goals',
};

class _SearchScreenState extends State<SearchScreen> {
  late final _field = TextEditingController(text: widget.query ?? '');

  @override
  void initState() {
    super.initState();
    // Every letter searches again in the same frame: the family's records are on this device.
    _field.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  String? _routeFor(FamilyReads app, SearchHit hit) {
    var route = routeForRecord(app, hit.type, hit.id);
    if (route != null && hit.type == RecordType.event && hit.when != null) route = '$route?at=${hit.when}';
    // Something only History remembers (it was removed, or renamed since) opens its history.
    return route ?? (hit.type == RecordType.member ? null : '/history?q=${Uri.encodeQueryComponent(hit.title)}');
  }

  static List<SearchHit> _tiesByWhose(FamilyReads app, List<SearchHit> hits) {
    String whose(SearchHit h) => _ResultRow.whose(app, h) ?? '';
    final out = <SearchHit>[];
    for (var i = 0; i < hits.length;) {
      var j = i + 1;
      while (j < hits.length && hits[j].title == hits[i].title) {
        j++;
      }
      out.addAll(hits.sublist(i, j)..sort((a, b) => whose(a).compareTo(whose(b))));
      i = j;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final t = context.text;
    final query = _field.text.trim();
    final hits = query.isEmpty ? const <SearchHit>[] : app.den.search(query);
    final byKind = <String, List<SearchHit>>{};
    for (final hit in hits) {
      byKind.putIfAbsent(hit.type, () => []).add(hit);
    }
    // The engine ranks ties by title alone: chores of one name ("Make bed") go in the order of
    // whose they are, so the list reads the same every time.
    if (byKind[RecordType.chore] case final chores?) byKind[RecordType.chore] = _tiesByWhose(app, chores);
    final kinds = [...searchKinds.keys.where(byKind.containsKey), ...byKind.keys.where((k) => !searchKinds.containsKey(k))];
    void open(SearchHit hit) {
      final route = _routeFor(app, hit);
      if (route != null) context.push(route);
    }

    final field = TextField(
      controller: _field,
      autofocus: widget.query == null || widget.query!.isEmpty,
      textInputAction: TextInputAction.search,
      autocorrect: false,
      style: t.body(c.ink),
      onSubmitted: (_) {
        if (hits.isNotEmpty) open(hits.first);
      },
      decoration: InputDecoration(
        hintText: 'People, events, chores, lists',
        prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 20, color: c.ink2),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: _field.clear,
                icon: Icon(PhosphorIconsBold.xCircle, size: 20, color: c.ink2),
              ),
      ),
    );

    return DenPage(
      title: 'Search',
      onBack: () => closePage(context, fallback: '/today'),
      children: [
        Semantics(textField: true, label: 'Search', child: field),
        if (query.isNotEmpty && hits.isEmpty)
          EmptyState(
            message: 'Nothing here matches “$query”.',
            actionLabel: 'Look in History',
            onAction: () => context.push('/history?q=${Uri.encodeQueryComponent(query)}'),
          ),
        for (final kind in kinds)
          DenSection(
            title: searchKinds[kind] ?? fieldLabel(kind),
            trailing: SectionCount('${byKind[kind]!.length}'),
            child: Column(
              children: ruled(
                [for (final hit in byKind[kind]!) _ResultRow(hit: hit, onTap: _routeFor(app, hit) == null ? null : () => open(hit))],
                indent: kind == RecordType.member ? RowRule.afterFace : 36,
              ),
            ),
          ),
      ],
    );
  }
}

/// One result: what it is at a glance (a person's face, an event's pictogram, an ink glyph), its
/// name with where or which list under it, and when for an event.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.hit, required this.onTap});

  final SearchHit hit;
  final VoidCallback? onTap;

  /// Chores of the same name ("Make bed") are told apart by whose they are.
  static String? whose(FamilyReads app, SearchHit hit) {
    final chore = hit.type == RecordType.chore ? app.den.chore(hit.id) : null;
    return switch (chore?.owner) {
      OwnerMember(:final id) => app.memberById(id)?.name,
      OwnerAnyone() => 'Anyone',
      OwnerRotation() => 'Taking turns',
      _ => null,
    };
  }

  static IconData _glyph(String type) => switch (type) {
        RecordType.chore => PhosphorIconsRegular.checkCircle,
        RecordType.list => PhosphorIconsRegular.listBullets,
        RecordType.item => PhosphorIconsRegular.circle,
        RecordType.reward => PhosphorIconsRegular.gift,
        RecordType.goal => PhosphorIconsRegular.flag,
        _ => PhosphorIconsRegular.fileText,
      };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final member = hit.type == RecordType.member ? app.memberById(hit.id) : null;
    final event = hit.type == RecordType.event ? app.den.event(hit.id) : null;
    final when = hit.when == null ? null : f.shortWithYear(f.localDate(hit.when!), relativeTo: app.today);
    final detail = hit.detail == null || hit.detail!.isEmpty ? whose(app, hit) : hit.detail;
    return NavRow(
      label: hit.title,
      detail: detail,
      value: when,
      onTap: onTap,
      chevron: onTap != null,
      leading: member != null ? DenAvatar(member, size: 40) : null,
      icon: member != null
          ? null
          : event != null
              ? Pictograms.event(eventKind(event.title, location: event.location))
              : _glyph(hit.type),
    );
  }
}
