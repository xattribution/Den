import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';

import '../../../app/actions.dart';

/// Add's one sheet, as state: what the person typed or said, what Den's own reader (on this
/// device, no network) found in it as they go, and what was added, with its receipt for Undo.
///
/// Typing reads again a moment after the last key. "milk" becomes an item for the groceries;
/// "Soccer every Wednesday at 5 for Leo" an event with When, Who and Repeats to adjust. Adding
/// writes what's ready through [AppActions.record], so Undo takes exactly that back.
class QuickAdd extends ChangeNotifier {
  QuickAdd(this.actions, {this.delay = const Duration(milliseconds: 250)});

  final AppActions actions;

  /// How long after the last key Den reads again.
  final Duration delay;

  Den get den => actions.den;

  String _text = '';
  String get text => _text;

  bool _spoken = false;

  /// What the words were heard as, for History ("said out loud").
  bool get spoken => _spoken;

  CaptureDraft? _draft;

  /// What Den found; null before it has read anything.
  CaptureDraft? get draft => _draft;

  bool _reading = false;
  bool get reading => _reading;

  bool _adding = false;
  bool get adding => _adding;

  /// What the last add did, and how to take it back.
  AddedNote? _added;
  AddedNote? get added => _added;

  String? _problem;

  /// Why the last add or read didn't work, in words.
  String? get problem => _problem;

  Timer? _timer;
  int _seq = 0;
  bool _disposed = false;

  /// What's found and not held back by a question (an unknown name, a time Den guessed).
  List<DraftEntry> get ready => [for (final e in _draft?.entries ?? const <DraftEntry>[]) if (!e.blocked) e];

  /// What Den found that needs a person's look first.
  List<DraftEntry> get blocked => [for (final e in _draft?.entries ?? const <DraftEntry>[]) if (e.blocked) e];

  void setText(String text, {bool spoken = false}) {
    if (text == _text && spoken == _spoken) return;
    _text = text;
    _spoken = spoken;
    _problem = null;
    if (_added != null && text.trim().isNotEmpty) _added = null;
    _timer?.cancel();
    if (text.trim().isEmpty) {
      _seq++;
      _draft = null;
      _reading = false;
      _notify();
      return;
    }
    _timer = Timer(delay, read);
    _notify();
  }

  /// Reads the words now.
  Future<void> read() async {
    _timer?.cancel();
    final words = _text.trim();
    final seq = ++_seq;
    if (words.isEmpty) return;
    _reading = true;
    _notify();
    try {
      final input = _spoken ? CaptureInput.spoken(words) : CaptureInput.typed(words);
      final result = await Capturer(readers: [const RulesReader()]).read(input, den);
      if (seq != _seq || _disposed) return;
      _draft = result.draft;
    } on ReaderException catch (e) {
      if (seq != _seq || _disposed) return;
      _draft = null;
      _problem = e.message;
    } finally {
      if (seq == _seq && !_disposed) {
        _reading = false;
        _notify();
      }
    }
  }

  /// Puts [entry] (changed with a chip) in place of the one with its key, and checks it again.
  void replace(DraftEntry entry) {
    final draft = _draft;
    if (draft == null) return;
    _draft = checkDraft(den, draft.replace(entry));
    _notify();
  }

  /// Adds what's ready; the words clear and what was added shows with Undo.
  Future<bool> add() async {
    final draft = _draft;
    final keys = [for (final e in ready) e.key];
    if (draft == null || keys.isEmpty || _adding) return false;
    _adding = true;
    _problem = null;
    _notify();
    try {
      late final CaptureReceipt written;
      final receipt = await actions.record('Added from Add', () async {
        written = await writeDraft(den, draft, keys: keys);
      });
      if (written.added.isEmpty) {
        _problem = written.failed.values.firstOrNull ?? writeFailedMessage;
        return false;
      }
      _added = AddedNote(
        titles: [for (final a in written.added) a.title],
        entries: [for (final e in draft.entries) if (written.keys.contains(e.key)) e],
        receipt: receipt,
        text: _text,
        spoken: _spoken,
      );
      _seq++;
      _text = '';
      _draft = null;
      return true;
    } on PermissionDenied catch (e) {
      _problem = e.message;
      return false;
    } on InvalidInput catch (e) {
      _problem = e.message;
      return false;
    } on Object catch (e, stack) {
      debugPrint('Add failed: $e\n$stack');
      _problem = writeFailedMessage;
      return false;
    } finally {
      _adding = false;
      _notify();
    }
  }

  /// Takes back the last add; its words come back to change and add again.
  Future<bool> undo() async {
    final note = _added;
    final receipt = note?.receipt;
    if (note == null || receipt == null) return false;
    final result = await actions.undo(receipt);
    if (result.isError) {
      _problem = result.message ?? result.text;
      _notify();
      return false;
    }
    _added = null;
    setText(note.text, spoken: note.spoken);
    await read();
    return true;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// What an add did: the titles of what it added, the entries (to describe them), the receipt
/// Undo takes back, and the words, which Undo puts back.
class AddedNote {
  const AddedNote({required this.titles, required this.entries, required this.receipt, required this.text, required this.spoken});

  final List<String> titles;
  final List<DraftEntry> entries;
  final Receipt? receipt;
  final String text;
  final bool spoken;
}
