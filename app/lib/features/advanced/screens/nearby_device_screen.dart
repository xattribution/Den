import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/sync/pairing.dart';
import '../../family/family.dart';

/// Advanced → Hub and sync → A device in the same room: a code to scan with Den on the new
/// device, or four words to read out to it, live for ten minutes while this screen stays open.
/// Works without a hub. The new device then asks to join, and a parent lets it in on Today.
class NearbyDeviceScreen extends StatefulWidget {
  const NearbyDeviceScreen({super.key, this.now});

  /// The clock for the expiry countdown; tests pass a fixed time.
  final DateTime Function()? now;

  @override
  State<NearbyDeviceScreen> createState() => _NearbyDeviceScreenState();
}

class _NearbyDeviceScreenState extends State<NearbyDeviceScreen> {
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

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final children = <Widget>[];
    if (_loading) {
      children.add(Text('Making a code', style: t.body(c.ink2)));
    } else if (_error != null) {
      children.add(GroupCard(child: ErrorState(message: _error!, actionLabel: 'Try again', onAction: _load)));
    } else {
      final left = Duration(milliseconds: _code!.expires - (widget.now ?? DateTime.now)().millisecondsSinceEpoch);
      final expired = left.isNegative;
      final size = (MediaQuery.sizeOf(context).width.clamp(0.0, 560.0) - 96).clamp(180.0, 320.0);
      // QR codes read most reliably dark on light, so the code keeps day colors at night too.
      const day = DenColors.day;
      children.addAll([
        DenSection(
          title: 'Scan with the new device',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('On it, open Den and choose Join your family.', style: t.body(c.ink)),
                const SizedBox(height: Sp.l),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(Sp.l),
                    decoration: BoxDecoration(color: day.card, borderRadius: BorderRadius.circular(Radii.tile)),
                    child: QrImageView(
                      data: _uri!,
                      size: size,
                      padding: EdgeInsets.zero,
                      backgroundColor: day.card,
                      eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
                      dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
                      semanticsLabel: 'A code for the new device to scan',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        DenSection(
          title: 'Or read out these words',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  _code!.words.join(' '),
                  style: t.sheetTitle(expired ? c.ink3 : c.ink).copyWith(decoration: expired ? TextDecoration.lineThrough : null),
                ),
                const SizedBox(height: Sp.xs),
                if (expired)
                  Wrap(
                    spacing: Sp.m,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('These words ran out.', style: t.meta(c.ink2)),
                      OutlinedButton(onPressed: _load, child: const Text('Get new words')),
                    ],
                  )
                else
                  Text('Good for ${FamilyWords.countdown(left)} more', style: t.meta(c.ink2)),
              ],
            ),
          ),
        ),
        Text("When it asks to join, you'll get one tap on Today to let it in.", style: t.meta(c.ink2)),
      ]);
    }
    return DenPage(title: 'A device in the same room', children: children);
  }
}
