import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';

/// Advanced → Hub and sync → A browser on a computer: scan the code the browser shows (or paste
/// it), then let the browser in on Today when it asks to join through the hub.
class LinkBrowserScreen extends StatefulWidget {
  const LinkBrowserScreen({super.key, this.scan, this.linkedTo});

  /// Forces the camera on or off, for tests; by default phones and tablets scan.
  final bool? scan;

  /// Shows the step after a code was answered, for tests: the hub's name.
  final String? linkedTo;

  @override
  State<LinkBrowserScreen> createState() => _LinkBrowserScreenState();
}

class _LinkBrowserScreenState extends State<LinkBrowserScreen> {
  final _code = TextEditingController();
  late final bool _scanning = widget.scan ?? Capabilities.scanQr;
  late String? _hub = widget.linkedTo;
  bool _busy = false;
  String? _error;
  Set<String> _before = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_before.isEmpty) {
      _before = {for (final d in context.watch(const {}).den.devices) d.id};
      // A hub reachable from the internet gives browsers link codes only while a parent has
      // this page open.
      unawaited(Pairing.of(context).openLinking());
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _answer(String code) async {
    if (_busy || _hub != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final hub = await Pairing.of(context).answerBrowserLink(code);
      if (mounted) setState(() => _hub = hub);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scanned(BarcodeCapture capture) {
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw != null) _answer(raw);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final den = context.watch(const {}).den;
    final hub = _hub;

    if (hub != null) {
      final linked = den.devices
          .where((d) => !_before.contains(d.id) && d.kind == DeviceKind.browser && d.approved && !d.revoked)
          .firstOrNull;
      return DenPage(
        title: 'Link a browser',
        bottom: linked == null ? null : FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
        children: [
          GroupCard(
            child: linked != null
                ? DoneRow(message: '${linked.name} is linked.')
                : NoticeLine(
                    icon: PhosphorIconsRegular.hourglass,
                    message: 'When the browser asks to join through $hub, let it in on Today.',
                  ),
          ),
        ],
      );
    }

    final width = MediaQuery.sizeOf(context).width;
    final camera = (width.clamp(0.0, 560.0) - 64).clamp(200.0, 420.0);
    return DenPage(
      title: 'Link a browser',
      bottom: _scanning
          ? null
          : FilledButton(
              onPressed: _busy ? null : () => _answer(_code.text),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(_busy ? 'Linking' : 'Link the browser'),
            ),
      children: [
        Text(
          "On the computer, open the hub's address in a browser and choose Link with a parent's phone.",
          style: t.body(c.ink),
        ),
        if (_scanning)
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.tile),
              child: SizedBox.square(
                dimension: camera,
                child: MobileScanner(
                  onDetect: _scanned,
                  errorBuilder: (context, error) => ColoredBox(
                    color: c.card,
                    child: Padding(
                      padding: const EdgeInsets.all(Sp.l),
                      child: Center(
                        child: Text(
                          "Den can't use the camera. Allow camera access in this device's settings, then come back.",
                          style: t.body(c.ink2),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          LabeledField(
            label: 'The code the browser shows',
            error: _error,
            child: TextField(
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'den://link?hub=…'),
              onSubmitted: _answer,
            ),
          ),
        if (_scanning && _error != null) Text(_error!, style: t.meta(c.destructive)),
      ],
    );
  }
}
