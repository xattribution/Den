import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/forms/choices.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../calendar/screens/event_detail.dart' show closePage;
import '../../add/words/capture_words.dart' show sourceWords;
import '../words/history_words.dart';

/// Everything that changed, newest first and grouped by day: "Mia completed Dishes", with the
/// time, the device, and each changed field as the old value struck through beside the new.
/// Filter by person and kind, or search; "Search everything" finds items themselves.
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
    _debounce = Timer(const Duration(milliseconds: 300), () {
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
    final kind = _kind;
    final entries = app.den
        .history(query: _query.isEmpty ? null : _query, member: _member, limit: kind == null ? 200 : 500)
        .where((e) => kind == null || kind.types.contains(e.type))
        .toList();
    final noise = bookkeeping(entries);
    entries.removeWhere(noise.contains);
    final filtered = _query.isNotEmpty || _member != null || _kind != null;

    final groups = <String, List<HistoryEntry>>{};
    for (final entry in entries) {
      groups.putIfAbsent(f.localDate(entry.when.millis), () => []).add(entry);
    }

    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.s, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => closePage(context),
                        icon: const Icon(PhosphorIconsRegular.arrowLeft),
                      ),
                      const SizedBox(width: Sp.xs),
                      Expanded(
                        child: Semantics(header: true, child: Text('History', style: context.type.heading(c.ink))),
                      ),
                      TextButton.icon(
                        onPressed: () => context.push('/search'),
                        icon: const Icon(PhosphorIconsRegular.magnifyingGlass, size: 18),
                        label: const Text('Search everything'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearch,
                    textInputAction: TextInputAction.search,
                    style: context.type.body(c.ink),
                    decoration: InputDecoration(
                      hintText: 'Search history',
                      prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 18, color: c.ink2),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _search.clear();
                                _onSearch('');
                              },
                              icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.ink2),
                            ),
                    ),
                  ),
                ),
                _FilterRow(
                  children: [
                    for (final m in app.den.members)
                      PersonChip(
                        member: m,
                        selected: _member == m.id,
                        onTap: () => setState(() => _member = _member == m.id ? null : m.id),
                      ),
                  ],
                ),
                const SizedBox(height: Sp.s),
                _FilterRow(
                  children: [
                    ChoiceTile(label: 'All', selected: _kind == null, onTap: () => setState(() => _kind = null)),
                    for (final k in HistoryKind.values)
                      ChoiceTile(
                        label: k.label,
                        selected: _kind == k,
                        onTap: () => setState(() => _kind = _kind == k ? null : k),
                      ),
                  ],
                ),
                const SizedBox(height: Sp.s),
                Divider(height: 1, color: c.rule),
                Expanded(
                  child: entries.isEmpty
                      ? ListView(
                          children: [
                            EmptyLine(
                              message: filtered
                                  ? (_query.isNotEmpty
                                        ? 'No changes match “$_query”.'
                                        : 'No changes match these filters.')
                                  : 'Nothing has changed yet.',
                              actionLabel: filtered ? 'Clear filters' : null,
                              onAction: _clear,
                            ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: Sp.xxxl),
                          children: [
                            for (final date in groups.keys) ...[
                              SectionHeader(
                                f.relative(date, app.today),
                                trailing: f.relative(date, app.today) == f.short(date) ? null : f.short(date),
                              ),
                              for (final entry in groups[date]!) _EntryRow(entry),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Sp.l),
      child: Row(
        children: [
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(width: Sp.s), child],
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow(this.entry);
  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final actor = app.memberById(entry.actor);
    final line = historyLine(app, entry);
    final route = entry.verb == 'removed' ? null : _route(app);
    final diffs = line.diffs;
    final where = [
      entry.deviceName,
      if (entry.via != null && entry.via!.isNotEmpty) 'through ${entry.via}',
      if (entry.from != null) sourceWords(entry.from!),
    ].join(', ');
    final avatarSize = 24 * context.type.scale;

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(f.time(entry.when.millis), style: context.type.meta(c.ink2)),
            ),
          ),
          const SizedBox(width: Sp.m),
          if (actor != null)
            DenAvatar(actor, size: avatarSize)
          else
            Container(
              width: avatarSize,
              height: avatarSize,
              decoration: BoxDecoration(color: c.well, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(PhosphorIconsRegular.deviceTablet, size: avatarSize * 0.6, color: c.ink2),
            ),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: entry.actorName, style: context.type.bodyStrong(c.ink)),
                      TextSpan(text: ' ${line.verb} ', style: context.type.body(c.ink)),
                      TextSpan(text: line.title, style: context.type.body(c.ink)),
                    ],
                  ),
                ),
                for (final diff in diffs) _DiffLine(type: entry.type, diff: diff),
                if (where.isNotEmpty) Text(where, style: context.type.meta(c.ink2)),
              ],
            ),
          ),
        ],
      ),
    );
    if (route == null) return row;
    return InkWell(onTap: () => context.push(route), child: row);
  }

  String? _route(AppState app) {
    if (entry.type != RecordType.eventException) return routeForRecord(app, entry.type, entry.rid);
    final id = entry.diffs.where((d) => d.field == 'event').map((d) => d.after).whereType<String>().firstOrNull;
    final at = entry.diffs.where((d) => d.field == 'occurrence').map((d) => d.after).whereType<num>().firstOrNull;
    if (id == null || app.den.event(id) == null) return null;
    return at == null ? '/event/$id' : '/event/$id?at=${at.toInt()}';
  }
}

/// "Starts  ~~3:30 PM~~ > 4:00 PM": the old value in ink2, struck through, beside the new one.
class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.type, required this.diff});
  final String type;
  final FieldDiff diff;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final (before, after) = diffWords(app, type, diff);
    if (before == null && after == null) return const SizedBox.shrink();
    final old = context.type.meta(c.ink2).copyWith(decoration: TextDecoration.lineThrough, decorationColor: c.ink2);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${fieldLabel(diff.field)}  ', style: context.type.meta(c.ink2)),
            if (before != null) ...[
              TextSpan(text: before, style: old, semanticsLabel: 'was $before'),
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
            TextSpan(text: after ?? 'none', style: context.type.meta(after == null ? c.ink2 : c.ink)),
          ],
        ),
      ),
    );
  }
}
