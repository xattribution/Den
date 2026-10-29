import 'package:den_actions/den_actions.dart' show readableSpacesFor;
import 'package:den_core/den_core.dart';

import 'oauth_store.dart';

/// A caller authenticated by a bearer token: the connection it belongs to, who it acts as, and
/// what it may do.
class Access {
  /// Creates the access a [connection] grants, acting as [member] ([Den.connectionActsAs]).
  const Access(this.connection, {this.member});

  /// The connection record the token resolved to.
  final Connection connection;

  /// The connection's label, recorded as `_via` on every change the caller makes.
  String get label => connection.label;

  /// Who the caller acts as: the connection's person, or for one approved before every
  /// connection acted as someone, the parent who approved it. Null for one that acts for nobody
  /// (its parent left the family, say): it only reads.
  final String? member;

  /// Scopes as granted; only `read` for a connection that acts for nobody.
  Set<Scope> get scopes {
    final granted = connection.scopes;
    if (member != null) return granted;
    return granted.contains(Scope.read) || granted.contains(Scope.admin) ? const {Scope.read} : const {};
  }

  /// The time zone the connection's person lives in, when a parent set one.
  String? get timezone => connection.tz;

  /// Whether the token carries [scope] (`admin` implies every scope).
  bool has(Scope scope) => scopes.contains(Scope.admin) || scopes.contains(scope);

  /// The spaces this caller may read on [den] (a hub, which holds every space): its member's
  /// readable spaces, or what a parent reads for one that acts for nobody.
  Set<String> readable(Den den) => readableSpacesFor(den, member);
}

/// Resolves a bearer token on [den]: an active, unexpired connection whose member (if any) is
/// still in the family, acting as that member or, for a connection that names none, as the
/// parent who approved it. Null otherwise. A token a parent made is found by its hash in the log;
/// an OAuth access token by its hash in the hub's [oauth] state, for a connection the log still
/// has active.
Access? accessForToken(Den den, String? token, {OAuthStore? oauth, int? now}) {
  if (token == null || token.isEmpty || token.length > 512) return null;
  var connection = den.connectionForToken(token);
  if (connection == null && oauth != null) {
    final id = oauth.accessConnection(token, now ?? DateTime.now().toUtc().millisecondsSinceEpoch);
    final c = id == null ? null : den.connectionWithId(id);
    if (c != null && c.kind == ConnectionKind.oauth && c.status == ConnectionStatus.active) connection = c;
  }
  if (connection == null) return null;
  final named = connection.member;
  if (named != null && den.member(named) == null) return null;
  return Access(connection, member: den.connectionActsAs(connection));
}

/// The token in an `Authorization: Bearer <token>` header, or null.
String? bearerToken(String? header) {
  if (header == null) return null;
  final match = RegExp(r'^\s*Bearer\s+(\S+)\s*$', caseSensitive: false).firstMatch(header);
  return match?.group(1);
}

/// The scope name as the API spells it.
String scopeName(Scope scope) => scope.name;

/// What an assistant gets when it asks for nothing in particular: everything but `admin`.
const Set<Scope> defaultScopes = {Scope.read, Scope.calendar, Scope.chores, Scope.lists, Scope.points};

/// [defaultScopes] by name, in order.
final List<String> defaultScopeNames = [for (final s in Scope.values) if (defaultScopes.contains(s)) s.name];
