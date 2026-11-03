import '../../platform/sync/den_network.dart';
import '../../platform/sync/hub_api.dart';

/// "The Smith family", "The Riveras", for a linked family named [name].
String linkedFamilyName(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'The other family';
  final lower = n.toLowerCase();
  if (lower.startsWith('the ')) return 'The ${n.substring(4)}';
  if (lower.endsWith(' family')) return 'The $n';
  return 'The $n family';
}

/// The id in a family link's address (`<hub>/family-link/<id>/<secret>`), or null when [text]
/// isn't one.
String? familyLinkId(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return null;
  final s = uri.pathSegments;
  final at = s.indexOf('family-link');
  if (at < 0 || s.length != at + 3) return null;
  final id = s[at + 1];
  if (!RegExp(r'^[A-Za-z0-9_\-]{8,80}$').hasMatch(id) || !RegExp(r'^[A-Za-z0-9_\-]{20,100}$').hasMatch(s[at + 2])) {
    return null;
  }
  return id;
}

/// Where family links are made and accepted: the family's hub, or a fake in tests.
abstract interface class FamilyLinksSource {
  /// The address to send the other family's parent for link [id], which a parent here made.
  Future<String> offer(String id);

  /// Accepts the link at [url] (whose `familyLink` a parent here added); answers the other
  /// family's name.
  Future<String> accept(String url);
}

/// The hub's family links (`/api/v1/families`), from a parent's own device.
class HubFamilyLinks implements FamilyLinksSource {
  HubFamilyLinks(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;

  static const _old = "The family's hub can't link families yet. Update the hub, then try again.";

  @override
  Future<String> offer(String id) async {
    final json = await _api.send('POST', '/api/v1/families/$id/offer', missing: _old);
    return json['url']! as String;
  }

  @override
  Future<String> accept(String url) async {
    final json = await _api.send('POST', '/api/v1/families/accept', body: {'url': url}, missing: _old);
    return json['name'] as String? ?? '';
  }
}
