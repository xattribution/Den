import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../widgets/chore_row.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import 'swap_sheet.dart';
import '../../../design/forms/forms.dart';
import '../state/chore_actions.dart';
import '../state/chore_groups.dart';
import '../state/chores_model.dart';

/// The Chores tab: reads the day from the URL (`/chores?date=2026-10-17`).
class ChoresTab extends StatelessWidget {
  const ChoresTab({super.key});

  @override
  Widget build(BuildContext context) {
    final date = GoRouterState.of(context).uri.queryParameters['date'];
    return ChoresBoard(date: date);
  }
}

/// Everyone's chores for one day, like the fridge chart: a section per person (the signed-in
/// person first, then family order, then "Anyone"), late chores at the top of each. On tablets
/// and desktops the people become columns, the family-columns idea.
class ChoresBoard extends StatelessWidget {
  const ChoresBoard({super.key, this.date});

  /// Local date; null means today.
  final String? date;

  static const double _minColumn = 212;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final today = app.today;
    final day = date ?? today;
    final groups = _groups(app, context.view(ChoresModel(day)), day);

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(date: day, groups: groups, wide: wide),
            Expanded(
              child: groups.isEmpty
                  ? ListView(
                      children: [
                        EmptyLine(
                          message: day == today ? 'No chores today.' : 'No chores on ${app.formats.short(day)}.',
                          actionLabel: app.allows(DenAction.editChores) ? 'Add chore' : null,
                          onAction: () => context.push('/chore/new'),
                        ),
                      ],
                    )
                  : wide
                  ? _Columns(groups: groups, minColumn: _minColumn)
                  : _Sections(groups: groups),
            ),
          ],
        );
      },
    );
  }

  static List<ChoreGroup> _groups(AppState app, List<ChoreDay> days, String date) {
    final sorted = [...days]..sort((a, b) => _order(a, date).compareTo(_order(b, date)));
    return choreGroups(app.den.members, sorted, me: app.me?.id);
  }

  /// A key that doesn't change when a chore is checked, so rows never jump: chores carried over
  /// from earlier days, then by due time (late ones are the earliest due), then title.
  static String _order(ChoreDay d, String date) {
    final carried = d.date != date ? '0' : '1';
    return '$carried${d.chore.dueTime ?? '99:99'}${d.chore.title.toLowerCase()}';
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.date, required this.groups, required this.wide});
  final String date;
  final List<ChoreGroup> groups;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final f = app.formats;
    final c = context.colors;
    final today = app.today;
    final relative = f.relative(date, today);
    final isWord = relative != f.short(date);
    void goTo(String d) => context.go(d == today ? '/chores' : '/chores?date=$d');
    final total = groups.fold(0, (n, g) => n + g.days.length);
    final done = groups.fold(0, (n, g) => n + g.days.where((d) => d.done).length);

    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.s, Sp.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Semantics(
                    header: true,
                    label: isWord ? '$relative, ${f.long(date)}' : f.long(date),
                    child: ExcludeSemantics(
                      child: Text(relative, style: context.type.heading(c.ink), overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
                if (wide && isWord) ...[
                  const SizedBox(width: Sp.s),
                  ExcludeSemantics(child: Text(f.short(date), style: context.type.body(c.ink2))),
                ],
                if (wide && total > 0) ...[
                  const SizedBox(width: Sp.l),
                  Text('$done of $total done', style: context.type.meta(c.ink2)),
                ],
              ],
            ),
          ),
          const SizedBox(width: Sp.s),
          IconButton(
            tooltip: 'Earlier',
            onPressed: () => goTo(f.addDays(date, -1)),
            icon: const Icon(PhosphorIconsRegular.caretLeft),
          ),
          OutlinedButton(onPressed: () => goTo(today), child: const Text('Today')),
          IconButton(
            tooltip: 'Later',
            onPressed: () => goTo(f.addDays(date, 1)),
            icon: const Icon(PhosphorIconsRegular.caretRight),
          ),
        ],
      ),
    );
  }
}

class _PersonHead extends StatelessWidget {
  const _PersonHead(this.group, {this.large = true});
  final ChoreGroup group;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = group.member;
    final size = large ? 28.0 : 26.0;
    return Semantics(
      header: true,
      label: '${m?.name ?? 'Anyone'}, ${group.leftWords}',
      child: ExcludeSemantics(
        child: Row(
          children: [
            if (m != null) DenAvatar(m, size: size) else AnyoneMark(size: size),
            const SizedBox(width: Sp.s),
            Expanded(
              child: Text(
                m?.name ?? 'Anyone',
                style: large ? context.type.title(c.ink) : context.type.bodyStrong(c.ink),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(group.leftWords, style: context.type.meta(c.ink2)),
          ],
        ),
      ),
    );
  }
}

/// Phones: one section per person, flush, separated by space.
class _Sections extends StatelessWidget {
  const _Sections({required this.groups});
  final List<ChoreGroup> groups;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    return ListView(
      padding: const EdgeInsets.only(bottom: Sp.xxxl),
      children: [
        for (final (i, g) in groups.indexed) ...[
          Padding(padding: EdgeInsets.fromLTRB(Sp.l, i == 0 ? Sp.s : Sp.xl, Sp.l, Sp.xs), child: _PersonHead(g)),
          for (final d in g.days)
            ChoreRow(day: d, onSwap: canSwap(app, d) ? () => showSwapSheet(context, d) : null),
        ],
      ],
    );
  }
}

/// Tablets and desktops: a column per person headed by their avatar over their marker, like the
/// paper family organizer. Columns scroll on their own; too many people scroll sideways.
class _Columns extends StatelessWidget {
  const _Columns({required this.groups, required this.minColumn});
  final List<ChoreGroup> groups;
  final double minColumn;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final natural = groups.length * minColumn;
        final width = natural > constraints.maxWidth ? natural : constraints.maxWidth;
        final column = width / groups.length;
        final compact = column < 320;
        final table = SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(height: 1, color: c.rule),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, g) in groups.indexed)
                      Container(
                        width: column,
                        decoration: BoxDecoration(
                          border: i == 0 ? null : Border(left: BorderSide(color: c.rule)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.fromLTRB(Sp.m, Sp.m, Sp.m, Sp.m),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: g.member == null ? c.rule : c.marker(g.member!.marker),
                                    width: 3,
                                  ),
                                ),
                              ),
                              child: _PersonHead(g, large: false),
                            ),
                            Expanded(
                              child: ListView(
                                padding: const EdgeInsets.only(top: Sp.xs, bottom: Sp.xxl),
                                children: [
                                  for (final d in g.days)
                                    ChoreRow(
                                      day: d,
                                      compact: compact,
                                      onSwap: canSwap(app, d) ? () => showSwapSheet(context, d) : null,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
        return natural > constraints.maxWidth
            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: table)
            : table;
      },
    );
  }
}
