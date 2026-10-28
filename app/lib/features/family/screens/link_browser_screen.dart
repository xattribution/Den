import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../../app/app_state.dart';
import '../widgets/device_parts.dart';
import '../../../design/forms/forms.dart';
import '../../../platform/capabilities.dart';

/// Linking a browser from a parent's phone: scan the code the browser shows (or paste it on a
/// computer), then approve the browser when its request arrives through the hub.
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
      _before = {for (final d in context.den.devices) d.id};
      // A hub reachable from the internet gives browsers link codes only while a parent has
      // "Add a device" open.
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
    final den = context.den;
    final hub = _hub;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width.clamp(0.0, 600.0) - Sp.l * 2).clamp(200.0, 420.0);

    if (hub != null) {
      final linked = den.devices
          .where((d) => !_before.contains(d.id) && d.kind == DeviceKind.browser && d.approved && !d.revoked)
          .firstOrNull;
      return FormFrame(
        title: 'Link a browser',
        bottom: linked == null
            ? null
            : SizedBox(width: double.infinity, child: FilledButton(onPressed: () => context.pop(), child: const Text('Done'))),
        children: [
          const PendingApprovals(),
          FormBlock(
            child: linked != null
                ? Row(
                    children: [
                      Icon(PhosphorIconsBold.check, size: 20, color: c.ink),
                      const SizedBox(width: Sp.m),
                      Expanded(child: Text('${linked.name} is linked.', style: context.type.body(c.ink))),
                    ],
                  )
                : Row(
                    children: [
                      Icon(PhosphorIconsRegular.hourglass, size: 20, color: c.ink2),
                      const SizedBox(width: Sp.m),
                      Expanded(
                        child: Text('Approve the browser here when it asks to join through $hub.', style: context.type.body(c.ink2)),
                      ),
                    ],
                  ),
          ),
        ],
      );
    }

    return FormFrame(
      title: 'Link a browser',
      bottom: _scanning
          ? null
          : SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : () => _answer(_code.text),
                child: Text(_busy ? 'Linking' : 'Link the browser'),
              ),
            ),
      children: [
        InfoHeader(
          _scanning ? 'Scan the code on the browser' : 'Paste the code from the browser',
          info: "On the computer, open the hub's address in a browser and choose Link this browser.",
        ),
        if (_scanning)
          FormBlock(
            top: 0,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.control),
                child: SizedBox.square(
                  dimension: camera,
                  child: MobileScanner(
                    onDetect: _scanned,
                    errorBuilder: (context, error) => Container(
                      color: c.well,
                      padding: const EdgeInsets.all(Sp.l),
                      alignment: Alignment.center,
                      child: Text(
                        "Den can't use the camera. Allow camera access in this device's settings, then come back.",
                        style: context.type.body(c.ink2),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          FormBlock(
            top: 0,
            child: TextField(
              controller: _code,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Link code', hintText: 'den://link?hub=…'),
              onSubmitted: _answer,
            ),
          ),
        if (_error != null) FormBlock(child: AttentionLine(message: _error!, bad: true)),
      ],
    );
  }
}
