import 'dart:async';
import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/family_reads.dart';
import '../../../app/navigation.dart';
import '../../../design/forms/forms.dart' show Hang;
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../add/add.dart';
import '../words/history_words.dart';

/// Advanced, Data, History: everything that changed, newest first, a section a day, each as a
/// plain sentence with its face ("Alex moved Soccer practice to 5:30 PM"), the time and the
/// device under it. A tap shows what each field was before, with a way to the thing itself;
/// a row with nothing more to show opens the thing. Narrow it by person, by kind or by words;
/// the magnifying glass searches everything instead.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.query});

  /// Search text to start with.
  final String? query;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late final _search = TextEditingController(text: widget.query ?? '');
  late String _query = widget.query ?? '';
  Timer? _debounce;
  String? _member;
  HistoryKind? _kind;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _query = text.trim());
    });
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _query = '';
      _member = null;
      _kind = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final kind = _kind;
    final entries = app.den
        .history(query: _query.isEmpty ? null : _query, member: _member, limit: kind == null ? 200 : 500)
        .where((e) => kind == null || kind.types.contains(e.type))
        .toList();
    final noise = bookkeeping(entries);
    entries.removeWhere(noise.contains);
    final filtered = _query.isNotEmpty || _member != null || _kind != null;

    final days = <String, List<HistoryEntry>>{};
    for (final entry in entries) {
      days.putIfAbsent(f.localDate(entry.when.millis), () => []).add(entry);
    }

    return DenPage(
      title: 'History',
      onBack: () => closePage(context, fallback: '/settings/advanced/data'),
      trailing: RoundButton(
        icon: PhosphorIconsRegular.magnifyingGlass,
        label: 'Search everything',
        onTap: () => context.push('/search'),
        fill: c.card,
        color: c.ink,
        size: Targets.adult,
      ),
      children: [
        TextField(
          controller: _search,
          onChanged: _onSearch,
          textInputAction: TextInputAction.search,
          style: t.body(c.ink),
          decoration: InputDecoration(
            hintText: 'Search what changed',
            prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 20, color: c.ink2),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: () {
                      _search.clear();
                      _onSearch('');
                    },
                    icon: Icon(PhosphorIconsBold.xCircle, size: 20, color: c.ink2),
                  ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChipRow(
              inset: 0,
              children: [
                for (final m in app.den.members)
                  PersonPill(
                    face: DenAvatar(m, size: 32),
                    name: m.name,
                    selected: _member == m.id,
                    onTap: () => setState(() => _member = _member == m.id ? null : m.id),
                  ),
              ],
            ),
            const SizedBox(height: Sp.s),
            ChipRow(
              inset: 0,
              children: [
                TagChip(label: 'Everything', selected: _kind == null, onTap: () => setState(() => _kind = null)),
                for (final k in HistoryKind.values)
                  TagChip(label: k.label, selected: _kind == k, onTap: () => setState(() => _kind = _kind == k ? null : k)),
              ],
            ),
          ],
        ),
        if (entries.isEmpty)
          EmptyState(
            message: filtered
                ? (_query.isNotEmpty ? 'No changes match “$_query”.' : 'No changes match these filters.')
                : 'Nothing has changed yet.',
            actionLabel: filtered ? 'Show everything' : null,
            onAction: filtered ? _clear : null,
          ),
        for (final day in days.keys)
          DenSection(
            title: f.relative(day, app.today),
            trailing: f.relative(day, app.today) == f.short(day) ? null : SectionCount(f.short(day)),
            child: Column(
              children: ruled([for (final entry in days[day]!) _EntryRow(entry)], indent: RowRule.afterFace),
            ),
          ),
      ],
    );
  }
}

/// One change as a sentence: the face of whoever made it, what they did, and when and where
/// under it. Field changes wait behind a tap, revealed in place.
class _EntryRow extends StatefulWidget {
  const _EntryRow(this.entry);
  final HistoryEntry entry;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _open = false;

  HistoryEntry get entry => widget.entry;

  String? _route(FamilyReads app) {
    if (entry.verb == 'removed') return null;
    if (entry.type != RecordType.eventException) return routeForRecord(app, entry.type, entry.rid);
    final id = entry.diffs.where((d) => d.field == 'event').map((d) => d.after).whereType<String>().firstOrNull;
    final at = entry.diffs.where((d) => d.field == 'occurrence').map((d) => d.after).whereType<num>().firstOrNull;
    if (id == null || app.den.event(id) == null) return null;
    return at == null ? '/event/$id' : '/event/$id?at=${at.toInt()}';
  }

  /// What the way to the thing says: "Open the event".
  String _openLabel() => switch (entry.type) {
        RecordType.event || RecordType.eventException => 'Open the event',
        RecordType.chore || RecordType.completion => 'Open the chore',
        RecordType.list || RecordType.item => 'Open the list',
        RecordType.member => 'Open their page',
        RecordType.device => 'Open Family',
        _ => 'Open stars and rewards',
      };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final t = context.text;
    final actor = app.memberById(entry.actor);
    final line = historyLine(app, entry);
    final sentence = historySentence(app, entry, line);
    final route = _route(app);
    final diffs = [
      for (final d in line.diffs)
        if (diffWords(app, entry.type, d) case (final b, final a) when b != null || a != null) d,
    ];
    final details = diffs.isNotEmpty;
    final where = [
      f.time(entry.when.millis),
      entry.deviceName,
      if (entry.via != null && entry.via!.isNotEmpty) 'through ${entry.via}',
      if (entry.from != null) sourceWords(entry.from!),
    ].join(' · ');
    final face = SizedBox.square(
      dimension: 40,
      child: actor != null
          ? DenAvatar(actor, size: 40)
          : Center(child: Icon(PhosphorIconsRegular.deviceTablet, size: 24, color: c.ink2)),
    );

    return DenPressable(
      onTap: details ? () => setState(() => _open = !_open) : (route == null ? null : () => context.push(route)),
      scale: false,
      shape: const RoundedRectangleBorder(),
      selected: details ? _open : null,
      semanticLabel: '${entry.actorName} $sentence. $where',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            face,
            const SizedBox(width: Sp.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: entry.actorName, style: t.body(c.ink).bold),
                          TextSpan(text: ' ${tidy(sentence)}'),
                        ],
                      ),
                      style: t.body(c.ink),
                    ),
                  ),
                  const SizedBox(height: 2),
                  ExcludeSemantics(child: Text(keepUnits(where), style: t.meta(c.ink2))),
                  if (details)
                    DenReveal(
                      visible: _open,
                      child: Padding(
                        padding: const EdgeInsets.only(top: Sp.s),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final diff in diffs) _DiffLine(type: entry.type, diff: diff),
                            if (route != null)
                              Hang(
                                by: Sp.m,
                                child: TextButton(onPressed: () => context.push(route), child: Text(_openLabel())),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Sp.s),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: details
                  ? SpringValue(
                      value: _open ? 1 : 0,
                      child: Icon(PhosphorIconsBold.caretDown, size: 18, color: c.ink3),
                      builder: (context, turn, caret) => Transform.rotate(angle: turn * math.pi, child: caret),
                    )
                  : route == null
                      ? const SizedBox(width: 18)
                      : Icon(PhosphorIconsBold.caretRight, size: 18, color: c.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Starts  ~~3:30 PM~~ → 4:00 PM": the field, the old value in ink2 struck through, and the
/// new one.
class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.type, required this.diff});
  final String type;
  final FieldDiff diff;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final t = context.text;
    final (before, after) = diffWords(app, type, diff);
    final old = t.meta(c.ink2).copyWith(decoration: TextDecoration.lineThrough, decorationColor: c.ink2);
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.xs),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${fieldLabel(diff.field)}  ', style: t.meta(c.ink2).bold),
            if (before != null) ...[
              TextSpan(text: keepUnits(before), style: old, semanticsLabel: 'was $before'),
              // The face has no arrow glyph; the icon set does.
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Semantics(
                  label: ', now',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Sp.xs + 2),
                    child: Icon(PhosphorIconsRegular.arrowRight, size: 12 * context.type.scale, color: c.ink2),
                  ),
                ),
              ),
            ],
            TextSpan(text: keepUnits(after ?? 'none'), style: t.meta(after == null ? c.ink2 : c.ink)),
          ],
        ),
      ),
    );
  }
}
