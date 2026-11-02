import 'spoken_code.dart' show normalizeCode, spokenCodeWords;

/// What a Den link (or the message around it) is for.
enum DenLinkKind {
  /// An invite to a family: `#/join/<w>-<w>-<w>-<w>`.
  family,

  /// An invite to a group of families: `#/group/<w>-<w>-<w>-<w>` (read now, joined later).
  group,

  /// A fresh hub's setup link: `#/setup/<code>/<hub device id>` (`den_hub setup-link`).
  setup,

  /// A recovery code from whoever runs the hub: `#/recover/<w>-<w>-<w>-<w>`.
  recover,
}

/// A link Den made, read from whatever someone pasted or opened: the link alone
/// (`https://den.example.com/#/join/maple-river-canoe-tiger`), the route the app was opened at
/// (`/join/maple-river-canoe-tiger`), the whole message it came in, or the four words typed.
/// One parser for every kind, so the paste box, the router and Safari's handoff agree.
class DenLink {
  /// Creates a link; [parse] reads one.
  const DenLink({required this.kind, this.hub, this.words, this.code, this.hubDevice});

  /// What it is for.
  final DenLinkKind kind;

  /// The hub's address (`https://den.example.com`), when the text carried the link.
  final Uri? hub;

  /// The four words, lowercase with single spaces, for [DenLinkKind.family],
  /// [DenLinkKind.group] and [DenLinkKind.recover]. Not checked against the word list here.
  final String? words;

  /// The setup code as printed (`ABCD-EFGH`), for [DenLinkKind.setup].
  final String? code;

  /// The device id of the hub that printed the setup link: the phone takes in only that hub.
  final String? hubDevice;

  static const Map<String, DenLinkKind> _paths = {
    'join': DenLinkKind.family,
    'group': DenLinkKind.group,
    'setup': DenLinkKind.setup,
    'recover': DenLinkKind.recover,
  };

  static List<String> _split(String s) =>
      s.toLowerCase().split(RegExp(r'[\s,.\-_]+')).where((w) => w.isNotEmpty).toList();

  /// The route this link opens in the app: `/join/maple-river-canoe-tiger`.
  String get route => switch (kind) {
        DenLinkKind.setup => '/setup/$code/$hubDevice',
        _ => '/${_paths.entries.firstWhere((e) => e.value == kind).key}/${words!.replaceAll(' ', '-')}',
      };

  /// The link in full, at [base] (or [hub]). Invites and setup links carry their words or code
  /// in the path (`https://den.example.com/join/maple-river-canoe-tiger`), so the hub can let a
  /// browser in from outside for a link that works; the hub sends it on to the app's route.
  Uri link([Uri? base]) {
    final b = (base ?? hub)!;
    if (kind == DenLinkKind.family || kind == DenLinkKind.setup) {
      return Uri(scheme: b.scheme, host: b.host, port: b.hasPort ? b.port : null, path: route);
    }
    return b.replace(path: '/', fragment: route);
  }

  /// Reads [text]; null when it holds no Den link and isn't four words. Four words with no
  /// link are taken as an invite to a family.
  static DenLink? parse(String text) {
    final whole = text.trim();
    final link = RegExp(r'(\S*?)#?/(join|group|setup|recover)/([^\s#?&]+)').firstMatch(whole);
    if (link != null) {
      final before = link.group(1)!;
      final base = Uri.tryParse(before.endsWith('/') ? before.substring(0, before.length - 1) : before);
      final hub = base != null && base.host.isNotEmpty && (base.scheme == 'https' || base.scheme == 'http')
          ? Uri(scheme: base.scheme, host: base.host, port: base.port)
          : null;
      final kind = _paths[link.group(2)]!;
      String rest;
      try {
        rest = Uri.decodeComponent(link.group(3)!);
      } on ArgumentError {
        rest = link.group(3)!;
      }
      if (kind == DenLinkKind.setup) {
        final parts = rest.split('/');
        final code = parts.first.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        final device = parts.length > 1 ? parts[1].toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '') : '';
        if (code.length != 8) return null;
        return DenLink(
          kind: kind,
          hub: hub,
          code: '${code.substring(0, 4)}-${code.substring(4)}',
          hubDevice: device.isEmpty ? null : device,
        );
      }
      final words = _split(rest.replaceAll(RegExp(r'[^A-Za-z\-_ ]+$'), ''));
      if (words.length == spokenCodeWords) return DenLink(kind: kind, hub: hub, words: words.join(' '));
    }
    final typed = _split(whole);
    if (typed.length == spokenCodeWords) return DenLink(kind: DenLinkKind.family, words: typed.join(' '));
    if (typed.length < spokenCodeWords) return null;
    // The whole message without a working link: the part between punctuation that is four
    // words, preferring words from Den's list.
    final parts = [
      for (final part in whole.split(RegExp(r'[:;!?\n]|\.(?=\s|$)')))
        if (_split(part).length == spokenCodeWords) _split(part),
    ];
    final known = parts.where((p) => normalizeCode(p.join(' ')) != null);
    final pick = known.isNotEmpty ? known.last : parts.lastOrNull;
    return pick == null ? null : DenLink(kind: DenLinkKind.family, words: pick.join(' '));
  }
}
