import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../calendars/phone_calendars.dart';
import '../../design/parts/family_frame.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// The words for who sees a calendar brought in from this phone, "Off" for one left out.
const Map<Audience?, String> phoneCalendarChoices = {
  null: 'Off',
  Audience.everyone: 'Everyone',
  Audience.parents: 'Parents',
  Audience.justMe: 'Just me',
};

/// Settings → Calendars on this phone: every calendar the phone holds, grouped by account, each
/// brought into Den for Everyone, Parents or Just me, or left off. Calendar colors stay on the
/// phone; in Den a hue means a person.
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
    context.app.phoneCalendars?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final calendars = context.app.phoneCalendars;
    if (calendars == null) {
      return const FormFrame(
        title: 'Calendars on this phone',
        children: [EmptyLine(message: 'Only a phone has calendars to bring in.')],
      );
    }
    return ListenableBuilder(
      listenable: calendars,
      builder: (context, _) => FormFrame(title: 'Calendars on this phone', children: _body(context, calendars)),
    );
  }

  List<Widget> _body(BuildContext context, PhoneCalendars calendars) {
    switch (calendars.access) {
      case null:
        return const [];
      case PhoneAccess.ask:
        return [
          EmptyLine(
            message: "Den can't read this phone's calendars yet.",
            actionLabel: 'Allow access',
            onAction: calendars.requestAccess,
          ),
        ];
      case PhoneAccess.denied:
        return [
          FormBlock(
            child: AttentionLine(
              message: "Calendar access is off for Den. Turn it on in the phone's Settings.",
              action: OutlinedButton(onPressed: calendars.openSettings, child: const Text('Open Settings')),
            ),
          ),
        ];
      case PhoneAccess.restricted:
        return const [
          FormBlock(child: AttentionLine(message: 'Screen Time or a device policy blocks calendar access on this phone.')),
        ];
      case PhoneAccess.granted:
        break;
    }
    if (calendars.calendars.isEmpty) return const [EmptyLine(message: 'This phone has no calendars.')];

    final accounts = <String, List<PhoneCalendar>>{};
    for (final cal in calendars.calendars) {
      accounts.putIfAbsent(cal.account.isEmpty ? 'On this phone' : cal.account, () => []).add(cal);
    }
    return [
      InfoHeader(
        'Who sees each',
        info: 'Events from a calendar you bring in show in Den for the people you choose, read-only. '
            'Den checks this phone for changes whenever you open it.',
        action: _Updated(calendars),
      ),
      for (final account in accounts.entries) ...[
        SectionHeader(account.key),
        for (final cal in account.value)
          _CalendarRow(
            calendar: cal,
            audience: calendars.picks[cal.id],
            count: calendars.countFor(cal.id),
            onChanged: (audience) => calendars.choose(cal.id, audience),
          ),
      ],
    ];
  }
}

/// When the last pass finished, or that one is running.
class _Updated extends StatelessWidget {
  const _Updated(this.calendars);
  final PhoneCalendars calendars;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final at = calendars.syncedAt;
    final words = calendars.syncing ? 'Updating' : (at == null ? null : 'Updated ${context.app.formats.time(at)}');
    if (words == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Sp.s),
      child: Text(words, style: context.type.meta(c.ink2)),
    );
  }
}

class _CalendarRow extends StatelessWidget {
  const _CalendarRow({required this.calendar, required this.audience, required this.count, required this.onChanged});

  final PhoneCalendar calendar;
  final Audience? audience;
  final int count;
  final ValueChanged<Audience?> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.rule))),
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: Text(calendar.name, style: context.type.bodyStrong(c.ink))),
              if (audience != null)
                Text('$count event${count == 1 ? '' : 's'}', style: context.type.meta(c.ink2)),
            ],
          ),
          const SizedBox(height: Sp.s),
          Semantics(
            label: 'Who sees ${calendar.name}',
            child: Segmented<Audience?>(options: phoneCalendarChoices, value: audience, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}
