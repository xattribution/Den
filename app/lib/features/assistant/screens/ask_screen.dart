import 'dart:async';

import 'package:den_capture/den_capture.dart' show ReaderException;
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capture/capture_sources.dart';
import '../../add/add.dart' show Capture;
import '../../shared_screens/shared_screens.dart' show speak;
import '../state/ask_request.dart';
import '../state/ask_session.dart';
import '../state/helper_link.dart';
import '../widgets/ask_parts.dart';

/// Ask (`/ask`): the AI helper's answers, opened from Add. A sheet on phones, a panel at the
/// right edge from 840 pt. Each thing asked shows the helper's plain sentences, then every change
/// it made as a row in the person's color with Undo, and a change that needs a tap as a "Do it /
/// Not now" card first. The field at the bottom asks more; "undo that" takes back the last
/// change. A kid gets big buttons and "Read it to me". Nothing is kept once it closes.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, this.request, this.session, this.panel = false});

  /// What Add sent, which also keeps the conversation while the route lives.
  final AskRequest? request;

  /// A conversation to show, for tests.
  final AskSession? session;

  /// Drawn as the iPad panel: full height, the field at the foot.
  final bool panel;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  AskSession? _session;
  bool _ownSession = false;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _slow;
  bool _showAsking = false;
  bool _listening = false;
  CaptureSources? _listeningTo;
  int _seen = 0;

  AskSession get session => _session!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final app = DenScope.read(context);
    final request = widget.request;
    final session = widget.session ?? request?.session ?? AskSession(app: app, link: Assistant.linkFor(context, app));
    _ownSession = widget.session == null && request == null;
    request?.session = session;
    _session = session
      ..attach()
      ..addListener(_changed);
    _sync();
    if (request != null && !request.sent) {
      request.sent = true;
      // After the first frame, so the sheet is up before anything changes in it.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(session.ask(request.words, spoken: request.spoken)),
      );
    }
  }

  @override
  void dispose() {
    _slow?.cancel();
    _session?.removeListener(_changed);
    // Closing Ask ends the conversation; drawn again as a sheet or a panel, it carries on.
    if (_ownSession) {
      _session?.dispose();
    } else if (widget.session == null) {
      _session?.detach();
    }
    if (_listening) unawaited(_listeningTo?.stopListening());
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Something changed in the conversation.
  void _changed() {
    if (mounted) setState(_sync);
  }

  /// "Asking Claude" once the helper takes more than a second, and the newest part scrolled into
  /// view.
  void _sync() {
    if (session.busy) {
      _slow ??= Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() => _showAsking = true);
      });
    } else {
      _slow?.cancel();
      _slow = null;
      _showAsking = false;
    }
    final count = session.exchanges.length;
    if (count != _seen || !session.busy) {
      _seen = count;
      WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
    }
  }

  void _toEnd() {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (DenMotion.reduced(context)) {
      _scroll.jumpTo(end);
    } else {
      unawaited(_scroll.animateTo(end, duration: DenMotion.uiSettle, curve: DenMotion.uiCurve));
    }
  }

  Future<void> _ask() async {
    final words = _text.text.trim();
    if (words.isEmpty || session.busy) return;
    _text.clear();
    await session.ask(words);
  }

  Future<void> _speak() async {
    final sources = _listeningTo = Capture.of(context).sources;
    if (_listening) {
      await sources.stopListening();
      return;
    }
    setState(() => _listening = true);
    try {
      final words = await sources.listen(
        onWords: (w) {
          if (mounted) _text.text = w;
        },
      );
      if (words != null && words.trim().isNotEmpty && mounted) {
        _text.clear();
        await session.ask(words, spoken: true);
      }
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _readAloud(String words) async {
    final problem = await speak(words);
    if (problem != null && mounted) showNote(context, problem);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final c = context.colors;
    final me = app.den.actor;
    final kid = session.kid;
    final color = me == null ? c.ink : c.marker(me.marker);
    final sources = Capture.of(context).sources;
    final exchanges = session.exchanges;

    final talk = Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, x) in exchanges.indexed) ...[
            if (i > 0) const SizedBox(height: DenLayout.sectionGap),
            _ExchangeView(
              exchange: x,
              me: me,
              color: color,
              kid: kid,
              busy: session.busy,
              asking: _showAsking && x.working ? session.speaker : null,
              onDo: () => session.decide(approve: true),
              onNotNow: () => session.decide(approve: false),
              onUndo: session.undo,
              onRetry: () => session.retry(x),
              onRead: kid ? _readAloud : null,
            ),
          ],
          if (exchanges.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset, vertical: Sp.l),
              child: Text(
                kid
                    ? 'Ask about your chores, stars, lists or the calendar.'
                    : 'Ask about the calendar, chores, stars or lists, or ask for a change.',
                style: context.text.body(c.ink2),
              ),
            ),
        ],
      ),
    );

    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.gutter, Sp.s, DenLayout.gutter, Sp.s),
      child: AskBar(
        controller: _text,
        focus: _focus,
        onAsk: _ask,
        onSpeak: sources.canSpeak ? _speak : null,
        listening: _listening,
        busy: session.busy,
        kid: kid,
      ),
    );

    final scroller = SingleChildScrollView(
      controller: _scroll,
      child: ReadableWidth(child: talk),
    );
    return Column(
      mainAxisSize: widget.panel ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(DenLayout.gutter, widget.panel ? Sp.l : 0, DenLayout.gutter, 0),
          child: SheetHeader(title: 'Ask', actionLabel: 'Done'),
        ),
        if (widget.panel) Expanded(child: scroller) else Flexible(child: scroller),
        bar,
      ],
    );
  }
}

/// One thing asked and what came of it.
class _ExchangeView extends StatelessWidget {
  const _ExchangeView({
    required this.exchange,
    required this.me,
    required this.color,
    required this.kid,
    required this.busy,
    required this.asking,
    required this.onDo,
    required this.onNotNow,
    required this.onUndo,
    required this.onRetry,
    this.onRead,
  });

  final Exchange exchange;
  final Member? me;
  final Color color;
  final bool kid;
  final bool busy;

  /// Who is being asked, once it has taken more than a second; null otherwise.
  final String? asking;
  final VoidCallback onDo;
  final VoidCallback onNotNow;
  final void Function(ChangeLine line) onUndo;
  final VoidCallback onRetry;
  final void Function(String words)? onRead;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    final x = exchange;
    final pending = x.pending;
    final preview = x.previewLines;
    final parts = <Widget>[
      AskedLine(member: me, words: x.asked),
      if (asking != null) AskingLine(speaker: asking!),
      if (x.answer.isNotEmpty)
        Semantics(liveRegion: true, child: Text(x.answer, style: (kid ? t.rowTitle : t.body)(c.ink))),
      if (x.answer.isNotEmpty && onRead != null) ReadAloudButton(onTap: () => onRead!(x.answer)),
      if (x.changes.isNotEmpty) ChangeRows(lines: x.changes, color: color, onUndo: onUndo, kid: kid),
      if (pending != null)
        ConfirmCard(
          question: pending.preview,
          lines: preview.changes,
          more: preview.more,
          warnings: preview.warnings,
          onDo: onDo,
          onNotNow: onNotNow,
          busy: busy,
          kid: kid,
        ),
      if (pending == null && x.declined != null && x.answer.isEmpty && !x.working)
        Text('Left as it is.', style: t.meta(c.ink2)),
      if (x.problem != null) ProblemLine(problem: x.problem!, onRetry: onRetry, kid: kid),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, p) in parts.indexed) ...[if (i > 0) const SizedBox(height: Sp.m), p],
      ],
    );
  }
}
