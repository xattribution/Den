import 'dart:math' as math;

import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../words/block_words.dart';
import 'calendar_parts.dart';

/// "Change just this Wednesday, or every Wednesday?", asked in place under the change to a
/// repeating event, never in a dialog. Nothing is written until it's answered.
class ScopeCard extends StatelessWidget {
  const ScopeCard({super.key, required this.occ, required this.onPick, required this.onCancel, this.verb = 'Change'});

  final Occurrence occ;
  final ValueChanged<EditScope> onPick;
  final VoidCallback onCancel;

  /// What the change does: "Change", "Move".
  final String verb;

  @override
  Widget build(BuildContext context) {
    final f = DenScope.read(context).formats;
    final c = context.colors;
    final (question, all) = scopeQuestion(f, occ, verb: verb);
    return Semantics(
      liveRegion: true,
      child: GroupCard(
        padding: const EdgeInsets.all(Sp.l),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tidyLine(question), style: context.text.rowTitle(c.ink)),
              const SizedBox(height: Sp.m),
              _SplitButtons(
                first: CalendarPill(label: 'Just this one', edge: true, onTap: () => onPick(EditScope.one)),
                second: CalendarPill(label: all, primary: true, onTap: () => onPick(EditScope.all)),
                labels: ('Just this one', all),
              ),
              const SizedBox(height: Sp.xs),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                children: [
                  TextButton(onPressed: () => onPick(EditScope.following), child: const Text('From this one on')),
                  TextButton(
                    onPressed: onCancel,
                    child: Text('Keep it as it was', style: context.text.label(c.ink2)),
                  ),
                ],
              ),
            ],
        ),
      ),
    );
  }
}

/// Two buttons sharing a row while both labels fit, one above the other when they don't.
class _SplitButtons extends StatelessWidget {
  const _SplitButtons({required this.first, required this.second, required this.labels});

  final Widget first;
  final Widget second;
  final (String, String) labels;

  @override
  Widget build(BuildContext context) {
    final style = context.text.label(context.colors.ink);
    final scaler = MediaQuery.textScalerOf(context);
    double width(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final w = p.width;
      p.dispose();
      return w + Sp.l * 2;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - Sp.s) / 2;
        if (math.max(width(labels.$1), width(labels.$2)) <= half) {
          return Row(
            children: [
              Expanded(child: first),
              const SizedBox(width: Sp.s),
              Expanded(child: second),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            first,
            const SizedBox(height: Sp.s),
            second,
          ],
        );
      },
    );
  }
}
