import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/web/web_app.dart';
import '../state/recovery.dart';
import '../state/trust_actions.dart';
import '../words/recovery_lines.dart';
import 'family_parts.dart';

/// "Recovery words" on a parent's own page, on their own device: whether their 12 words are set
/// up, Make my words (or Make new words, which replaces the old), and, on a phone that was let
/// in by recovery, Remove your old phone.
class RecoverySection extends StatefulWidget {
  const RecoverySection({super.key, required this.member});

  /// The parent whose page this is: the one using this device.
  final Member member;

  @override
  State<RecoverySection> createState() => _RecoverySectionState();
}

class _RecoverySectionState extends State<RecoverySection> {
  bool _replacing = false;
  String? _removing;
  bool _busy = false;
  String? _error;
  String? _done;

  Future<void> _make() async {
    setState(() {
      _replacing = false;
      _done = null;
    });
    final saved = await showRecoveryWordsSheet(context, widget.member);
    if (saved && mounted) setState(() => _done = 'Your recovery words are saved. Keep them safe.');
  }

  Future<void> _remove(Device d) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final trust = context.trustActions;
    final problem = await tryWrite(() => trust.revokeDevice(d.id));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
      if (problem == null) {
        _removing = null;
        _done = '${d.name} is out of the family';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final t = context.text;
    final m = app.den.member(widget.member.id) ?? widget.member;
    final has = Recovery.hasWords(m);
    final letIn = Recovery.ofThisDevice(app.den);
    final old = letIn == null ? const <Device>[] : Recovery.otherDevices(app.den, m.id);
    final rows = <Widget>[];

    if (old.isNotEmpty) {
      final self = app.den.thisDevice!;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remove your old phone', style: t.rowTitle(c.ink)),
            const SizedBox(height: 2),
            Text(
              letIn!.kind == RecoveryKind.hub
                  ? "This phone was let in by the hub's recovery on ${RecoveryLines.when(app, self)}. "
                      'Your old one still has the family on it.'
                  : 'This phone was let in with your recovery words on ${RecoveryLines.when(app, self)}. '
                      'Your old one still has the family on it.',
              style: t.meta(c.ink2),
            ),
          ],
        ),
      ));
      for (final d in old) {
        final removing = _removing == d.id;
        rows.add(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  Icon(PhosphorIconsRegular.deviceMobile, size: 22, color: c.ink),
                  const SizedBox(width: 14),
                  Expanded(child: Text(d.name, style: t.body(c.ink))),
                  if (!removing)
                    TextButton(
                      onPressed: _busy ? null : () => setState(() => _removing = d.id),
                      style: TextButton.styleFrom(foregroundColor: c.destructive),
                      child: const Text('Remove', maxLines: 1, softWrap: false),
                    ),
                ],
              ),
            ),
            DenReveal(
              visible: removing,
              child: !removing
                  ? const SizedBox(width: double.infinity)
                  : ConfirmPanel(
                      message: '${d.name} stops syncing right away and forgets the family, wherever it is.',
                      confirmLabel: 'Remove ${d.name}',
                      destructive: true,
                      busy: _busy,
                      error: _error,
                      onConfirm: () => _remove(d),
                      onCancel: () => setState(() {
                        _removing = null;
                        _error = null;
                      }),
                    ),
            ),
          ],
        ));
      }
    }

    rows.add(Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(PhosphorIconsRegular.key, size: 22, color: c.ink),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(has ? 'Your words are set up' : 'Not set up yet', style: t.rowTitle(c.ink)),
                    const SizedBox(height: 2),
                    Text(
                      has
                          ? 'If you lose this phone, they let a new one in as you.'
                          : 'If you lose this phone, 12 words let a new one in as you.',
                      style: t.meta(c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.m),
          if (!_replacing)
            Align(
              alignment: Alignment.centerLeft,
              child: has
                  ? OutlinedButton(onPressed: () => setState(() => _replacing = true), child: const Text('Make new words'))
                  : FilledButton(onPressed: _make, child: const Text('Make my words')),
            ),
          DenReveal(
            visible: _replacing,
            child: !_replacing
                ? const SizedBox(width: double.infinity)
                : ConfirmPanel(
                    message: 'Your old words stop working once you save the new ones.',
                    confirmLabel: 'Make new words',
                    onConfirm: _make,
                    onCancel: () => setState(() => _replacing = false),
                  ),
          ),
          if (_done != null) ...[
            const SizedBox(height: Sp.s),
            NoticeLine(icon: PhosphorIconsRegular.check, message: _done!),
          ],
        ],
      ),
    ));

    return DenSection(
      title: 'Recovery words',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: ruled(rows, indent: 0)),
    );
  }
}

/// Twelve new words for [member] in a sheet: Save to Passwords, then I wrote them down, which
/// writes their recovery key. Returns whether they were saved.
Future<bool> showRecoveryWordsSheet(BuildContext context, Member member) async {
  final saved = await showDenSheet<bool>(context, builder: (_) => _WordsSheet(member: member));
  return saved ?? false;
}

class _WordsSheet extends StatefulWidget {
  const _WordsSheet({required this.member});
  final Member member;

  @override
  State<_WordsSheet> createState() => _WordsSheetState();
}

class _WordsSheetState extends State<_WordsSheet> {
  final _words = Recovery.newWords();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await saveRecoveryWords(context, widget.member, _words);
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader(title: 'Save these 12 words'),
          RecoveryWordsView(words: _words, member: widget.member),
          const SizedBox(height: DenLayout.sectionGap),
          if (_error != null) ...[
            ErrorState(message: _error!, actionLabel: 'Try again', onAction: _save),
            const SizedBox(height: Sp.m),
          ],
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text(_busy ? 'Saving' : 'I wrote them down'),
          ),
        ],
      ),
    );
  }
}

/// Stretches [words] to [member]'s recovery key and writes it, on their own device; null when it
/// saved, else why not. The stretch takes a moment, so the button can say Saving first.
Future<String?> saveRecoveryWords(BuildContext context, Member member, List<String> words) async {
  final trust = context.trustActions;
  // Let the frame that says Saving go out before the stretch takes its moment.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return tryWrite(() async => trust.setRecoveryKey(member.id, await Recovery.publicKey(words)));
}

/// The 12 words, numbered, with Save to Passwords (the share sheet, or a copy where there's
/// none). Used on the parent's page and when a family is started.
class RecoveryWordsView extends StatefulWidget {
  const RecoveryWordsView({super.key, required this.words, required this.member});

  final List<String> words;

  /// Whose they are, for the note they're saved with.
  final Member member;

  @override
  State<RecoveryWordsView> createState() => _RecoveryWordsViewState();
}

class _RecoveryWordsViewState extends State<RecoveryWordsView> {
  String? _note;

  /// What's saved: a title, the words one per line with numbers, and how to use them.
  String _text(String? family) {
    final title = family == null || family.isEmpty
        ? 'Den recovery words for ${widget.member.name}'
        : 'Den recovery words for ${widget.member.name} ($family)';
    return [
      title,
      '',
      for (final (i, w) in widget.words.indexed) '${i + 1}. $w',
      '',
      'If you lose your phone, open Den on a new one, choose "I lost my phone" and type these words. '
          'Anyone with them can get in as you, so keep them private.',
    ].join('\n');
  }

  /// Straight from the tap: browsers open the share sheet only for a user gesture.
  Future<void> _share(Rect? origin) async {
    final text = _text(DenScope.read(context).den.family?.name);
    if (Capabilities.web) {
      final outcome = await WebApp.share(text);
      if (!mounted) return;
      setState(() => _note = switch (outcome) {
            ShareOutcome.shared => 'Sent. Check they landed in Passwords or Notes.',
            ShareOutcome.copied => 'Copied. Paste them into Passwords or Notes.',
            ShareOutcome.failed => "Couldn't open the share sheet. Write them down instead.",
            ShareOutcome.cancelled => _note,
          });
      return;
    }
    if (Capabilities.mobile || Capabilities.macOS) {
      final result = await SharePlus.instance.share(ShareParams(text: text, subject: 'Den recovery words', sharePositionOrigin: origin));
      if (mounted && result.status != ShareResultStatus.dismissed) {
        setState(() => _note = 'Sent. Check they landed in Passwords or Notes.');
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => _note = 'Copied. Paste them into Passwords or Notes.');
  }

  /// Straight from the tap: browsers copy only for a user gesture.
  Future<void> _copy() async {
    final text = _text(DenScope.read(context).den.family?.name);
    final copied = Capabilities.web ? await WebApp.copy(text) : await Clipboard.setData(ClipboardData(text: text)).then((_) => true);
    if (mounted) {
      setState(() => _note = copied ? 'Copied. Paste them into Passwords or Notes.' : "Couldn't copy them. Write them down instead.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final scaler = MediaQuery.textScalerOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tidy('Keep them somewhere safe, like Passwords or on paper. If you lose your phone, they let a new one in '
              'as you. Anyone with them could too, so keep them to yourself.'),
          style: t.body(c.ink2),
        ),
        const SizedBox(height: Sp.l),
        GroupCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.m),
            child: SelectionArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  final columns = box.maxWidth >= scaler.scale(150) * 2 ? 2 : 1;
                  final perColumn = (widget.words.length / columns).ceil();
                  Widget word(int i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: Sp.s),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            SizedBox(
                              width: scaler.scale(28),
                              child: Text('${i + 1}', style: t.meta(c.ink2)),
                            ),
                            Expanded(child: Text(widget.words[i], style: t.rowTitle(c.ink))),
                          ],
                        ),
                      );
                  return Semantics(
                    label: [for (final (i, w) in widget.words.indexed) '${i + 1}, $w'].join('. '),
                    excludeSemantics: true,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var col = 0; col < columns; col++)
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = col * perColumn; i < (col + 1) * perColumn && i < widget.words.length; i++) word(i),
                              ],
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: Sp.m),
        Wrap(
          spacing: Sp.s,
          runSpacing: Sp.s,
          children: [
            Builder(
              builder: (button) => OutlinedButton.icon(
                onPressed: () {
                  final box = button.findRenderObject() as RenderBox?;
                  _share(box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                },
                icon: Icon(PhosphorIconsRegular.key, size: 20, color: c.ink),
                label: const Text('Save to Passwords', maxLines: 1, softWrap: false),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _copy,
              icon: Icon(PhosphorIconsRegular.copy, size: 20, color: c.ink),
              label: const Text('Copy', maxLines: 1, softWrap: false),
            ),
          ],
        ),
        if (_note != null) ...[
          const SizedBox(height: Sp.s),
          NoticeLine(icon: PhosphorIconsRegular.check, message: _note!),
        ],
      ],
    );
  }
}
