import 'dart:async';
import 'dart:math';

import 'package:den_core/den_core.dart';

import 'context.dart';
import 'input.dart';
import 'privacy.dart';
import 'resolve.dart';
import 'schema.dart';
import 'spec.dart';
import 'times.dart';

class _Kept {
  _Kept(this.receipt, this.caller);
  final Receipt receipt;
  final String caller;
  bool undone = false;
}

class _Pending {
  _Pending(this.caller, this.tool, this.key, this.expires);
  final String caller;
  final String tool;
  final String key;
  final int expires;
}

/// Runs actions for every surface: checks the surface, the caller's scopes and permissions,
/// checks and reshapes the input, previews on a fork of the engine, asks for confirmation
/// where a spec says so, records what each write changed as a [Receipt], and turns the
/// engine's refusals into answers the caller can act on.
///
/// The engine must already act as the caller (`DenGate.run` on the hub, the device's own person
/// in the app). One runner serves every call on an engine: it keeps the receipts and
/// confirmation tokens it hands out (in memory, the newest [maxReceipts]).
class ActionRunner {
  /// A runner for [specs], with [aliases] for older names.
  ActionRunner(
    Iterable<ActionSpec> specs, {
    Iterable<ActionAlias> aliases = const [],
    this.maxReceipts = 500,
    this.confirmFor = const Duration(minutes: 10),
    Random? random,
  })  : _specs = {for (final s in specs) s.mcpName: s},
        _aliases = {for (final a in aliases) a.name: a},
        _random = random ?? Random.secure() {
    for (final s in _specs.values) {
      _byName[s.name] = s;
    }
  }

  final Map<String, ActionSpec> _specs;
  final Map<String, ActionSpec> _byName = {};
  final Map<String, ActionAlias> _aliases;
  final Random _random;
  final Map<String, _Kept> _receipts = {};
  final Map<String, _Pending> _tokens = {};

  /// Most receipts kept.
  final int maxReceipts;

  /// How long a confirmation token works.
  final Duration confirmFor;

  /// Every action, in the order given.
  List<ActionSpec> get specs => _specs.values.toList();

  /// Older names, still callable.
  List<ActionAlias> get aliases => _aliases.values.toList();

  /// The action [name] names: an MCP name, a dotted name, or an alias.
  ActionSpec? spec(String name) => _specs[name] ?? _byName[name] ?? _specs[_aliases[name]?.target];

  /// Why [c] can't use [s], or null when it can: not offered on its surface, a scope its
  /// connection lacks, or something its person isn't allowed.
  ActionResult? refusal(ActionContext c, ActionSpec s) {
    if (!s.surfaces.contains(c.surface)) {
      return ActionResult.failed('Den doesn\'t offer ${s.mcpName} here.', code: 'unknown_action');
    }
    if (!s.scopes.any(c.has)) {
      final names = [for (final scope in Scope.values) if (s.scopes.contains(scope)) '"${scope.name}"'];
      final which = names.length == 1 ? 'the ${names.single} scope' : 'any of the ${names.join(', ')} scopes';
      return ActionResult.failed(
        'This connection doesn\'t have $which, which ${s.mcpName} needs. A parent can change that in the Den app: '
        'Settings → AI and automations.',
        code: 'insufficient_scope',
        details: {'scope': s.scopes.first.name},
      );
    }
    if (!s.readOnly && c.member == null && c.den.thisDevice?.mode == DeviceMode.hub) {
      return ActionResult.failed(
        'This connection doesn\'t act for anyone in the family, so it only reads. A parent can choose who it acts as '
        'in the Den app: Settings → AI and automations.',
        code: 'permission_denied',
      );
    }
    if (s.person && c.me == null) {
      return ActionResult.failed('${s.mcpName} is for a person, and this connection doesn\'t act for anyone.', code: 'permission_denied');
    }
    if (s.needs.isNotEmpty && !s.needs.any(c.can)) {
      return ActionResult.failed(cannot(c.who, s.needs.first), code: 'permission_denied');
    }
    return null;
  }

  /// The actions [c] may use, for `tools/list` and `GET /api/v1/actions`.
  List<ActionSpec> available(ActionContext c) => [for (final s in _specs.values) if (refusal(c, s) == null) s];

  /// What someone who may not [action] is told.
  static String cannot(String who, DenAction action) => switch (action) {
        DenAction.editEvents => '$who can\'t add or change events',
        DenAction.editChores => '$who can\'t add or change chores',
        DenAction.editLists => '$who can\'t add or change lists',
        DenAction.checkItems => '$who can\'t check items',
        DenAction.completeOwnChore => '$who can\'t complete chores',
        DenAction.completeAnyChore => '$who can\'t complete someone else\'s chore',
        DenAction.swapChore => '$who can\'t swap chores',
        DenAction.managePoints => '$who can\'t give or take stars, or change goals and rewards',
        DenAction.requestReward => '$who can\'t ask for rewards',
        DenAction.manageFamily => 'Only a parent can change the family\'s people and settings',
      };

  /// Runs action [name] with [args] for [c].
  Future<ActionResult> run(ActionContext c, String name, Map<String, Object?>? args, {RunMode mode = RunMode.run}) async {
    c.runner = this;
    c.asked = null;
    c.shownZones.clear();
    final s = spec(name);
    if (s == null) return ActionResult.failed('Den has no action called "$name".', code: 'unknown_action');
    final refused = refusal(c, s);
    if (refused != null) return refused;
    var raw = Map<String, Object?>.of(args ?? const {});
    final adapt = _aliases[name]?.adapt;
    if (adapt != null) raw = adapt(raw);
    final prepare = s.prepare;
    if (prepare != null) raw = prepare(raw);
    final ActionInput input;
    var preview = mode == RunMode.preview;
    String? token;
    try {
      final checked = normalizeInput(s.inputSchema, raw);
      if (checked.remove('preview') == true) preview = true;
      token = checked.remove('confirm') as String?;
      if (s.readOnly) {
        final zone = (checked.remove('timezone') as String?)?.trim();
        if (zone != null && zone.isNotEmpty) {
          if (!isZone(zone)) throw ActionError('Den doesn\'t know the time zone "$zone".', field: 'timezone');
          c.asked = zone;
        }
      }
      input = ActionInput(checked);
    } on ActionError catch (e) {
      return _failed(e);
    }
    if (s.readOnly) return _labeled(c, await _guard(() => s.run(c, input)));
    if (preview) return _labeled(c, await _preview(c, s, input));
    if (mode == RunMode.run && asks(c, s, input)) {
      if (token == null || !_consume(token, c, s, input)) return _labeled(c, await _needsYes(c, s, input, stale: token != null));
    }
    return _labeled(c, await _write(c, s, input));
  }

  /// [r] with the line saying which zone its times are in, when the caller lives in another
  /// zone than the family's or asked for one, and with its warnings said.
  static ActionResult _labeled(ActionContext c, ActionResult r) {
    if (r.isError) return r;
    final line = c.zoneLine;
    final warnings = [for (final w in r.data['warnings'] as List? ?? const []) '$w'];
    final said = r.status == ActionStatus.done && warnings.isNotEmpty;
    if (line == null && !said) return r;
    final text = [
      r.text,
      if (said)
        for (final w in warnings) 'Note: $w',
      ?line,
    ].join('\n');
    return ActionResult(text, r.data, receipt: r.receipt, status: r.status, code: r.code, message: r.message);
  }

  /// Whether a call of [s] with [input] needs a yes before it runs, for [c]'s surface: always
  /// for [Confirm.server] (when its test holds), and for [Confirm.client] in the assistant.
  bool asks(ActionContext c, ActionSpec s, ActionInput input) {
    if (s.confirm == Confirm.none) return false;
    if (s.confirm == Confirm.client && c.surface != Surface.assistant) return false;
    final when = s.confirmWhen;
    if (when == null) return true;
    try {
      return when(c, input);
    } on Object {
      return true;
    }
  }

  Future<ActionResult> _guard(FutureOr<ActionResult> Function() body) async {
    try {
      return await body();
    } on ActionError catch (e) {
      return _failed(e);
    } on PermissionDenied catch (e) {
      return ActionResult.failed(e.message, code: 'permission_denied');
    } on InvalidInput catch (e) {
      return ActionResult.failed(e.message);
    }
  }

  static ActionResult _failed(ActionError e) =>
      ActionResult.failed(e.message, code: e.code, field: e.field, details: e.details);

  Future<ActionResult> _write(ActionContext c, ActionSpec s, ActionInput input) => _guard(() async {
        // What a change to the calendar newly leaves uncovered (a ride nobody drives, a driver in
        // two places, someone double-booked) is said with it, as a preview would.
        final before = s.scopes.contains(Scope.calendar) ? _gapMessages(c) : null;
        final r = await c.den.recording(() => s.run(c, input), undoOnError: true);
        var result = r.value;
        if (result.isError || r.changes.isEmpty) return result;
        if (before != null) {
          final fresh = [for (final g in _gapMessages(c)) if (!before.contains(g)) g];
          if (fresh.isNotEmpty) result = withWarnings(result, fresh);
        }
        return result.withReceipt(_keep(c, s, result, r.changes));
      });

  /// [r] with [more] added to its `warnings`.
  static ActionResult withWarnings(ActionResult r, List<String> more) {
    final had = [for (final w in r.data['warnings'] as List? ?? const []) '$w'];
    final all = [...had, for (final w in more) if (!had.contains(w)) w];
    return ActionResult(r.text, {...r.data, 'warnings': all}, receipt: r.receipt, status: r.status, code: r.code, message: r.message);
  }

  String _newId(String prefix) {
    final bytes = List<int>.generate(12, (_) => _random.nextInt(256));
    return '${prefix}_${b64e(bytes)}';
  }

  static String _firstLine(String text) {
    final line = text.trim().split('\n').first;
    return line.length > 300 ? '${line.substring(0, 297)}...' : line;
  }

  Receipt _keep(ActionContext c, ActionSpec s, ActionResult result, List<String> changes) {
    final receipt = Receipt(
      id: _newId('r'),
      summary: _firstLine(result.text),
      undoable: c.den.canUndo(changes),
      tool: s.mcpName,
      changes: changes,
    );
    _receipts[receipt.id] = _Kept(receipt, c.caller);
    while (_receipts.length > maxReceipts) {
      _receipts.remove(_receipts.keys.first);
    }
    return receipt;
  }

  /// The receipt [id] if [c]'s caller got it and it isn't undone yet.
  Receipt? receipt(ActionContext c, String id) {
    final kept = _receipts[id];
    return kept == null || kept.caller != c.caller || kept.undone ? null : kept.receipt;
  }

  /// [c]'s caller's newest receipt that undo can still take back, other than an undo's own.
  Receipt? lastReceipt(ActionContext c) {
    for (final kept in _receipts.values.toList().reversed) {
      if (kept.caller == c.caller && !kept.undone && kept.receipt.tool != 'undo' && kept.receipt.undoable) return kept.receipt;
    }
    return null;
  }

  /// Marks the receipt [id] taken back.
  void markUndone(String id) => _receipts[id]?.undone = true;

  Future<ActionResult> _preview(ActionContext c, ActionSpec s, ActionInput input) async {
    final fork = await c.den.fork();
    try {
      final fc = c.on(fork);
      final r = await fork.recording(() => _guard(() => s.run(fc, input)));
      c.shownZones.addAll(fc.shownZones);
      final result = r.value;
      if (result.isError) return result;
      final entries = fork.historyOf(r.changes);
      final warnings = <String>{
        for (final w in result.data['warnings'] as List? ?? const []) '$w',
        ..._newGaps(c, fc),
        ..._duplicates(c, fork, entries),
      }.toList();
      final summary = _firstLine(result.text);
      String question;
      try {
        question = s.ask?.call(c, input) ?? 'Go ahead? $summary';
      } on Object {
        question = 'Go ahead? $summary';
      }
      return ActionResult(
        [
          'Nothing changed yet. This would: $summary',
          for (final w in warnings) 'Note: $w',
        ].join('\n'),
        {
          'preview': {
            'summary': summary,
            'question': question,
            'changes': [
              for (final h in entries)
                {'type': h.type, 'id': h.rid, 'title': h.title, 'verb': h.verb, 'fields': [for (final d in h.diffs) d.field]},
            ],
            'warnings': warnings,
          },
        },
        status: ActionStatus.preview,
      );
    } finally {
      await fork.close();
    }
  }

  /// Gaps (missing drivers, overlaps) in the next two weeks that [after] has and [before]
  /// doesn't.
  static List<String> _newGaps(ActionContext before, ActionContext after) {
    final had = _gapMessages(before);
    return [for (final g in _gapMessages(after)) if (!had.contains(g)) g];
  }

  /// What needs someone in the next two weeks, as [c] may see it: missing drivers, drivers in
  /// two places, people in two places.
  static Set<String> _gapMessages(ActionContext c) {
    final start = c.den.dayStart(c.today);
    final end = start + 15 * Duration.millisecondsPerDay;
    return {
      for (final g in visibleGaps(c.den, c.den.gaps(start, end), c.readable))
        if (g.kind != GapKind.unowned) g.message,
    };
  }

  static List<String> _duplicates(ActionContext c, Den fork, List<HistoryEntry> entries) {
    final out = <String>[];
    for (final h in entries) {
      if (h.verb != 'added') continue;
      final title = h.title.trim().toLowerCase();
      bool same(String other) => other.trim().toLowerCase() == title;
      switch (h.type) {
        case RecordType.event:
          final e = fork.event(h.rid);
          if (e != null && c.events.any((x) => same(x.title) && x.start == e.start)) {
            out.add('${h.title} is already on the calendar then.');
          }
        // Chores, lists, rewards and categories of a name the family has say so themselves.
        case RecordType.item:
          String? listOf(Den den) {
            for (final l in den.lists) {
              if (l.items.any((i) => i.id == h.rid)) return l.list.id;
            }
            return null;
          }
          final list = listOf(fork);
          final onIt = c.lists.where((l) => l.list.id == list).expand((l) => l.items);
          if (onIt.any((i) => !i.checked && same(i.text))) out.add('${h.title} is already on that list.');
      }
    }
    return out;
  }

  static String _key(ActionSpec s, ActionInput input) => '${s.mcpName} ${canonicalJson(input.raw)}';

  /// Uses up [token] when [c]'s caller got it for exactly this call and it hasn't run out.
  bool _consume(String token, ActionContext c, ActionSpec s, ActionInput input) {
    final pending = _tokens[token];
    if (pending == null || pending.caller != c.caller) return false;
    if (pending.expires <= c.den.now()) {
      _tokens.remove(token);
      return false;
    }
    if (pending.tool != s.mcpName || pending.key != _key(s, input)) return false;
    _tokens.remove(token);
    return true;
  }

  Future<ActionResult> _needsYes(ActionContext c, ActionSpec s, ActionInput input, {required bool stale}) async {
    final preview = await _preview(c, s, input);
    if (preview.isError) return preview;
    final now = c.den.now();
    _tokens.removeWhere((_, p) => p.expires <= now);
    while (_tokens.length >= maxReceipts) {
      _tokens.remove(_tokens.keys.first);
    }
    final token = _newId('c');
    final expires = now + confirmFor.inMilliseconds;
    _tokens[token] = _Pending(c.caller, s.mcpName, _key(s, input), expires);
    final question = (preview.data['preview'] as Map)['question'] as String;
    return ActionResult(
      [
        if (stale) 'That confirmation didn\'t match or had run out, so nothing changed.',
        '$question Nothing has changed yet: ask first, then call ${s.mcpName} again with the same input and '
            '"confirm": "$token".',
      ].join(' '),
      {
        'confirm': {'token': token, 'question': question, 'expires_ms': expires},
        'preview': preview.data['preview'],
      },
      status: ActionStatus.needsConfirmation,
      code: 'confirmation_required',
    );
  }
}
