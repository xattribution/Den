import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/web/web_app.dart';
import '../words/family_words.dart';
import '../widgets/family_parts.dart';

/// What a sitter sees once their last day has passed, by this device's clock or because a
/// parent's device removed this one: that their access ended and how to get it back. The
/// family's own devices enforce it (they stop syncing with this one and remove it); this screen
/// only says so.
class AccessEndedScreen extends StatefulWidget {
  const AccessEndedScreen({super.key});

  @override
  State<AccessEndedScreen> createState() => _AccessEndedScreenState();
}

class _AccessEndedScreenState extends State<AccessEndedScreen> {
  bool _startingOver = false;

  Future<void> _startOver() async {
    final den = DenScope.read(context).den;
    await attempt(context, den.leaveFamily);
    // A browser opens again as a fresh device, with new keys (see Boot).
    if (Capabilities.web) WebApp.reload();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final den = app.den;
    final c = context.colors;
    final t = context.text;
    final me = den.owner;
    final until = me?.until;
    final name = den.family?.name.trim() ?? '';
    final family = name.isEmpty
        ? 'The family'
        : name.toLowerCase().endsWith(' family') && !name.toLowerCase().startsWith('the ')
            ? 'The $name'
            : name;
    final parents = [for (final m in den.members) if (m.isParent) m.name];
    final ask = parents.isEmpty ? 'a parent' : FamilyWords.joinAnd(parents).replaceAll(' and ', ' or ');
    return DenPage(
      title: 'Your access ended',
      back: false,
      children: [
        Text(
          tidy(until == null
              ? '$family shared Den with you for a while. To use it again, ask $ask to invite you.'
              : '$family shared Den with you through ${app.formats.long(until)}. To use it again, ask $ask to invite '
                  'you.'),
          style: t.body(c.ink),
        ),
        const NoticeLine(
          icon: PhosphorIconsRegular.calendarX,
          message: "This device doesn't get the family's plans anymore.",
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_startingOver)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _startingOver = true),
                  child: const Text('Start over with a new invite'),
                ),
              ),
            DenReveal(
              visible: _startingOver,
              child: !_startingOver
                  ? const SizedBox(width: double.infinity)
                  : ConfirmPanel(
                      message: 'This device forgets the family. When a parent invites you again, join with the new '
                          'invite.',
                      confirmLabel: 'Start over',
                      onConfirm: _startOver,
                      onCancel: () => setState(() => _startingOver = false),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Whether this device belongs to a sitter whose access has ended, by its own clock: what the
/// router shows [AccessEndedScreen] for.
bool accessEndedHere(AppState app) {
  final me = app.den.owner;
  return me != null && me.accessEndedOn(app.today);
}
