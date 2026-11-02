import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../design/layout.dart';
import '../design/tokens.dart';
import '../platform/web/web_app.dart';
import 'build_info.dart';

/// Settings → Advanced → Show screen info: a small panel over the top of the app with the
/// numbers that say what the screen and the keyboard are doing, for a screenshot at the moment
/// something looks wrong. It shows what Flutter measured (its view's size, keyboard inset and
/// padding), what the app lays out with after [WebSafeArea] (and the layout class that gives),
/// and in a browser what the page says (window, layout and visual viewport, scroll, Flutter's
/// view, the keyboard, the focused element, the safe areas, the browser) with its last few
/// viewport and focus events, newest last. Touches go through it. Off, it costs nothing but an
/// empty slot over the app.
class ScreenInfoOverlay extends StatefulWidget {
  const ScreenInfoOverlay({super.key, required this.enabled, required this.child, this.page});

  final bool enabled;
  final Widget child;

  /// What the page says, for tests; by default den_web.js's (null off the web).
  final Map<String, Object?>? Function()? page;

  @override
  State<ScreenInfoOverlay> createState() => _ScreenInfoOverlayState();
}

class _ScreenInfoOverlayState extends State<ScreenInfoOverlay> {
  Timer? _timer;
  Map<String, Object?>? _page;
  String _last = '';

  Map<String, Object?>? _read() => (widget.page ?? WebApp.screenInfo)();

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _start();
  }

  @override
  void didUpdateWidget(ScreenInfoOverlay old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) _start();
    if (!widget.enabled && old.enabled) _stop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    WebApp.diagnose(true);
    _poll();
    // A few times a second while it shows: the page moves without telling Flutter.
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    WebApp.diagnose(false);
    _page = null;
    _last = '';
  }

  void _poll() {
    final page = _read();
    final text = page == null ? '' : jsonEncode(page);
    if (text == _last && _page != null) return;
    _last = text;
    if (mounted) setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.enabled)
          Positioned(
            left: MediaQuery.paddingOf(context).left + 4,
            top: MediaQuery.paddingOf(context).top + 4,
            child: IgnorePointer(child: _Panel(lines: screenInfoLines(context, _page))),
          ),
      ],
    );
  }
}

String _n(Object? v) {
  if (v is num) return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
  return '$v';
}

String _size(Size s) => '${_n(s.width)}×${_n(s.height)}';

String _insets(EdgeInsets e) => 't${_n(e.top)} r${_n(e.right)} b${_n(e.bottom)} l${_n(e.left)}';

String _pair(Object? list) => list is List && list.length == 2 ? '${_n(list[0])}×${_n(list[1])}' : '-';

String _rect(Object? list) =>
    list is List && list.length == 4 ? '${_n(list[0])},${_n(list[1])} ${_n(list[2])}×${_n(list[3])}' : '-';

/// The panel's lines for [context] (Flutter's and the app's numbers) and [page] (den_web.js's
/// `screenInfo`, null off the web).
List<String> screenInfoLines(BuildContext context, Map<String, Object?>? page) {
  final view = View.of(context);
  final dpr = view.devicePixelRatio;
  final media = MediaQuery.of(context);
  final window = DenWindow.sizeOf(context);
  final lines = <String>[
    'Den ${DenBuild.label}',
    'Flutter ${_size(view.physicalSize / dpr)} @${_n(dpr)} keyboard ${_n(view.viewInsets.bottom / dpr)} '
        'pad ${_insets(EdgeInsets.fromViewPadding(view.padding, dpr))}',
    'App ${_size(media.size)} keyboard ${_n(media.viewInsets.bottom)} pad ${_insets(media.padding)}',
    'Layout ${DenLayout.of(context).name} for ${_size(window)} · text ×${_n(media.textScaler.scale(1))}',
  ];
  if (page == null) return lines;
  final visual = page['visual'];
  final scroll = page['scroll'];
  final safe = page['safe'];
  lines.addAll([
    'Page window ${_pair(page['inner'])} layout ${_pair(page['client'])} screen ${_pair(page['screen'])} '
        '${page['orientation'] ?? ''}',
    if (visual is Map)
      'Visual ${_n(visual['width'])}×${_n(visual['height'])} top ${_n(visual['offsetTop'])} '
          'pageTop ${_n(visual['pageTop'])} scale ${_n(visual['scale'])}',
    if (scroll is Map) 'Scroll window ${_n(scroll['window'])} root ${_n(scroll['root'])} body ${_n(scroll['body'])}',
    'Drawn ${_rect(page['view'])} · keyboard ${_n(page['keyboard'])} of ${_n(page['full'])}'
        '${page['virtualKeyboard'] == null ? '' : ' · vk ${_rect(page['virtualKeyboard'])}'}',
    'Focus ${page['focus'] == '' ? '-' : page['focus']} · safe ${safe is List && safe.length == 4 ? 't${_n(safe[0])} r${_n(safe[1])} b${_n(safe[2])} l${_n(safe[3])}' : '-'}',
    '${page['display']} · ${page['ua']}',
  ]);
  final events = page['events'];
  if (events is List && events.isNotEmpty) {
    lines.add('Events (s: what, visual h/top, window h, drawn, keyboard, focus)');
    for (final e in events.whereType<Map<Object?, Object?>>()) {
      final t = e['t'] is num ? ((e['t']! as num) / 1000).toStringAsFixed(1) : '?';
      lines.add(' $t: ${e['what']} ${_n(e['visual'])}/${_n(e['top'])} ${_n(e['inner'])} ${_n(e['drawn'])} '
          '${_n(e['keyboard'])} ${e['focus']}');
    }
  }
  return lines;
}

/// White on near-black at a fixed small size whatever the theme and text size: numbers to read
/// off a screenshot.
class _Panel extends StatelessWidget {
  const _Panel({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Semantics(
      container: true,
      label: 'Screen info',
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: (width - 8).clamp(120, 460)),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0xD9000000),
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: MediaQuery.withNoTextScaling(
              child: Text(
                lines.join('\n'),
                textDirection: TextDirection.ltr,
                // Not inherited: above the app's pages there's only the app's error style.
                style: const TextStyle(
                  inherit: false,
                  fontFamily: DenType.family,
                  color: Color(0xFFFFFFFF),
                  fontSize: 10.5,
                  height: 1.3,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
