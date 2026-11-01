import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_state.dart';
import '../../../app/build_info.dart';
import '../../../app/family_label.dart';
import '../../../app/household.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/notifications/reminder_scheduler.dart';
import '../../advanced/advanced.dart';
import '../../family/family.dart' show ConfirmPanel, MembershipActions, pasteAnotherFamily, sharedDisplays;
import '../../onboarding/onboarding.dart';
import '../widgets/text_size_choice.dart';
import 'about_screen.dart';
import 'appearance_screen.dart';
import 'web_reminders.dart';

/// Settings, short enough to see at once on a phone: how this device syncs in one line; for
/// parents the family's settings, calendars, the kitchen screen and the AI helper, and on a
/// parent's own phone the Google or Apple account that signs in as them; Appearance (Day, Night,
/// Auto or Soft, and how the calendar looks) and Text size, each saying what it's set to;
/// reminders on this device; Advanced for parents; and About, which says so here when the hub
/// serves a newer Den.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.version, this.web, this.hub});

  /// Overrides the version read from the platform, for tests.
  final String? version;

  /// Shows what a browser shows, for tests; by default only on the web.
  final bool? web;

  /// What the hub serves, for tests; by default its `build.json` and `/health`, in a browser.
  final Future<HubBuild?> Function()? hub;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _reminders;
  String? _version;
  HubBuild? _hub;
  String? _remindersError;
  String? _pasteError;
  bool _leaving = false;
  bool _leavingBusy = false;
  String? _leaveError;

  /// Paste an invite to another family. Straight from the tap, so a browser lets it read the
  /// clipboard.
  Future<void> _joinAnother() async {
    final problem = await pasteAnotherFamily(GoRouter.maybeOf(context));
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
    _version = widget.version;
    if (_version == null) {
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) setState(() => _version = info.version);
          })
          .catchError((Object _) {});
    }
    if (widget.hub != null || (widget.web ?? Capabilities.web)) {
      (widget.hub ?? AboutScreen.hubBuild)()
          .then((hub) {
            if (mounted) setState(() => _hub = hub);
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
    final app = context.watch(const {RecordType.subscription, RecordType.member, Changes.prefs});
    final den = app.den;
    final parent = app.allows(DenAction.manageFamily);
    final web = widget.web ?? Capabilities.web;
    final helper = den.family?.assistant.enabled ?? false;
    final calendars = den.subscriptions.length + (app.phoneCalendars?.picks.length ?? 0);
    final thing = web ? 'this browser' : 'this device';
    // Which Google or Apple account signs in as them: a parent's own, set on their own phone, in a
    // family with a hub to sign in to.
    final signIn = den.thisDevice?.mode == DeviceMode.personal &&
        app.allowsTrust(DenAction.manageFamily) &&
        !DemoSession.active &&
        app.network?.hubDevice != null;
    final account = app.me?.account;

    final displays = sharedDisplays(den).length;
    final newer = _hub?.differsFrom(DenBuild.commit) ?? false;

    return DenPage(
      title: 'Settings',
      children: [
        // Which family's settings, where the switcher doesn't say.
        const FamilyLabel(),
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
                  icon: PhosphorIconsRegular.monitor,
                  label: 'Kitchen screen',
                  value: displays == 0 ? 'Set up' : '$displays',
                  onTap: () => context.push('/settings/advanced/displays'),
                ),
              if (parent)
                NavRow(
                  icon: PhosphorIconsRegular.chatCircle,
                  label: 'AI helper',
                  value: helper ? 'On' : 'Off',
                  onTap: () => context.push('/settings/assistant'),
                ),
              if (signIn)
                NavRow(
                  icon: PhosphorIconsRegular.signIn,
                  label: 'Google or Apple sign-in',
                  value: account == null ? 'Off' : (account.provider == 'apple' ? 'Apple' : 'Google'),
                  onTap: () => context.push('/settings/sign-in'),
                ),
            ], indent: 36),
          ),
        ),
        GroupCard(
          child: Column(
            children: ruled([
              NavRow(
                icon: PhosphorIconsRegular.palette,
                label: 'Appearance',
                value: AppearanceScreen.themeLabel(app.theme),
                onTap: () => context.push('/settings/appearance'),
              ),
              const TextSizeRow(icon: PhosphorIconsRegular.textAa),
            ], indent: 36),
          ),
        ),
        // Said once: the browser's part says which device in its own words ("Turn on reminders
        // on this iPhone"); elsewhere the switch says it.
        if (web)
          const DenSection(title: 'Reminders', child: WebReminders())
        else
          GroupCard(
            child: SwitchLine(
              label: 'Reminders on $thing',
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
              detail: 'Hub, assistants, Home Assistant, data',
              onTap: () => context.push('/settings/advanced'),
            ),
          ),
        GroupCard(
          child: NavRow(
            icon: PhosphorIconsRegular.info,
            label: 'About',
            value: _version,
            // The one thing here she may need to act on, said where she'll see it.
            detail: newer ? AboutScreen.newerWaiting : null,
            onTap: () => context.push('/settings/about'),
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
    // The family this page is for (`/l/<id>/settings` is another family's), never simply the
    // one the device shows.
    final log = home.of(DenScope.read(context).den);
    if (log == null || !MembershipActions.canLeave(home, log)) return null;
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
                  message: "$name's calendar, chores and lists leave $thing, and the family's parents see $thing go. "
                      'Your other families stay. To come back, ask one of its parents for a new invite.',
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
