import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/calendars/phone_calendars.dart';

/// The words for who sees a calendar brought in from this phone, "Off" for one left out.
const Map<Audience?, String> phoneCalendarChoices = {
  null: 'Off',
  Audience.everyone: 'Everyone',
  Audience.parents: 'Parents',
  Audience.justMe: 'Just me',
};

/// Settings → Calendars → Calendars on this phone: every calendar the phone holds, grouped by
/// account, each brought into Den for Everyone, Parents or Just me, or left off. Calendar colors
/// stay on the phone; in Den a hue means a person.
class PhoneCalendarsScreen extends StatefulWidget {
  const PhoneCalendarsScreen({super.key});

  @override
  State<PhoneCalendarsScreen> createState() => _PhoneCalendarsScreenState();
}

class _PhoneCalendarsScreenState extends State<PhoneCalendarsScreen> {
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    context.watch(const {}).phoneCalendars?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final calendars = context.watch(const {}).phoneCalendars;
    if (calendars == null) {
      return const DenPage(
        title: 'Calendars on this phone',
        children: [EmptyState(message: 'Only a phone has calendars to bring in.')],
      );
    }
    return ListenableBuilder(
      listenable: calendars,
      builder: (context, _) => DenPage(title: 'Calendars on this phone', children: _body(context, calendars)),
    );
  }

  List<Widget> _body(BuildContext context, PhoneCalendars calendars) {
    final c = context.colors;
    final t = context.text;
    switch (calendars.access) {
      case null:
        return const [];
      case PhoneAccess.ask:
        return [
          GroupCard(
            child: EmptyState(
              compact: true,
              message: "Den can't read this phone's calendars yet.",
              actionLabel: 'Allow access',
              onAction: calendars.requestAccess,
            ),
          ),
        ];
      case PhoneAccess.denied:
        return [
          GroupCard(
            child: ErrorState(
              message: "Calendar access is off for Den. Turn it on in the phone's Settings.",
              actionLabel: 'Open Settings',
              onAction: calendars.openSettings,
            ),
          ),
        ];
      case PhoneAccess.restricted:
        return const [NoticeLine(message: 'Screen Time or a device policy blocks calendar access on this phone.')];
      case PhoneAccess.granted:
        break;
    }
    if (calendars.calendars.isEmpty) return const [EmptyState(message: 'This phone has no calendars.')];

    final accounts = <String, List<PhoneCalendar>>{};
    for (final cal in calendars.calendars) {
      accounts.putIfAbsent(cal.account.isEmpty ? 'On this phone' : cal.account, () => []).add(cal);
    }
    final at = calendars.syncedAt;
    final updated = calendars.syncing ? 'Updating' : (at == null ? null : 'Updated ${context.watch(const {}).formats.time(at)}');
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
        child: Text(
          'Events from a calendar you bring in show in Den for the people you choose, read-only.${updated == null ? '' : ' $updated.'}',
          style: t.meta(c.ink2),
        ),
      ),
      for (final account in accounts.entries)
        DenSection(
          title: account.key,
          child: Column(
            children: ruled([
              for (final cal in account.value)
                NavRow(
                  label: cal.name,
                  detail: calendars.picks[cal.id] == null
                      ? null
                      : '${calendars.countFor(cal.id)} event${calendars.countFor(cal.id) == 1 ? '' : 's'}',
                  value: phoneCalendarChoices[calendars.picks[cal.id]],
                  onTap: () => _choose(context, calendars, cal),
                ),
            ]),
          ),
        ),
    ];
  }

  Future<void> _choose(BuildContext context, PhoneCalendars calendars, PhoneCalendar cal) async {
    final current = calendars.picks[cal.id];
    final picked = await showDenSheet<(Audience?,)>(
      context,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: 'Who sees ${cal.name}?'),
            GroupCard(
              child: ChoiceRows<Audience?>(
                choices: [for (final e in phoneCalendarChoices.entries) Choice(e.key, e.value)],
                value: current,
                onChanged: (a) => Navigator.of(sheet).pop((a,)),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) await calendars.choose(cal.id, picked.$1);
  }
}
