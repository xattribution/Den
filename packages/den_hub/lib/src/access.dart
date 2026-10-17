import 'package:den_core/den_core.dart';

/// A caller authenticated by a bearer token: the connection it belongs to, and what it may do.
class Access {
  /// Creates the access a [connection] grants.
  const Access(this.connection);

  /// The connection record the token resolved to.
  final Connection connection;

  /// The connection's label, recorded as `_via` on every change the caller makes.
  String get label => connection.label;

  /// Whose permissions the caller uses; null is parent level.
  String? get member => connection.member;

  /// Scopes as granted.
  Set<Scope> get scopes => connection.scopes;

  /// Whether the token carries [scope] (`admin` implies every scope).
  bool has(Scope scope) => scopes.contains(Scope.admin) || scopes.contains(scope);

  /// The spaces this caller may read on [den] (a hub, which holds every space): its member's
  /// readable spaces, or what a parent reads for a token with no member.
  Set<String> readable(Den den) => readableSpacesFor(den, member);
}

/// The spaces [member] may read among those [den] holds; null [member] reads what a parent
/// reads (the family, parents-only, and private spaces the oversight policy opens to parents).
Set<String> readableSpacesFor(Den den, String? member) {
  final held = den.spacesForDevice(den.deviceId);
  final family = den.family;
  if (member != null) {
    final m = den.member(member);
    if (m == null) return const {};
    return {for (final s in held) if (canRead(m, s, family)) s};
  }
  return {
    for (final s in held)
      if (s == Space.family ||
          s == Space.parents ||
          (Space.isMember(s) && (family?.parentsSeePrivate(Space.memberOf(s)!) ?? true)))
        s,
  };
}

/// Resolves a bearer token on [den]: an active, unexpired connection whose member (if any) is
/// still in the family. Null otherwise.
Access? accessForToken(Den den, String? token) {
  if (token == null || token.isEmpty || token.length > 512) return null;
  final connection = den.connectionForToken(token);
  if (connection == null) return null;
  final member = connection.member;
  if (member != null && den.member(member) == null) return null;
  return Access(connection);
}

/// The token in an `Authorization: Bearer <token>` header, or null.
String? bearerToken(String? header) {
  if (header == null) return null;
  final match = RegExp(r'^\s*Bearer\s+(\S+)\s*$', caseSensitive: false).firstMatch(header);
  return match?.group(1);
}

/// The scope name as the API spells it.
String scopeName(Scope scope) => scope.name;
