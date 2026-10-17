import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../design/parts/family_frame.dart';
import '../../design/parts/family_pickers.dart';
import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../net/pairing.dart';

/// Joining a family from a parent's invite: name this device, then scan the QR code (phones and
/// tablets) or type the four spoken words. The waiting screen takes over once the request is sent.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.scan});

  /// Forces the camera on or off, for tests; by default phones and tablets scan.
  final bool? scan;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _device = TextEditingController();
  final _words = TextEditingController();
  final _hub = TextEditingController();
  DeviceKind? _kind;
  late bool _scanning = widget.scan ?? canScanQr;
  bool _busy = false;
  bool _tried = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= guessDeviceKind(context);
  }

  @override
  void dispose() {
    _device.dispose();
    _words.dispose();
    _hub.dispose();
    super.dispose();
  }

  bool get _named => _device.text.trim().isNotEmpty;

  Future<void> _join(Future<JoinTicket> Function(PairingService p) send) async {
    setState(() {
      _tried = true;
      _error = null;
    });
    if (!_named) return;
    setState(() => _busy = true);
    final pairing = Pairing.of(context);
    try {
      final ticket = await send(pairing);
      Pairing.ticket = ticket;
      if (mounted) context.go('/welcome/waiting');
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on InvalidInput catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scanned(BarcodeCapture capture) {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    if (!raw.startsWith('den://join')) {
      setState(() => _error = "That code isn't a Den invite. Scan the code under Add a device on a parent's phone.");
      return;
    }
    _join((p) => p.joinWithQr(raw, deviceName: _device.text.trim(), kind: _kind!));
  }

  void _sendWords() {
    final words = _words.text.trim().toLowerCase().split(RegExp(r'[\s,.\-]+')).where((w) => w.isNotEmpty).toList();
    if (words.length != 4) {
      setState(() {
        _tried = true;
        _error = 'Type all four words from the other screen.';
      });
      return;
    }
    final hub = _hub.text.trim();
    _join(
      (p) => p.joinWithCode(
        words.join(' '),
        hubUrl: hub.isEmpty ? null : hub,
        deviceName: _device.text.trim(),
        kind: _kind!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width - Sp.l * 2).clamp(200.0, 420.0);

    return FormFrame(
      title: 'Join your family',
      bottom: _scanning
          ? null
          : SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _sendWords,
                child: Text(_busy ? 'Joining' : 'Join the family'),
              ),
            ),
      children: [
        const SectionHeader('This device'),
        FormBlock(
          top: 0,
          child: TextField(
            controller: _device,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Device name',
              hintText: "Leo's iPad",
              errorText: _tried && !_named ? 'Name this device so a parent knows which one is asking.' : null,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const FormBlock(child: FieldLabel('Kind')),
        FormBlock(
          top: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Segmented<DeviceKind>(
                options: {for (final k in personalKinds) k: FamilyWords.deviceKind(k)},
                value: _kind ?? DeviceKind.phone,
                onChanged: (k) => setState(() => _kind = k),
              ),
            ),
          ),
        ),
        InfoHeader(
          _scanning ? 'Scan the code' : 'Enter the code',
          info: "On a parent's device, open Family and devices, then Add a device.",
        ),
        if (_scanning) ...[
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
                        "Den can't use the camera. Allow camera access in this device's settings, or enter the code instead.",
                        style: context.type.body(c.ink2),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          FormBlock(
            top: Sp.s,
            child: Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _scanning = false;
                  _error = null;
                }),
                child: const Text('Enter the code instead'),
              ),
            ),
          ),
        ] else ...[
          FormBlock(
            top: 0,
            child: TextField(
              controller: _words,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'The four words', hintText: 'maple river candle tiger'),
              onSubmitted: (_) => _sendWords(),
            ),
          ),
          FormBlock(
            child: TextField(
              controller: _hub,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Hub address (optional)',
                hintText: 'http://192.168.1.20:47733',
                suffixIcon: const InfoTip("Only needed when this device can't find the family's hub by itself."),
                suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
            ),
          ),
          if (widget.scan ?? canScanQr)
            FormBlock(
              top: Sp.s,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    _scanning = true;
                    _error = null;
                  }),
                  child: const Text('Scan the code instead'),
                ),
              ),
            ),
        ],
        if (_error != null) FormBlock(child: AttentionLine(message: _error!, bad: true)),
      ],
    );
  }
}
