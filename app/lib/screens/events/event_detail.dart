import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/parts/calendar_panel.dart';
import '../../design/parts/calendar_scope.dart';
import '../../design/parts/calendar_category.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';
import '../calendar/calendar_time.dart';
import 'event_lookup.dart';
import 'event_words.dart';
import 'recurrence.dart';

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

/// Leaves a pushed page, or goes to the calendar when there's nothing to go back to.
void closePage(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/calendar');
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
        _Fact(
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
          _Fact(
            label: 'Category',
            child: Row(
              children: [
                Icon(categoryIcon(category.icon), size: 20, color: c.ink2),
                const SizedBox(width: Sp.s - 2),
                Flexible(child: Text(category.name, style: context.type.body(c.ink))),
              ],
            ),
          ),
        if (occ.location.isNotEmpty) _Fact(label: 'Where', child: _Location(occ.location)),
        for (final ride in occ.rides)
          _Fact(
            label: legWords(ride.leg),
            center: true,
            child: _RideValue(occ: occ, ride: ride),
          ),
        if (occ.reminders.isNotEmpty)
          _Fact(
            label: 'Reminders',
            child: Text(
              (occ.reminders.toList()..sort()).map(reminderWords).join(', '),
              style: context.type.body(c.ink),
            ),
          ),
        if (countdown != null)
          _Fact(
            label: 'Countdown',
            child: Text(countdown, style: context.type.body(c.ink)),
          ),
        _Fact(
          label: 'Seen by',
          child: Text(audienceWords(app, event.space), style: context.type.body(c.ink)),
        ),
        if (occ.notes.isNotEmpty)
          _Fact(
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

/// A labeled line of the detail: label in ink2 on the left, the value in ink.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.child, this.center = false});
  final String label;
  final Widget child;

  /// For a value that holds a button: the label centers on it, and the button's own 48 px
  /// height stands in for the row's padding.
  final bool center;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(Sp.l, center ? 0 : Sp.s, Sp.l, center ? 0 : Sp.s),
      child: Row(
        crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96 * context.type.scale,
            child: Padding(
              padding: EdgeInsets.only(top: center ? 0 : 2),
              child: Text(label, style: context.type.meta(c.ink2)),
            ),
          ),
          const SizedBox(width: Sp.s),
          Expanded(child: child),
        ],
      ),
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
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
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
    final canClaim = canDrive(me) && !occ.event.source.readOnly;

    Future<void> claim(String? who) => attempt(
      context,
      () => app.den.claimRide(occ.event.id, occurrence: occ.seriesStart, leg: ride.leg, driver: who),
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
          if (mine) TextButton(onPressed: () => claim(null), child: const Text('Release it')),
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

/// Deletes an occurrence, asking how far for a repeating event, then offers Undo. Someone
/// else's private event can't be put back from here, so that one asks first instead.
Future<void> deleteOccurrence(BuildContext context, Occurrence occ) async {
  final app = DenScope.read(context);
  final den = app.den;
  final f = app.formats;
  final event = occ.event;
  final owner = Space.memberOf(event.space);
  final restorable = owner == null || owner == app.me?.id;
  var scope = EditScope.all;
  if (occ.isRepeating) {
    final chosen = await askEditScope(context, title: 'Delete ${occ.title}');
    if (chosen == null || !context.mounted) return;
    scope = chosen;
  }
  if (!restorable && scope != EditScope.one) {
    final name = app.memberById(owner)?.name ?? 'someone';
    final sure = await confirmDelete(
      context,
      title: 'Delete ${occ.title}?',
      message: 'It’s in $name’s private calendar, so it can’t be brought back from here.',
      action: 'Delete event',
    );
    if (!sure || !context.mounted) return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final error = await tryWrite(
    () => den.deleteEvent(event.id, scope: scope, occurrence: occ.isRepeating ? occ.seriesStart : null),
  );
  if (!context.mounted) return;
  if (error != null) {
    showNote(context, error);
    return;
  }
  closePage(context);
  if (!restorable && scope != EditScope.one) return;
  final message = switch (scope) {
    EditScope.one => 'Deleted ${occ.title} on ${f.short(f.localDate(occ.start))}.',
    EditScope.following => 'Deleted ${occ.title} from ${f.short(f.localDate(occ.start))} on.',
    EditScope.all => 'Deleted ${occ.title}.',
  };
  showUndoOn(messenger, message, () => _restore(den, event, occ, scope));
}

/// Puts back what [deleteOccurrence] removed: the one day, the rest of the series, or the
/// event itself (added again from its fields).
Future<void> _restore(Den den, Event event, Occurrence occ, EditScope scope) async {
  if (den.event(event.id) != null) {
    if (scope == EditScope.one) {
      // Any change to the one occurrence also lifts its cancellation.
      await tryWrite(
        () =>
            den.updateEvent(event.id, {'reminders': occ.reminders}, scope: EditScope.one, occurrence: occ.seriesStart),
      );
    } else {
      await tryWrite(() => den.updateEvent(event.id, {'rrule': event.rrule}));
    }
    return;
  }
  await tryWrite(
    () => den.addEvent(
      title: event.title,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
      tz: event.tz,
      rrule: event.rrule,
      assignees: event.assignees,
      category: event.category,
      location: event.location,
      notes: event.notes,
      reminders: event.reminders,
      rides: event.rides,
      countdown: event.countdown,
      audience: event.audience,
    ),
  );
}

/// Asks before something that can't be undone, naming it. Returns true to go ahead.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final c = context.colors;
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Keep it')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: c.bad),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return sure ?? false;
}
