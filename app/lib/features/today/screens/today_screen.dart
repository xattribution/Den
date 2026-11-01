import 'dart:async';

import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/shell.dart' show PersonButton, SearchButton;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/den_network.dart';
import '../../../app/household.dart';
import '../../assistant/assistant.dart' show AskSetUpLine, AskTodayEntry;
import '../../family/family.dart' show FamilySwitch;
import '../state/today_model.dart';
import '../widgets/needs_you_card.dart';
import '../widgets/today_chores.dart';
import '../widgets/today_events.dart';
import '../widgets/today_groceries.dart';
import '../words/today_words.dart';

/// The first screen for every adult (Main.dc.html, PadToday.dc.html): the date and a greeting,
/// Ask while the AI helper is on for them, what needs them, the day's events, everyone's chores,
/// and the groceries. From 5 PM it looks ahead to tomorrow too. A parent while the helper is off
/// finds a quiet way to set it up at the end.
///
/// On a phone, one column, the person's face in the header. With room for two columns (an iPad
/// in landscape, beside the sidebar), Needs you and the events on the left, chores and
/// groceries on the right.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  /// The width from which Today's content sits in two columns.
  static const double twoColumns = 760;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  Timer? _tick;
  int? _hour;
  int _ended = 0;

  @override
  void initState() {
    super.initState();
    // The greeting and Tomorrow follow the clock even when nothing else changes, and so does
    // something put off coming back (a ride an hour before it leaves).
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      final app = DenScope.read(context);
      final now = app.den.now();
      if (app.formats.at(now).hour != _hour || app.snoozesEnded(now) != _ended) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(todayReads);
    final view = context.view(const TodayModel());
    final f = app.formats;
    final now = app.den.now();
    final hour = f.at(now).hour;
    _hour = hour;
    _ended = app.snoozesEnded(now);
    final compact = DenLayout.of(context).isCompact;
    final tomorrow = showsTomorrow(hour) ? app.den.today(date: f.addDays(view.date, 1)) : null;

    final events = TodayEvents(
      title: 'Today',
      date: view.date,
      events: view.events,
      gaps: view.gaps,
      link: SectionLink('Week', onTap: () => context.go('/calendar')),
    );
    final ahead = tomorrow == null
        ? null
        : TodayEvents(
            title: 'Tomorrow',
            date: tomorrow.date,
            events: tomorrow.events,
            gaps: tomorrow.gaps,
            link: SectionLink('Calendar', onTap: () => context.go('/calendar?date=${tomorrow.date}')),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final two = constraints.maxWidth >= TodayScreen.twoColumns;
        final side = two ? 32.0 : (compact ? DenLayout.gutter : 24.0);
        final header = PageHeader(
          overline: f.long(view.date),
          title: greeting(hour),
          large: !compact,
          trailing: compact
              ? Row(mainAxisSize: MainAxisSize.min, children: [const SearchButton(), PersonButton(member: app.me)])
              : null,
        );
        final notice = _SyncNotice(network: app.network);
        // On a phone in several families, the family showing is a switch at the top.
        final several = compact && (Household.maybeOf(context)?.several ?? false);
        if (!two) {
          return ListView(
            padding: EdgeInsets.fromLTRB(side, several ? Sp.xs : Sp.l, side, Sp.xxl),
            children: [
              if (several) const Padding(padding: EdgeInsets.only(left: DenLayout.headingInset), child: Align(alignment: Alignment.centerLeft, child: FamilySwitch())),
              header,
              notice,
              const AskTodayEntry(padding: EdgeInsets.only(top: Sp.l)),
              const SizedBox(height: DenLayout.sectionGap),
              NeedsYouSection(now: now, gap: DenLayout.sectionGap),
              events,
              if (ahead != null) ...[const SizedBox(height: DenLayout.sectionGap), ahead],
              const SizedBox(height: DenLayout.sectionGap),
              TodayChores(chores: view.chores),
              const SizedBox(height: DenLayout.sectionGap),
              const TodayGroceries(),
              const AskSetUpLine(padding: EdgeInsets.only(top: DenLayout.sectionGap)),
            ],
          );
        }
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(side, 32, side, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              notice,
              const SizedBox(height: DenLayout.sectionGap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AskTodayEntry(padding: EdgeInsets.only(bottom: DenLayout.sectionGap)),
                        NeedsYouSection(now: now, carded: true, gap: DenLayout.sectionGap),
                        events,
                        if (ahead != null) ...[const SizedBox(height: DenLayout.sectionGap), ahead],
                      ],
                    ),
                  ),
                  const SizedBox(width: DenLayout.sectionGap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TodayChores(chores: view.chores, rows: true),
                        const SizedBox(height: DenLayout.sectionGap),
                        const TodayGroceries(),
                        const AskSetUpLine(padding: EdgeInsets.only(top: DenLayout.sectionGap)),
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

/// When this device can't reach the family's hub: changes stay here and sync later. Nothing
/// otherwise.
class _SyncNotice extends StatelessWidget {
  const _SyncNotice({required this.network});

  final DenNetwork? network;

  @override
  Widget build(BuildContext context) {
    final net = network;
    if (net == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: net,
      builder: (context, _) {
        final status = net.status;
        final offline = status.state == SyncState.offline || status.state == SyncState.stopped;
        if (net.isHub || !offline || status.lastError == 'no hub' || net.hubDevice == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: Sp.m),
          child: NoticeLine(
            message: net.describe(),
            action: TextButton(onPressed: () => context.push('/settings'), child: const Text('Sync')),
          ),
        );
      },
    );
  }
}
