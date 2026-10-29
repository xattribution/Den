import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/recovery_reminder.dart';
import 'recovery_section.dart';

/// The answers to "Save your recovery words" in Needs you, on Today and in Family: Save them
/// (the twelve words, then I wrote them down) and, unless [later] is false, Remind me later,
/// which hides it from Needs you for three days. [onDone] gets what the row then says.
class RecoveryWordsButtons extends StatefulWidget {
  const RecoveryWordsButtons({super.key, required this.onDone, this.later = true});

  final ValueChanged<String> onDone;
  final bool later;

  @override
  State<RecoveryWordsButtons> createState() => _RecoveryWordsButtonsState();
}

class _RecoveryWordsButtonsState extends State<RecoveryWordsButtons> {
  bool _busy = false;

  Future<void> _save() async {
    final me = DenScope.read(context).me;
    if (me == null) return;
    setState(() => _busy = true);
    final saved = await showRecoveryWordsSheet(context, me);
    if (!mounted) return;
    setState(() => _busy = false);
    if (saved) widget.onDone('Your recovery words are saved. Keep them safe.');
  }

  void _later() {
    final app = DenScope.read(context);
    final me = app.me;
    if (me == null) return;
    app.snooze(RecoveryReminder.snoozeKey(me.id), app.den.now() + RecoveryReminder.later.inMilliseconds);
    widget.onDone('Den will ask again in 3 days');
  }

  /// A label on one line, made a little smaller only where it couldn't fit otherwise (a narrow
  /// column at 200 % text), never cut off.
  static Widget _label(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Sp.s,
        runSpacing: Sp.s,
        children: [
          FilledButton(onPressed: _busy ? null : _save, child: _label('Save them')),
          if (widget.later) OutlinedButton(onPressed: _busy ? null : _later, child: _label('Remind me later')),
        ],
      );
}

/// Settings → Family, beside "Let the hub help us get back in": the same reminder for as long as
/// this parent's words are missing, whether or not Needs you is putting it off. Nothing once
/// they're saved, or when another parent's device could let them back in.
class RecoveryWordsReminder extends StatefulWidget {
  const RecoveryWordsReminder({super.key});

  @override
  State<RecoveryWordsReminder> createState() => _RecoveryWordsReminderState();
}

class _RecoveryWordsReminderState extends State<RecoveryWordsReminder> {
  String? _done;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final done = _done;
    if (done == null && !RecoveryReminder.due(app)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: DenLayout.sectionGap),
      child: GroupCard(
        child: DoneSwap(
          done: done == null ? null : DoneRow(message: done),
          child: ActionRow(
            leading: SizedBox.square(dimension: 40, child: Icon(PhosphorIconsRegular.key, size: 26, color: c.ink)),
            title: RecoveryReminder.title,
            detail: RecoveryReminder.detail,
            actionBelow: true,
            action: RecoveryWordsButtons(later: false, onDone: (m) => setState(() => _done = m)),
          ),
        ),
      ),
    );
  }
}
