import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../words/family_words.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../app/app_state.dart';
import '../widgets/device_parts.dart';
import '../../../design/forms/forms.dart';
import '../../../design/pictograms.dart';

/// One device: its name, whose it is, a shared display's layout and open check-off, and Revoke.
/// Whose it is doesn't change; giving it to someone else means revoking it and adding it again.
class DeviceScreen extends StatefulWidget {
  const DeviceScreen({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  final _name = TextEditingController();
  final _focus = FocusNode();
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _name.text = DenScope.read(context).den.device(widget.deviceId)?.name ?? '';
    _focus.addListener(() {
      if (!_focus.hasFocus) _saveName();
    });
  }

  /// Also runs when the field loses focus, which can happen as the page closes: it reads the
  /// engine without depending on it, and only while this page is still here.
  void _saveName() {
    if (!mounted) return;
    final den = DenScope.read(context).den;
    final name = _name.text.trim();
    if (name.isEmpty || name == den.device(widget.deviceId)?.name) return;
    attempt(context, () => den.updateDevice(widget.deviceId, {'name': name}));
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _display(Device device, Map<String, Object?> change) {
    final display = {...device.rec.map('display'), ...change};
    attempt(context, () => context.den.updateDevice(device.id, {'display': display}));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final den = app.den;
    final c = context.colors;
    final device = den.device(widget.deviceId);
    final manage = app.allows(DenAction.manageFamily);
    if (device == null) {
      return const FormFrame(
        title: 'Device',
        children: [EmptyLine(message: 'This device is no longer in the family.')],
      );
    }
    final owner = device.member == null ? null : den.member(device.member!);
    final isThis = den.thisDevice?.id == device.id;
    final shared = device.mode == DeviceMode.shared;

    return FormFrame(
      title: device.name,
      children: [
        FormBlock(
          child: TextField(
            controller: _name,
            focusNode: _focus,
            enabled: manage,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _saveName(),
          ),
        ),
        const SizedBox(height: Sp.s),
        ListTile(
          leading: Icon(Pictograms.device(device.kind), color: c.ink2),
          title: Text(FamilyWords.deviceKind(device.kind)),
          subtitle: Text(
            isThis
                ? 'This device'
                : device.revoked
                ? 'Revoked'
                : device.approved
                ? 'Approved'
                : 'Waiting for approval',
          ),
        ),
        ListTile(
          leading: owner != null
              ? DenAvatar(owner, size: 28)
              : Icon(
                  Pictograms.device(device.mode == DeviceMode.hub ? DeviceKind.hub : DeviceKind.display),
                  color: c.ink2,
                ),
          // A device stays with whoever it was approved for, since it keeps what it already
          // holds: to give it to someone else, revoke it and add it again.
          title: Text(owner != null ? '${FamilyWords.possessive(owner.name)} device' : FamilyWords.mode(device.mode)),
        ),
        if (shared) ...[
          const SectionHeader('Wall display'),
          const FormBlock(top: 0, child: FieldLabel.quiet('Shows')),
          FormBlock(
            top: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Segmented<DisplayLayout>(
                  options: {for (final l in wallLayouts) l: FamilyWords.layout(l)},
                  value: wallLayoutOf(device),
                  onChanged: manage ? (l) => _display(device, {'layout': l.name}) : (_) {},
                ),
              ),
            ),
          ),
          const SizedBox(height: Sp.s),
          SwitchListTile(
            title: const Row(
              children: [
                Flexible(child: Text('Open check-off')),
                InfoTip(
                  'Anyone at this display can check off chores and grocery items without signing in. '
                  'History shows them as done on this display.',
                ),
              ],
            ),
            value: device.openCheckoff,
            onChanged: manage ? (v) => _display(device, {'openCheckoff': v}) : null,
          ),
        ],
        if (manage && !isThis && !device.revoked) ...[
          const SizedBox(height: Sp.xl),
          FormBlock(
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.bad,
                  side: BorderSide(color: c.bad),
                ),
                onPressed: () async {
                  if (await confirmRevoke(context, device) && context.mounted) context.pop();
                },
                child: Text('Revoke ${device.name}'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Adding a device: anyone waiting to join first, then the QR code and the spoken words.
class AddDeviceScreen extends StatelessWidget {
  const AddDeviceScreen({super.key, this.now});

  /// The clock for the code's expiry; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final qr = (width.clamp(0.0, 600.0) - Sp.l * 4).clamp(200.0, 400.0);
    final c = context.colors;
    Widget other(IconData icon, String label, String route) => ListTile(
          leading: Icon(icon, color: c.ink2),
          title: Text(label),
          trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
          onTap: () => context.push(route),
        );
    return FormFrame(
      title: 'Add a device',
      children: [
        const PendingApprovals(),
        other(PhosphorIconsRegular.hardDrives, 'A hub (NAS, Raspberry Pi, computer)', '/family/devices/add/hub'),
        other(PhosphorIconsRegular.browser, 'A browser on a computer', '/family/devices/add/browser'),
        Divider(color: c.rule),
        InvitePanel(qrSize: qr, now: now),
      ],
    );
  }
}
