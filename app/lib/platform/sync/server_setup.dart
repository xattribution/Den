import 'dart:convert';

import 'package:http/http.dart' as http;

import 'den_network.dart';
import 'hub_api.dart';
import 'hub_client.dart';

/// A NAS's shared folder (or a computer over SFTP) that backups go to or come from, as the app
/// sends it to the server. The password goes only to the server; the server never says it back.
class NasPlace {
  const NasPlace({
    required this.host,
    this.kind = 'nas',
    this.share = '',
    this.folder = defaultFolder,
    this.user = '',
    this.password = '',
    this.name,
    this.hasPassword = false,
  });

  /// The folder Den makes on the share.
  static const String defaultFolder = 'Den backups';

  factory NasPlace.fromJson(Map<String, Object?> j) => NasPlace(
        kind: j['kind'] as String? ?? 'nas',
        host: j['host'] as String? ?? '',
        share: j['share'] as String? ?? '',
        folder: j['folder'] as String? ?? defaultFolder,
        user: j['user'] as String? ?? '',
        name: j['name'] as String?,
        hasPassword: j['has_password'] == true,
      );

  final String kind;
  final String host;
  final String share;
  final String folder;
  final String user;
  final String password;

  /// What the NAS calls itself ("Family NAS").
  final String? name;

  /// The server keeps a password for it.
  final bool hasPassword;

  /// What people call it: its name, or its address.
  String get label => name ?? host;

  NasPlace copyWith({String? host, String? share, String? folder, String? user, String? password, String? name}) => NasPlace(
        kind: kind,
        host: host ?? this.host,
        share: share ?? this.share,
        folder: folder ?? this.folder,
        user: user ?? this.user,
        password: password ?? this.password,
        name: name ?? this.name,
        hasPassword: hasPassword,
      );

  Map<String, Object?> toJson() => {
        'kind': kind,
        'host': host,
        if (share.isNotEmpty) 'share': share,
        'folder': folder,
        if (user.isNotEmpty) 'user': user,
        if (password.isNotEmpty) 'password': password,
        'name': ?name,
      };
}

/// A NAS that answered on the home network.
class FoundNas {
  const FoundNas({required this.name, required this.host});
  final String name;
  final String host;
}

/// A backup the server can restore: its file name, size and when it was made.
class BackupItem {
  const BackupItem({required this.name, required this.size, required this.at});

  factory BackupItem.fromJson(Map<String, Object?> j) =>
      BackupItem(name: j['name'] as String? ?? '', size: (j['size'] as num?)?.toInt() ?? 0, at: (j['at'] as num?)?.toInt() ?? 0);

  final String name;
  final int size;

  /// UTC milliseconds.
  final int at;
}

/// What an uploaded backup says about itself before it is opened.
class BackupFileInfo {
  const BackupFileInfo({this.madeAt, this.familyName, this.names = const [], this.passphrase = false, this.version = 2});

  factory BackupFileInfo.fromJson(Map<String, Object?> j) => BackupFileInfo(
        version: (j['version'] as num?)?.toInt() ?? 2,
        madeAt: (j['made_at'] as num?)?.toInt(),
        familyName: j['family_name'] as String?,
        names: [if (j['names'] case final List<Object?> l) for (final n in l) if (n is String) n],
        passphrase: j['passphrase'] == true,
      );

  final int version;
  final int? madeAt;
  final String? familyName;

  /// The parents whose recovery words open it.
  final List<String> names;

  /// A passphrase opens it (an older backup).
  final bool passphrase;

  /// Only a passphrase opens it.
  bool get needsPassphrase => names.isEmpty && passphrase;
}

/// How the server reaches the internet: the Cloudflare tunnel, as the server says it. Never the
/// token itself.
class InternetState {
  const InternetState({this.available = false, this.token = false, this.connected = false, this.reachable = true, this.problem});

  factory InternetState.fromJson(Object? json) {
    final j = json is Map ? json : const {};
    return InternetState(
      available: j['available'] == true,
      token: j['token'] == true,
      connected: j['connected'] == true,
      reachable: j['reachable'] != false,
      problem: j['problem'] as String?,
    );
  }

  /// The server has a connector at all.
  final bool available;

  /// A token is saved.
  final bool token;

  /// The tunnel is up.
  final bool connected;

  /// The connector answered.
  final bool reachable;

  /// What is wrong, in the connector's own plain words.
  final String? problem;
}

/// Where a fresh server's first boot stands.
class FirstBootState {
  const FirstBootState({required this.internet, this.address, this.setupLink, this.passphraseKnown = false});

  factory FirstBootState.fromJson(Map<String, Object?> j) => FirstBootState(
        internet: InternetState.fromJson(j['internet']),
        address: j['address'] as String?,
        setupLink: j['setup_link'] as String?,
        passphraseKnown: (j['restore'] is Map) && (j['restore']! as Map)['passphrase_known'] == true,
      );

  final InternetState internet;

  /// The family's address (`https://den.example.com`), once the server has one.
  final String? address;

  /// The link that makes the family on a phone, at the address when there is one.
  final String? setupLink;

  /// The server knows the passphrase older backups were made with.
  final bool passphraseKnown;

  /// The address as people read it: `den.example.com`.
  String? get addressText => address == null ? null : Uri.parse(address!).host;
}

/// A fresh server's first-boot pages (docs/hub-api.md, "First boot"), with the setup code from
/// the link it printed: the server, or a fake in tests. Every call throws [HubException].
abstract interface class FirstBootSource {
  Future<FirstBootState> state();

  /// Saves the Cloudflare tunnel token (or what was pasted around it) and starts the tunnel.
  Future<FirstBootState> saveToken(String pasted);

  /// The family's address, when the tunnel doesn't say it.
  Future<FirstBootState> saveAddress(String address);

  /// The family is made on a phone next: the setup link there goes straight to it.
  Future<void> chooseFamily();

  Future<List<FoundNas>> findNas();

  /// The shared folders on the NAS [place] names.
  Future<List<String>> shares(NasPlace place);

  /// The backups in [place], or on this server with none, newest first.
  Future<List<BackupItem>> backups({NasPlace? place});

  /// Sends a backup file from this device; says what it is.
  Future<BackupFileInfo> upload(List<int> bytes);

  /// Restores from `upload`, `disk` or `nas` with recovery [words] (or an older backup's
  /// [passphrase]); answers the family's name.
  Future<String?> restore({required String from, String? name, NasPlace? place, String? words, String? passphrase});

  /// Whether the server has its family now (the phone made it).
  Future<bool> paired();
}

/// [FirstBootSource] at the server [base], with the setup [code].
class HubFirstBoot implements FirstBootSource {
  HubFirstBoot(this.base, this.code, {http.Client? client}) : _http = client ?? http.Client();

  final Uri base;
  final String code;
  final http.Client _http;

  Future<Map<String, Object?>> _send(String method, String path, {Object? body, List<int>? bytes, Duration? timeout}) async {
    final request = http.Request(method, base.replace(path: path))..headers['x-den-setup-code'] = code;
    if (bytes != null) {
      request.headers['content-type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    } else if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request)).timeout(timeout ?? const Duration(seconds: 60));
    } on Object {
      throw const HubException("Couldn't reach the server. Check that it's on, then try again.");
    }
    final json = decodeHubJson(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) return json;
    throw hubError(response, json);
  }

  @override
  Future<FirstBootState> state() async => FirstBootState.fromJson(await _send('GET', '/api/v1/hub/first-boot'));

  @override
  Future<FirstBootState> saveToken(String pasted) async =>
      FirstBootState.fromJson(await _send('PUT', '/api/v1/hub/first-boot/internet', body: {'token': pasted}));

  @override
  Future<FirstBootState> saveAddress(String address) async =>
      FirstBootState.fromJson(await _send('PUT', '/api/v1/hub/first-boot/address', body: {'address': address}));

  @override
  Future<void> chooseFamily() => _send('POST', '/api/v1/hub/first-boot/choice', body: {'choice': 'family'});

  @override
  Future<List<FoundNas>> findNas() async => foundNasOf(await _send('POST', '/api/v1/hub/first-boot/nas/find', body: const {}));

  @override
  Future<List<String>> shares(NasPlace place) async =>
      sharesOf(await _send('POST', '/api/v1/hub/first-boot/nas/shares', body: {'place': place.toJson()}));

  @override
  Future<List<BackupItem>> backups({NasPlace? place}) async {
    final json = await _send('POST', '/api/v1/hub/first-boot/backups', body: {if (place != null) 'place': place.toJson()});
    return [if (json['backups'] case final List<Object?> l) for (final b in l) if (b is Map) BackupItem.fromJson(b.cast())];
  }

  @override
  Future<BackupFileInfo> upload(List<int> bytes) async {
    final json = await _send('POST', '/api/v1/hub/first-boot/upload', bytes: bytes, timeout: const Duration(minutes: 10));
    return BackupFileInfo.fromJson((json['backup'] as Map? ?? const {}).cast());
  }

  @override
  Future<String?> restore({required String from, String? name, NasPlace? place, String? words, String? passphrase}) async {
    final json = await _send('POST', '/api/v1/hub/first-boot/restore',
        body: {
          'from': from,
          'name': ?name,
          if (place != null) 'place': place.toJson(),
          'words': ?words,
          'passphrase': ?passphrase,
        },
        timeout: const Duration(minutes: 10));
    return json['family_name'] as String?;
  }

  @override
  Future<bool> paired() async {
    try {
      return (await HubClient(client: _http).status(base)).paired;
    } on HubException {
      return false;
    }
  }
}

/// The NASes in a find answer.
List<FoundNas> foundNasOf(Map<String, Object?> json) => [
      if (json['found'] case final List<Object?> l)
        for (final f in l)
          if (f is Map && f['host'] is String) FoundNas(name: f['name'] as String? ?? f['host']! as String, host: f['host']! as String),
    ];

/// The shared folders in a shares answer.
List<String> sharesOf(Map<String, Object?> json) => [if (json['shares'] case final List<Object?> l) for (final s in l) if (s is String) s];

/// What the updater on the server says.
class UpdateState {
  const UpdateState({required this.current, this.available, this.state = 'idle', this.message});

  factory UpdateState.fromJson(Map<String, Object?> j) => UpdateState(
        current: j['current'] as String? ?? '',
        available: j['available'] as String?,
        state: j['state'] as String? ?? 'idle',
        message: j['message'] as String?,
      );

  final String current;

  /// A newer version, or null.
  final String? available;

  /// `idle`, `updating` or `failed`.
  final String state;
  final String? message;
}

/// The server, as Settings shows it to a parent of its own family.
class ServerState {
  const ServerState({required this.version, required this.internet, this.address, this.update});

  factory ServerState.fromJson(Map<String, Object?> j) => ServerState(
        version: j['version'] as String? ?? '',
        internet: InternetState.fromJson(j['internet']),
        address: j['address'] as String?,
        update: j['update'] is Map ? UpdateState.fromJson((j['update']! as Map).cast()) : null,
      );

  final String version;
  final InternetState internet;
  final String? address;

  /// Null without an updater (a dev build): no update row.
  final UpdateState? update;
}

/// Why the last backup didn't happen or didn't reach the NAS.
class BackupProblem {
  const BackupProblem({required this.kind, required this.at, this.place = false});

  static BackupProblem? fromJson(Object? json) {
    if (json is! Map || json['kind'] is! String) return null;
    return BackupProblem(kind: json['kind']! as String, at: (json['at'] as num?)?.toInt() ?? 0, place: json['place'] == true);
  }

  /// `no_words`, `disk`, `unreachable`, `login`, `missing`, `readOnly`, `noTool` or `other`.
  final String kind;

  /// UTC milliseconds.
  final int at;

  /// The NAS failed; the copy on the server is there.
  final bool place;
}

/// How the server's backups stand.
class BackupsState {
  const BackupsState({
    this.keep = 14,
    this.lastAt,
    this.lastSize,
    this.problem,
    this.place,
    this.placeLastAt,
    this.opensWith = const [],
    this.running = false,
  });

  factory BackupsState.fromJson(Map<String, Object?> j) {
    final last = j['last'] is Map ? (j['last']! as Map) : null;
    final place = j['place'] is Map ? (j['place']! as Map).cast<String, Object?>() : null;
    return BackupsState(
      keep: (j['keep'] as num?)?.toInt() ?? 14,
      lastAt: (last?['at'] as num?)?.toInt(),
      lastSize: (last?['size'] as num?)?.toInt(),
      problem: BackupProblem.fromJson(j['problem']),
      place: place == null ? null : NasPlace.fromJson(place),
      placeLastAt: (place?['last_at'] as num?)?.toInt(),
      opensWith: [if (j['opens_with'] case final List<Object?> l) for (final n in l) if (n is String) n],
      running: j['running'] == true,
    );
  }

  final int keep;
  final int? lastAt;
  final int? lastSize;
  final BackupProblem? problem;
  final NasPlace? place;
  final int? placeLastAt;

  /// Whose recovery words open the backups.
  final List<String> opensWith;
  final bool running;
}

/// The server's settings from a parent's own phone in its own family (docs/hub-api.md, "The
/// server"): the server, or a fake in tests. Every call throws [HubException]; its code is
/// `host_family_only` when this family isn't the server's own.
abstract interface class ServerSource {
  Future<ServerState> server();
  Future<ServerState> saveToken(String pasted);
  Future<ServerState> updateNow();
  Future<BackupsState> backups();
  Future<BackupsState> backUpNow();
  Future<List<FoundNas>> findNas();
  Future<List<String>> shares(NasPlace place);

  /// Tests [place] with a small file and saves it: backups go there too.
  Future<BackupsState> setPlace(NasPlace place);

  /// Backups stay on the server alone.
  Future<BackupsState> clearPlace();
}

/// [ServerSource] through the family's hub, signed by this phone.
class HubServerSource implements ServerSource {
  HubServerSource(DenNetwork network) : _api = HubApi(network);

  final HubApi _api;
  static const String _old = 'The server runs an older Den. Update it first.';

  Future<Map<String, Object?>> _send(String method, String path, {Map<String, Object?>? body}) =>
      _api.send(method, path, body: body, missing: _old);

  @override
  Future<ServerState> server() async => ServerState.fromJson(await _send('GET', '/api/v1/hub/server'));

  @override
  Future<ServerState> saveToken(String pasted) async =>
      ServerState.fromJson(await _send('PUT', '/api/v1/hub/server/internet', body: {'token': pasted}));

  @override
  Future<ServerState> updateNow() async => ServerState.fromJson(await _send('POST', '/api/v1/hub/server/update', body: const {}));

  @override
  Future<BackupsState> backups() async => BackupsState.fromJson(await _send('GET', '/api/v1/hub/backups'));

  @override
  Future<BackupsState> backUpNow() async => BackupsState.fromJson(await _send('POST', '/api/v1/hub/backups/run', body: const {}));

  @override
  Future<List<FoundNas>> findNas() async => foundNasOf(await _send('POST', '/api/v1/hub/backups/find', body: const {}));

  @override
  Future<List<String>> shares(NasPlace place) async =>
      sharesOf(await _send('POST', '/api/v1/hub/backups/shares', body: {'place': place.toJson()}));

  @override
  Future<BackupsState> setPlace(NasPlace place) async =>
      BackupsState.fromJson(await _send('PUT', '/api/v1/hub/backups/place', body: {'place': place.toJson()}));

  @override
  Future<BackupsState> clearPlace() async => BackupsState.fromJson(await _send('DELETE', '/api/v1/hub/backups/place'));
}

/// "2.1 MB", "340 KB".
String sizeWords(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).ceil()} KB';
}

/// What a backup problem says to a parent, in a sentence. [when] is "last night", "on Oct 28".
String backupProblemWords(BackupProblem p, {required String when, String? nas}) => switch (p.kind) {
      'no_words' => 'No backup $when: save your recovery words first. A backup opens only with them.',
      'disk' => 'Couldn\'t save a backup on the server $when. Check that its disk has room.',
      'unreachable' => 'Couldn\'t reach ${nas ?? 'the NAS'} $when. The server kept its own copy.',
      'login' => '${nas ?? 'The NAS'} didn\'t accept the username and password $when.',
      'missing' => 'The shared folder on ${nas ?? 'the NAS'} wasn\'t there $when.',
      'readOnly' => '${nas ?? 'The NAS'} didn\'t let Den save there $when.',
      'noTool' => 'The server can\'t copy to a NAS. Update Den on the server.',
      _ => 'The backup didn\'t reach ${nas ?? 'the NAS'} $when. The server kept its own copy.',
    };
