import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../design/parts/family_frame.dart';
import '../../design/parts/family_pickers.dart';
import '../../design/parts/family_words.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../net/pairing.dart';
import '../../web/web_app.dart';
import 'home_screen_steps.dart';

/// Joining a family from a parent's invite: the four words from an invite message (filled in
/// when the invite's link opened Den), or a QR code on a phone or tablet with a camera. The
/// waiting screen takes over once the request is sent.
///
/// In Safari on an iPhone or iPad, Den goes on the Home Screen first: the family will live in
/// the Home Screen app, which keeps its own storage.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.scan, this.code, this.browser, this.web});

  /// Forces the camera on or off, for tests; by default phones and tablets scan.
  final bool? scan;

  /// The invite's words, from its link.
  final String? code;

  /// Joins as a browser served by the hub, for tests; by default only on the web.
  final bool? browser;

  /// The browser, for tests; by default read from the page.
  final WebAppInfo? web;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _device = TextEditingController();
  late final _words = TextEditingController(text: widget.code);
  final _hub = TextEditingController();
  DeviceKind? _kind;
  late bool _scanning = widget.code == null && (widget.scan ?? canScanQr);
  bool _busy = false;
  bool _tried = false;
  bool _inSafari = false;
  String? _error;

  bool get _browser => widget.browser ?? kIsWeb;

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

  /// This device's name: what was typed, else from whom the invite is for ("Sam's iPhone").
  String _name(String? forName) => _named ? _device.text.trim() : suggestDeviceName(forName ?? '', _kind ?? DeviceKind.phone);

  Future<void> _join(Future<JoinTicket> Function(PairingService p) send, {bool needsName = false}) async {
    setState(() {
      _tried = true;
      _error = null;
    });
    if (needsName && !_named) return;
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
    if (raw.startsWith('den://link')) {
      setState(
        () => _error = "That's a browser's link code. Scan it from a parent's phone that's already in the family: "
            'Family and devices, Add a device, A browser on a computer.',
      );
      return;
    }
    if (!raw.startsWith('den://join')) {
      setState(() => _error = "That code isn't a Den invite. Scan the code under Add a device on a parent's phone.");
      return;
    }
    _join((p) => p.joinWithQr(raw, deviceName: _name(null), kind: _kind!), needsName: true);
  }

  void _sendWords() {
    final typed = inviteFrom(_words.text);
    if (typed.words.length != 4) {
      setState(() {
        _tried = true;
        _error = 'Type all four words from the invite.';
      });
      return;
    }
    final words = typed.words.join(' ');
    final hub = typed.hub ?? (_hub.text.trim().isEmpty ? null : _hub.text.trim());
    final kind = _kind!;
    _join((p) async {
      if (_browser || hub != null) {
        try {
          return await p.joinWithInvite(words, hubUrl: hub, deviceName: _name, kind: kind);
        } on PairingException catch (e) {
          // Not an invite the hub holds: maybe words a parent's phone is showing right now.
          if (_browser || e.reason != PairingException.unknownCode) rethrow;
        }
      }
      return p.joinWithCode(words, hubUrl: hub, deviceName: _name(null), kind: kind);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final web = widget.web ?? WebApp.info;
    final steps = _browser && web.needsHomeScreen && !_inSafari;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width - Sp.l * 2).clamp(200.0, 420.0);

    return FormFrame(
      title: 'Join your family',
      bottom: _scanning || steps
          ? null
          : SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _sendWords,
                child: Text(_busy ? 'Joining' : 'Join the family'),
              ),
            ),
      children: [
        if (steps) ...[
          HomeScreenSteps(ipad: web.ipad, code: inviteFrom(widget.code ?? '').words.join(' ').nullIfEmpty),
          FormBlock(
            top: Sp.xl,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _inSafari = true),
                child: const Text('Join here in Safari instead'),
              ),
            ),
          ),
        ] else ...[
          InfoHeader(
            _scanning ? 'Scan the code' : 'The code from your invite',
            info: _browser
                ? 'The four words in the invite a parent sent you. Opening its link fills them in.'
                : "On a parent's device, open Family and devices, then Add a device.",
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
            if (!_browser)
              FormBlock(
                child: TextField(
                  controller: _hub,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Hub address (optional)',
                    hintText: 'https://den.example.com',
                    suffixIcon: const InfoTip("The start of the invite's link. Only needed when this device can't find the hub by itself."),
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
          const SectionHeader('This device'),
          FormBlock(
            top: 0,
            child: TextField(
              controller: _device,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: _scanning ? 'Device name' : 'Device name (optional)',
                hintText: suggestDeviceName('Leo', _kind ?? DeviceKind.phone),
                errorText: _scanning && _tried && !_named ? 'Name this device so a parent knows which one is asking.' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (!_browser) ...[
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
          ],
          if (_error != null) FormBlock(child: AttentionLine(message: _error!, bad: true)),
        ],
      ],
    );
  }
}

/// An invite as someone typed or pasted it: the four words, and the hub's address when they
/// pasted the whole link (`https://den.example.com/#/join/maple-river-candle-tiger`).
({List<String> words, String? hub}) inviteFrom(String text) {
  var rest = text.trim();
  String? hub;
  final at = rest.indexOf('#/join/');
  if (at >= 0) {
    final base = Uri.tryParse(rest.substring(0, at));
    if (base != null && base.host.isNotEmpty) hub = Uri(scheme: base.scheme, host: base.host, port: base.port).toString();
    rest = Uri.decodeComponent(rest.substring(at + '#/join/'.length));
  }
  final words = rest.toLowerCase().split(RegExp(r'[\s,.\-_]+')).where((w) => w.isNotEmpty).toList();
  return (words: words, hub: hub);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
