import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/side_panel.dart';
import '../widgets/calendar_category.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../words/calendar_time.dart';
import '../state/event_lookup.dart';
import '../words/event_words.dart';
import '../words/recurrence.dart';
import '../../../platform/capabilities.dart';
import '../../../app/navigation.dart';
import '../state/event_actions.dart';

/// What the editor tells the detail when it closes: whether the occurrence the detail shows
/// still exists as it was addressed.
enum EditOutcome { saved, moved }

/// One event occurrence: when, how it repeats, who, where, rides, reminders and who can see it.
/// A side panel on wide screens, a full page on phones (see [calendarPanelPage]).
class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({super.key, required this.eventId, this.at});

  final String eventId;

  /// The occurrence's start, UTC ms.
  final int? at;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final event = den.event(eventId);
    if (event == null) return const _Missing();
    final occ = findOccurrence(den, eventId, at) ?? occurrenceOf(event);
    final canEdit = app.allows(DenAction.editEvents) && !event.source.readOnly;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(
              actions: [
                if (canEdit)
                  OutlinedButton.icon(
                    onPressed: () => _edit(context, occ),
                    icon: const Icon(PhosphorIconsRegular.pencilSimple, size: 18),
                    label: const Text('Edit event'),
                  ),
              ],
            ),
            Expanded(
              child: _Body(occ: occ, canEdit: canEdit),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, Occurrence occ) async {
    final outcome = await context.push<EditOutcome>('/event/${occ.event.id}/edit?at=${occ.start}');
    if (outcome == EditOutcome.moved && context.mounted) closePage(context);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({this.actions = const []});
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= panelBreakpoint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.s, Sp.l, Sp.s),
      child: Row(
        children: [
          IconButton(
            tooltip: wide ? 'Close' : 'Back',
            onPressed: () => closePage(context),
            icon: Icon(wide ? PhosphorIconsRegular.x : PhosphorIconsRegular.arrowLeft),
          ),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _TopBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.l),
              child: Text(
                'This event was deleted, or it isn’t shared with this device.',
                style: context.type.body(c.ink2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Sp.l),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(onPressed: () => context.go('/calendar'), child: const Text('Open the calendar')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.occ, required this.canEdit});
  final Occurrence occ;
  final bool canEdit;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final f = app.formats;
    final c = context.colors;
    final event = occ.event;
    final today = app.today;
    final first = f.localDate(occ.start);
    final last = f.lastDate(occ.start, occ.end);
    final weekStart = den.family?.weekStart ?? 0;
    final repeat = describeRrule(event.rrule, f, startDate: f.localDate(event.start), weekStart: weekStart);
    final category = event.category == null ? null : den.category(event.category!);
    final people = occ.assignees.map(app.memberById).whereType<Member>().toList();
    final source = event.source;
    final days = f.daysFrom(today, first);
    final countdown = event.countdown ? countdownWords(days) : null;

    final whenLines = first == last
        ? [f.longWithYear(first, relativeTo: today), f.occurrenceSpan(occ, today: today)]
        : [f.occurrenceSpan(occ, today: today)];

    return ListView(
      padding: const EdgeInsets.only(bottom: Sp.xxxl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, 0),
          child: Semantics(header: true, child: Text(occ.title, style: context.type.heading(c.ink))),
        ),
        const SizedBox(height: Sp.s),
        for (final line in whenLines)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l),
            child: Text(line, style: context.type.body(c.ink)),
          ),
        if (repeat != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(PhosphorIconsRegular.repeat, size: 18, color: c.ink2),
                ),
                const SizedBox(width: Sp.s),
                Expanded(child: Text(repeat, style: context.type.body(c.ink2))),
              ],
            ),
          ),
        if (source.readOnly) ...[const SizedBox(height: Sp.l), _SourceBanner(source)],
        const SizedBox(height: Sp.l),
        FactRow(
          label: 'Who',
          child: occ.forEveryone
              ? Text('Everyone', style: context.type.body(c.ink))
              : Wrap(
                  spacing: Sp.m,
                  runSpacing: Sp.xs,
                  children: [
                    for (final m in people)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DenAvatar(m, size: 22 * context.type.scale),
                          const SizedBox(width: Sp.s - 2),
                          Text(m.name, style: context.type.body(c.ink)),
                        ],
                      ),
                  ],
                ),
        ),
        if (category != null)
          FactRow(
            label: 'Category',
            child: Row(
              children: [
                Icon(categoryIcon(category.icon), size: 20, color: c.ink2),
                const SizedBox(width: Sp.s - 2),
                Flexible(child: Text(category.name, style: context.type.body(c.ink))),
              ],
            ),
          ),
        if (occ.location.isNotEmpty) FactRow(label: 'Where', child: _Location(occ.location)),
        for (final ride in occ.rides)
          FactRow(
            label: legWords(ride.leg),
            center: true,
            child: _RideValue(occ: occ, ride: ride),
          ),
        if (occ.reminders.isNotEmpty)
          FactRow(
            label: 'Reminders',
            child: Text(
              (occ.reminders.toList()..sort()).map(reminderWords).join(', '),
              style: context.type.body(c.ink),
            ),
          ),
        if (countdown != null)
          FactRow(
            label: 'Countdown',
            child: Text(countdown, style: context.type.body(c.ink)),
          ),
        FactRow(
          label: 'Seen by',
          child: Text(app.seenBy(event.space), style: context.type.body(c.ink)),
        ),
        if (occ.notes.isNotEmpty)
          FactRow(
            label: 'Notes',
            child: SelectableText(occ.notes, style: context.type.body(c.ink)),
          ),
        _Provenance(event),
        if (canEdit)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.s, Sp.l, Sp.l, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: c.bad),
                onPressed: () => deleteOccurrence(context, occ),
                icon: const Icon(PhosphorIconsRegular.trash, size: 18),
                label: const Text('Delete event'),
              ),
            ),
          ),
      ],
    );
  }
}

class _SourceBanner extends StatelessWidget {
  const _SourceBanner(this.source);
  final EventSource source;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = source.label;
    final String from;
    if (source.kind == 'device') {
      // A phone calendar: its name, and the phone it lives on (the device id leads the ref).
      final ref = source.ref ?? '';
      final phone = ref.contains('/') ? context.den.device(ref.substring(0, ref.indexOf('/')))?.name : null;
      final name = label == null || label.isEmpty ? 'a phone calendar' : label;
      from = phone == null || phone.isEmpty ? 'From $name on a phone.' : 'From $name on $phone.';
    } else {
      from = label == null || label.isEmpty ? 'From another calendar.' : 'From $label’s calendar.';
    }
    return Container(
      color: c.well,
      padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(PhosphorIconsRegular.calendarCheck, size: 18, color: c.ink2),
          ),
          const SizedBox(width: Sp.s),
          Expanded(child: Text('$from Change it there.', style: context.type.body(c.ink))),
        ],
      ),
    );
  }
}

class _Location extends StatelessWidget {
  const _Location(this.location);
  final String location;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      hint: 'Opens in Maps',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.control),
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: Text(
                  location,
                  style: context.type
                      .body(c.ink)
                      .copyWith(decoration: TextDecoration.underline, decorationColor: c.rule),
                ),
              ),
              const SizedBox(width: Sp.xs),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(PhosphorIconsRegular.arrowSquareOut, size: 16, color: c.ink2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final apple = Capabilities.apple;
    final uri = apple
        ? Uri.https('maps.apple.com', '/', {'q': location})
        : Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': location});
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      opened = false;
    }
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: location));
      if (context.mounted) showNote(context, 'Couldn’t open a maps app. The address is copied, so you can paste it.');
    }
  }
}

class _RideValue extends StatelessWidget {
  const _RideValue({required this.occ, required this.ride});
  final Occurrence occ;
  final Ride ride;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final me = app.me;
    final driver = app.memberById(ride.driver);
    final canClaim = canTakeRide(app) && !occ.event.source.readOnly;

    Future<void> claim(String? who) => attempt(
      context,
      () => context.eventActions.setRide(occ, ride.leg, who),
    );

    Widget line(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Targets.adult),
      child: Align(alignment: Alignment.centerLeft, child: child),
    );

    if (ride.driver == null) {
      return line(
        AttentionLine(
          message: 'Nobody is driving',
          action: canClaim ? TextButton(onPressed: () => claim(me!.id), child: const Text('Take it')) : null,
        ),
      );
    }
    final mine = ride.driver == me?.id;
    return line(
      Row(
        children: [
          if (driver != null) ...[DenAvatar(driver, size: 22 * context.type.scale), const SizedBox(width: Sp.s - 2)],
          Expanded(child: Text(mine ? 'You' : (driver?.name ?? 'Someone'), style: context.type.body(c.ink))),
          if (mine && canClaim) TextButton(onPressed: () => claim(null), child: const Text('Release it')),
        ],
      ),
    );
  }
}

class _Provenance extends StatelessWidget {
  const _Provenance(this.event);
  final Event event;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final f = app.formats;
    final c = context.colors;
    final rec = event.rec;
    final today = app.today;
    String on(Hlc hlc) => f.monthDay(f.localDate(hlc.millis), relativeTo: today);
    final added = app.memberById(rec.createdBy)?.name;
    final changed = app.memberById(rec.updatedBy)?.name;
    final parts = [
      if (added != null) 'Added by $added, ${on(rec.created)}',
      if (changed != null && rec.updated != rec.created) 'Changed by $changed, ${on(rec.updated)}',
    ];
    if (parts.isEmpty) return const SizedBox(height: Sp.s);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, 0),
      child: Text(parts.join(' · '), style: context.type.meta(c.ink2)),
    );
  }
}

/// Deletes an occurrence, asking how far for a repeating event, then offers Undo, which puts
/// back exactly what was removed.
Future<void> deleteOccurrence(BuildContext context, Occurrence occ) async {
  final app = DenScope.read(context);
  final actions = app.actions;
  final f = app.formats;
  final event = occ.event;
  var scope = EditScope.all;
  if (occ.isRepeating) {
    final chosen = await askEditScope(context, title: 'Delete ${occ.title}');
    if (chosen == null || !context.mounted) return;
    scope = chosen;
  }
  final keep = Navigator.of(context, rootNavigator: true).context;
  final occurrence = occ.isRepeating ? occ.seriesStart : null;
  final result = await perform(context, () => EventActions(actions).delete(event, scope: scope, occurrence: occurrence));
  if (result == null || !context.mounted) return;
  closePage(context);
  final message = switch (scope) {
    EditScope.one => 'Deleted ${occ.title} on ${f.short(f.localDate(occ.start))}.',
    EditScope.following => 'Deleted ${occ.title} from ${f.short(f.localDate(occ.start))} on.',
    EditScope.all => 'Deleted ${occ.title}.',
  };
  if (keep.mounted) offerUndo(keep, actions, message, result);
}
