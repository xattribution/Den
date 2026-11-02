import 'package:den_core/den_core.dart';
import 'package:den_net/den_net.dart' show ScreenCode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/pictograms.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/sync/pairing.dart';
import '../words/kitchen_screen_words.dart';

/// Settings, Kitchen screen, Add a screen (`/settings/advanced/displays/add`), on a parent's own
/// phone: the code the screen shows, typed (any case, dashes and spaces or not), or scanned where
/// Den has a camera scanner. No link fills it in: typing what the screen in front of her shows
/// is what says she is there, then one question, "Add Kitchen iPad as a kitchen
/// screen?", with the name she can change. Add approves it here, signed by this phone, as a
/// shared screen nobody owns, the same as approving a display that asked to join.
class AddScreenScreen extends StatefulWidget {
  const AddScreenScreen({super.key, this.scan, this.found, this.added = false});

  /// Forces the camera on or off, for tests; by default phones with a camera scan.
  final bool? scan;

  /// Starts at the question for this screen, for tests and screenshots.
  final ScreenAsk? found;

  /// Starts at the end, for tests and screenshots ([found] says which screen).
  final bool added;

  @override
  State<AddScreenScreen> createState() => _AddScreenScreenState();
}

enum _Step { code, confirm, done }

class _AddScreenScreenState extends State<AddScreenScreen> {
  final _code = TextEditingController();
  late final _name = TextEditingController(text: widget.found?.name ?? '');
  late _Step _step = widget.found == null ? _Step.code : (widget.added ? _Step.done : _Step.confirm);
  late ScreenAsk? _found = widget.found;
  bool _scanning = false;
  bool _busy = false;
  String? _error;

  bool get _canScan => widget.scan ?? Capabilities.scanQr;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final code = ScreenCode.fromText(_code.text);
    if (code == null) {
      setState(() => _error = "That isn't a screen's code. It's 8 letters and numbers, like K7QM-3RXA.");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final found = await Pairing.of(context).findScreen(code);
      if (!mounted) return;
      setState(() {
        _found = found;
        _name.text = found.name;
        _step = _Step.confirm;
      });
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final found = _found;
    if (found == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Pairing.of(context).addScreen(found, name: _name.text);
      if (mounted) setState(() => _step = _Step.done);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _scanned(BarcodeCapture capture) {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    final code = raw == null ? null : ScreenCode.fromText(raw);
    if (code == null) {
      setState(() => _error = "That isn't a kitchen screen's code. Scan the code on the screen, or type it.");
      return;
    }
    setState(() {
      _scanning = false;
      _code.text = ScreenCode.format(code);
    });
    _find();
  }

  void _again() => setState(() {
        _step = _Step.code;
        _found = null;
        _error = null;
        _code.clear();
      });

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    if (!app.allowsTrust(DenAction.manageFamily)) {
      return const DenPage(
        title: 'Add a screen',
        children: [NoticeLine(icon: PhosphorIconsRegular.lockKey, message: "Kitchen screens are added on a parent's own phone.")],
      );
    }
    return switch (_step) {
      _Step.code => _codeStep(context),
      _Step.confirm => _confirmStep(context, _found!),
      _Step.done => _doneStep(context, _found!),
    };
  }

  Widget _codeStep(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final width = MediaQuery.sizeOf(context).width;
    final camera = (width.clamp(0.0, 560.0) - 64).clamp(200.0, 420.0);
    return DenPage(
      title: 'Add a screen',
      bottom: _scanning
          ? null
          : FilledButton(
              onPressed: _busy ? null : _find,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: Text(_busy ? 'Finding the screen' : 'Next'),
            ),
      children: [
        if (_scanning) ...[
          Text('Scan the code on the screen.', style: t.body(c.ink)),
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
                          "Den can't use the camera. Allow camera access in this phone's settings, or type the code instead.",
                          style: t.body(c.ink2),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null) Text(_error!, style: t.meta(c.destructive)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() {
                _scanning = false;
                _error = null;
              }),
              child: const Text('Type the code instead'),
            ),
          ),
        ] else ...[
          Text('Type the code the kitchen screen shows.', style: t.body(c.ink)),
          LabeledField(
            label: 'Code',
            error: _error,
            child: TextField(
              controller: _code,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: [ScreenCodeFormatter()],
              style: t.screenTitle(c.ink).bold.copyWith(letterSpacing: 2),
              decoration: InputDecoration(hintText: 'K7QM-3RXA', hintStyle: t.screenTitle(c.ink3).bold.copyWith(letterSpacing: 2)),
              onSubmitted: (_) => _find(),
            ),
          ),
          if (_canScan)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() {
                  _scanning = true;
                  _error = null;
                }),
                child: const Text('Scan the code instead'),
              ),
            ),
          Text(KitchenScreenWords.whereTheCodeIs, style: t.meta(c.ink2)),
        ],
      ],
    );
  }

  Widget _confirmStep(BuildContext context, ScreenAsk found) {
    final c = context.colors;
    final t = context.text;
    final name = _name.text.trim().isEmpty ? found.name : _name.text.trim();
    return DenPage(
      title: 'Add a screen',
      onBack: _busy ? null : _again,
      bottom: FilledButton(
        onPressed: _busy ? null : _add,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Adding' : 'Add $name', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      children: [
        GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.l),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox.square(dimension: 40, child: Icon(Pictograms.device(found.kind), size: 28, color: c.ink)),
                const SizedBox(width: Sp.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(KitchenScreenWords.confirm(name), style: t.section(c.ink)),
                      const SizedBox(height: Sp.xs),
                      Text(KitchenScreenWords.whatItDoes, style: t.meta(c.ink2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        LabeledField(
          label: 'Name',
          child: TextField(
            controller: _name,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            maxLength: 40,
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            style: t.body(c.ink),
            onSubmitted: (_) => _add(),
          ),
        ),
        if (_error != null) ErrorState(message: _error!, actionLabel: 'Type the code again', onAction: _again),
        if (_error == null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: _busy ? null : _again, child: const Text('Not this screen')),
          ),
      ],
    );
  }

  Widget _doneStep(BuildContext context, ScreenAsk found) {
    final c = context.colors;
    final t = context.text;
    final name = _name.text.trim().isEmpty ? found.name : _name.text.trim();
    return DenPage(
      title: 'Add a screen',
      back: false,
      bottom: FilledButton(
        onPressed: () => context.canPop() ? context.pop() : context.go('/settings/advanced/displays'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: const Text('Done'),
      ),
      children: [
        GroupCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.l),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox.square(dimension: 40, child: Icon(PhosphorIconsRegular.checkCircle, size: 28, color: c.ink)),
                  const SizedBox(width: Sp.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(KitchenScreenWords.added(name), style: t.section(c.ink)),
                        const SizedBox(height: Sp.xs),
                        Text(KitchenScreenWords.afterAdded, style: t.meta(c.ink2)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Types a screen's code the way it is shown: upper case, letters and digits only, a dash after
/// the first four, eight at most.
class ScreenCodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '');
    final kept = raw.length > ScreenCode.length ? raw.substring(0, ScreenCode.length) : raw;
    final text = kept.length > 4 ? '${kept.substring(0, 4)}-${kept.substring(4)}' : kept;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}
