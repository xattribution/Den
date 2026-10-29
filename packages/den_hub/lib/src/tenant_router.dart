/// How a Den host picks the log a request or a connection is for (docs/hub-api.md, "One host,
/// several families"). Every choice here fails closed: a request that two logs could answer, or
/// none, gets no log, never "the first one". The one exception is a host configured for a
/// single family (a hub of its own, or a host whose `host.json` lists no other), whose one log
/// answers at any address, as a hub always has. That is decided by configuration, never by how
/// many logs happen to be attached at the moment: a host whose other families are still opening,
/// or failed to, never hands their requests to the one that is there.
///
/// Picking a log is not letting the request in: the log it goes to checks whatever it carries
/// (a device signature, a token, a calendar link's secret, an invite's words) against its own
/// records only. A wrong pick can only end in a refusal, never in another family's data.
library;

/// What the router needs to know about one log on the host.
abstract interface class RoutableLog {
  /// The family (or, later, group) the log holds; null while a fresh hub waits for setup.
  String? get familyId;

  /// The log's hub device: what `X-Den-Hub` and an invite grant name.
  String get hubDevice;

  /// The names requests come to it by (lower case): its public address's host.
  Set<String> get hostnames;
}

/// Picks logs for requests, over the host's logs as they are now.
class TenantRouter<T extends RoutableLog> {
  /// A router over [logs], read afresh on every choice (logs come and go while the host runs).
  /// [single] says whether the host is configured for one family (default: it isn't).
  TenantRouter(this._logs, {bool Function()? single}) : _single = single ?? _never;

  final Iterable<T> Function() _logs;
  final bool Function() _single;

  static bool _never() => false;

  /// The one log of a host configured for a single family, when it is attached; else null.
  T? _theOnly(List<T> all) => _single() && all.length == 1 ? all.single : null;

  /// The logs now.
  List<T> get logs => List.of(_logs());

  /// The one log among [matches], or null for none or several.
  static T? only<T>(Iterable<T> matches) {
    T? found;
    for (final m in matches) {
      if (found != null) return null;
      found = m;
    }
    return found;
  }

  /// The log whose address is [hostname]; null when none is, or (a mistake in the host's
  /// records) more than one.
  T? mapped(String? hostname) {
    if (hostname == null) return null;
    return only(logs.where((l) => l.hostnames.contains(hostname)));
  }

  /// The log for a request that carries nothing that names one: the one at [hostname], else, on
  /// a host configured for one family, that family; null otherwise.
  T? forHostname(String? hostname) {
    final all = logs;
    final at = hostname == null ? null : only(all.where((l) => l.hostnames.contains(hostname)));
    return at ?? _theOnly(all);
  }

  /// The log a session's hello is for: the one holding [family]. Should two hold it (a group's
  /// replicas, later), the one at [hostname] among them; else none.
  T? forFamily(String family, {String? hostname}) {
    final holding = [for (final l in logs) if (l.familyId == family) l];
    if (holding.length <= 1) return holding.firstOrNull;
    return hostname == null ? null : only(holding.where((l) => l.hostnames.contains(hostname)));
  }

  /// The log whose hub device is [hubDevice] (`X-Den-Hub`, an invite grant's inviting device).
  T? forHub(String hubDevice) => only(logs.where((l) => l.hubDevice == hubDevice));

  /// For a credential the address should decide (a token, a calendar link's secret): the log at
  /// [hostname] when the address is one of theirs, whether it holds the credential or not (so a
  /// family's token works only at its own address); else, on a host configured for one family,
  /// that family; else the one log that [holds] it.
  T? forCredential(String? hostname, bool Function(T log) holds) {
    final all = logs;
    final at = hostname == null ? null : only(all.where((l) => l.hostnames.contains(hostname)));
    return at ?? _theOnly(all) ?? only(all.where(holds));
  }

  /// For something only one log can hold, wherever it is asked (an invite's words, a recovery
  /// code, a link code, the hub a request is signed for): the one log that [holds] it; else,
  /// when [fallback], the log for [hostname] ([forHostname]), which then refuses it as its own
  /// would be refused.
  T? forBook(String? hostname, bool Function(T log) holds, {bool fallback = true}) {
    final holder = only(logs.where(holds));
    if (holder != null) return holder;
    return fallback ? forHostname(hostname) : null;
  }
}
