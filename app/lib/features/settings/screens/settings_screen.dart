import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/notifications/reminder_scheduler.dart';
import '../../advanced/advanced.dart';
import '../../onboarding/onboarding.dart';
import '../widgets/text_size_choice.dart';
import 'web_reminders.dart';

/// Settings: how this device syncs in one line; for parents the family's settings, calendars
/// and the AI helper; Day, Night or Auto and the text size; reminders on this device; Advanced
/// for parents; and About.
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
        if (DemoSession.active)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(onPressed: DemoSession.leave, child: const Text('Leave the demo family')),
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
