import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import '../calendar/calendar_time.dart';
import '../events/event_detail.dart' show closePage;
import 'history_words.dart';

/// Finds events, chores, lists and items by what they're called or what's written in them, and
/// opens the one you pick.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.query});
  final String? query;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final _field = TextEditingController(text: widget.query ?? '');
  late String _query = widget.query?.trim() ?? '';
  Timer? _debounce;

  static const _groups = <String, String>{
    RecordType.event: 'Events',
    RecordType.chore: 'Chores',
    RecordType.list: 'Lists',
    RecordType.item: 'List items',
    RecordType.member: 'People',
    RecordType.reward: 'Rewards',
    RecordType.goal: 'Goals',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = text.trim());
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final hits = _query.isEmpty ? const <SearchHit>[] : app.den.search(_query);
    final byType = <String, List<SearchHit>>{};
    for (final hit in hits) {
      byType.putIfAbsent(hit.type, () => []).add(hit);
    }
    final order = [..._groups.keys.where(byType.containsKey), ...byType.keys.where((t) => !_groups.containsKey(t))];

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
                  padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.l, Sp.s),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => closePage(context),
                        icon: const Icon(PhosphorIconsRegular.arrowLeft),
                      ),
                      const SizedBox(width: Sp.xs),
                      Expanded(
                        child: TextField(
                          controller: _field,
                          autofocus: widget.query == null || widget.query!.isEmpty,
                          onChanged: _onChanged,
                          textInputAction: TextInputAction.search,
                          style: context.type.body(c.ink),
                          decoration: InputDecoration(
                            hintText: 'Search events, chores, and lists',
                            prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, size: 18, color: c.ink2),
                            suffixIcon: _field.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear search',
                                    onPressed: () {
                                      _field.clear();
                                      _onChanged('');
                                    },
                                    icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.ink2),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: c.rule),
                Expanded(
                  child: _query.isEmpty
                      ? const SizedBox.shrink()
                      : hits.isEmpty
                      ? ListView(children: [EmptyLine(message: 'Nothing matches “$_query”.')])
                      : ListView(
                          padding: const EdgeInsets.only(bottom: Sp.xxxl),
                          children: [
                            for (final type in order) ...[
                              SectionHeader(_groups[type] ?? fieldLabel(type), trailing: '${byType[type]!.length}'),
                              for (final hit in byType[type]!) _HitRow(hit),
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

class _HitRow extends StatelessWidget {
  const _HitRow(this.hit);
  final SearchHit hit;

  static IconData _icon(String type) => switch (type) {
    RecordType.event => PhosphorIconsRegular.calendarBlank,
    RecordType.chore => PhosphorIconsRegular.checkSquare,
    RecordType.list => PhosphorIconsRegular.listChecks,
    RecordType.item => PhosphorIconsRegular.shoppingCart,
    RecordType.member => PhosphorIconsRegular.user,
    RecordType.reward => PhosphorIconsRegular.gift,
    RecordType.goal => PhosphorIconsRegular.flag,
    _ => PhosphorIconsRegular.fileText,
  };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    var route = routeForRecord(app, hit.type, hit.id);
    if (route != null && hit.type == RecordType.event && hit.when != null) route = '$route?at=${hit.when}';
    // Something only History remembers (it was removed, or renamed since) opens its history.
    route ??= hit.type == RecordType.member ? null : '/history?q=${Uri.encodeQueryComponent(hit.title)}';
    final when = hit.when == null ? null : f.shortWithYear(f.localDate(hit.when!), relativeTo: app.today);
    final detail = hit.detail;

    return ListTile(
      leading: Icon(_icon(hit.type), color: c.ink2),
      title: Text(hit.title),
      subtitle: detail == null || detail.isEmpty ? null : Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: when == null ? null : Text(when, style: context.type.meta(c.ink2)),
      onTap: route == null ? null : () => context.push(route!),
    );
  }
}
