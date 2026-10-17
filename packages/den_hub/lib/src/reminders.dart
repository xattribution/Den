import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:den_core/den_core.dart';

import 'config.dart';
import 'context.dart';
import 'hub.dart';

/// One message for one person.
class Notice {
  /// Creates a notice.
  const Notice(this.title, this.body);

  /// Title line.
  final String title;

  /// Body text.
  final String body;
}

/// Reminders from the hub: every [HubConfig.reminderInterval] it asks the engine what comes due
/// next and sends each reminder once (keys kept in the hub's state) through Home Assistant's
/// `notify` service and ntfy. Items outside the family space reach ntfy only as "A reminder from
/// Den".
class ReminderService implements HubService {
  /// Creates the service for [hub].
  ReminderService(this.hub);

  /// Shared hub context.
  final HubContext hub;

  @override
  String get name => 'Reminders';

  Timer? _timer;
  final Map<String, Timer> _scheduled = {};

  Map<String, Object?> get _sent => hub.state.read('reminders');

  @override
  Future<void> start() async {
    _timer = Timer.periodic(hub.config.reminderInterval, (_) => unawaited(tick()));
    unawaited(tick());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    for (final t in _scheduled.values) {
      t.cancel();
    }
    _scheduled.clear();
  }

  bool get _configured =>
      hub.config.notify.values.any((n) => n.ntfyTopic != null || n.homeAssistantService != null);

  /// Looks ahead one interval and schedules what comes due.
  Future<void> tick() async {
    if (!hub.ready || !_configured) return;
    final now = hub.now();
    final from = now - const Duration(minutes: 2).inMilliseconds;
    final to = now + hub.config.reminderInterval.inMilliseconds + 5000;
    final due = await hub.gate.asHub(() => hub.den.remindersDue(from, to));
    _sent.removeWhere((_, at) => at is! int || at < now - const Duration(days: 3).inMilliseconds);
    for (final r in due) {
      if (_sent.containsKey(r.key) || _scheduled.containsKey(r.key)) continue;
      final wait = r.at - now;
      _scheduled[r.key] = Timer(Duration(milliseconds: wait < 0 ? 0 : wait), () => unawaited(_deliver(r)));
    }
  }

  Future<void> _deliver(ReminderDue r) async {
    _scheduled.remove(r.key);
    if (_sent.containsKey(r.key)) return;
    _sent[r.key] = r.at;
    await hub.state.save('reminders');
    final targets = await hub.gate.asHub(() => _targets(r));
    for (final t in targets) {
      await _send(t.$1, t.$2);
    }
  }

  /// Who gets [r] and what each target sees.
  List<(_Target, Notice)> _targets(ReminderDue r) {
    final den = hub.den;
    final parts = r.key.split(':');
    final id = parts.length > 1 ? parts[1] : '';
    final space = parts.first == 'chore' ? den.chore(id)?.space : den.event(id)?.space;
    if (space == null) return const [];
    final members = r.members.isEmpty ? den.members : [for (final m in r.members) ?den.member(m)];
    final out = <(_Target, Notice)>[];
    final full = Notice(r.title, r.body);
    const vague = Notice('Den', 'A reminder from Den');
    for (final m in members) {
      if (!canRead(m, space, den.family)) continue;
      final config = hub.config.notify[m.id] ??
          hub.config.notify.entries.firstWhereOrNull((e) => e.key.toLowerCase() == m.name.toLowerCase())?.value;
      if (config == null) continue;
      final service = config.homeAssistantService;
      if (service != null && hub.config.homeAssistantUrl != null && hub.config.homeAssistantToken != null) {
        out.add((_Target.ha(service), full));
      }
      final topic = config.ntfyTopic;
      if (topic != null) out.add((_Target.ntfy(topic), space == Space.family ? full : vague));
    }
    return out;
  }

  Future<void> _send(_Target target, Notice notice) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      int? status;
      try {
        final response = await (target.isHa ? _postHa(target.name, notice) : _postNtfy(target.name, notice))
            .timeout(const Duration(seconds: 15));
        status = response;
        if (status >= 200 && status < 300) return;
      } on Object catch (e) {
        hub.log.debug('${target.kind} notifier error: ${e.runtimeType}');
      }
      hub.log.warn('${target.kind} notifier failed${status == null ? '' : ' (HTTP $status)'}${attempt == 0 ? '; retrying once' : ''}');
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<int> _postHa(String service, Notice n) async {
    final base = hub.config.homeAssistantUrl!;
    final url = base.replace(path: '${base.path.replaceAll(RegExp(r'/$'), '')}/api/services/notify/$service');
    final r = await hub.http.post(
      url,
      headers: {'authorization': 'Bearer ${hub.config.homeAssistantToken}', 'content-type': 'application/json'},
      body: jsonEncode({'title': n.title, 'message': n.body}),
    );
    return r.statusCode;
  }

  Future<int> _postNtfy(String topic, Notice n) async {
    var base = Uri.parse('https://ntfy.sh');
    var name = topic;
    if (topic.contains('://')) {
      final u = Uri.parse(topic);
      base = Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null);
      name = u.pathSegments.where((s) => s.isNotEmpty).join('/');
    }
    final r = await hub.http.post(
      base,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'topic': name, 'title': n.title, 'message': n.body}),
    );
    return r.statusCode;
  }
}

class _Target {
  const _Target.ha(this.name) : isHa = true;
  const _Target.ntfy(this.name) : isHa = false;
  final String name;
  final bool isHa;
  String get kind => isHa ? 'Home Assistant' : 'ntfy';
}
