import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';

/// Advanced → Hub and sync → Open Den on your computer: a link for a browser on the parent's own
/// computer, made on their phone. It is their own invite (it carries an invite key, good for a
/// day, for one browser), so the browser is let in as them as soon as it opens the link, with
/// nothing to scan or approve. The link is short enough to type; Send hands it to the share
/// sheet (AirDrop to a Mac, a message to themselves), and the QR code suits a tablet's camera.
/// Showing a code on the computer to scan from here stays as the other way.
class ComputerLinkScreen extends StatefulWidget {
  const ComputerLinkScreen({super.key, this.now});

  /// The clock for when the link stops working; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  State<ComputerLinkScreen> createState() => _ComputerLinkScreenState();
}

class _ComputerLinkScreenState extends State<ComputerLinkScreen> {
  InviteMessage? _link;
  String? _error;
  bool _copied = false;
  PairingService? _pairing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pairing = Pairing.of(context);
    if (pairing == _pairing) return;
    _pairing = pairing;
    _make();
  }

  Future<void> _make() async {
    final me = DenScope.read(context).me;
    setState(() {
      _error = null;
      _link = null;
      _copied = false;
    });
    try {
      final link = await _pairing!.createInvite(memberId: me?.id, letIn: true);
      if (mounted) setState(() => _link = link);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Called straight from the tap: browsers copy and share only for a user gesture.
  Future<void> _copy(String text) async {
    if (Capabilities.web) {
      await WebApp.copy(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _send(String text, Rect? origin) async {
    if (Capabilities.web) {
      await WebApp.share(text);
      return;
    }
    await SharePlus.instance.share(ShareParams(text: text, subject: 'Den', sharePositionOrigin: origin));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final link = _link;
    final width = MediaQuery.sizeOf(context).width;
    final qr = (width.clamp(0.0, 560.0) - 120).clamp(160.0, 260.0);
    // QR codes read most reliably dark on light, so the code keeps day colors at night too.
    const day = DenColors.day;
    final text = link?.link.toString();
    final shown = text?.replaceFirst(RegExp('^https://'), '');
    final now = (widget.now ?? DateTime.now)();
    final until = link == null ? null : DateTime.fromMillisecondsSinceEpoch(link.expires);
    final when = until == null
        ? null
        : DateFormat(until.day == now.day ? "'today at' h:mm a" : "'tomorrow at' h:mm a").format(until);

    return DenPage(
      title: 'Open Den on your computer',
      children: [
        if (_error != null)
          GroupCard(child: ErrorState(message: _error!, actionLabel: 'Try again', onAction: _make))
        else if (link == null)
          NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Making your link')
        else ...[
          DenSection(
            title: 'On your computer, open',
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(shown!, style: t.sheetTitle(c.ink).copyWith(fontSize: 22)),
                  const SizedBox(height: Sp.m),
                  Row(
                    children: [
                      Builder(
                        builder: (button) => FilledButton.icon(
                          onPressed: () {
                            final box = button.findRenderObject() as RenderBox?;
                            _send(text!, box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                          },
                          icon: const Icon(PhosphorIconsBold.export, size: 20),
                          label: const Text('Send', maxLines: 1, softWrap: false),
                        ),
                      ),
                      const SizedBox(width: Sp.s),
                      OutlinedButton(
                        onPressed: () => _copy(text!),
                        child: Text(_copied ? 'Copied' : 'Copy', maxLines: 1, softWrap: false),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Text(
            "It lets one browser in as you, until $when. It's in as soon as it opens the link, and Today says so.",
            style: t.body(c.ink2),
          ),
          GroupCard(
            padding: const EdgeInsets.all(Sp.l),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(Sp.m),
                  decoration: BoxDecoration(color: day.card, borderRadius: BorderRadius.circular(Radii.tile)),
                  child: QrImageView(
                    data: text!,
                    size: qr,
                    padding: EdgeInsets.zero,
                    backgroundColor: day.card,
                    eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
                    dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
                    semanticsLabel: 'Your link, as a code',
                  ),
                ),
                const SizedBox(height: Sp.m),
                Text('Or scan it with a tablet or a computer that has a camera', style: t.meta(c.ink2), textAlign: TextAlign.center),
              ],
            ),
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => context.push('/settings/advanced/hub/browser'),
            child: const Text('Show a code on the computer instead'),
          ),
        ),
      ],
    );
  }
}
