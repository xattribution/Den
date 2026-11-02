import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/family_label.dart';
import '../../../design/forms/forms.dart' show AnyoneMark;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../rewards/rewards.dart';
import '../state/chore_actions.dart';
import '../state/chore_groups.dart';
import '../state/chores_model.dart';
import '../widgets/chore_row.dart';
import '../widgets/give.dart';

/// The Chores tab: reads the day from the URL (`/chores?date=2026-10-17`).
class ChoresTab extends StatelessWidget {
  const ChoresTab({super.key});

  @override
  Widget build(BuildContext context) {
    final date = GoRouterState.of(context).uri.queryParameters['date'];
    return ChoresBoard(date: date);
  }
}

/// Everyone's chores for one day (Chores.dc.html): the day and how many are done, with back,
/// Today and forward; then a section per person (whoever is using the device first, then the
/// family, then anyone's): their face and name, their stars and the bar toward their goal while
/// points are on, and their chores in one card. A chore's ring checks it; its words open it in
/// place (steps, Give to…, Details); Give to… hands it on for the day with Undo in place.
///
/// With room for two columns (an iPad in landscape, beside the sidebar), the people sit in two.
class ChoresBoard extends StatefulWidget {
  const ChoresBoard({super.key, this.date});

  /// Local date; null means today.
  final String? date;

  /// The content width from which the people sit in two columns.
  static const double twoColumns = 760;

  @override
  State<ChoresBoard> createState() => _ChoresBoardState();
}

/// A Give to… that moved a chore out of [from]'s section, kept there with Undo.
class _Note {
  const _Note(this.from, this.given);
  final String? from;
  final Done given;
}

class _ChoresBoardState extends State<ChoresBoard> {
  String? _open;
  final _notes = <String, _Note>{};

  static String _key(ChoreDay d) => '${d.chore.id}@${d.date}';

  @override
  void didUpdateWidget(ChoresBoard old) {
    super.didUpdateWidget(old);
    if (old.date != widget.date) {
      _open = null;
      _notes.clear();
    }
  }

  Future<void> _give(ChoreDay d) async {
    final from = d.owner;
    final given = await giveChore(context, d);
    if (given == null || !mounted) return;
    setState(() {
      _open = null;
      _notes[_key(d)] = _Note(from, given);
    });
  }

  Future<void> _undo(String key, Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _notes.remove(key));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch({...choreReads, ...pointsReads});
    final f = app.formats;
    final today = app.today;
    final day = widget.date ?? today;
    final days = context.view(ChoresModel(day));
    final sorted = [...days]..sort((a, b) => _order(a, day).compareTo(_order(b, day)));
    final groups = choreGroups(app.den.members, sorted, me: app.me?.id);
    final pointsOn = app.den.family?.pointsEnabled ?? true;
    final points = pointsOn ? context.view(const PointsModel()) : null;
    final done = days.where((d) => d.done).length;
    final relative = f.relative(day, today);
    final dayWords = relative == f.short(day) ? f.long(day) : '$relative, ${f.long(day)}';
    void goTo(String d) => context.go(d == today ? '/chores' : '/chores?date=$d');
    final compact = DenLayout.of(context).isCompact;

    final c = context.colors;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // In "All my families", whose chores these are.
        const FamilyLabel(note: 'Chores and stars stay with each family'),
        PageHeader(
          overline: f.long(day),
          title: day == today || relative == f.short(day) ? 'Chores' : relative,
          large: !compact,
          trailing: DayStepper(
            dayLabel: dayWords,
            onPrevious: () => goTo(f.addDays(day, -1)),
            onNext: () => goTo(f.addDays(day, 1)),
            onToday: day == today ? null : () => goTo(today),
          ),
        ),
        if (days.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, DenLayout.headingInset, 0),
            child: Text('$done of ${days.length} done', style: context.text.meta(c.ink2)),
          ),
      ],
    );

    final sections = [
      for (final g in groups)
        _PersonSection(
          group: g,
          date: day,
          points: points,
          open: _open,
          notes: {
            for (final e in _notes.entries)
              if (e.value.from == g.member?.id) e.key: e.value.given,
          },
          onOpen: (d) => setState(() => _open = _open == _key(d) ? null : _key(d)),
          onGive: (d) => canSwap(app, d) ? () => _give(d) : null,
          onUndo: _undo,
        ),
      // A chore given away from someone who now has nothing that day keeps its Undo.
      for (final e in _notes.entries)
        if (!groups.any((g) => g.member?.id == e.value.from))
          _PersonSection(
            group: ChoreGroup(app.memberById(e.value.from), const []),
            date: day,
            points: points,
            open: _open,
            notes: {e.key: e.value.given},
            onOpen: (_) {},
            onGive: (_) => null,
            onUndo: _undo,
          ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= ChoresBoard.twoColumns;
        final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
        final Widget body;
        if (sections.isEmpty) {
          final canAdd = app.allows(DenAction.editChores);
          body = EmptyState(
            message: day == today ? 'No chores today.' : 'No chores on ${f.short(day)}.',
            actionLabel: canAdd ? 'Add chore' : null,
            onAction: canAdd ? () => context.push('/chore/new') : null,
          );
        } else if (two) {
          // Balance the two columns by how many rows each holds.
          final left = <Widget>[], right = <Widget>[];
          var l = 0, r = 0;
          for (final s in sections) {
            final rows = s.group.days.length + 2;
            if (l <= r) {
              left.add(s);
              l += rows;
            } else {
              right.add(s);
              r += rows;
            }
          }
          Widget column(List<Widget> children) => Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, s) in children.indexed) ...[if (i > 0) const SizedBox(height: DenLayout.sectionGap), s],
                  ],
                ),
              );
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [column(left), const SizedBox(width: DenLayout.sectionGap), column(right)],
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, s) in sections.indexed) ...[if (i > 0) const SizedBox(height: DenLayout.sectionGap), s],
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(side, two ? 32 : Sp.l, side, Sp.xxl),
          children: [header, const SizedBox(height: DenLayout.sectionGap), body],
        );
      },
    );
  }

  /// A key that doesn't change when a chore is checked, so rows never jump: chores carried over
  /// from earlier days, then by due time (late ones are the earliest due), then title.
  static String _order(ChoreDay d, String date) {
    final carried = d.date != date ? '0' : '1';
    return '$carried${d.chore.dueTime ?? '99:99'}${d.chore.title.toLowerCase()}';
  }
}

/// One person's chores: their face, name and stars, the bar toward their goal, and their chores
/// in one card, with what was given away from them (and its Undo) at the end.
class _PersonSection extends StatelessWidget {
  const _PersonSection({
    required this.group,
    required this.date,
    required this.points,
    required this.open,
    required this.notes,
    required this.onOpen,
    required this.onGive,
    required this.onUndo,
  });

  final ChoreGroup group;
  final String date;
  final PointsSummary? points;
  final String? open;
  final Map<String, Done> notes;
  final ValueChanged<ChoreDay> onOpen;
  final VoidCallback? Function(ChoreDay) onGive;
  final void Function(String key, Receipt receipt) onUndo;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(choreReads);
    final c = context.colors;
    final t = context.text;
    final m = group.member;
    final name = m?.name ?? 'Anyone';
    // Stars for kids, and for anyone else who has some.
    final total = m == null || points == null ? null : points!.totals[m.id] ?? 0;
    final stars = total == null || (!m!.isKid && total == 0) ? null : total;
    final goal = m == null || points == null ? null : currentGoal(points!, m.id, app.today);
    final left = group.left;

    final head = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
      child: Row(
        crossAxisAlignment: goal == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          if (m != null) DenAvatar(m, size: 44) else const AnyoneMark(size: 44),
          const SizedBox(width: Sp.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        label: group.days.isEmpty ? name : '$name, ${left == 0 ? 'all done' : '$left left'}',
                        child: ExcludeSemantics(child: Text(name, style: t.section(c.ink))),
                      ),
                    ),
                    if (stars != null)
                      Semantics(
                        label: '$stars stars',
                        excludeSemantics: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$stars', style: t.rowTitle(c.ink).copyWith(fontSize: 18 * t.scale)),
                            const SizedBox(width: 4),
                            const Star(size: 18),
                          ],
                        ),
                      ),
                  ],
                ),
                if (goal != null) ...[
                  const SizedBox(height: 6),
                  ProgressBar(
                    fraction: goalFraction(goal.$1, goal.$2),
                    color: c.marker(m!.marker),
                    label: '$name, ${goalLine(goal.$1, goal.$2, app.today, app.formats)}',
                  ),
                  const SizedBox(height: 6),
                  ExcludeSemantics(child: Text(tidy(goalLine(goal.$1, goal.$2, app.today, app.formats)), style: t.meta(c.ink2))),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    final rows = [
      for (final d in group.days)
        ChoreRow(
          key: ValueKey('${d.chore.id}@${d.date}'),
          day: d,
          date: date,
          open: open == '${d.chore.id}@${d.date}',
          onOpen: () => onOpen(d),
          onGive: onGive(d),
        ),
      for (final e in notes.entries)
        Padding(
          key: ValueKey('given:${e.key}'),
          padding: const EdgeInsetsDirectional.only(start: 6),
          child: DoneRow(
            message: e.value.message,
            onUndo: e.value.receipt?.undoable == true ? () => onUndo(e.key, e.value.receipt!) : null,
          ),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        const SizedBox(height: Sp.m),
        if (rows.isEmpty)
          GroupCard(child: EmptyState(compact: true, message: 'Nothing else for $name.'))
        else
          GroupCard(
            padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(rows, indent: 52)),
          ),
      ],
    );
  }
}
