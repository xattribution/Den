import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../motion.dart';
import '../tokens.dart';

/// What an editor keeps out of the way until asked: a quiet "More options" row with a caret,
/// and the [child] revealed under it on the UI spring. Starts open when [initiallyOpen] (an
/// existing thing that already uses one of the options), so nothing set is ever hidden.
class MoreOptions extends StatefulWidget {
  const MoreOptions({super.key, required this.child, this.label = 'More options', this.initiallyOpen = false});

  final Widget child;
  final String label;
  final bool initiallyOpen;

  @override
  State<MoreOptions> createState() => _MoreOptionsState();
}

class _MoreOptionsState extends State<MoreOptions> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: DenPressable(
            onTap: () => setState(() => _open = !_open),
            scale: false,
            toggled: null,
            selected: _open,
            semanticLabel: widget.label,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Targets.adult),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(child: Text(widget.label, style: context.text.label(c.ink))),
                    const SizedBox(width: Sp.xs),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: DenMotion.reduced(context) ? Duration.zero : DenMotion.uiSettle,
                      curve: DenMotion.uiCurve,
                      child: Icon(PhosphorIconsBold.caretDown, size: 16, color: c.ink),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        DenReveal(visible: _open, child: widget.child),
      ],
    );
  }
}
