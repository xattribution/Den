import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../words/family_words.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../../../platform/web/web_app.dart';
import '../screens/member_editor.dart';
import '../../../platform/capabilities.dart';
import '../../../design/pictograms.dart';
import '../state/trust_actions.dart';

/// Devices waiting for approval: the synced join requests, with the matching words from the
/// pairing session when this device holds it.
class PendingApprovals extends StatelessWidget {
  const PendingApprovals({super.key, this.padTop = true});
  final bool padTop;

  @override
  Widget build(BuildContext context) {
    final den = context.watch(const {}).den;
    if (!context.watch(const {}).allowsTrust(DenAction.manageFamily)) return const SizedBox.shrink();
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
                onPressed: () => attempt(context, () => context.trustActions.revokeDevice(deviceId)),
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
  final den = context.watch(const {}).den;
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
                Icon(Pictograms.device(DeviceKind.display), color: c.ink2),
                'Shared display',
                const DeviceOwner.shared(DeviceMode.shared),
              ),
              row(
                Icon(Pictograms.device(DeviceKind.hub), color: c.ink2),
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

/// Approves a device as someone's, a shared display or the hub. A parent who just made a shared
/// display and has no PIN is asked to set one, since without it they can't act there.
Future<void> approveDevice(BuildContext context, String deviceId, String name) async {
  final owner = await showWhoseDeviceSheet(context, name);
  if (owner == null || !context.mounted) return;
  final trust = context.trustActions;
  // The request leaves the list once approved, so ask from somewhere that stays.
  final keep = Navigator.of(context, rootNavigator: true).context;
  final ok = await attempt(context, () => trust.approveDevice(deviceId, member: owner.member, mode: owner.mode));
  if (!ok || owner.mode != DeviceMode.shared || !keep.mounted) return;
  await askParentForSignIn(keep, name);
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
  return attempt(context, () => context.trustActions.revokeDevice(device.id));
}

/// A device in a list: kind icon, name, and what it is in words.
class DeviceRow extends StatelessWidget {
  const DeviceRow(this.device, {super.key, this.indent = false});
  final Device device;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    final den = context.watch(const {}).den;
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
        Pictograms.device(device.mode == DeviceMode.shared ? DeviceKind.display : device.kind),
        color: c.ink2,
      ),
      title: Text(device.name),
      subtitle: Text(detail),
      trailing: Icon(PhosphorIconsRegular.caretRight, size: 18, color: c.ink3),
      onTap: () => context.push('/family/device/${device.id}'),
    );
  }
}

/// The layouts a parent can pick for a shared display.
const List<DisplayLayout> wallLayouts = [DisplayLayout.today, DisplayLayout.week, DisplayLayout.month, DisplayLayout.lists];

/// The layout a shared display shows; the week grid unless a parent picked another (a photos
/// layout was never built, so a display set to it shows the week too).
DisplayLayout wallLayoutOf(Device? device) {
  if (device == null || device.rec.map('display')['layout'] == null) return DisplayLayout.week;
  return wallLayouts.contains(device.layout) ? device.layout : DisplayLayout.week;
}

/// Devices grouped by person, then shared displays and hubs. Pending and revoked devices are
/// left out.
List<Widget> deviceGroups(BuildContext context) {
  final den = context.watch(const {}).den;
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

/// The invite for a new device. With a hub: an invite to send as a message (the share sheet,
/// or copy), a link and four words that work for three days, bound to [memberId] when given,
/// and the same invite as a QR code for a phone with a camera. Without one: a QR code and four
/// words to read out, live for ten minutes while this device stays open.
class InvitePanel extends StatefulWidget {
  const InvitePanel({super.key, this.qrSize = 280, this.now, this.memberId});
  final double qrSize;

  /// The clock for the expiry countdown; tests pass a fixed time.
  final DateTime Function()? now;

  /// Who the invite is for; the device that uses it asks to be theirs.
  final String? memberId;

  @override
  State<InvitePanel> createState() => _InvitePanelState();
}

class _InvitePanelState extends State<InvitePanel> {
  InviteMessage? _message;
  String? _uri;
  SpokenCode? _code;
  String? _error;
  String? _sent;
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
      _sent = null;
    });
    try {
      final message = await _service!.createInvite(memberId: widget.memberId);
      if (!mounted) return;
      setState(() {
        _message = message;
        _loading = false;
      });
      return;
    } on PairingException catch (e) {
      // Without a hub (or one too old for invites), fall back to a live code below. A browser
      // can't host one, so there it says why.
      if (Capabilities.web) {
        if (mounted) {
          setState(() {
            _error = e.message;
            _loading = false;
          });
        }
        return;
      }
    }
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

  /// Hands the message to the share sheet, or copies it where there's none. Called straight
  /// from the tap: browsers open the share sheet only for a user gesture.
  Future<void> _send(InviteMessage message, Rect? origin) async {
    if (Capabilities.web) {
      final outcome = await WebApp.share(message.text);
      if (!mounted) return;
      setState(() => _sent = switch (outcome) {
            ShareOutcome.shared => 'Sent. Approve them on Today when they ask to join.',
            ShareOutcome.copied => 'Copied. Paste it into a message to them.',
            ShareOutcome.cancelled => null,
            ShareOutcome.failed => "Couldn't open the share sheet. Copy the invite instead.",
          });
      return;
    }
    await SharePlus.instance.share(ShareParams(text: message.text, subject: 'Join us on Den', sharePositionOrigin: origin));
  }

  Future<void> _copy(InviteMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (mounted) setState(() => _sent = 'Copied. Paste it into a message to them.');
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
    final message = _message;
    if (message != null) return _messageInvite(context, message);
    final left = Duration(milliseconds: _code!.expires - (widget.now ?? DateTime.now)().millisecondsSinceEpoch);
    final expired = left.isNegative;
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
        Padding(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0), child: _qr(context, _uri!)),
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

  Widget _messageInvite(BuildContext context, InviteMessage message) {
    final c = context.colors;
    final until = DateFormat('EEEE, MMMM d').format(DateTime.fromMillisecondsSinceEpoch(message.expires));
    final expired = message.expires <= (widget.now ?? DateTime.now)().millisecondsSinceEpoch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
          child: Row(
            children: [
              Text('The code in the invite', style: context.type.meta(c.ink2)),
              const InfoTip('Whoever opens the link, or types these words in Den, asks to join. You approve them on Today.'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
          child: SelectableText(message.code, style: context.type.heading(expired ? c.ink3 : c.ink)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
          child: Text(expired ? 'This invite expired.' : 'Works until $until', style: context.type.meta(c.ink2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.l, Sp.l, Sp.l, 0),
          child: expired
              ? OutlinedButton(onPressed: _load, child: const Text('Make a new invite'))
              : Wrap(
                  spacing: Sp.s,
                  runSpacing: Sp.s,
                  children: [
                    Builder(
                      builder: (button) => FilledButton.icon(
                        onPressed: () {
                          final box = button.findRenderObject() as RenderBox?;
                          _send(message, box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                        },
                        icon: const Icon(PhosphorIconsRegular.paperPlaneTilt, size: 18),
                        label: const Text('Send invite'),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _copy(message),
                      icon: const Icon(PhosphorIconsRegular.copy, size: 18),
                      label: const Text('Copy invite'),
                    ),
                  ],
                ),
        ),
        if (_sent != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0),
            child: Text(_sent!, style: context.type.body(c.ink2)),
          ),
        if (message.qr != null && !expired) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.l, 0),
            child: Text('Or scan it with a phone that has Den', style: context.type.meta(c.ink2)),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, 0), child: _qr(context, message.qr!, size: 200)),
        ],
      ],
    );
  }

  Widget _qr(BuildContext context, String data, {double? size}) {
    final c = context.colors;
    // QR codes read most reliably dark on light, so the code keeps day colors at night too.
    const day = DenColors.day;
    return Container(
      padding: const EdgeInsets.all(Sp.l),
      decoration: BoxDecoration(
        color: day.paper,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: c.rule),
      ),
      child: QrImageView(
        data: data,
        size: size ?? widget.qrSize,
        padding: EdgeInsets.zero,
        backgroundColor: day.paper,
        eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
        dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
        semanticsLabel: 'Invite code',
      ),
    );
  }
}
