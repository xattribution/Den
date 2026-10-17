import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';
import '../widgets.dart';

/// The top bar for a page whose content is held to [maxWidth]: the heading lines up with the
/// content's left edge on tablets and desktops instead of sitting at the window's edge.
PreferredSizeWidget pageBar(
  BuildContext context,
  String title, {
  double maxWidth = 600,
  bool back = true,
  List<Widget>? actions,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final contentLeft = math.max(0.0, (width - maxWidth) / 2) + Sp.l;
  final leading = back && (ModalRoute.of(context)?.impliesAppBarDismissal ?? false);
  final spacing = leading ? contentLeft - kToolbarHeight : contentLeft;
  return AppBar(
    title: Semantics(header: true, child: Text(title)),
    automaticallyImplyLeading: back,
    titleSpacing: spacing >= Sp.l ? spacing : null,
    actions: actions,
  );
}

/// A group heading with its help beside it, where [SectionHeader] would put it at the far edge.
class InfoHeader extends StatelessWidget {
  const InfoHeader(this.title, {super.key, required this.info, this.action});

  final String title;
  final String info;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.xl, Sp.s, Sp.s),
      child: Row(
        children: [
          Semantics(header: true, child: Text(title, style: context.type.title(c.ink))),
          InfoTip(info),
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

/// The page frame for onboarding and other single-column forms: a top bar with the one heading,
/// and content held to a readable width on tablets and desktops.
class FormFrame extends StatelessWidget {
  const FormFrame({
    super.key,
    required this.title,
    required this.children,
    this.bottom,
    this.back = true,
    this.actions,
    this.maxWidth = 600,
  });

  final String title;
  final List<Widget> children;

  /// Pinned under the scrolling content, such as the form's primary button.
  final Widget? bottom;
  final bool back;
  final List<Widget>? actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: pageBar(context, title, maxWidth: maxWidth, back: back, actions: actions),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: Sp.xxl),
                    children: children,
                  ),
                ),
              ),
            ),
            if (bottom != null)
              DecoratedBox(
                decoration: BoxDecoration(border: Border(top: BorderSide(color: c.rule))),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.m),
                      child: bottom,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A labeled block inside a form, padded to the page gutter.
class FormBlock extends StatelessWidget {
  const FormBlock({super.key, required this.child, this.top = Sp.l});
  final Widget child;
  final double top;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(Sp.l, top, Sp.l, 0), child: child);
}
