import 'dart:async';

import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show ScreenCode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../../../platform/web/web_app.dart';
import '../../onboarding/state/this_device.dart';
import '../words/kitchen_screen_words.dart';

/// "Set up this screen as a kitchen screen" (`/welcome/screen`), on a tablet or old laptop with
/// no family yet, opened at the family's Den address: its code, big enough to read across the
/// kitchen, and the same as a QR code, while it waits for a parent to type it on their own
/// phone (Settings, Kitchen screen, Add a screen). Once she has, it joins as a shared screen
/// nobody owns and the router takes it to the wall. Outside a browser it first asks for the
/// family's Den address.
class ScreenCodeScreen extends StatefulWidget {
  const ScreenCodeScreen({super.key, this.session, this.now, this.browser});

  /// A code shown already, for tests; by default this screen gets one.
  final ScreenCodeSession? session;

  /// The clock for the code's time left; tests pass a fixed time.
  final DateTime Function()? now;

  /// Opened in a browser at the family's address, for tests; by default only on the web.
  final bool? browser;

  @override
  State<ScreenCodeScreen> createState() => _ScreenCodeScreenState();
}

class _ScreenCodeScreenState extends State<ScreenCodeScreen> {
  final _address = TextEditingController();
  ScreenCodeSession? _session;
  PairingService? _pairing;
  DeviceKind? _kind;
  Timer? _tick;
  bool _loading = false;
  bool _askAddress = false;
  bool _left = false;
  String? _error;

  bool get _browser => widget.browser ?? Capabilities.web;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _kind ??= guessDeviceKind(context);
    final pairing = Pairing.of(context);
    if (pairing == _pairing) return;
    _pairing = pairing;
    final given = widget.session;
    if (given != null) {
      _follow(given);
    } else if (_browser) {
      _open();
    } else {
      _askAddress = true;
    }
  }

  void _follow(ScreenCodeSession session) {
    _session?.removeListener(_changed);
    _session = session..addListener(_changed);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _open() async {
    final old = _session;
    if (old != null) {
      old.removeListener(_changed);
      unawaited(old.cancel());
      if (!identical(old, widget.session)) old.dispose();
    }
    setState(() {
      _session = null;
      _loading = true;
      _error = null;
    });
    try {
      final kind = _kind ?? DeviceKind.tablet;
      final session = await _pairing!.showScreenCode(
        hubUrl: _askAddress ? _address.text : null,
        deviceName: KitchenScreenWords.suggestedName(kind, ipad: Capabilities.web && WebApp.info.ipad),
        kind: kind,
      );
      if (!mounted) {
        session.dispose();
        return;
      }
      setState(() {
        _loading = false;
        _askAddress = false;
      });
      _follow(session);
    } on PairingException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
  }

  /// Gives up on the family it asked to join, for a new code.
  Future<void> _startOver() async {
    setState(() => _left = true);
    await attempt(context, DenScope.read(context).den.leaveFamily);
    if (Capabilities.web) {
      WebApp.reload();
    } else if (mounted) {
      context.go('/welcome');
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _session?.removeListener(_changed);
    if (widget.session == null) {
      unawaited(_session?.cancel());
      _session?.dispose();
    }
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    if (app.den.isApproved) {
      // Let in: the router shows the family's wall.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/today');
      });
    }
    final width = MediaQuery.sizeOf(context).width;
    final wide = !DenLayout.forWidth(width).isCompact;
    final session = _session;
    if (_askAddress && session == null) return _addressPage(context);
    return DenPage(
      title: KitchenScreenWords.screenTitle,
      maxWidth: 1100,
      children: [
        if (_loading)
          const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Getting a code')
        else if (_error != null)
          ErrorState(message: _error!, actionLabel: 'Try again', onAction: _open)
        else if (session != null)
          wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _codeColumn(context, session, large: true)),
                    if (_showsCode(session)) ...[const SizedBox(width: Sp.xxl), _qr(context, session, size: 240)],
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _codeColumn(context, session, large: false),
                    if (_showsCode(session)) ...[
                      const SizedBox(height: DenLayout.sectionGap),
                      Align(alignment: Alignment.centerLeft, child: _qr(context, session, size: 200)),
                    ],
                  ],
                ),
      ],
    );
  }

  static bool _showsCode(ScreenCodeSession s) => s.stage == ScreenStage.waiting;

  Widget _codeColumn(BuildContext context, ScreenCodeSession session, {required bool large}) {
    final c = context.colors;
    final t = context.text;
    final instructions = t.section(c.ink).regular;
    final left = Duration(milliseconds: session.expires - (widget.now ?? DateTime.now)().millisecondsSinceEpoch);
    final code = ScreenCode.format(session.code);
    // Asked to join already (a code a parent took): a new code means starting over.
    final asked = DenScope.read(context).den.hasFamily;
    final again = asked ? _startOver : _open;
    final againLabel = asked ? 'Start over' : 'Get a new code';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_showsCode(session)) ...[
          Text(tidy(KitchenScreenWords.howToAdd), style: instructions),
          const SizedBox(height: Sp.xl),
          Semantics(
            label: KitchenScreenWords.spelled(session.code),
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                code,
                maxLines: 1,
                softWrap: false,
                style: t.display(c.ink).copyWith(fontSize: large ? 120 : 64, height: 1.0, letterSpacing: large ? 6 : 3),
              ),
            ),
          ),
          const SizedBox(height: Sp.xl),
        ],
        switch (session.stage) {
          ScreenStage.starting => const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: 'Getting a code'),
          ScreenStage.waiting when !left.isNegative => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const NoticeLine(icon: PhosphorIconsRegular.hourglass, message: KitchenScreenWords.waiting),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                  child: Text(KitchenScreenWords.timeLeft(left), style: t.meta(c.ink2)),
                ),
              ],
            ),
          ScreenStage.joining => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const NoticeLine(icon: PhosphorIconsRegular.checkCircle, message: KitchenScreenWords.joining),
                if (!_left)
                  TextButton(onPressed: _startOver, child: const Text('Start over with a new code')),
              ],
            ),
          ScreenStage.approved => const NoticeLine(icon: PhosphorIconsRegular.checkCircle, message: KitchenScreenWords.approved),
          ScreenStage.failed => ErrorState(
              message: session.error ?? "Adding this screen didn't finish. Get a new code and try again.",
              actionLabel: againLabel,
              onAction: again,
            ),
          _ => Wrap(
              spacing: Sp.m,
              runSpacing: Sp.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(KitchenScreenWords.ranOut, style: t.body(c.ink)),
                OutlinedButton(onPressed: again, child: Text(againLabel)),
              ],
            ),
        },
      ],
    );
  }

  Widget _qr(BuildContext context, ScreenCodeSession session, {required double size}) {
    final c = context.colors;
    final t = context.text;
    // QR codes read most reliably dark on light, so the code keeps day colors at night too.
    const day = DenColors.day;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(Sp.l),
          decoration: BoxDecoration(color: day.card, borderRadius: BorderRadius.circular(Radii.section)),
          child: QrImageView(
            data: session.link,
            size: size,
            padding: EdgeInsets.zero,
            backgroundColor: day.card,
            eyeStyle: QrEyeStyle(eyeShape: QrEyeShape.square, color: day.ink),
            dataModuleStyle: QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: day.ink),
            semanticsLabel: 'The same code, to scan',
          ),
        ),
        const SizedBox(height: Sp.s),
        SizedBox(
          width: size + 2 * Sp.l,
          child: Text(KitchenScreenWords.scanInstead, style: t.meta(c.ink2)),
        ),
      ],
    );
  }

  /// Outside a browser: the family's Den address first.
  Widget _addressPage(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPage(
      title: KitchenScreenWords.screenTitle,
      bottom: FilledButton(
        onPressed: _loading ? null : _open,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_loading ? 'Getting a code' : 'Show the code'),
      ),
      children: [
        Text("This screen shows a code. A parent types it on their phone, and it's set.", style: t.body(c.ink)),
        LabeledField(
          label: "Your family's Den address",
          error: _error,
          child: TextField(
            controller: _address,
            autocorrect: false,
            keyboardType: TextInputType.url,
            style: t.body(c.ink),
            decoration: const InputDecoration(hintText: 'https://den.example.com'),
            onSubmitted: (_) => _open(),
          ),
        ),
      ],
    );
  }
}
