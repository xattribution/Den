import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/words.dart';
import '../state/list_actions.dart';
import '../state/lists_model.dart';

/// "Clear checked (3)": once something on the list is checked, an ink pill at the bottom end of
/// the list's page, in reach of the thumb however far the list is scrolled. Checked things stay
/// where they are, crossed off, until this is tapped; then they go, and the pill says so with
/// Undo in the same place. Out of the way while the keyboard is up, and not there for someone
/// who can't change the list.
class ClearChecked extends StatefulWidget {
  const ClearChecked({super.key, required this.listId});

  final String listId;

  /// What a list's page leaves free under its last row, so the pill never covers it.
  static const double room = Targets.adult + 2 * Sp.l;

  @override
  State<ClearChecked> createState() => _ClearCheckedState();
}

class _ClearCheckedState extends State<ClearChecked> {
  Done? _cleared;

  Future<void> _clear(int count) async {
    final result = await perform(context, () => context.listActions.clearChecked(widget.listId));
    if (result == null || !mounted) return;
    final n = (result.data['removed'] as int?) ?? count;
    setState(() => _cleared = (message: 'Cleared $n checked ${n == 1 ? 'item' : 'items'}', receipt: result.receipt));
  }

  Future<void> _undo(Receipt receipt) async {
    final result = await perform(context, () => context.actions.undo(receipt));
    if (result != null && mounted) setState(() => _cleared = null);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(listReads);
    final lv = app.den.list(widget.listId);
    final checked = lv?.items.where((i) => i.checked).length ?? 0;
    // Checking something new retires the last clear's note.
    if (checked > 0) _cleared = null;
    final cleared = _cleared;
    final hidden = lv == null || !app.canChangeItems || MediaQuery.viewInsetsOf(context).bottom > 0;
    final Widget shown;
    if (hidden || (checked == 0 && cleared == null)) {
      shown = const SizedBox.shrink(key: ValueKey('none'));
    } else if (checked > 0) {
      shown = FilledButton(
        key: const ValueKey('clear'),
        onPressed: () => _clear(checked),
        child: Semantics(
          label: 'Clear $checked checked ${checked == 1 ? 'item' : 'items'}',
          excludeSemantics: true,
          child: Text('Clear checked ($checked)', maxLines: 1, softWrap: false),
        ),
      );
    } else {
      final receipt = cleared!.receipt;
      shown = _ClearedPill(
        key: const ValueKey('cleared'),
        message: cleared.message,
        onUndo: receipt != null && receipt.undoable ? () => _undo(receipt) : null,
      );
    }
    return DenCrossfade(alignment: AlignmentDirectional.bottomEnd, child: shown);
  }
}

/// What the clear did, on the same ink pill, with Undo.
class _ClearedPill extends StatelessWidget {
  const _ClearedPill({super.key, required this.message, required this.onUndo});

  final String message;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(color: c.primary, shape: const StadiumBorder()),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Targets.adult),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(Sp.l, 0, onUndo == null ? 20 : Sp.xs, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(PhosphorIconsBold.check, size: 18, color: c.onPrimary),
                const SizedBox(width: Sp.s),
                Flexible(child: Text(tidy(message), style: t.label(c.onPrimary))),
                if (onUndo != null)
                  TextButton(
                    onPressed: onUndo,
                    style: TextButton.styleFrom(
                      foregroundColor: c.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: Sp.m),
                    ),
                    child: Text(
                      'Undo',
                      style: t.label(c.onPrimary).copyWith(decoration: TextDecoration.underline, decorationColor: c.onPrimary),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A list's scrolling page ([child]) with [ClearChecked] floating over its bottom end, [end]
/// in from the side so it lines up with the cards.
class ClearCheckedOver extends StatelessWidget {
  const ClearCheckedOver({super.key, required this.listId, required this.child, this.end = DenLayout.gutter});

  final String? listId;
  final Widget child;
  final double end;

  @override
  Widget build(BuildContext context) {
    final id = listId;
    if (id == null) return child;
    return Stack(
      children: [
        Positioned.fill(child: child),
        PositionedDirectional(
          end: end,
          bottom: Sp.l + MediaQuery.paddingOf(context).bottom,
          child: ClearChecked(key: ValueKey(id), listId: id),
        ),
      ],
    );
  }
}
