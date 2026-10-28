import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../../../platform/calendars/phone_calendars.dart';
import '../../../platform/notifications/reminder_scheduler.dart';
import 'web_reminders.dart';
import '../../../platform/capabilities.dart';
import '../../../design/forms/forms.dart';
import '../../../design/pictograms.dart';
import '../../family/family.dart';
import '../../onboarding/onboarding.dart';
import '../../advanced/advanced.dart';


/// Settings: this device's look and role, notifications, AI and automations, Home Assistant,
/// backup and export, and About.
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
  final _deviceName = TextEditingController();
  final _deviceFocus = FocusNode();
  bool? _reminders;
  String? _version;
  bool _ready = false;

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
    _deviceFocus.addListener(() {
      if (!_deviceFocus.hasFocus) _saveDeviceName();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _deviceName.text = DenScope.read(context).den.thisDevice?.name ?? '';
  }

  @override
  void dispose() {
    _deviceName.dispose();
    _deviceFocus.dispose();
    super.dispose();
  }

  /// Also runs when the field loses focus, which can happen as the page closes: it reads the
  /// engine without depending on it, and only while this page is still here.
  void _saveDeviceName() {
    if (!mounted) return;
    final den = DenScope.read(context).den;
    final device = den.thisDevice;
    final name = _deviceName.text.trim();
    if (device == null || name.isEmpty || name == device.name) return;
    attempt(context, () => den.updateDevice(device.id, {'name': name}));
  }

  void _setWall(AppState app, bool on) => app.wall = on;

  Future<void> _setReminders(bool on) async {
    setState(() => _reminders = on);
    final reminders = context.app.reminders;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(remindersPrefKey, on);
    } on Object {
      if (mounted) showNote(context, "Couldn't save that on this device. Try again.");
      return;
    }
    await reminders?.setEnabled(on);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final device = den.thisDevice;
    final parent = app.allows(DenAction.manageFamily);
    final connections = parent ? den.connections : const <Connection>[];
    final active = connections.where((x) => x.status == ConnectionStatus.active).length;
    final waiting = connections.where((x) => x.status == ConnectionStatus.pending).length;

    Widget block(Widget child, {double top = Sp.l}) =>
        Padding(padding: EdgeInsets.fromLTRB(Sp.l, top, Sp.l, 0), child: child);

    return Scaffold(
      appBar: pageBar(context, 'Settings', maxWidth: 720),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: Sp.xxxl),
              children: [
                const SectionHeader('Appearance'),
                block(const FieldLabel.quiet('Theme'), top: 0),
                block(
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Segmented<ThemeChoice>(
                      options: const {
                        ThemeChoice.day: 'Day',
                        ThemeChoice.night: 'Night',
                        ThemeChoice.auto: 'Match device',
                      },
                      value: app.theme,
                      onChanged: (t) => app.theme = t,
                    ),
                  ),
                  top: 0,
                ),
                const SizedBox(height: Sp.s),
                SwitchListTile(
                  title: const Row(
                    children: [
                      Flexible(child: Text('Use as wall display')),
                      InfoTip('Larger type and the family week first, for a tablet on the kitchen wall.'),
                    ],
                  ),
                  value: app.wall,
                  onChanged: (v) => _setWall(app, v),
                ),
                if (device != null) ...[
                  const SectionHeader('This device'),
                  block(
                    TextField(
                      controller: _deviceName,
                      focusNode: _deviceFocus,
                      decoration: const InputDecoration(labelText: 'Name'),
                      onSubmitted: (_) => _saveDeviceName(),
                    ),
                    top: 0,
                  ),
                  const SizedBox(height: Sp.s),
                  ListTile(
                    leading: Icon(Pictograms.device(device.kind), color: c.ink2),
                    title: const Row(
                      children: [
                        Text('Mode'),
                        InfoTip(
                          "Personal: one person's device. Shared display: the family's; people sign in with a PIN or "
                          'pattern to change things. Hub: an always-on device that keeps everyone in sync. Turn on '
                          'Keep the family online to make this device the hub.',
                        ),
                      ],
                    ),
                    trailing: Text(FamilyWords.mode(device.mode), style: context.type.body(c.ink2)),
                  ),
                  const DeviceSyncSection(),
                  if (parent && app.phoneCalendars != null) _PhoneCalendarsRow(app.phoneCalendars!),
                ],
                const SectionHeader('Notifications'),
                // A browser can't schedule notifications itself; the hub sends them (Web Push).
                if (widget.web ?? Capabilities.web)
                  const WebReminders()
                else
                  SwitchListTile(
                    title: const Text('Reminders on this device'),
                    value: _reminders ?? true,
                    onChanged: _reminders == null ? null : _setReminders,
                  ),
                if (parent) ...[
                  const SectionHeader('Connections'),
                  ListTile(
                    leading: Icon(PhosphorIconsRegular.plugsConnected, color: c.ink2),
                    title: const Text('AI and automations'),
                    subtitle: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: active == 0 ? 'None connected' : '$active connected'),
                          if (waiting > 0) ...[
                            const TextSpan(text: ' · '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: Icon(PhosphorIconsFill.warning, size: 14, color: c.caution),
                            ),
                            TextSpan(
                              text: ' $waiting waiting',
                              style: TextStyle(color: c.caution),
                            ),
                          ],
                        ],
                      ),
                    ),
                    trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
                    onTap: () => context.push('/settings/connections'),
                  ),
                  ListTile(
                    leading: Icon(PhosphorIconsRegular.houseLine, color: c.ink2),
                    title: const Text('Home Assistant'),
                    trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
                    onTap: () => context.push('/settings/home-assistant'),
                  ),
                  const SectionHeader('Backup and export'),
                  ListTile(
                    leading: Icon(PhosphorIconsRegular.fileArrowDown, color: c.ink2),
                    title: const Text('Everything as JSON'),
                    trailing: OutlinedButton(onPressed: () => exportFamilyJson(context), child: const Text('Export')),
                  ),
                ],
                const SectionHeader('About'),
                ListTile(
                  title: const Text('Version'),
                  trailing: Text(_version ?? '', style: context.type.body(c.ink2)),
                ),
                ListTile(
                  title: const Text('Licenses'),
                  trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
                  onTap: () => showLicensePage(context: context, applicationName: 'Den', applicationVersion: _version),
                ),
                if (DemoSession.active)
                  block(
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(onPressed: DemoSession.leave, child: const Text('Leave the demo family')),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings → This device → Calendars on this phone, with how many are brought in.
class _PhoneCalendarsRow extends StatelessWidget {
  const _PhoneCalendarsRow(this.calendars);
  final PhoneCalendars calendars;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListenableBuilder(
      listenable: calendars,
      builder: (context, _) {
        final n = calendars.picks.length;
        return ListTile(
          leading: Icon(PhosphorIconsRegular.calendarPlus, color: c.ink2),
          title: const Text('Calendars on this phone'),
          subtitle: Text(n == 0 ? 'None brought in' : '$n brought in'),
          trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
          onTap: () => context.push('/settings/phone-calendars'),
        );
      },
    );
  }
}
