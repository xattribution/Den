import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../avatar.dart';
import '../layout.dart';
import '../motion.dart';
import '../sheet.dart';
import '../tokens.dart';
import '../widgets/section.dart';

/// Who someone picked in [showPeoplePicker]: a person, or anyone.
class PeoplePick {
  const PeoplePick.person(String this.member) : anyone = false;
  const PeoplePick.anyone()
      : member = null,
        anyone = true;

  final String? member;
  final bool anyone;
}

/// A sheet of people to pick one from ("Give to…", "Who?", "Who's driving?"): their faces and
/// names, [current] checked. [anyoneLabel] adds a first row for nobody in particular. Completes
/// with null when the sheet is closed without a pick.
Future<PeoplePick?> showPeoplePicker(
  BuildContext context, {
  required String title,
  required List<Member> people,
  String? current,
  String? anyoneLabel,
  bool anyoneCurrent = false,
}) =>
    showDenSheet<PeoplePick>(
      context,
      builder: (sheet) => _PeopleSheet(
        title: title,
        people: people,
        current: current,
        anyoneLabel: anyoneLabel,
        anyoneCurrent: anyoneCurrent,
      ),
    );

class _PeopleSheet extends StatelessWidget {
  const _PeopleSheet({required this.title, required this.people, this.current, this.anyoneLabel, this.anyoneCurrent = false});

  final String title;
  final List<Member> people;
  final String? current;
  final String? anyoneLabel;
  final bool anyoneCurrent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rows = <Widget>[
      if (anyoneLabel != null)
        _PersonRow(
          face: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: c.ink2, width: 1.5)),
            child: Icon(PhosphorIconsBold.usersThree, size: 22, color: c.ink2),
          ),
          name: anyoneLabel!,
          chosen: anyoneCurrent,
          onTap: () => Navigator.of(context).pop(const PeoplePick.anyone()),
        ),
      for (final m in people)
        _PersonRow(
          face: DenAvatar(m, size: 40),
          name: m.name,
          chosen: m.id == current,
          onTap: () => Navigator.of(context).pop(PeoplePick.person(m.id)),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, Sp.l),
            child: Semantics(header: true, child: Text(title, style: context.text.sheetTitle(c.ink))),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: GroupCard(child: Column(children: ruled(rows, indent: RowRule.afterFace))),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.face, required this.name, required this.chosen, required this.onTap});

  final Widget face;
  final String name;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: chosen,
      button: true,
      label: name,
      excludeSemantics: true,
      child: DenPressable(
        onTap: onTap,
        scale: false,
        haptic: true,
        shape: const RoundedRectangleBorder(),
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
