import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../calendar/words/event_words.dart';
import 'join_requests.dart';
import '../../chores/state/chore_groups.dart';
import '../../chores/widgets/chore_row.dart';

/// The first screen for every adult: what's happening today and who's doing what.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final view = den.today();
    final f = app.formats;
    final c = context.colors;

    // Each gap shows once, under the last of its events: two that overlap warn under the second.
    final gapsByEvent = <String, List<Gap>>{};
    for (final gap in view.gaps) {
      final occ = gap.occurrences.lastOrNull;
      if (occ != null) gapsByEvent.putIfAbsent('${occ.event.id}@${occ.start}', () => []).add(gap);
    }
    final takeRides = canTakeRide(app);
    final looseGaps = view.gaps.where((g) => g.occurrences.isEmpty).toList();

    final chores = view.chores;
    final doneCount = chores.where((d) => d.done).length;

    final heading = Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.m),
      child: Semantics(header: true, child: Text(f.long(view.date), style: context.type.heading(c.ink))),
    );

    final calendar = <Widget>[
        if (view.events.isEmpty)
          EmptyLine(
            message: 'Nothing on the calendar today.',
            actionLabel: app.allows(DenAction.editEvents) ? 'Add event' : null,
            onAction: () => context.push('/event/new?date=${view.date}'),
          )
        else
          for (final occ in view.events) ...[
            _EventRow(occ),
            for (final gap in gapsByEvent['${occ.event.id}@${occ.start}'] ?? const <Gap>[])
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l + 76 + Sp.m, 0, Sp.s, Sp.xs),
                child: AttentionLine(
                  message: gap.message,
                  action: gap.kind == GapKind.noDriver && takeRides && !occ.event.source.readOnly
                      ? TextButton(
                          onPressed: () => _takeRide(context, occ, gap),
                          child: const Text('Take it'),
                        )
                      : null,
                ),
              ),
          ],
        for (final gap in looseGaps)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: AttentionLine(message: gap.message),
          ),
    ];
    final choreSection = <Widget>[
      if (chores.isNotEmpty) ...[
        SectionHeader('Chores', trailing: '$doneCount of ${chores.length} done'),
        ..._choreGroups(context, chores),
      ],
    ];
    final listSection = <Widget>[
      if (view.lists.isNotEmpty) ...[
        const SectionHeader('Lists'),
        for (final lv in view.lists) _ListRow(lv),
      ],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const bottom = EdgeInsets.only(bottom: Sp.xxxl);
        if (constraints.maxWidth < 900) {
          return ListView(
            padding: bottom,
            children: [const JoinRequests(), heading, ...calendar, ...choreSection, ...listSection],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(padding: bottom, children: [const JoinRequests(), heading, ...calendar, ...listSection]),
            ),
            VerticalDivider(width: 1, color: c.rule),
            Expanded(
              child: ListView(
                padding: bottom,
                children: choreSection.isEmpty
                    ? [const EmptyLine(message: 'No chores today.')]
                    : choreSection,
              ),
            ),
          ],
        );
      },
    );
  }

  /// Takes the leg this gap is about, for this occurrence.
  Future<void> _takeRide(BuildContext context, Occurrence occ, Gap gap) async {
    final app = DenScope.read(context);
    final leg = gap.leg ?? occ.rides.firstWhere((r) => r.driver == null, orElse: () => const Ride('to', null)).leg;
    await attempt(context, () => app.den.claimRide(occ.event.id, occurrence: occ.seriesStart, leg: leg, driver: app.me?.id));
  }

  List<Widget> _choreGroups(BuildContext context, List<ChoreDay> chores) => [
        for (final g in choreGroups(context.den.members, chores, me: context.app.me?.id))
          _ChoreGroup(owner: g.member, days: g.days),
      ];
}

class _EventRow extends StatelessWidget {
  const _EventRow(this.occ);
  final Occurrence occ;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final people = occ.assignees.map(app.memberById).whereType<Member>().toList();
    final who = occ.forEveryone ? 'Everyone' : people.map((m) => m.name).join(', ');
    return InkWell(
      onTap: () => context.push('/event/${occ.event.id}?at=${occ.start}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 76,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(occ.allDay ? 'All day' : f.time(occ.start), style: context.type.meta(c.ink2)),
                ),
              ),
              const SizedBox(width: Sp.m),
              PersonBar(markers: app.markersFor(occ.assignees)),
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(occ.title, style: context.type.body(c.ink)),
                    if (occ.location.isNotEmpty) Text(occ.location, style: context.type.meta(c.ink2)),
                  ],
                ),
              ),
              const SizedBox(width: Sp.s),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(who, style: context.type.meta(c.ink2)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoreGroup extends StatelessWidget {
  const _ChoreGroup({required this.owner, required this.days});
  final Member? owner;
  final List<ChoreDay> days;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final left = days.where((d) => !d.done).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
            child: Row(
              children: [
                if (owner != null) DenAvatar(owner!, size: 22) else Icon(PhosphorIconsRegular.usersThree, size: 22, color: c.ink2),
                const SizedBox(width: Sp.s),
                Text(owner?.name ?? 'Anyone', style: context.type.bodyStrong(c.ink)),
                const Spacer(),
                Text(left == 0 ? 'All done' : '$left left', style: context.type.meta(c.ink2)),
              ],
            ),
          ),
          for (final d in days) ChoreRow(day: d, showDue: false, vertical: 2),
        ],
      ),
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow(this.lv);
  final ListState lv;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stores = lv.openByStore.entries.where((e) => e.key.isNotEmpty).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final detail = [
      '${lv.open} ${lv.open == 1 ? 'item' : 'items'}',
      if (stores.isNotEmpty) '${stores.first.value} at ${stores.first.key}',
    ].join(', ');
    return ListTile(
      leading: Icon(Pictograms.listKind(lv.list.kind), color: c.ink2),
      title: Text(lv.list.title),
      subtitle: Text(detail),
      trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
      onTap: () => context.push('/lists/${lv.list.id}'),
    );
  }
}
