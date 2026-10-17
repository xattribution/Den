import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../net/pairing.dart';
import '../../state/app_state.dart';

/// Devices waiting for approval: the synced join requests, with the matching words from the
/// pairing session when this device holds it.
class PendingApprovals extends StatelessWidget {
  const PendingApprovals({super.key, this.padTop = true});
  final bool padTop;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    if (!context.app.allows(DenAction.manageFamily)) return const SizedBox.shrink();
    return StreamBuilder<List<PendingJoin>>(
      stream: Pairing.of(context).pendingJoins,
      builder: (context, snap) {
        final joins = {for (final j in snap.data ?? const <PendingJoin>[]) j.deviceId: j};
        final items = <(String, String, DeviceKind, List<String>)>[
          for (final d in den.pendingDevices) (d.id, d.name, d.kind, joins[d.id]?.words ?? const []),
          for (final j in joins.values)
            if (!den.pendingDevices.any((d) => d.id == j.deviceId)) (j.deviceId, j.deviceName, j.kind, j.words),
        ];
        if (items.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (padTop) const SizedBox(height: Sp.s),
            for (final item in items) PendingApproval(deviceId: item.$1, name: item.$2, kind: item.$3, words: item.$4),
          ],
        );
      },
    );
  }
}

/// One device asking to join: the request in caution words, the three matching words large, and
/// Approve or Decline.
class PendingApproval extends StatelessWidget {
  const PendingApproval({
    super.key,
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.words,
  });

  final String deviceId;
  final String name;
  final DeviceKind kind;
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.rule)),
      ),
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AttentionLine(message: '$name wants to join'),
          if (words.isNotEmpty) ...[
            const SizedBox(height: Sp.s),
            Row(
              children: [
                Text('Words', style: context.type.meta(c.ink2)),
                const InfoTip('The same three words show on the new device. Approve only if they match.'),
              ],
            ),
            const SizedBox(height: Sp.xs),
            Text(words.join('  '), style: context.type.heading(c.ink)),
          ],
          const SizedBox(height: Sp.m),
          Wrap(
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [
              FilledButton(onPressed: () => approveDevice(context, deviceId, name), child: Text('Approve $name')),
              OutlinedButton(
                onPressed: () => attempt(context, () => context.den.revokeDevice(deviceId)),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Whose a device is: a person (personal), or nobody's (a shared display or the hub).
class DeviceOwner {
  const DeviceOwner.person(String this.member) : mode = DeviceMode.personal;
  const DeviceOwner.shared(this.mode) : member = null;
  final String? member;
  final DeviceMode mode;
}

/// Asks "Whose device is Leo's iPad?"; returns the answer, or null if dismissed.
Future<DeviceOwner?> showWhoseDeviceSheet(BuildContext context, String deviceName, {String verb = 'Approve'}) {
  final den = context.den;
  return showModalBottomSheet<DeviceOwner>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) {
      final c = sheet.colors;
      Widget row(Widget leading, String label, DeviceOwner owner) => ListTile(
        leading: leading,
        title: Text(label),
        minTileHeight: Targets.adult + Sp.s,
        onTap: () => Navigator.of(sheet).pop(owner),
      );
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Sp.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
                child: Text('Whose device is $deviceName?', style: sheet.type.title(c.ink)),
              ),
              for (final m in den.members) row(DenAvatar(m, size: 32), m.name, DeviceOwner.person(m.id)),
              Divider(color: c.rule),
              row(
                Icon(FamilyWords.deviceIcon(DeviceKind.display), color: c.ink2),
                'Shared display',
                const DeviceOwner.shared(DeviceMode.shared),
              ),
              row(
                Icon(FamilyWords.deviceIcon(DeviceKind.hub), color: c.ink2),
                'Hub',
                const DeviceOwner.shared(DeviceMode.hub),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> approveDevice(BuildContext context, String deviceId, String name) async {
  final owner = await showWhoseDeviceSheet(context, name);
  if (owner == null || !context.mounted) return;
  await attempt(context, () => context.den.approveDevice(deviceId, member: owner.member, mode: owner.mode));
}

/// Revoking is irreversible for that device: it has to join again. Confirms, naming it.
Future<bool> confirmRevoke(BuildContext context, Device device) async {
  final c = context.colors;
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('Revoke ${device.name}?'),
      content: const Text('It stops syncing right away. To come back it has to join the family again.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.bad, foregroundColor: c.paper),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text('Revoke ${device.name}'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  return attempt(context, () => context.den.revokeDevice(device.id));
}

/// A device in a list: kind icon, name, and what it is in words.
class DeviceRow extends StatelessWidget {
  const DeviceRow(this.device, {super.key, this.indent = false});
  final Device device;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final den = context.den;
    final c = context.colors;
    final isThis = den.thisDevice?.id == device.id;
    final detail = [
      if (isThis) 'This device',
      if (device.mode == DeviceMode.shared) 'Shared display · ${FamilyWords.layout(wallLayoutOf(device))}',
      if (device.mode == DeviceMode.hub) 'Hub',
      if (device.mode == DeviceMode.personal && !isThis) FamilyWords.deviceKind(device.kind),
    ].join(' · ');
    return ListTile(
      contentPadding: EdgeInsets.only(left: indent ? Sp.l + 30 : Sp.l, right: Sp.l),
      leading: Icon(
        FamilyWords.deviceIcon(device.mode == DeviceMode.shared ? DeviceKind.display : device.kind),
        color: c.ink2,
      ),
      title: Text(device.name),
      subtitle: Text(detail),
      trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
      onTap: () => context.push('/family/device/${device.id}'),
    );
  }
}

/// The layout a shared display shows; the week grid unless a parent picked another.
DisplayLayout wallLayoutOf(Device? device) {
  if (device == null || device.rec.map('display')['layout'] == null) return DisplayLayout.week;
  return device.layout;
}

/// Devices grouped by person, then shared displays and hubs. Pending and revoked devices are
/// left out.
List<Widget> deviceGroups(BuildContext context) {
  final den = context.den;
  final c = context.colors;
  final live = den.devices.where((d) => d.approved && !d.revoked).toList();
  final widgets = <Widget>[];
  for (final m in den.members) {
    final mine = live.where((d) => d.mode == DeviceMode.personal && d.member == m.id).toList();
    if (mine.isEmpty) continue;
    widgets.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, 0),
        child: Row(
          children: [
            DenAvatar(m, size: 22),
            const SizedBox(width: Sp.s),
            Text(m.name, style: context.type.bodyStrong(c.ink)),
          ],
        ),
      ),
    );
    widgets.addAll(mine.map((d) => DeviceRow(d, indent: true)));
  }
  final shared = live.where((d) => d.mode != DeviceMode.personal || d.member == null).toList();
  if (shared.isNotEmpty) {
    widgets.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, 0),
        child: Row(
          children: [
            Icon(PhosphorIconsRegular.house, size: 22, color: c.ink2),
            const SizedBox(width: Sp.s),
            Text('Shared displays and hubs', style: context.type.bodyStrong(c.ink)),
          ],
        ),
      ),
    );
    widgets.addAll(shared.map((d) => DeviceRow(d, indent: true)));
  }
  return widgets;
}

/// The invite for a new device: a QR code to scan and a 4-word code to read out, with the
/// time left. Both come from the pairing service; without a hub or relay it says so.
class InvitePanel extends StatefulWidget {
  const InvitePanel({super.key, this.qrSize = 280, this.now});
  final double qrSize;

  /// The clock for the expiry countdown; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  String? _uri;
  SpokenCode? _code;
  String? _error;
  bool _loading = true;
  Timer? _tick;
  PairingService? _service;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = Pairing.of(context);
    if (service != _service) {
      _service = service;
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = await _service!.createInviteQr();
      final code = await _service!.createSpokenCode();
      if (!mounted) return;
      setState(() {
        _uri = uri;
        _code = code;
        _loading = false;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(Sp.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
        child: AttentionLine(message: _error!),
      );
    }
    final left = Duration(milliseconds: _code!.expires - (widget.now ?? DateTime.now)().millisecondsSinceEpoch);
    final expired = left.isNegative;
    // QR codes read most reliably dark on light, so the code keeps day colors at night too.
    const day = DenColors.day;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
          child: Row(
            children: [
              Text('Scan with the new device', style: context.type.meta(c.ink2)),
              const InfoTip('On the new device, open Den and choose "Join your family".'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
          child: Container(
            padding: const EdgeInsets.all(Sp.l),
            decoration: BoxDecoration(
              color: day.paper,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: c.rule),
            ),
            child: QrImageView(
              data: _uri!,
              size: widget.qrSize,
              padding: EdgeInsets.zero,
              backgroundColor: day.paper,
              eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
              dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
              semanticsLabel: 'Invite code',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, 0),
          child: Row(
            children: [
              Text('No camera? Read out these words', style: context.type.meta(c.ink2)),
              const InfoTip('On the new device, choose "Join your family", then type the four words.'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
          child: Text(
            _code!.words.join(' '),
            style: context.type
                .heading(expired ? c.ink3 : c.ink)
                .copyWith(decoration: expired ? TextDecoration.lineThrough : null),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
          child: expired
              ? Row(
                  children: [
                    Expanded(child: Text('These words expired.', style: context.type.meta(c.ink2))),
                    OutlinedButton(onPressed: _load, child: const Text('Get new words')),
                  ],
                )
              : Text('Expires in ${FamilyWords.countdown(left)}', style: context.type.meta(c.ink2)),
        ),
      ],
    );
  }
}
