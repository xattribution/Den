import 'dart:convert';

import 'package:den_assistant/den_assistant.dart' show ModelProvider, modelInfo, usageFrom;
import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:http/http.dart' as http;

import 'context.dart';

/// What the family's AI costs and how much each kid used it today, for the limits a parent sets
/// in `family.assistant`: one monthly budget and one daily limit for a kid, covering both the
/// assistant's model requests (`/api/v1/assistant/model`) and what the hub's reader reads for
/// devices, apps and assistants (captures). Kept in `<data>/hub/assistant_usage.json`.
class AiUsage {
  /// The usage of the family [hub] serves.
  AiUsage(this.hub);

  /// Shared hub context.
  final HubContext hub;

  /// The share of the month's budget at which parents are warned.
  static const double warnAt = 0.8;

  static const String _doc = 'assistant_usage';

  Map<String, Object?> get _usage => hub.state.read(_doc);

  /// The family's rules.
  AssistantPolicy get policy => hub.den.family?.assistant ?? const AssistantPolicy();

  String get _today => hub.den.todayDate();

  String get _month => _today.substring(0, 7);

  int _monthly(String key) => _usage['month'] == _month ? (_usage[key] as int? ?? 0) : 0;

  /// Micro-dollars spent this month, captures included.
  int get spentMicros => _monthly('spent_micros');

  /// Micro-dollars of [spentMicros] that reading captures cost.
  int get captureMicros => _monthly('capture_micros');

  /// Captures the hub's reader read this month.
  int get captureReads => _monthly('capture_reads');

  /// Whether this month's budget is used up.
  bool get budgetSpent => spentMicros >= policy.budgetCents * 10000;

  int _daily(String key, String member) {
    final u = _usage;
    if (u['day'] != _today) return 0;
    return ((u[key] as Map?)?[member] as int?) ?? 0;
  }

  /// What kid [member] used today: questions to the assistant and captures read for them.
  int usedToday(String member) => _daily('turns', member);

  /// Of [usedToday], the captures.
  int capturesToday(String member) => _daily('captures', member);

  /// Whether kid [member] has used up today.
  bool dayUsedUp(String member) => usedToday(member) >= policy.kidDailyLimit;

  /// Counts one request toward kid [member]'s day ([capture]: a capture read for them).
  Future<void> countFor(String member, {bool capture = false}) {
    final u = _usage;
    final today = _today;
    if (u['day'] != today) {
      u['day'] = today;
      u['turns'] = <String, Object?>{};
      u['captures'] = <String, Object?>{};
    }
    void bump(String key) {
      final m = ((u[key] as Map?) ?? const {}).cast<String, Object?>();
      u[key] = {...m, member: ((m[member] as int?) ?? 0) + 1};
    }

    bump('turns');
    if (capture) bump('captures');
    return hub.state.save(_doc, u);
  }

  void _thisMonth(Map<String, Object?> u) {
    final month = _month;
    if (u['month'] == month) return;
    u
      ..['month'] = month
      ..['spent_micros'] = 0
      ..['capture_micros'] = 0
      ..['capture_reads'] = 0
      ..['warned'] = false;
  }

  /// Counts one capture the hub's reader read.
  Future<void> countCapture() {
    final u = _usage;
    _thisMonth(u);
    u['capture_reads'] = (u['capture_reads'] as int? ?? 0) + 1;
    return hub.state.save(_doc, u);
  }

  /// Adds [micros] to the month ([capture]: a capture's reading), and warns parents in the log
  /// at [warnAt] of the budget.
  Future<void> spend(int micros, {bool capture = false}) {
    final u = _usage;
    _thisMonth(u);
    final spent = (u['spent_micros'] as int? ?? 0) + micros;
    u['spent_micros'] = spent;
    if (capture) u['capture_micros'] = (u['capture_micros'] as int? ?? 0) + micros;
    final budget = policy.budgetCents * 10000;
    if (budget > 0 && spent >= budget * warnAt && u['warned'] != true) {
      u['warned'] = true;
      hub.log.warn('The family\'s AI has used ${(spent * 100 / budget).floor()}% of this month\'s budget');
    }
    return hub.state.save(_doc, u);
  }

  /// The month for `GET /api/v1/assistant`; [free] when the assistant runs on a model at home,
  /// [captureFree] when the reader does.
  Map<String, Object?> monthJson({required bool free, required bool captureFree}) {
    final budget = policy.budgetCents;
    final spent = spentMicros;
    return {
      'month': _month,
      'spent_cents': (spent / 10000).ceil(),
      'budget_cents': budget,
      'warn': budget > 0 && spent >= budget * 10000 * warnAt,
      'stopped': !free && budgetSpent,
      'captures': {
        'reads': captureReads,
        'spent_cents': (captureMicros / 10000).ceil(),
        'stopped': !captureFree && budgetSpent,
      },
    };
  }
}

/// The hub's capture reader with the family's budget around it: a paid reader reads nothing
/// once the month's budget is spent, and every read counts, with what it cost.
class BudgetedReader implements CaptureReader {
  /// Wraps [inner]; [paid] when it runs on a provider's servers.
  BudgetedReader(this.inner, this.usage, {required this.paid});

  /// The reader the family set up.
  final CaptureReader inner;

  /// Where it counts.
  final AiUsage usage;

  /// Whether reading costs money.
  final bool paid;

  /// What a read says once the month's budget is spent.
  static const String spentMessage = 'Reading with Claude has used this month\'s AI budget. A parent can raise it '
      'in Settings, AI helper, or it starts again next month.';

  @override
  ReaderInfo get info => inner.info;

  @override
  Future<bool> available() => inner.available();

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    if (paid && usage.budgetSpent) throw const ReaderException(spentMessage);
    await usage.countCapture();
    return inner.read(request);
  }
}

/// An HTTP client to Anthropic that adds what each successful Messages API answer cost, at
/// [model]'s price, to the family's AI budget as a capture's reading.
class MeteredClient extends http.BaseClient {
  /// Meters [inner]'s answers.
  MeteredClient(this.inner, this.usage, this.model);

  /// Where requests go.
  final http.Client inner;

  /// Where the cost goes.
  final AiUsage usage;

  /// The model the reader uses, for its price.
  final String model;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (response.statusCode != 200) return response;
    final bytes = await response.stream.toBytes();
    try {
      final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (json is Map) {
        final cost = usageFrom(ModelProvider.anthropic, json.cast<String, Object?>())
            .costUsd(modelInfo(ModelProvider.anthropic, model).price);
        if (cost > 0) await usage.spend((cost * 1000000).round(), capture: true);
      }
    } on FormatException {
      // Not JSON: the reader says so; nothing to count.
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
