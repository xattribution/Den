import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../tokens.dart';
import '../widgets.dart';

/// One event on one line, the way it's written in a calendar square: the person's marker bar
/// (3 px), an optional time in ink2, the title in ink.
class CalendarEventLine extends StatelessWidget {
  const CalendarEventLine({
    super.key,
    required this.occ,
    this.time,
    this.onTap,
    this.bold = false,
    this.fade = false,
    this.height,
  });

  final Occurrence occ;
  final String? time;
  final VoidCallback? onTap;
  final bool bold;

  /// Fade the end of the title instead of an ellipsis, for narrow squares where every letter
  /// counts.
  final bool fade;

  /// Fixed line height; defaults to the meta line plus 4.
  final double? height;

  static double lineHeight(BuildContext context) => (context.type.meta(context.colors.ink).fontSize! * 1.3).ceilToDouble() + 4;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final c = context.colors;
    final line = SizedBox(
      height: height ?? lineHeight(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: PersonBar(markers: app.markersFor(occ.assignees), width: 3, minHeight: 0),
          ),
          const SizedBox(width: Sp.xs),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text.rich(
                TextSpan(children: [
                  if (time != null) TextSpan(text: '$time ', style: context.type.meta(c.ink2)),
                  TextSpan(
                    text: occ.title,
                    style: context.type.meta(c.ink).copyWith(fontWeight: bold ? FontWeight.w700 : null),
                  ),
                ]),
                maxLines: 1,
                softWrap: false,
                overflow: fade ? TextOverflow.fade : TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return line;
    return Semantics(
      button: true,
      label: [occ.title, ?time].join(', '),
      excludeSemantics: true,
      child: InkWell(onTap: onTap, child: line),
    );
  }
}
