import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../family/family.dart';
import '../state/this_device.dart';

/// Linking this browser through the hub that served it: a link code to scan with a parent's
/// phone, the hub's address, and the time left. The browser names itself ("Browser",
/// "Computer"). When the phone answers, it asks to join and the waiting screen takes over.
class LinkThisBrowserScreen extends StatefulWidget {
  const LinkThisBrowserScreen({super.key, this.now});

  /// The clock for the code's expiry; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  State<LinkThisBrowserScreen> createState() => _LinkThisBrowserScreenState();
}

class _LinkThisBrowserScreenState extends State<LinkThisBrowserScreen> {
  BrowserLinkSession? _link;
  String? _error;
  bool _loading = true;
  bool _copied = false;
  Timer? _tick;
  PairingService? _pairing;
  DeviceKind? _kind;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= guessDeviceKind(context);
    final pairing = Pairing.of(context);
    if (pairing != _pairing) {
      _pairing = pairing;
      _open();
    }
  }

  Future<void> _open() async {
    _link?.removeListener(_changed);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final link = await _pairing!.linkThisBrowser(deviceName: () => suggestDeviceName('', _kind ?? DeviceKind.browser));
      link.addListener(_changed);
      if (!mounted) return;
      setState(() {
        _link = link;
        _loading = false;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  void _changed() {
    final link = _link;
    if (link == null || !mounted) return;
    if (link.stage == LinkStage.joined && link.ticket != null) {
      Pairing.ticket = link.ticket;
      _tick?.cancel();
      context.go('/welcome/waiting');
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _tick?.cancel();
    _link?.removeListener(_changed);
    _link?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final link = _link;
    final width = MediaQuery.sizeOf(context).width;
    final qr = (width.clamp(0.0, 560.0) - 96).clamp(180.0, 320.0);
    // QR codes read most reliably dark on light, so the code keeps day colors at night too.
    const day = DenColors.day;

    return DenPage(
      title: 'Link this browser',
      children: [
        Text(
          "On a parent's phone: Settings, Advanced, Hub and sync, Open Den on your computer, then Show a code on the computer instead. Scan this code with it.",
          style: t.body(c.ink),
        ),
        if (_loading)
          Text('Getting a code from the hub', style: t.body(c.ink2))
        else if (_error != null)
          GroupCard(child: ErrorState(message: _error!, actionLabel: 'Try again', onAction: _open))
        else if (link != null) ...[
          GroupCard(
            padding: const EdgeInsets.all(Sp.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(Sp.m),
                    decoration: BoxDecoration(color: day.card, borderRadius: BorderRadius.circular(Radii.tile)),
                    child: QrImageView(
                      data: link.uri,
                      size: qr,
                      padding: EdgeInsets.zero,
                      backgroundColor: day.card,
                      eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
                      dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
                      semanticsLabel: 'Link code',
                    ),
                  ),
                ),
                const SizedBox(height: Sp.l),
                Text('Or paste it on the phone', style: t.meta(c.ink2)),
                Row(
                  children: [
                    Expanded(child: SelectableText(link.uri, maxLines: 2, style: t.meta(c.ink))),
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: link.uri));
                        if (mounted) setState(() => _copied = true);
                      },
                      child: Text(_copied ? 'Copied' : 'Copy'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          NoticeLine(
            icon: PhosphorIconsRegular.hardDrives,
            message: 'Hub ${link.hub.hasPort ? '${link.hub.host}:${link.hub.port}' : link.hub.host}',
          ),
          _Status(link: link, now: widget.now, onRetry: _open),
        ],
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.link, required this.onRetry, this.now});
  final BrowserLinkSession link;
  final VoidCallback onRetry;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final left = Duration(milliseconds: link.expires - (now ?? DateTime.now)().millisecondsSinceEpoch);
    return switch (link.stage) {
      LinkStage.waiting when !left.isNegative => Text('Good for ${FamilyWords.countdown(left)} more', style: t.meta(c.ink2)),
      LinkStage.joining || LinkStage.joined => Text('Asking to join the family', style: t.meta(c.ink2)),
      LinkStage.failed => ErrorState(
          message: link.error ?? "Linking didn't finish. Get a new code and try again.",
          actionLabel: 'Get a new code',
          onAction: onRetry,
        ),
      _ => Wrap(
          spacing: Sp.m,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [Text('This code ran out.', style: t.meta(c.ink2)), OutlinedButton(onPressed: onRetry, child: const Text('Get a new code'))],
        ),
    };
  }
}
