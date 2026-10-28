import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'capture_settings.dart';
import '../../../platform/capture/capture_sources.dart';
import '../../../platform/capture/platform_capture.dart';
import '../../../platform/capabilities.dart';

/// Reads what someone shared with the readers a parent allowed, in their order: this device
/// first (its model, then Den's own reader) unless a parent chose otherwise; then the home model
/// or Claude set up on this device; then the reader a parent set up on the family's hub, for
/// every device. Nothing is sent anywhere unless a parent set one of those up.
class CaptureService {
  CaptureService({
    required this.settings,
    this.platform = const PlatformCapture(),
    CaptureSources? sources,
    http.Client? client,
    List<CaptureReader>? readers,
    HubCaptureClient? hubClient,
  })  : sources = sources ?? DeviceCaptureSources(),
        hub = hubClient == null ? null : HubReader(hubClient),
        _fixed = readers,
        _http = client ?? http.Client();

  final CaptureSettings settings;
  final PlatformCapture platform;

  /// The camera, files and microphone.
  final CaptureSources sources;

  /// The family hub's reader, when the family has a hub.
  final HubReader? hub;

  /// Readers to use instead of the ones settings choose, for tests and the demo.
  final List<CaptureReader>? _fixed;
  final http.Client _http;
  DeviceAbilities? _abilities;

  Future<DeviceAbilities> abilities() async => _abilities ??= await platform.abilities();

  /// Forgets what the device reported, after its model finishes downloading.
  void refreshAbilities() => _abilities = null;

  /// The readers to try, in order.
  Future<List<CaptureReader>> readers() async {
    if (_fixed != null) return _fixed;
    final device = await abilities();
    final own = <CaptureReader>[if (device.model != null) DeviceModelReader(device, platform: platform), const RulesReader()];
    CaptureReader? remote;
    // In a browser the hub serves, the page may talk to the hub and nothing else (its
    // Content-Security-Policy), so a model at home or Claude is reached through the hub's reader.
    switch (Capabilities.web ? ReaderChoice.device : settings.reader) {
      case ReaderChoice.device:
        break;
      case ReaderChoice.home:
        final base = HomeModelReader.baseFor(settings.homeAddress);
        if (base != null) remote = HomeModelReader(base: base, model: settings.homeModel, client: _http);
      case ReaderChoice.claude:
        final key = await settings.claudeKey();
        if (key != null && key.isNotEmpty) {
          remote = ClaudeReader(apiKey: key, model: settings.claudeModel, client: _http, browser: Capabilities.web);
        }
    }
    final hubReader = hub;
    final family = hubReader == null ? null : await hubReader.refresh();
    final shared = family?.ready ?? false ? hubReader : null;
    if (remote != null) return [...(settings.deviceFirst ? [...own, remote] : [remote, ...own]), ?shared];
    if (shared == null) return own;
    return family!.deviceFirst ? [...own, shared] : [shared, ...own];
  }

  /// Reads [input] for [den]'s family. Throws [ReaderException] when nothing could.
  Future<CaptureResult> read(CaptureInput input, Den den) async {
    final device = await abilities();
    final prepared = CaptureInput(
      kind: input.kind,
      text: input.text,
      files: [for (final f in input.files) await _common(f)],
      link: input.link,
      subject: input.subject,
    );
    final capturer = Capturer(
      readers: await readers(),
      textFinder: DeviceTextFinder(device, platform: platform),
      pageText: Capabilities.web ? null : _pageText,
    );
    return capturer.read(prepared, den);
  }

  /// Photos as JPEG at a sensible size, so every reader can take them.
  Future<CaptureFile> _common(CaptureFile f) async {
    if (!f.isImage) return f;
    final small = f.bytes.length < 3 * 1024 * 1024 && ClaudeReader.imageTypes.contains(f.mimeType);
    if (small) return f;
    final jpeg = await platform.toJpeg(f.bytes);
    return jpeg == null ? f : CaptureFile(jpeg, 'image/jpeg', name: f.name);
  }

  /// A shared page's readable text: its title and the words between its tags.
  Future<String?> _pageText(Uri link) async {
    try {
      final r = await _http.get(link).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200 || !(r.headers['content-type'] ?? 'text/html').contains('html')) return null;
      return pageWords(r.body);
    } on Object {
      return null;
    }
  }
}

/// The words a person reads on an HTML page: no scripts, styles or tags, one line per block.
String pageWords(String html) {
  var t = html
      .replaceAll(RegExp(r'<(script|style|noscript|svg|head)[^>]*>.*?</\1>', caseSensitive: false, dotAll: true), ' ')
      .replaceAll(RegExp(r'<(br|/p|/div|/li|/h\d|/tr|/section|/article)[^>]*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  const entities = {'&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&ndash;': '–', '&mdash;': '—'};
  entities.forEach((k, v) => t = t.replaceAll(k, v));
  final lines = [
    for (final l in t.split('\n'))
      if (l.trim().isNotEmpty) l.replaceAll(RegExp(r'[ \t]+'), ' ').trim(),
  ];
  final text = lines.join('\n');
  return text.length > 20000 ? text.substring(0, 20000) : text;
}

/// The app's capture service and share inbox. Startup replaces [service]; tests override it below
/// a widget with [CaptureScope].
abstract final class Capture {
  static CaptureService service = CaptureService(settings: CaptureSettings(secrets: MemoryCaptureSecrets()));

  /// Shares that arrived from the system share sheet, for the app to open: a [CaptureInput],
  /// or a [CaptureProblem] when what was shared couldn't be opened.
  static final StreamController<Object> inbox = StreamController.broadcast();

  /// Shares that arrived before anything listened to [inbox] (Den was starting), taken once.
  static final List<Object> waiting = [];

  static void deliver(Object input) {
    if (inbox.hasListener) {
      inbox.add(input);
    } else {
      waiting.add(input);
    }
  }

  static CaptureService of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CaptureScope>()?.service ?? service;

  /// Hands everything the platform has waiting to [inbox]; called at start, on resume and when
  /// the platform says a share arrived.
  static Future<void> collectShares([PlatformCapture platform = const PlatformCapture()]) async {
    for (final s in await platform.takeShares()) {
      final input = s.input;
      if (!input.isEmpty) {
        deliver(input);
      } else if (s.unread > 0) {
        deliver(const CaptureProblem('Den couldn\'t open what was shared. Try sharing it again, or choose it from Add.'));
      }
    }
  }
}

/// Something was shared that Den couldn't open; [message] says so, for people.
class CaptureProblem {
  const CaptureProblem(this.message);
  final String message;
}

class CaptureScope extends InheritedWidget {
  const CaptureScope({super.key, required this.service, required super.child});
  final CaptureService service;

  @override
  bool updateShouldNotify(CaptureScope oldWidget) => oldWidget.service != service;
}
