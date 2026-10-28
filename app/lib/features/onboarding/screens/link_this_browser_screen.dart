import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../family/words/family_words.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../design/forms/forms.dart';

/// Linking this browser through the hub that served it: a link code to scan with a parent's
/// phone, the hub's address, and the time left. When the phone answers, the browser asks to join
/// and the waiting screen takes over.
class LinkThisBrowserScreen extends StatefulWidget {
  const LinkThisBrowserScreen({super.key, this.now});

  /// The clock for the code's expiry; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  State<LinkThisBrowserScreen> createState() => _LinkThisBrowserScreenState();
}

class _LinkThisBrowserScreenState extends State<LinkThisBrowserScreen> {
  final _name = TextEditingController(text: 'Browser');
  BrowserLinkSession? _link;
  String? _error;
  bool _loading = true;
  Timer? _tick;
  PairingService? _pairing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      final link = await _pairing!.linkThisBrowser(deviceName: () {
        final name = _name.text.trim();
        return name.isEmpty ? 'Browser' : name;
      });
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
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final link = _link;
    final width = MediaQuery.sizeOf(context).width;
    final qr = (width.clamp(0.0, 600.0) - Sp.l * 4).clamp(200.0, 360.0);
    const day = DenColors.day;

    return FormFrame(
      title: 'Link this browser',
      children: [
        const InfoHeader(
          "Scan with a parent's phone",
          info: 'On the phone: Family and devices, then Add a device, then A browser on a computer.',
        ),
        if (_loading)
          FormBlock(top: 0, child: Text('Getting a code from the hub', style: context.type.body(c.ink2)))
        else if (_error != null) ...[
          FormBlock(top: 0, child: AttentionLine(message: _error!, bad: true)),
          FormBlock(
            top: Sp.m,
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(onPressed: _open, child: const Text('Try again')),
            ),
          ),
        ]
        else if (link != null) ...[
          FormBlock(
            top: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.all(Sp.l),
                decoration: BoxDecoration(
                  color: day.paper,
                  borderRadius: BorderRadius.circular(Radii.control),
                  border: Border.all(color: c.rule),
                ),
                child: QrImageView(
                  data: link.uri,
                  size: qr,
                  padding: EdgeInsets.zero,
                  backgroundColor: day.paper,
                  eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
                  dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
                  semanticsLabel: 'Link code',
                ),
              ),
            ),
          ),
          // A parent at the same computer, or with Den in a browser, pastes the code instead.
          FormBlock(
            top: Sp.s,
            child: Row(
              children: [
                Expanded(child: SelectableText(link.uri, maxLines: 2, style: context.type.meta(c.ink2))),
                TextButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: link.uri)),
                  icon: const Icon(PhosphorIconsRegular.copy, size: 18),
                  label: const Text('Copy code'),
                ),
              ],
            ),
          ),
          FormBlock(
            child: Row(
              children: [
                Icon(PhosphorIconsRegular.hardDrives, size: 20, color: c.ink2),
                const SizedBox(width: Sp.s),
                Text('Hub ', style: context.type.meta(c.ink2)),
                Expanded(
                  child: SelectableText(
                    link.hub.hasPort ? '${link.hub.host}:${link.hub.port}' : link.hub.host,
                    style: context.type.bodyStrong(c.ink),
                  ),
                ),
              ],
            ),
          ),
          FormBlock(top: Sp.s, child: _Status(link: link, now: widget.now, onRetry: _open)),
        ],
        FormBlock(
          top: Sp.xl,
          child: TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name this browser', hintText: 'Kitchen laptop'),
          ),
        ),
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
    final left = Duration(milliseconds: link.expires - (now ?? DateTime.now)().millisecondsSinceEpoch);
    return switch (link.stage) {
      LinkStage.waiting when !left.isNegative =>
        Text('Expires in ${FamilyWords.countdown(left)}', style: context.type.meta(c.ink2)),
      LinkStage.joining || LinkStage.joined => Text('Asking to join the family', style: context.type.meta(c.ink2)),
      LinkStage.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AttentionLine(message: link.error ?? "Linking didn't finish. Get a new code and try again.", bad: true),
            const SizedBox(height: Sp.s),
            OutlinedButton(onPressed: onRetry, child: const Text('Get a new code')),
          ],
        ),
      _ => Row(
          children: [
            Expanded(child: Text('This code expired.', style: context.type.meta(c.ink2))),
            OutlinedButton(onPressed: onRetry, child: const Text('Get a new code')),
          ],
        ),
    };
  }
}

