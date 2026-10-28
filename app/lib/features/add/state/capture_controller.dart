import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/foundation.dart';

import 'capture_service.dart';

enum CaptureStage { reading, failed, ready }

/// One capture from reading to adding: what was found, what the person has chosen, what has
/// been added and can be taken back. With the family's `capture` set to `direct`, entries that
/// need no look are added as soon as they're read; with `review`, nothing is added until the
/// person says so.
class CaptureController extends ChangeNotifier {
  CaptureController({required this.service, required this.den, required this.input, CaptureResult? result})
      : _result = result {
    if (result != null) _take(result);
  }

  final CaptureService service;
  final Den den;
  final CaptureInput input;

  CaptureStage _stage = CaptureStage.reading;
  CaptureStage get stage => _stage;

  CaptureResult? _result;
  CaptureResult? get result => _result;

  CaptureDraft? _draft;
  CaptureDraft? get draft => _draft;

  String? _error;
  String? get error => _error;
  bool _retry = false;
  bool get canRetry => _retry;

  final Set<String> chosen = {};
  final Set<String> added = {};
  final List<CaptureReceipt> receipts = [];

  /// The record each added entry became, by entry key.
  final Map<String, Added> records = {};
  bool _busy = false;
  bool get busy => _busy;
  bool _disposed = false;

  /// Whether ready entries are added without asking (the family's `capture` setting).
  bool get direct => !(den.family?.captureNeedsReview ?? false);

  /// What's still waiting: entries not added yet, in the draft's order.
  List<DraftEntry> get tray => [for (final e in _draft?.entries ?? const <DraftEntry>[]) if (!added.contains(e.key)) e];

  int get addedCount => added.length;

  /// Entries already added, in the draft's order.
  List<DraftEntry> get done => [for (final e in _draft?.entries ?? const <DraftEntry>[]) if (added.contains(e.key)) e];

  /// Reads the input (unless a result was given) and, in direct mode, adds what needs no look.
  Future<void> start() async {
    if (_result == null) {
      _stage = CaptureStage.reading;
      _error = null;
      _notify();
      try {
        _take(await service.read(input, den));
      } on ReaderException catch (e) {
        _stage = CaptureStage.failed;
        _error = e.message;
        _retry = e.retry;
        _notify();
        return;
      }
    }
    _notify();
    if (direct && chosen.isNotEmpty) await add();
  }

  void _take(CaptureResult result) {
    _result = result;
    _draft = result.draft;
    _stage = CaptureStage.ready;
    chosen
      ..clear()
      ..addAll([for (final e in result.draft.entries) if (e.ready) e.key]);
  }

  /// Adds [keys] (the chosen entries by default). Entries the engine refuses stay, with why.
  Future<void> add([Iterable<String>? keys]) async {
    final draft = _draft;
    if (draft == null || _busy) return;
    final which = (keys ?? chosen).toSet();
    if (which.isEmpty) return;
    _busy = true;
    _notify();
    try {
      final receipt = await writeDraft(den, draft, keys: which);
      receipts.add(receipt);
      added.addAll(receipt.keys);
      for (final a in receipt.added) {
        if (a.key != null) records[a.key!] = a;
      }
      chosen.removeAll(receipt.keys);
      var next = checkDraft(den, draft);
      for (final f in receipt.failed.entries) {
        final e = next.entry(f.key);
        if (e != null) next = next.replace(e.withIssues([...e.issues, DraftIssue(IssueKind.invalid, f.value)]));
        chosen.remove(f.key);
      }
      _draft = next;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// Takes back everything this capture added; it all waits in the tray again.
  Future<void> undo() async {
    if (_busy || receipts.isEmpty) return;
    _busy = true;
    _notify();
    try {
      for (final r in receipts.reversed) {
        await r.undo(den);
      }
      receipts.clear();
      added.clear();
      records.clear();
      if (_draft != null) _draft = checkDraft(den, _draft!);
    } finally {
      _busy = false;
      _notify();
    }
  }

  void toggle(String key) {
    if (!chosen.remove(key)) {
      final e = _draft?.entry(key);
      if (e == null || e.blocked) return;
      chosen.add(key);
    }
    _notify();
  }

  /// Puts an edited entry in place of its original, checks it again and chooses it when it can
  /// be added.
  void edit(DraftEntry entry) {
    final draft = _draft;
    if (draft == null) return;
    final next = checkDraft(den, draft.replace(entry));
    _draft = next;
    final e = next.entry(entry.key)!;
    if (e.blocked) {
      chosen.remove(e.key);
    } else {
      chosen.add(e.key);
    }
    _notify();
  }

  void remove(String key) {
    final draft = _draft;
    if (draft == null) return;
    _draft = draft.remove(key);
    chosen.remove(key);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
