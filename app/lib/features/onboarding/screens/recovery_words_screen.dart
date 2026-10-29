import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../family/family.dart';

/// Right after starting a family: the founding parent's 12 recovery words, to save before
/// anything else, since theirs is the only device that can let anyone in yet. "I wrote them
/// down" saves them and moves on to "Add people"; "Not now" leaves them for their page in
/// Family.
class RecoveryWordsScreen extends StatefulWidget {
  const RecoveryWordsScreen({super.key, this.words});

  /// The words to show, for tests and screenshots; new ones by default.
  final List<String>? words;

  @override
  State<RecoveryWordsScreen> createState() => _RecoveryWordsScreenState();
}

class _RecoveryWordsScreenState extends State<RecoveryWordsScreen> {
  late final List<String> _words = widget.words ?? Recovery.newWords();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    final me = DenScope.read(context).me;
    if (me == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await saveRecoveryWords(context, me, _words);
    if (!mounted) return;
    if (problem == null) {
      context.go('/welcome/people');
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final me = app.me;
    return DenPage(
      title: 'Save these 12 words',
      back: false,
      bottom: FilledButton(
        onPressed: _busy || me == null ? null : _save,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        child: Text(_busy ? 'Saving' : 'I wrote them down'),
      ),
      children: [
        if (me != null) RecoveryWordsView(words: _words, member: me),
        if (_error != null) ErrorState(message: _error!, actionLabel: 'Try again', onAction: _save),
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.s),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _busy ? null : () => context.go('/welcome/people'),
              child: const Text('Not now'),
            ),
          ),
        ),
      ],
    );
  }
}
