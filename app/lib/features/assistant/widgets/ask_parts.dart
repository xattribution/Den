import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../design/layout.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../state/ask_session.dart';
import '../words/assistant_words.dart';

/// The height of a button: 44 for grown-ups, 72 for a kid.
double buttonHeight({required bool kid}) => kid ? Targets.kid : Targets.adult;

/// What the person asked, quietly, beside their face.
class AskedLine extends StatelessWidget {
  const AskedLine({super.key, required this.member, required this.words});

  final Member? member;
  final String words;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: 'You asked: $words',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (member != null) ...[DenAvatar(member!, size: 26), const SizedBox(width: Sp.s)],
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(tidy(words), style: context.text.body(c.ink2)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Each change the helper made, as a row in the person's color with Undo in place: a filled
/// check and "Moved Dentist to 4:00 PM Tue". Taken back, the ring empties and the row says so.
class ChangeRows extends StatelessWidget {
  const ChangeRows({super.key, required this.lines, required this.color, required this.onUndo, this.kid = false});

  final List<ChangeLine> lines;

  /// The person's color.
  final Color color;
  final void Function(ChangeLine line) onUndo;
  final bool kid;

  @override
  Widget build(BuildContext context) => GroupCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: ruled([
        for (final l in lines) _ChangeRow(line: l, color: color, onUndo: onUndo, kid: kid),
      ], indent: 26 + Sp.m),
    ),
  );
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.line, required this.color, required this.onUndo, required this.kid});

  final ChangeLine line;
  final Color color;
  final void Function(ChangeLine line) onUndo;
  final bool kid;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final undone = line.undone;
    final undo = line.receipt.undoable && !undone
        ? (kid
              ? OutlinedButton(
                  onPressed: line.undoing ? null : () => onUndo(line),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(96, Targets.kid)),
                  child: const Text('Undo', maxLines: 1, softWrap: false),
                )
              : UndoButton(onTap: line.undoing ? null : () => onUndo(line)))
        : null;
    final words = tidy(undone ? 'Took back: ${line.words}' : line.words);
    final style = (kid ? t.rowTitle : t.body)(undone ? c.ink2 : c.ink);
    const lead = 26 + Sp.m;
    return Semantics(
      container: true,
      liveRegion: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: kid ? 88 : 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Sp.s),
          child: LayoutBuilder(
            builder: (context, box) {
              // Undo sits beside the words only while they fit on one line beside it; otherwise
              // under them, lined up with them (the words never squeeze).
              final scaler = MediaQuery.textScalerOf(context);
              double width(String text, TextStyle s) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: s),
                  textScaler: scaler,
                  maxLines: 1,
                  textDirection: Directionality.of(context),
                )..layout();
                final w = painter.width;
                painter.dispose();
                return w;
              }

              final undoWidth = undo == null ? 0.0 : (kid ? 96.0 : width('Undo', t.label(c.ink)) + Sp.l + Sp.s);
              final beside = undo == null || width(words, style) <= box.maxWidth - lead - undoWidth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: beside ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: EdgeInsets.only(top: beside ? 0 : 2),
                        child: CheckRing(color: color, done: !undone, size: 26),
                      ),
                      const SizedBox(width: Sp.m),
                      Expanded(child: Text(words, style: style)),
                      if (undo != null && beside) ...[const SizedBox(width: Sp.s), undo],
                    ],
                  ),
                  if (undo != null && !beside)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: lead - Sp.xs, top: Sp.xs),
                      child: Align(alignment: AlignmentDirectional.centerStart, child: undo),
                    ),
                  if (line.error != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 26 + Sp.m, top: Sp.xs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(PhosphorIconsFill.warningOctagon, size: 16, color: c.destructive),
                          ),
                          const SizedBox(width: Sp.xs),
                          Expanded(child: Text(tidy(line.error!), style: t.meta(c.destructive))),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A change that waits for a tap: the question, what it would change (from the preview on a
/// fork of the family), any warning, and "Do it" or "Not now". A spoken yes doesn't count.
class ConfirmCard extends StatelessWidget {
  const ConfirmCard({
    super.key,
    required this.question,
    required this.lines,
    this.more = 0,
    this.warnings = const [],
    required this.onDo,
    required this.onNotNow,
    this.busy = false,
    this.kid = false,
  });

  final String question;
  final List<String> lines;
  final int more;
  final List<String> warnings;
  final VoidCallback onDo;
  final VoidCallback onNotNow;
  final bool busy;
  final bool kid;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final height = buttonHeight(kid: kid);
    return Semantics(
      container: true,
      liveRegion: true,
      child: GroupCard(
        padding: const EdgeInsets.all(DenLayout.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tidy(question), style: t.rowTitle(c.ink)),
            for (final l in lines) ...[const SizedBox(height: Sp.xs), Text(tidy(l), style: t.meta(c.ink2))],
            if (more > 0) ...[const SizedBox(height: Sp.xs), Text('And $more more', style: t.meta(c.ink2))],
            for (final w in warnings) ...[
              const SizedBox(height: Sp.s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(PhosphorIconsBold.info, size: 18, color: c.ink),
                  ),
                  const SizedBox(width: Sp.s),
                  Expanded(child: Text(tidy(w), style: t.meta(c.ink))),
                ],
              ),
            ],
            const SizedBox(height: Sp.l),
            Wrap(
              spacing: Sp.s,
              runSpacing: Sp.s,
              children: [
                FilledButton(
                  onPressed: busy
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          onDo();
                        },
                  style: FilledButton.styleFrom(minimumSize: Size(kid ? 140 : 96, height)),
                  child: const Text('Do it', maxLines: 1, softWrap: false),
                ),
                OutlinedButton(
                  onPressed: busy ? null : onNotNow,
                  style: OutlinedButton.styleFrom(minimumSize: Size(kid ? 140 : 96, height)),
                  child: const Text('Not now', maxLines: 1, softWrap: false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Why the helper couldn't answer: a limit or "not on for you" as a plain line with an ink icon;
/// the hub or the company being down in red words, with Try again.
class ProblemLine extends StatelessWidget {
  const ProblemLine({super.key, required this.problem, required this.onRetry, this.kid = false});

  final HelperProblem problem;
  final VoidCallback onRetry;
  final bool kid;

  @override
  Widget build(BuildContext context) {
    if (problem.kind == ProblemKind.down) {
      return ErrorState(message: problem.message, actionLabel: 'Try again', onAction: onRetry);
    }
    final c = context.colors;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              problem.kind == ProblemKind.limit ? PhosphorIconsBold.hourglassMedium : PhosphorIconsBold.lockSimple,
              size: 20,
              color: c.ink,
            ),
          ),
          const SizedBox(width: Sp.s),
          Expanded(child: Text(tidy(problem.message), style: (kid ? context.text.rowTitle : context.text.body)(c.ink))),
        ],
      ),
    );
  }
}

/// Where the next question goes: one field, and Ask (Say it too, where the device can listen).
/// Return asks.
class AskBar extends StatelessWidget {
  const AskBar({
    super.key,
    required this.controller,
    required this.focus,
    required this.onAsk,
    this.onSpeak,
    this.listening = false,
    this.busy = false,
    this.kid = false,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onAsk;
  final VoidCallback? onSpeak;
  final bool listening;
  final bool busy;
  final bool kid;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final height = buttonHeight(kid: kid);
    final field = TextField(
      controller: controller,
      focusNode: focus,
      minLines: 1,
      maxLines: 3,
      textInputAction: TextInputAction.send,
      textCapitalization: TextCapitalization.sentences,
      onSubmitted: (_) => onAsk(),
      style: t.body(c.ink),
      decoration: InputDecoration(hintText: listening ? 'Listening' : 'Ask something else'),
    );
    final ask = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => FilledButton(
        onPressed: busy || value.text.trim().isEmpty ? null : onAsk,
        style: FilledButton.styleFrom(minimumSize: Size(kid ? 120 : 72, height)),
        child: const Text('Ask', maxLines: 1, softWrap: false),
      ),
    );
    final speak = onSpeak == null
        ? null
        : RoundButton(
            icon: listening ? PhosphorIconsFill.stop : PhosphorIconsRegular.microphone,
            label: listening ? 'Stop listening' : 'Say it',
            onTap: onSpeak,
            fill: listening ? c.primary : c.card,
            color: listening ? c.onPrimary : c.ink,
            size: height,
          );
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        // The buttons beside the field while it has room; under it at large text or for a kid.
        if (kid || scale > 1.35 || box.maxWidth < 300) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              const SizedBox(height: Sp.s),
              Row(
                children: [
                  Expanded(child: ask),
                  if (speak != null) ...[const SizedBox(width: Sp.s), speak],
                ],
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: field),
            const SizedBox(width: Sp.s),
            ?speak,
            if (speak != null) const SizedBox(width: Sp.s),
            ask,
          ],
        );
      },
    );
  }
}

/// A kid's "Read it to me", 72 tall, under an answer.
class ReadAloudButton extends StatelessWidget {
  const ReadAloudButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, Targets.kid)),
      icon: const Icon(PhosphorIconsRegular.speakerHigh, size: 22),
      label: const Text('Read it to me', maxLines: 1, softWrap: false),
    ),
  );
}

/// "Asking Claude", shown once the helper has taken more than a moment.
class AskingLine extends StatelessWidget {
  const AskingLine({super.key, required this.speaker});

  final String speaker;

  @override
  Widget build(BuildContext context) =>
      Semantics(liveRegion: true, child: Text(askingWords(speaker), style: context.text.meta(context.colors.ink2)));
}
