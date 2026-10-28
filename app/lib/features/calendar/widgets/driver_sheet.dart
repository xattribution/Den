import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/avatar.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../words/block_words.dart';

/// Who drives: a sheet of the people who can, their faces and names, the current driver
/// checked, and "Nobody yet" first. One tap picks and closes it. Completes with the member id,
/// an empty string for nobody, or null when closed without a pick.
Future<String?> showDriverSheet(
  BuildContext context, {
  required String title,
  required List<Member> drivers,
  required String? current,
  String? me,
}) =>
    showDenSheet<String>(
      context,
      builder: (_) => DriverSheet(title: title, drivers: drivers, current: current, me: me),
    );

class DriverSheet extends StatelessWidget {
  const DriverSheet({super.key, required this.title, required this.drivers, required this.current, this.me});

  final String title;
  final List<Member> drivers;
  final String? current;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[
      _Row(
        face: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.line, width: 1.5)),
          child: Icon(PhosphorIconsBold.minus, size: 20, color: c.ink2),
        ),
        name: 'Nobody yet',
        chosen: current == null,
        onTap: () => Navigator.of(context).pop(''),
      ),
      for (final m in drivers)
        _Row(
          face: DenAvatar(m, size: 40),
          name: m.id == me ? '${m.name} (you)' : m.name,
          chosen: m.id == current,
          onTap: () => Navigator.of(context).pop(m.id),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.s),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, Sp.xs, 4, Sp.l),
            child: Semantics(header: true, child: Text(tidyLine(title), style: context.text.sheetTitle(c.ink))),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: DecoratedBox(
                decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(Radii.section)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DenLayout.cardPadding),
                  child: Column(
                    children: [
                      for (final (i, row) in rows.indexed) ...[
                        if (i > 0) Padding(padding: const EdgeInsets.only(left: 52), child: Container(height: 1, color: c.line)),
                        row,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.face, required this.name, required this.chosen, required this.onTap});

  final Widget face;
  final String name;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DenPressable(
      onTap: onTap,
      scale: false,
      haptic: true,
      selected: chosen,
      shape: const RoundedRectangleBorder(),
      semanticLabel: name,
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Row(
            children: [
              face,
              const SizedBox(width: Sp.m),
              Expanded(child: Text(name, style: chosen ? context.text.body(c.ink).bold : context.text.body(c.ink))),
              if (chosen) Icon(PhosphorIconsBold.check, size: 22, color: c.ink),
            ],
          ),
        ),
      ),
    );
  }
}
