import 'dart:async';

import 'package:den_net/den_net.dart' show SyncState;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/shell.dart' show PersonButton;
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/den_network.dart';
import '../state/today_model.dart';
import '../widgets/needs_you_card.dart';
import '../widgets/today_chores.dart';
import '../widgets/today_events.dart';
import '../widgets/today_groceries.dart';
import '../words/today_words.dart';

/// The first screen for every adult (Main.dc.html, PadToday.dc.html): the date and a greeting,
/// what needs them, the day's events, everyone's chores, and the groceries. From 5 PM it looks
/// ahead to tomorrow too.
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

  @override
  void initState() {
    super.initState();
    // The greeting and Tomorrow follow the clock even when nothing else changes.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      final app = DenScope.read(context);
      final hour = app.formats.at(app.den.now()).hour;
      if (hour != _hour) setState(() {});
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
          trailing: compact ? PersonButton(member: app.me) : null,
        );
        final notice = _SyncNotice(network: app.network);
        if (!two) {
          return ListView(
            padding: EdgeInsets.fromLTRB(side, Sp.l, side, Sp.xxl),
            children: [
              header,
              notice,
              const SizedBox(height: DenLayout.sectionGap),
              NeedsYouSection(now: now, gap: DenLayout.sectionGap),
              events,
              if (ahead != null) ...[const SizedBox(height: DenLayout.sectionGap), ahead],
              const SizedBox(height: DenLayout.sectionGap),
              TodayChores(chores: view.chores),
              const SizedBox(height: DenLayout.sectionGap),
              const TodayGroceries(),
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
