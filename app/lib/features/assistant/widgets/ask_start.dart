import 'package:flutter/material.dart';

import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/words.dart';
import '../state/suggestions.dart';
import '../words/assistant_words.dart';
import 'ask_parts.dart';

/// An empty conversation: "Hi Alex. What can I help with?", what can be asked, and three or four
/// things to ask now as chips ([askSuggestions]). While the helper can't answer this person
/// ([gate]: a kid's questions for the day, the month's budget, nobody chose who runs it), its
/// plain words stand where the chips were, and for a parent the way to Settings ([onSetUp]).
class AskWelcome extends StatelessWidget {
  const AskWelcome({
    super.key,
    required this.greeting,
    required this.help,
    required this.suggestions,
    required this.onPick,
    this.kid = false,
    this.gate,
    this.onSetUp,
  });

  final String greeting;
  final String help;
  final List<AskSuggestion> suggestions;
  final ValueChanged<AskSuggestion> onPick;
  final bool kid;
  final HelperProblem? gate;
  final VoidCallback? onSetUp;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final gate = this.gate;
    final below = gate == null
        ? Wrap(
            key: const ValueKey('suggestions'),
            spacing: Sp.s,
            runSpacing: Sp.s,
            children: [for (final s in suggestions) AskChip(suggestion: s, onTap: () => onPick(s), kid: kid)],
          )
        : Column(
            key: ValueKey(gate.message),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProblemLine(problem: gate, onRetry: () {}, kid: kid),
              if (onSetUp != null) ...[const SizedBox(height: Sp.l), SetUpButton(onTap: onSetUp!)],
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset, vertical: Sp.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(header: true, child: Text(greeting, style: t.section(c.ink))),
          const SizedBox(height: Sp.xs),
          Text(tidy(help), style: t.body(c.ink2)),
          const SizedBox(height: Sp.l),
          // A limit the hub reports as Ask opens takes the chips' place without a jump.
          DenCrossfade(child: below),
        ],
      ),
    );
  }
}

/// Something to ask, as a pill on the card color: the words in ink, 44 tall (72 for a kid). A
/// question is asked at once; a change goes in the field to finish ([AskSuggestion.send]).
class AskChip extends StatelessWidget {
  const AskChip({super.key, required this.suggestion, required this.onTap, this.kid = false});

  final AskSuggestion suggestion;
  final VoidCallback onTap;
  final bool kid;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return DenPressable(
      onTap: onTap,
      color: c.card,
      // A screen reader says which ones ask at once and which only start the words.
      semanticLabel: suggestion.send ? 'Ask: ${suggestion.words}' : 'Start a message: ${suggestion.words}',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: buttonHeight(kid: kid)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.l, vertical: Sp.s),
            child: Text(suggestion.words, style: (kid ? t.rowTitle : t.control)(c.ink)),
          ),
        ),
      ),
    );
  }
}

/// Ask for a parent while the helper is off or has no hub to run through: what it does, why it
/// isn't answering, and the way to Settings, AI helper.
class AskSetUp extends StatelessWidget {
  const AskSetUp({super.key, required this.reason, required this.onSetUp});

  /// Why it isn't on: off for the family, or no hub yet.
  final String reason;
  final VoidCallback onSetUp;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset, vertical: Sp.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tidy(askSetUpWords), style: t.body(c.ink)),
          const SizedBox(height: Sp.l),
          Text(tidy(reason), style: t.body(c.ink2)),
          const SizedBox(height: Sp.l),
          Align(alignment: AlignmentDirectional.centerStart, child: SetUpButton(onTap: onSetUp)),
        ],
      ),
    );
  }
}

/// "Set up the helper", in ink: to Settings, AI helper.
class SetUpButton extends StatelessWidget {
  const SetUpButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(minimumSize: const Size(0, Targets.adult)),
        child: const Text(askSetUpAction, maxLines: 1, softWrap: false),
      );
}
