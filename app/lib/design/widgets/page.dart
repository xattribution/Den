import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../layout.dart';
import '../motion.dart';
import '../tokens.dart';
import '../words.dart';

/// A page pushed over the app (Family, Settings, a setup step): a round back button and the
/// page's one title (30/800, 34 on iPad), then its sections [DenLayout.sectionGap] apart, held
/// to a readable width and centered on iPad. [bottom] stays under the scrolling part, within
/// reach of the thumb: the page's one primary action.
///
/// A child that may draw nothing (a "Needs you" that is empty) goes in [Ungapped] and keeps its
/// own room under it, so an empty one leaves no gap.
class DenPage extends StatelessWidget {
  const DenPage({
    super.key,
    required this.title,
    required this.children,
    this.overline,
    this.trailing,
    this.bottom,
    this.back = true,
    this.onBack,
    this.maxWidth = DenLayout.readableWidth,
    this.scrollController,
  });

  final String title;
  final List<Widget> children;

  /// A small line above the title.
  final String? overline;

  /// At the end of the title row: at most one icon action.
  final Widget? trailing;

  /// Pinned under the content: the primary button.
  final Widget? bottom;

  /// Shows the back button when there is somewhere to go back to (or [onBack] says where).
  final bool back;
  final VoidCallback? onBack;

  /// The content's widest; a two-column page passes more.
  final double maxWidth;
  final ScrollController? scrollController;

  /// The side padding for [width]: 16 on phones, 24 on iPad, 32 with room to spare.
  static double gutterFor(double width) => switch (DenLayout.forWidth(width)) {
        DenWidth.compact => DenLayout.gutter,
        DenWidth.regular => 24,
        DenWidth.wide => 32,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final width = MediaQuery.sizeOf(context).width;
    final side = gutterFor(width);
    final large = !DenLayout.forWidth(width).isCompact;
    final canBack = back && (onBack != null || (ModalRoute.of(context)?.impliesAppBarDismissal ?? false));
    final items = <Widget>[];
    for (final (i, child) in children.indexed) {
      items.add(child is Ungapped ? child.child : child);
      final last = i == children.length - 1;
      if (!last && child is! Ungapped) items.add(const SizedBox(height: DenLayout.sectionGap));
    }
    final header = Padding(
      padding: const EdgeInsets.only(bottom: DenLayout.sectionGap),
      child: Row(
        children: [
          if (canBack) ...[
            PageBackButton(onTap: onBack ?? () => Navigator.of(context).maybePop()),
            const SizedBox(width: Sp.s),
          ] else
            const SizedBox(width: DenLayout.headingInset),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (overline != null) Text(overline!, style: context.text.meta(c.ink2)),
                Semantics(header: true, child: Text(noOrphan(title), style: context.text.screenTitle(c.ink, large: large))),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: Sp.m), trailing!],
        ],
      ),
    );
    Widget held(Widget child) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        );
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: bottom == null,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.fromLTRB(side, Sp.l, side, Sp.xxl),
                children: [held(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...items]))],
              ),
            ),
            if (bottom != null)
              ColoredBox(
                color: c.bg,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(side, Sp.s, side, Sp.l),
                    child: held(bottom!),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A child of [DenPage] that may draw nothing: it gets no gap after it, and keeps its own.
class Ungapped extends StatelessWidget {
  const Ungapped(this.child, {super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// The round back button at the start of a page's title: 44 across on the card color, an ink
/// caret. Screen readers hear "Back".
class PageBackButton extends StatelessWidget {
  const PageBackButton({super.key, required this.onTap, this.label = 'Back'});

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: DenPressable(
        onTap: onTap,
        color: c.card,
        shape: const CircleBorder(),
        semanticLabel: label,
        child: SizedBox.square(
          dimension: Targets.adult,
          child: Icon(PhosphorIconsBold.caretLeft, size: 22, color: c.ink),
        ),
      ),
    );
  }
}
