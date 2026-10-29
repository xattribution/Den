import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/notifications/reminder_scheduler.dart';
import '../../advanced/advanced.dart';
import '../../family/family.dart' show ConfirmPanel, MembershipActions, pasteAnotherFamily;
import '../../onboarding/onboarding.dart';
import '../widgets/calendar_look_choice.dart';
import '../widgets/text_size_choice.dart';
import 'web_reminders.dart';

/// Settings: how this device syncs in one line; for parents the family's settings, calendars
/// and the AI helper; Day, Night or Auto, the text size and how the calendar looks; reminders on
/// this device; Advanced for parents; and About.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.version, this.web});

  /// Overrides the version read from the platform, for tests.
  final String? version;

  /// Shows what a browser shows, for tests; by default only on the web.
  final bool? web;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _reminders;
  String? _version;
  String? _remindersError;
  String? _pasteError;
  bool _leaving = false;
  bool _leavingBusy = false;
  String? _leaveError;

  /// Paste an invite to another family. Straight from the tap, so a browser lets it read the
  /// clipboard.
  Future<void> _joinAnother() async {
    final problem = await pasteAnotherFamily(GoRouter.maybeOf(context), web: widget.web);
    if (mounted) setState(() => _pasteError = problem);
  }

  /// Leaves the family these settings are for, on this device; another family shows.
  Future<void> _leave(Household home, FamilyLog log) async {
    setState(() {
      _leavingBusy = true;
      _leaveError = null;
    });
    final router = GoRouter.maybeOf(context);
    try {
      await MembershipActions.leave(home, log);
      router?.go('/today');
    } on Object {
      if (mounted) {
        setState(() {
          _leavingBusy = false;
          _leaveError = "Couldn't leave the family on this device. Try again.";
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    registerFontLicense();
    _version = widget.version;
    if (_version == null) {
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) setState(() => _version = info.version);
          })
          .catchError((Object _) {});
    }
    SharedPreferences.getInstance()
        .then((prefs) {
          if (mounted) setState(() => _reminders = prefs.getBool(remindersPrefKey) ?? true);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _reminders = true);
        });
  }

  Future<void> _setReminders(bool on) async {
    setState(() {
      _reminders = on;
      _remindersError = null;
    });
    final reminders = DenScope.read(context).reminders;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(remindersPrefKey, on);
    } on Object {
      if (mounted) {
        setState(() {
          _reminders = !on;
          _remindersError = "Couldn't save that on this device. Try again.";
        });
      }
      return;
    }
    await reminders?.setEnabled(on);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.subscription});
    final den = app.den;
    final parent = app.allows(DenAction.manageFamily);
    final web = widget.web ?? Capabilities.web;
    final helper = den.family?.assistant.enabled ?? false;
    final calendars = den.subscriptions.length + (app.phoneCalendars?.picks.length ?? 0);
    final thing = web ? 'this browser' : 'this device';

    return DenPage(
      title: 'Settings',
      children: [
        const SyncLine(),
        GroupCard(
          child: Column(
            children: ruled([
              if (parent)
                NavRow(
                  icon: PhosphorIconsRegular.usersThree,
                  label: 'Family',
                  value: den.family?.name,
                  onTap: () => context.push('/settings/family'),
                ),
              NavRow(
                icon: PhosphorIconsRegular.calendarPlus,
                label: 'Calendars',
                value: calendars == 0 ? null : '$calendars',
                onTap: () => context.push('/settings/calendars'),
              ),
              if (parent)
                NavRow(
                  icon: PhosphorIconsRegular.chatCircle,
                  label: 'AI helper',
                  value: helper ? 'On' : 'Off',
                  onTap: () => context.push('/settings/assistant'),
                ),
            ], indent: 36),
          ),
        ),
        DenSection(
          title: 'Appearance',
          carded: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GroupCard(
                child: ChoiceRows<ThemeChoice>(
                  choices: const [
                    Choice(ThemeChoice.day, 'Day'),
                    Choice(ThemeChoice.night, 'Night', detail: 'True black, easy on the eyes after dark'),
                    Choice(ThemeChoice.auto, 'Auto', detail: 'Follows this device'),
                  ],
                  value: app.theme,
                  onChanged: (t) => app.theme = t,
                ),
              ),
              const SizedBox(height: Sp.l),
              const TextSizeChoice(),
              const SizedBox(height: Sp.l),
              const CalendarLookChoice(),
            ],
          ),
        ),
        DenSection(
          title: 'Reminders on $thing',
          child: web
              ? const WebReminders()
              : SwitchLine(
                  label: 'Reminders',
                  detail: _remindersError ?? 'Events and chores you set a reminder for',
                  value: _reminders ?? true,
                  onChanged: _reminders == null ? null : _setReminders,
                ),
        ),
        ?_joinAnotherRow(context),
        if (parent)
          GroupCard(
            child: NavRow(
              icon: PhosphorIconsRegular.slidersHorizontal,
              label: 'Advanced',
              detail: 'Hub, shared displays, assistants, Home Assistant, data',
              onTap: () => context.push('/settings/advanced'),
            ),
          ),
        DenSection(
          title: 'About',
          child: Column(
            children: ruled([
              _Fact(label: 'Version', value: _version ?? ''),
              NavRow(
                label: 'Licenses',
                onTap: () => showLicensePage(context: context, applicationName: 'Den', applicationVersion: _version),
              ),
            ]),
          ),
        ),
        ?_leaveFamily(context, thing),
        if (DemoSession.active)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: DemoSession.leave, child: const Text('Leave the demo family')),
          ),
      ],
    );
  }

  /// Joining another family on this device (FAMILY-LINKS-PLAN §5.1): paste the invite its
  /// parent sent. In a family already; never in the demo family.
  Widget? _joinAnotherRow(BuildContext context) {
    final home = Household.maybeOf(context);
    if (home == null || home.store == null || DemoSession.active) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          child: NavRow(
            icon: PhosphorIconsRegular.clipboardText,
            label: 'Join another family',
            detail: "Paste the invite from one of its parents",
            chevron: false,
            onTap: _joinAnother,
          ),
        ),
        if (_pasteError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.m, DenLayout.headingInset, 0),
            child: Semantics(liveRegion: true, child: Text(_pasteError!, style: context.text.meta(context.colors.destructive))),
          ),
      ],
    );
  }

  /// "Leave the Smith family on this iPhone": only on a device in another family too, so the
  /// last family is never left this way (FAMILY-LINKS-PLAN, "only leave, not remove").
  Widget? _leaveFamily(BuildContext context, String thing) {
    final home = Household.maybeOf(context);
    if (home == null) return null;
    final log = home.active;
    if (!MembershipActions.canLeave(home, log)) return null;
    final name = log.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_leaving)
          GroupCard(
            child: NavRow(
              icon: PhosphorIconsRegular.signOut,
              label: 'Leave $name on $thing',
              detail: 'Your other families stay',
              chevron: false,
              onTap: () => setState(() => _leaving = true),
            ),
          ),
        DenReveal(
          visible: _leaving,
          child: !_leaving
              ? const SizedBox(width: double.infinity)
              : ConfirmPanel(
                  message: '$name leaves $thing: its calendar, chores and lists, and this device in it. '
                      "The family's parents see it go. To come back, ask one of them for a new invite.",
                  confirmLabel: 'Leave $name',
                  destructive: true,
                  busy: _leavingBusy,
                  error: _leaveError,
                  onConfirm: () => _leave(home, log),
                  onCancel: () => setState(() => _leaving = false),
                ),
        ),
      ],
    );
  }
}

/// A fact about this device, read-only: its label and value.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(
          children: [
            Expanded(child: Text(label, style: t.body(c.ink))),
            Text(value, style: t.meta(c.ink2)),
          ],
        ),
      ),
    );
  }
}
