import 'package:flutter/material.dart';

import '../layout.dart';
import '../motion.dart';
import '../tokens.dart';
import '../words.dart';

/// A sheet's top line (Invite.dc.html, AvatarPicker.dc.html): its one title (26/800) and the
/// pill that closes it, "Close" or "Done" on the card color, or in ink ([primary]) when closing
/// is what finishes the job ("Done" on a picture). The sheet's handle sits above it.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.title, this.actionLabel = 'Close', this.onAction, this.primary = false});

  final String title;
  final String actionLabel;

  /// Null closes the sheet.
  final VoidCallback? onAction;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, Sp.l),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text(noOrphan(title), style: t.sheetTitle(c.ink)))),
          const SizedBox(width: Sp.m),
          DenPressable(
            onTap: onAction ?? () => Navigator.of(context).maybePop(),
            color: primary ? c.primary : c.card,
            semanticLabel: actionLabel,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Targets.adult),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.l + 2),
                child: Center(
                  widthFactor: 1,
                  child: Text(actionLabel, style: t.label(primary ? c.onPrimary : c.ink), maxLines: 1, softWrap: false),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
