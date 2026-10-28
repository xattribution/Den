import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../design/parts/family_sign_in.dart';
import '../../design/parts/family_words.dart';
import '../../design/parts/family_glyphs.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../routes/family_routes.dart';
import '../../state/app_state.dart';
import '../calendar/family_week.dart';
import '../calendar/month_view.dart';
import '../family/device_parts.dart';

/// The kitchen wall: the date and a large clock, the family week as the main region, and a strip
/// with today's chores per person and the grocery list. Anyone can read it; writes ask "Who's
/// doing this?" unless open check-off is on, then act as that person for a minute.
class WallScreen extends StatefulWidget {
  const WallScreen({super.key, this.now, this.keepAwake = true});

  /// The clock; tests pass a fixed time.
  final DateTime Function()? now;

  /// Keeps the screen on while the wall is showing, where the platform allows it.
  final bool keepAwake;

  @override
  State<WallScreen> createState() => _WallScreenState();
}

class _WallScreenState extends State<WallScreen> {
  Timer? _minute;
  Timer? _second;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    if (widget.keepAwake) WakelockPlus.enable().catchError((Object _) {});
    _scheduleMinute();
  }

  void _scheduleMinute() {
    final now = _now();
    final next = DateTime(now.year, now.month, now.day, now.hour, now.minute + 1);
    _minute = Timer(next.difference(now), () {
      if (!mounted) return;
      setState(() {});
      _scheduleMinute();
    });
  }

  @override
  void dispose() {
    _minute?.cancel();
    _second?.cancel();
    if (widget.keepAwake) WakelockPlus.disable().catchError((Object _) {});
    super.dispose();
  }

  /// Ticks once a second while someone is acting, so the pill counts down and then ends.
  void _syncActingTicker(Den den) {
    final until = den.actingUntil;
    if (until == null || den.actor == null) {
      _second?.cancel();
      _second = null;
      return;
    }
    _second ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = (den.actingUntil ?? 0) - _now().millisecondsSinceEpoch;
      if (left <= 0) {
        den.actAs(null);
        _second?.cancel();
        _second = null;
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    _syncActingTicker(den);
    final size = MediaQuery.sizeOf(context);
    // Wide walls put today's chores and groceries beside the week; narrower ones put them in a
    // band of person columns underneath, so every person's column in the week stays on screen.
    final side = size.width >= 1500;
    final layout = wallLayoutOf(den.thisDevice);
    final today = app.today;

    final Widget main = switch (layout) {
      DisplayLayout.today => _TodayBoard(onAct: () => setState(() {})),
      DisplayLayout.month => MonthView(anchor: today),
      DisplayLayout.lists => const _ListsBoard(),
      DisplayLayout.week || DisplayLayout.photos => FamilyWeek(startDate: today, showChores: false, fillHeight: true),
    };

    final onlyAnyone = layout == DisplayLayout.today;
    final strip = _TodayStrip(onAct: () => setState(() {}), onlyAnyone: onlyAnyone);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(now: _now(), onChanged: () => setState(() {})),
            Divider(height: 1, color: c.rule),
            Expanded(
              child: side
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: main),
                        VerticalDivider(width: 1, color: c.rule),
                        SizedBox(width: (size.width * 0.27).clamp(320.0, 560.0), child: strip),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: main),
                        Divider(height: 1, color: c.rule),
                        SizedBox(
                          height: (size.height * 0.4).clamp(240.0, 420.0),
                          child: _TodayBand(onAct: () => setState(() {}), onlyAnyone: onlyAnyone),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.now, required this.onChanged});
  final DateTime now;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final f = app.formats;
    final ms = now.millisecondsSinceEpoch;
    final actor = den.actor;
    final until = den.actingUntil;
    final shared = den.thisDevice?.isShared ?? false;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 760;
    final date = Semantics(
      header: true,
      child: Text(f.long(f.localDate(ms)), style: context.type.heading(c.ink2), overflow: TextOverflow.ellipsis),
    );

    final controls = <Widget>[
      if (actor != null && until != null)
        ActingPill(
          member: actor,
          left: Duration(milliseconds: until - ms),
          onDone: () {
            den.actAs(null);
            onChanged();
          },
        )
      else if (shared)
        TextButton.icon(
          onPressed: () => switchPerson(context),
          icon: const Icon(PhosphorIconsRegular.userSwitch),
          label: const Text('Switch person'),
        ),
      if (width >= 1100 && den.thisDevice != null) ...[
        const SizedBox(width: Sp.l),
        Text(den.thisDevice!.name, style: context.type.body(c.ink2)),
      ],
      const SizedBox(width: Sp.s),
      IconButton(
        tooltip: 'Settings',
        onPressed: () => context.push('/settings'),
        icon: Icon(PhosphorIconsRegular.gear, color: c.ink2),
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(narrow ? Sp.l : Sp.xl, Sp.m, Sp.m, Sp.m),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(f.time(ms), style: context.type.display(c.ink)),
                    const Spacer(),
                    ...controls,
                  ],
                ),
                date,
              ],
            )
          : Row(
              children: [
                Text(f.time(ms), style: context.type.display(c.ink)),
                const SizedBox(width: Sp.xl),
                Expanded(child: date),
                ...controls,
              ],
            ),
    );
  }
}

/// "Acting as Mia · 0:42 · Done": solid ink, because it's the state everything on the wall is
/// being done in.
class ActingPill extends StatelessWidget {
  const ActingPill({super.key, required this.member, required this.left, required this.onDone});

  final Member member;
  final Duration left;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      label: 'Acting as ${member.name}, ${FamilyWords.countdown(left)} left',
      child: Material(
        color: c.ink,
        shape: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.xs, Sp.xs, Sp.xs, Sp.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DenAvatar(member, size: 36),
              const SizedBox(width: Sp.s),
              ExcludeSemantics(
                child: Text(
                  'Acting as ${member.name} · ${FamilyWords.countdown(left)}',
                  style: context.type.bodyStrong(c.onInk),
                ),
              ),
              const SizedBox(width: Sp.s),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.onInk, shape: const StadiumBorder()),
                onPressed: onDone,
                child: Text('Done', style: context.type.bodyStrong(c.onInk)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On a shared screen: pick a person, check their PIN or pattern, and open their app — the
/// kids' app for younger kids, the full app for everyone else.
Future<void> switchPerson(BuildContext context) async {
  final who = await showWhoSheet(context, title: "Who's using Den?", window: const Duration(minutes: 5));
  if (who == null || !context.mounted) return;
  context.go(isLittleKid(who) ? '/kid' : '/today');
}

/// Runs a write from the wall: directly when the person acting (or open check-off) allows it,
/// otherwise after "Who's doing this?". [actionFor] says which permission the write needs for
/// a given actor, since "your own chore" depends on who's doing it.
Future<void> wallWrite(
  BuildContext context,
  DenAction Function(Member? actor) actionFor,
  Future<void> Function() write, {
  String? likely,
}) async {
  final app = context.app;
  if (app.allows(actionFor(app.den.actor))) {
    await attempt(context, write);
    return;
  }
  final who = await showWhoSheet(context, likely: likely);
  if (who == null || !context.mounted) return;
  if (!can(who, actionFor(who))) {
    showNote(context, "${who.name} can't do that here. Someone it belongs to, or a parent, can.");
    return;
  }
  await attempt(context, write);
}

DenAction _choreAction(ChoreDay day, Member? actor) =>
    day.owner == null || day.owner == actor?.id ? DenAction.completeOwnChore : DenAction.completeAnyChore;

/// Today's chores per person with big checks, then the pinned grocery list.
class _TodayStrip extends StatelessWidget {
  const _TodayStrip({required this.onAct, this.onlyAnyone = false});
  final VoidCallback onAct;

  /// With the Today board, people's chores are in their columns; the strip keeps "anyone" chores.
  final bool onlyAnyone;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final view = den.today();
    final chores = onlyAnyone ? view.chores.where((d) => d.owner == null).toList() : view.chores;
    final byOwner = <String?, List<ChoreDay>>{};
    for (final d in chores) {
      byOwner.putIfAbsent(d.owner, () => []).add(d);
    }
    final owners = [
      for (final m in den.members)
        if (byOwner.containsKey(m.id)) m.id,
      if (byOwner.containsKey(null)) null,
    ];
    final groceries =
        view.lists.where((l) => l.list.kind == ListKind.shopping).firstOrNull ??
        den.lists.where((l) => l.list.pinned && l.list.kind == ListKind.shopping).firstOrNull;
    final done = chores.where((d) => d.done).length;

    return ListView(
      padding: const EdgeInsets.only(bottom: Sp.xl),
      children: [
        if (!onlyAnyone || chores.isNotEmpty)
          SectionHeader(
            onlyAnyone ? 'Anyone can do' : 'Chores',
            trailing: chores.isEmpty ? null : '$done of ${chores.length} done',
          ),
        if (chores.isEmpty && !onlyAnyone) const EmptyLine(message: 'No chores today.'),
        if (onlyAnyone)
          for (final d in chores) _WallChore(day: d, onAct: onAct)
        else
          for (final owner in owners)
            _ChoreGroup(owner: owner == null ? null : den.member(owner), days: byOwner[owner]!, onAct: onAct),
        if (groceries != null) ...[
          if (chores.isNotEmpty || !onlyAnyone) Divider(height: Sp.xl, color: c.rule),
          _ListPanel(state: groceries, onAct: onAct, limit: 12),
        ],
      ],
    );
  }
}

class _ChoreGroup extends StatelessWidget {
  const _ChoreGroup({required this.owner, required this.days, required this.onAct});
  final Member? owner;
  final List<ChoreDay> days;
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final left = days.where((d) => !d.done).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
            child: Row(
              children: [
                if (owner != null)
                  DenAvatar(owner!, size: 32)
                else
                  Icon(PhosphorIconsRegular.usersThree, size: 32, color: c.ink2),
                const SizedBox(width: Sp.s),
                Expanded(child: Text(owner?.name ?? 'Anyone', style: context.type.title(c.ink))),
                Text(left == 0 ? 'All done' : '$left left', style: context.type.meta(c.ink2)),
              ],
            ),
          ),
          for (final d in days) _WallChore(day: d, onAct: onAct),
        ],
      ),
    );
  }
}

class _WallChore extends StatelessWidget {
  const _WallChore({required this.day, required this.onAct, this.compact = false});
  final ChoreDay day;
  final VoidCallback onAct;

  /// In a narrow person column: no points or step count.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final chore = day.chore;
    final titleStyle = context.type
        .body(day.done ? c.ink2 : c.ink)
        .copyWith(decoration: day.done ? TextDecoration.lineThrough : null, decorationColor: c.ink2);
    Future<void> toggle(bool v) async {
      await wallWrite(
        context,
        (actor) => _choreAction(day, actor),
        () => den.setChoreDone(chore.id, day.date, v),
        likely: day.owner,
      );
      onAct();
    }

    return Padding(
      padding: EdgeInsets.only(left: compact ? 0 : Sp.xs, right: compact ? Sp.s : Sp.l),
      child: Row(
        children: [
          CheckDot(done: day.done, size: compact ? 30 : 36, label: chore.title, onChanged: toggle),
          Icon(choreGlyph(chore.icon, chore.title), size: 24, color: c.ink2),
          const SizedBox(width: Sp.s),
          Expanded(
            child: Text(chore.title, style: titleStyle, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          if (chore.steps.isNotEmpty && !compact) ...[
            Text('${day.stepsDone}/${day.stepCount}', style: context.type.meta(c.ink2)),
            const SizedBox(width: Sp.s),
          ],
          if (day.late && !day.done) ...[
            Icon(PhosphorIconsFill.clockCountdown, size: 18, color: c.bad),
            const SizedBox(width: 2),
            Text('Late', style: context.type.meta(c.bad)),
            const SizedBox(width: Sp.s),
          ],
          if ((den.family?.pointsEnabled ?? true) && day.pointsAvailable > 0 && !compact)
            StarCount(day.pointsAvailable, size: 20),
        ],
      ),
    );
  }
}

/// A list's open items with big checks; checked ones drop off the wall.
class _ListPanel extends StatelessWidget {
  const _ListPanel({required this.state, required this.onAct, this.limit});
  final ListState state;
  final VoidCallback onAct;
  final int? limit;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final open = state.items.where((i) => !i.checked).toList();
    final shown = limit == null ? open : open.take(limit!).toList();
    final more = open.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(state.list.title, trailing: '${open.length} ${open.length == 1 ? 'item' : 'items'}'),
        if (open.isEmpty) const EmptyLine(message: 'Nothing left on this list.'),
        for (final item in shown)
          Padding(
            padding: const EdgeInsets.only(left: Sp.xs, right: Sp.l),
            child: Row(
              children: [
                CheckDot(
                  done: false,
                  size: 32,
                  label: item.text,
                  onChanged: (v) async {
                    await wallWrite(context, (_) => DenAction.checkItems, () => den.setItemChecked(item.id, v));
                    onAct();
                  },
                ),
                Expanded(
                  child: Text(
                    [if (item.qty != null && item.qty!.isNotEmpty) item.qty!, item.text].join(' '),
                    style: context.type.body(c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (item.store != null && item.store!.isNotEmpty) Text(item.store!, style: context.type.meta(c.ink2)),
              ],
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
            child: Text('and $more more', style: context.type.meta(c.ink2)),
          ),
      ],
    );
  }
}

/// The "Lists" layout: every list side by side, pinned first.
class _ListsBoard extends StatelessWidget {
  const _ListsBoard();

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final lists = [...den.lists]..sort((a, b) => (b.list.pinned ? 1 : 0) - (a.list.pinned ? 1 : 0));
    if (lists.isEmpty) return const EmptyLine(message: 'No lists yet.');
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: lists.length,
      separatorBuilder: (_, _) => VerticalDivider(width: 1, color: c.rule),
      itemBuilder: (context, i) => SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: _ListPanel(state: lists[i], onAct: () {}),
        ),
      ),
    );
  }
}

/// The "Today" layout: a column per person for today, each with their events and chores, and
/// events for everyone across the top. The family-columns grid, one day tall.
class _TodayBoard extends StatelessWidget {
  const _TodayBoard({required this.onAct});
  final VoidCallback onAct;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final f = app.formats;
    final view = den.today();
    final people = den.members;
    final everyone = view.events.where((o) => o.forEveryone || o.assignees.length == people.length).toList();

    Widget event(Occurrence o, {bool spanning = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.xs),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PersonBar(markers: app.markersFor(o.assignees), width: 4, minHeight: 28),
            const SizedBox(width: Sp.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(o.allDay ? 'All day' : f.time(o.start), style: context.type.meta(c.ink2)),
                  Text(o.title, style: spanning ? context.type.bodyStrong(c.ink) : context.type.body(c.ink)),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (final m in people)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(Sp.s),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: c.rule),
                      bottom: BorderSide(color: c.marker(m.marker), width: 3),
                    ),
                  ),
                  child: Row(
                    children: [
                      DenAvatar(m, size: 32),
                      const SizedBox(width: Sp.s),
                      Flexible(
                        child: Text(m.name, style: context.type.title(c.ink), overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (everyone.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Sp.m, vertical: Sp.xs),
            decoration: BoxDecoration(
              color: c.well,
              border: Border(bottom: BorderSide(color: c.rule)),
            ),
            child: Column(children: [for (final o in everyone) event(o, spanning: true)]),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final m in people)
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: c.rule)),
                    ),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(Sp.s, Sp.s, 0, Sp.l),
                      children: [
                        for (final o in view.events)
                          if (!everyone.contains(o) && o.assignees.contains(m.id)) event(o),
                        for (final d in view.chores)
                          if (d.owner == m.id) _WallChore(day: d, onAct: onAct, compact: true),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Today's chores as person columns under the week, the fridge chart's layout, then groceries.
class _TodayBand extends StatelessWidget {
  const _TodayBand({required this.onAct, this.onlyAnyone = false});
  final VoidCallback onAct;
  final bool onlyAnyone;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final view = den.today();
    final chores = onlyAnyone ? view.chores.where((d) => d.owner == null).toList() : view.chores;
    final byOwner = <String?, List<ChoreDay>>{};
    for (final d in chores) {
      byOwner.putIfAbsent(d.owner, () => []).add(d);
    }
    final owners = [
      for (final m in den.members)
        if (byOwner.containsKey(m.id)) m.id,
      if (byOwner.containsKey(null)) null,
    ];
    final groceries =
        view.lists.where((l) => l.list.kind == ListKind.shopping).firstOrNull ??
        den.lists.where((l) => l.list.pinned && l.list.kind == ListKind.shopping).firstOrNull;

    final columns = <Widget>[
      for (final owner in owners)
        SizedBox(
          width: 280,
          child: ListView(
            padding: const EdgeInsets.only(bottom: Sp.l),
            children: [
              _ChoreGroup(owner: owner == null ? null : den.member(owner), days: byOwner[owner]!, onAct: onAct),
            ],
          ),
        ),
      if (groceries != null)
        SizedBox(
          width: 340,
          child: ListView(
            padding: const EdgeInsets.only(bottom: Sp.l),
            children: [_ListPanel(state: groceries, onAct: onAct, limit: 8)],
          ),
        ),
    ];
    if (columns.isEmpty) return const EmptyLine(message: 'No chores today.');
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: columns.length,
      separatorBuilder: (_, _) => VerticalDivider(width: 1, color: c.rule),
      itemBuilder: (_, i) => columns[i],
    );
  }
}
