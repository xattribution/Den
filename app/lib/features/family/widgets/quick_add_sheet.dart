import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/family_actions.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/oversight.dart';
import '../words/who.dart';
import 'person_sheets.dart' show sheetPadding;

/// Adding someone in two taps after their name: who they are (a kid's age, or a parent, a
/// grown-up, a sitter), then Add. Their color and initial are picked for them; their page has
/// the rest. Completes with the new person's id.
Future<String?> showQuickAddSheet(BuildContext context) => showDenSheet<String>(context, builder: (_) => const QuickAddSheet());

class QuickAddSheet extends StatefulWidget {
  const QuickAddSheet({super.key, this.initialName, this.initialWho});

  /// For screenshots: the sheet as it looks part way through.
  final String? initialName;
  final Who? initialWho;

  @override
  State<QuickAddSheet> createState() => _QuickAddSheetState();
}

class _QuickAddSheetState extends State<QuickAddSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  late Who? _who = widget.initialWho;
  bool _tried = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    setState(() => _tried = true);
    final who = _who;
    if (name.isEmpty || who == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = DenScope.read(context);
    final family = context.familyActions;
    final trust = context.trustActions;
    final look = freshLook(app.den.members);
    ActionResult? result;
    final problem = await tryWrite(() async => result = await family.addPerson(
          name: name,
          role: who.role,
          tier: who.tier,
          marker: look.$1,
          picture: look.$2,
        ));
    final id = (result?.data['member'] as Map?)?['id'] as String?;
    // What a kid may add starts from their age; it's a trust decision, so only on a parent's own
    // device. Elsewhere they start with nothing and a parent turns things on later.
    final grants = defaultGrants(who.tier);
    if (id != null && who.kid && grants.isNotEmpty && app.allowsTrust(DenAction.manageFamily)) {
      await tryWrite(() => trust.setGrants(id, grants));
    }
    if (!mounted) return;
    if (problem != null || id == null) {
      setState(() {
        _busy = false;
        _error = problem ?? writeFailedMessage;
      });
      return;
    }
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final name = _name.text.trim();
    final shown = name.isEmpty ? 'They' : name;
    final who = _who;
    Widget chips(List<Who> options) => Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            for (final w in options)
              TagChip(label: w.chip, selected: w == who, onTap: () => setState(() => _who = w)),
          ],
        );
    return SingleChildScrollView(
      padding: sheetPadding.copyWith(bottom: MediaQuery.viewInsetsOf(context).bottom + Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Add someone'),
          LabeledField(
            label: 'Name',
            error: _tried && name.isEmpty ? 'Add their name.' : null,
            child: TextField(
              controller: _name,
              autofocus: widget.initialName == null,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              style: t.body(c.ink),
              decoration: const InputDecoration(hintText: 'Leo'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: Sp.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text(name.isEmpty ? 'Who are they?' : 'Who is $name?', style: t.meta(c.ink2)),
          ),
          const SizedBox(height: Sp.s),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text('A kid', style: t.label(c.ink)),
          ),
          const SizedBox(height: Sp.xs),
          chips(const [Who.under6, Who.sixTo8, Who.nineTo12, Who.teen]),
          const SizedBox(height: Sp.m),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset),
            child: Text('A grown-up', style: t.label(c.ink)),
          ),
          const SizedBox(height: Sp.xs),
          chips(const [Who.parent, Who.grownUp, Who.sitter]),
          if (_tried && who == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, 0),
              child: Text('Choose who they are.', style: t.meta(c.destructive)),
            ),
          DenCrossfade(
            child: who == null
                ? const SizedBox(key: ValueKey('none'), width: double.infinity)
                : Padding(
                    key: ValueKey(who),
                    padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.l, DenLayout.headingInset, 0),
                    child: Text(tidy(who.means(shown)), style: t.body(c.ink2)),
                  ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Sp.m),
            ErrorState(message: _error!, actionLabel: 'Try again', onAction: _add),
          ],
          const SizedBox(height: Sp.xl),
          FilledButton(
            onPressed: _busy ? null : _add,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text(name.isEmpty ? 'Add' : 'Add $name', maxLines: 1, softWrap: false, overflow: TextOverflow.visible),
          ),
        ],
      ),
    );
  }
}
