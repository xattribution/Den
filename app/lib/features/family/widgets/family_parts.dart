import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../words/family_words.dart';

/// A change said in place before it saves: what it will do, its button ("Turn on", "Remove
/// Leo's iPad") and Cancel. It opens under the row that asked, never as a dialog.
class ConfirmPanel extends StatelessWidget {
  const ConfirmPanel({
    super.key,
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.destructive = false,
    this.busy = false,
    this.error,
  });

  final String message;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  /// Removing something: the button says so in red words, never a red fill.
  final bool destructive;
  final bool busy;

  /// Why it didn't save, with the same buttons to try again.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final confirm = destructive
        ? OutlinedButton.icon(
            onPressed: busy ? null : onConfirm,
            style: OutlinedButton.styleFrom(foregroundColor: c.destructive),
            icon: Icon(PhosphorIconsRegular.trash, size: 18, color: c.destructive),
            label: Text(confirmLabel, maxLines: 1, softWrap: false),
          )
        : FilledButton(onPressed: busy ? null : onConfirm, child: Text(confirmLabel, maxLines: 1, softWrap: false));
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Sp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tidy(message), style: t.body(c.ink)),
            if (error != null) ...[
              const SizedBox(height: Sp.s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(PhosphorIconsFill.warningOctagon, size: 18, color: c.destructive),
                  ),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text(tidy(error!), style: t.meta(c.destructive))),
                ],
              ),
            ],
            const SizedBox(height: Sp.m),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [confirm, TextButton(onPressed: busy ? null : onCancel, child: const Text('Cancel'))],
            ),
          ],
        ),
      ),
    );
  }
}

/// Two answers side by side, each half the width (Family.dc.html's "Let her in", "That's not
/// her"), or one under the other when a label wouldn't fit on its line at this text size.
class TwoButtons extends StatelessWidget {
  const TwoButtons({super.key, required this.primary, required this.onPrimary, required this.secondary, required this.onSecondary});

  final String primary;
  final VoidCallback? onPrimary;
  final String secondary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final t = context.text;
    final c = context.colors;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        double width(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: t.label(c.ink)),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          return painter.width + 40;
        }

        final half = (box.maxWidth - Sp.s) / 2;
        final side = width(primary) <= half && width(secondary) <= half;
        final a = FilledButton(
          onPressed: onPrimary,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: Text(primary, maxLines: 1, softWrap: false),
        );
        final b = OutlinedButton(
          onPressed: onSecondary,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: Colors.transparent),
          child: Text(secondary, maxLines: 1, softWrap: false),
        );
        if (side) return Row(children: [Expanded(child: a), const SizedBox(width: Sp.s), Expanded(child: b)]);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: Sp.s), b]);
      },
    );
  }
}

/// The family's faces in a row that scrolls sideways (Family.dc.html): 56 across with their
/// name under, the chosen one ringed in ink with a gap. [onAdd] adds a round Add at the end.
class PeopleStrip extends StatelessWidget {
  const PeopleStrip({super.key, required this.people, required this.selected, required this.onSelect, this.onAdd, this.me});

  final List<Member> people;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback? onAdd;

  /// Who is using the device, said as "You" under their face.
  final String? me;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    Widget item({required Widget face, required String name, required bool chosen, required VoidCallback onTap, String? semantic}) =>
        SizedBox(
          width: 72,
          child: DenPressable(
            onTap: onTap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.tile)),
            selected: chosen,
            semanticLabel: semantic ?? name,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Sp.xs),
              child: Column(
                children: [
                  Container(
                    width: 66,
                    height: 66,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: chosen ? c.ink : Colors.transparent, width: 2),
                    ),
                    child: face,
                  ),
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: Text(
                      name,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: chosen ? t.caption(c.ink).bold : t.caption(c.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    // Room for names on two lines only when one needs it.
    final scaler = MediaQuery.textScalerOf(context);
    final twoLines = people.any((m) {
      final painter = TextPainter(
        text: TextSpan(text: m.id == me ? 'You' : m.name, style: t.caption(c.ink).bold),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      return painter.width > 72;
    });
    return SizedBox(
      height: 66 + 8 + 4 + (twoLines ? 2 : 1) * 17 * scale,
      child: ListView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        children: [
          for (final m in people) ...[
            item(
              face: DenAvatar(m, size: 56),
              name: m.id == me ? 'You' : m.name,
              chosen: m.id == selected,
              onTap: () => onSelect(m.id),
              semantic: m.id == me ? '${m.name}, you' : m.name,
            ),
            const SizedBox(width: Sp.xs),
          ],
          if (onAdd != null)
            item(
              face: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
                child: Icon(PhosphorIconsBold.plus, size: 24, color: c.ink),
              ),
              name: 'Add',
              chosen: false,
              onTap: onAdd!,
              semantic: 'Add someone',
            ),
        ],
      ),
    );
  }
}

/// The family as rows in a card, for the iPad's left column: face, name, who they are; the
/// chosen one on the fill gray.
class PeopleList extends StatelessWidget {
  const PeopleList({
    super.key,
    required this.people,
    required this.selected,
    required this.onSelect,
    required this.today,
    this.onAdd,
    this.me,
  });

  final List<Member> people;
  final String? selected;
  final ValueChanged<String> onSelect;
  final String today;
  final VoidCallback? onAdd;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final rows = <Widget>[
      for (final m in people)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: DenPressable(
            onTap: () => onSelect(m.id),
            scale: false,
            selected: m.id == selected,
            color: m.id == selected ? c.fill : null,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.input)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.s),
                child: Row(
                  children: [
                    DenAvatar(m, size: 40),
                    const SizedBox(width: Sp.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.id == me ? '${m.name} (you)' : m.name, style: t.rowTitle(c.ink)),
                          Text(FamilyWords.memberLine(m, today), style: t.meta(c.ink2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      if (onAdd != null) NavRow(icon: PhosphorIconsRegular.userPlus, label: 'Add someone', chevron: false, onTap: onAdd),
    ];
    return GroupCard(
      padding: const EdgeInsets.symmetric(horizontal: Sp.s, vertical: Sp.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

/// A face, or the ink glyph for something that isn't anyone's, 40 across.
Widget faceOr(Member? m, IconData glyph, BuildContext context, {double size = 40}) => m == null
    ? SizedBox.square(dimension: size, child: Icon(glyph, size: size * 0.65, color: context.colors.ink))
    : DenAvatar(m, size: size);

/// The gap a page leaves under a part that may be empty.
const Widget sectionGap = SizedBox(height: DenLayout.sectionGap);
