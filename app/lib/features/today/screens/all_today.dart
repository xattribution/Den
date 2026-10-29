import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../app/log_scope.dart';
import '../../../app/shell.dart' show PersonButton, SearchButton;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../family/family.dart' show FamilySwitch;
import '../../lists/lists.dart' show ListsModel, listSummary;
import '../state/today_model.dart';
import '../widgets/needs_you_card.dart';
import '../widgets/today_events.dart';
import '../words/today_words.dart';
import 'today_screen.dart';

/// The Today tab: the family the device shows, or "All my families" on a device in several.
class TodayTab extends StatelessWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context) =>
      (Household.maybeOf(context)?.showingAll ?? false) ? const AllTodayScreen() : const TodayScreen();
}

/// Today in "All my families" (FAMILY-LINKS-PLAN §4.2, §4.3): what needs the person in each
/// family, every family's events for today in one list by time, each with its family's tag, and
/// each family's pinned lists. Everything is the family's own: a tap opens it in that family
/// (`/l/<log>/...`), and what a row does is written by that family's actions, so its receipt and
/// Undo stay there. Chores and stars stay with each family.
class AllTodayScreen extends StatefulWidget {
  const AllTodayScreen({super.key});

  @override
  State<AllTodayScreen> createState() => _AllTodayScreenState();
}

class _AllTodayScreenState extends State<AllTodayScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The greeting follows the clock even when nothing else changes.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = Household.maybeOf(context)!;
    final families = [for (final l in home.families) if (l.den.isApproved) l];
    return ListenableBuilder(
      listenable: Listenable.merge([for (final l in families) l.state]),
      builder: (context, _) => _build(context, home, families),
    );
  }

  Widget _build(BuildContext context, Household home, List<FamilyLog> families) {
    final app = context.watch(todayReads);
    final f = app.formats;
    final now = app.den.now();
    final hour = f.at(now).hour;
    final compact = DenLayout.of(context).isCompact;
    final date = app.today;

    // Every family's events today, by when they start.
    final events = <(FamilyLog, Occurrence)>[
      for (final log in families)
        for (final occ in log.state.view(const TodayModel()).events) (log, occ),
    ]..sort((a, b) => a.$2.start != b.$2.start ? a.$2.start.compareTo(b.$2.start) : a.$1.name.compareTo(b.$1.name));

    final needs = [
      for (final log in families)
        LogScope(
          log: log,
          child: NeedsYouSection(now: now, title: '${log.name} needs you', gap: DenLayout.sectionGap),
        ),
    ];

    final eventsSection = DenSection(
      title: 'Today',
      trailing: SectionLink('Week', onTap: () => context.go('/calendar')),
      child: events.isEmpty
          ? const EmptyState(compact: true, message: 'Nothing on any calendar today.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: ruled([for (final (log, occ) in events) _SourcedEvent(log: log, occ: occ)], indent: 32),
            ),
    );

    final lists = <(FamilyLog, ListState)>[
      for (final log in families)
        for (final l in log.state.view(const ListsModel()))
          if (l.list.pinned) (log, l),
    ];
    final listsSection = lists.isEmpty
        ? null
        : DenSection(
            title: 'Lists',
            trailing: SectionLink('All lists', onTap: () => context.go('/lists')),
            child: Column(
              children: ruled([
                for (final (log, l) in lists)
                  NavRow(
                    leading: SourceTag(label: log.name, color: log.color, size: 24),
                    label: tidy(l.list.title),
                    detail: '${log.name} · ${tidy(listSummary(l))}',
                    onTap: () => context.push(inLog(log.id, '/lists/${l.list.id}')),
                  ),
              ], indent: 36),
            ),
          );

    const chores = NoticeLine(
      icon: PhosphorIconsRegular.checkCircle,
      message: 'Chores and stars stay with each family. Choose one to see them.',
    );

    final header = PageHeader(
      overline: f.long(date),
      title: greeting(hour),
      large: !compact,
      trailing: compact ? Row(mainAxisSize: MainAxisSize.min, children: [const SearchButton(), PersonButton(member: app.me)]) : null,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= TodayScreen.twoColumns;
        final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
        if (!two) {
          return ListView(
            padding: EdgeInsets.fromLTRB(side, compact ? Sp.xs : Sp.l, side, Sp.xxl),
            children: [
              if (compact)
                const Padding(
                  padding: EdgeInsets.only(left: DenLayout.headingInset),
                  child: Align(alignment: Alignment.centerLeft, child: FamilySwitch()),
                ),
              header,
              const SizedBox(height: DenLayout.sectionGap),
              ...needs,
              eventsSection,
              if (listsSection != null) ...[const SizedBox(height: DenLayout.sectionGap), listsSection],
              const SizedBox(height: DenLayout.sectionGap),
              chores,
            ],
          );
        }
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(side, 32, side, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: DenLayout.sectionGap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...needs, eventsSection]),
                  ),
                  const SizedBox(width: DenLayout.sectionGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ?listsSection,
                        if (listsSection != null) const SizedBox(height: DenLayout.sectionGap),
                        chores,
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One event in "All my families": its family's tag, then the event as Today shows it, in its
/// family (its people, its time zone, and a tap opens it there).
class _SourcedEvent extends StatelessWidget {
  const _SourcedEvent({required this.log, required this.occ});

  final FamilyLog log;
  final Occurrence occ;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        children: [
          SourceTag(label: log.name, color: log.color, size: 22),
          const SizedBox(width: 10),
          Expanded(child: LogScope(log: log, child: EventLine(occ))),
        ],
      ),
    );
  }
}
