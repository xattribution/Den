import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../capture/capture_service.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../state/app_state.dart';

/// Whether the person acting may add anything capture finds.
bool canCapture(AppState app) =>
    app.allows(DenAction.editEvents) || app.allows(DenAction.editChores) || app.allows(DenAction.editLists);

/// The Add sheet: type, snap or say anything, and Den works out what it is; or add one thing by
/// hand. [choices] are the one-thing rows the person is allowed: label, icon, route.
class AddSheet extends StatefulWidget {
  const AddSheet({super.key, required this.choices, required this.open});
  final List<(String, IconData, String)> choices;

  /// Opens a route behind the sheet once it has closed.
  final void Function(String route, {Object? extra}) open;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  final _text = TextEditingController();
  bool _listening = false;
  bool _spoken = false;
  String _heardText = '';

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      if (_spoken && _text.text != _heardText) _spoken = false;
      setState(() {});
    });
  }

  @override
  void dispose() {
    if (_listening) unawaited(Capture.of(context).sources.stopListening());
    _text.dispose();
    super.dispose();
  }

  void _read(CaptureInput input) {
    Navigator.of(context).pop();
    widget.open('/capture', extra: input);
  }

  void _send() {
    final words = _text.text.trim();
    if (words.isEmpty) return;
    _read(_spoken ? CaptureInput.spoken(words) : CaptureInput.typed(words));
  }

  Future<void> _file(Future<CaptureFile?> Function() source) async {
    try {
      final file = await source();
      if (file != null && mounted) _read(CaptureInput.shared(files: [file], text: _text.text));
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } on Object {
      if (mounted) showNote(context, 'Den couldn\'t open that. Try another photo or file.');
    }
  }

  Future<void> _speak() async {
    final sources = Capture.of(context).sources;
    if (_listening) {
      await sources.stopListening();
      return;
    }
    setState(() => _listening = true);
    try {
      final words = await sources.listen(
        onWords: (w) {
          if (!mounted) return;
          _heardText = w;
          _spoken = true;
          _text.value = TextEditingValue(text: w, selection: TextSelection.collapsed(offset: w.length));
          _spoken = true;
        },
      );
      if (words != null && mounted) {
        _heardText = words;
        _text.value = TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length));
        _spoken = true;
      }
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final sources = Capture.of(context).sources;
    final capture = canCapture(app);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.l),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Sp.l, 0, Sp.l, Sp.s),
                child: Text('Add', style: context.type.title(c.ink)),
              ),
              if (capture) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xs, Sp.l, 0),
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    style: context.type.body(c.ink),
                    decoration: InputDecoration(
                      hintText: _listening ? 'Listening' : 'Type, snap or say',
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (sources.canSpeak)
                            IconButton(
                              tooltip: _listening ? 'Stop listening' : 'Say it',
                              isSelected: _listening,
                              onPressed: _speak,
                              icon: Icon(PhosphorIconsRegular.microphone, color: c.ink2),
                              selectedIcon: Icon(PhosphorIconsFill.microphone, color: c.ink),
                            ),
                          if (_text.text.trim().isNotEmpty)
                            IconButton(
                              tooltip: 'Read it',
                              onPressed: _send,
                              icon: Icon(PhosphorIconsFill.arrowCircleUp, color: c.ink),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.l, Sp.s, Sp.l, Sp.s),
                  child: Wrap(
                    spacing: Sp.s,
                    runSpacing: Sp.s,
                    children: [
                      if (sources.canSnap)
                        OutlinedButton.icon(
                          onPressed: () => _file(sources.snap),
                          icon: const Icon(PhosphorIconsRegular.camera, size: 18),
                          label: const Text('Snap a photo'),
                        ),
                      OutlinedButton.icon(
                        onPressed: () => _file(sources.pick),
                        icon: const Icon(PhosphorIconsRegular.filePlus, size: 18),
                        label: const Text('Photo or PDF'),
                      ),
                    ],
                  ),
                ),
                Divider(height: Sp.l, color: c.rule),
              ],
              for (final choice in widget.choices)
                ListTile(
                  leading: Icon(choice.$2),
                  title: Text(choice.$1),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.open(choice.$3);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens [AddSheet] over [context]'s page.
Future<void> showCaptureSheet(BuildContext context, List<(String, IconData, String)> choices) {
  final router = GoRouter.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => AddSheet(
      choices: choices,
      open: (route, {extra}) => router.push(route, extra: extra),
    ),
  );
}
