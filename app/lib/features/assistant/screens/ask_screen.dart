import 'dart:async';

import 'package:den_capture/den_capture.dart' show ReaderException;
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../platform/capture/capture_sources.dart';
import '../../add/add.dart' show Capture;
import '../../shared_screens/shared_screens.dart' show speak;
import '../state/ask_access.dart';
import '../state/ask_chats.dart';
import '../state/ask_request.dart';
import '../state/ask_session.dart';
import '../state/helper_link.dart';
import '../state/suggestions.dart';
import '../widgets/ask_parts.dart';
import '../widgets/ask_start.dart';
import '../words/assistant_words.dart';

/// Ask (`/ask`): a conversation with the AI helper. A sheet on phones, a panel at the right edge
/// from 840 pt. Opened from Today, the sidebar, Add or ⌘K, it shows the conversation this device
/// is keeping ([AskChats]); an empty one greets the person with a few things to ask as chips.
/// Each thing asked shows the helper's plain sentences, then every change it made as a row in
/// the person's color with Undo, and a change that needs a tap as a "Do it / Not now" card
/// first. The field at the bottom asks more; "undo that" takes back the last change; "New chat"
/// starts over. A kid gets big buttons and "Read it to me". A parent while the helper is off
/// gets what it does and the way to set it up.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key, this.request, this.session, this.panel = false});

  /// What opened it: Add's words, or nothing to send ([AskRequest.open]).
  final AskRequest? request;

  /// A conversation to show, for tests; by default the one [AskChats] keeps.
  final AskSession? session;

  /// Drawn as the iPad panel: full height, the field at the foot.
  final bool panel;

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  AskSession? _session;
  late AskChats _chats;
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _slow;
  bool _showAsking = false;
  bool _listening = false;
  CaptureSources? _listeningTo;

  /// The family Ask acts in, to name on a device in several: the one whose page this is.
  FamilyLog? _family(BuildContext context) {
    final home = Household.maybeOf(context);
    if (home == null || !home.several) return null;
    return home.of(DenScope.read(context).den) ?? home.active;
  }
  int _seen = 0;

  AskSession get session => _session!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_session != null) return;
    final app = DenScope.read(context);
    final request = widget.request;
    _chats = AskChats.of(app);
    // The request's own while its route lives (an iPad turning draws Ask again), else the kept one.
    final session = widget.session ?? request?.session ?? _chats.session(Assistant.linkFor(context, app));
    request?.session = session;
    final send = request != null && request.words.isNotEmpty && !request.sent;
    _show(session, peek: !send);
    if (send) {
      request.sent = true;
      // After the first frame, so the sheet is up before anything changes in it.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(session.ask(request.words, spoken: request.spoken)),
      );
    }
    if (request?.focus ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  /// Shows [s]: it counts this view, and asks the hub what it says for the person now.
  void _show(AskSession s, {bool peek = true}) {
    _session = s
      ..attach()
      ..addListener(_changed);
    _seen = s.exchanges.length;
    _sync();
    if (peek) unawaited(s.peek());
    // Back to a conversation already going: its newest part in view.
    if (s.exchanges.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd(jump: true));
  }

  void _letGo(AskSession s) {
    s.removeListener(_changed);
    // A test's own conversation stays as it is; the one AskChats keeps hears that Ask closed.
    if (widget.session == null || !identical(s, widget.session)) s.detach();
  }

  @override
  void dispose() {
    _slow?.cancel();
    final s = _session;
    if (s != null) _letGo(s);
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

  void _toEnd({bool jump = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (jump || DenMotion.reduced(context)) {
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

  /// A chip: a question is asked at once; a change goes in the field, its example word chosen
  /// so typing replaces it.
  void _pick(AskSuggestion s) {
    if (session.busy) return;
    if (s.send) {
      unawaited(session.ask(s.words));
      return;
    }
    final (start, end) = s.pick ?? (s.words.length, s.words.length);
    _text.value = TextEditingValue(text: s.words, selection: TextSelection(baseOffset: start, extentOffset: end));
    _focus.requestFocus();
  }

  /// "New chat": the conversation is forgotten (a turn still running changes nothing more) and
  /// an empty one takes its place.
  void _newChat() {
    final old = session;
    _letGo(old);
    final fresh = _chats.startOver(old.link);
    widget.request?.session = fresh;
    _text.clear();
    setState(() => _show(fresh));
  }

  /// Closes Ask and opens Settings, AI helper.
  void _setUp() {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push('/settings/assistant');
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
    final entry = askEntry(app, linked: session.link != null);
    final gate = session.gate;
    // A parent can do something about a helper nobody set up.
    final setUp = (me?.isParent ?? false) ? _setUp : null;

    final Widget body;
    Widget? bar;
    switch (entry) {
      case AskEntry.setUp:
        body = AskSetUp(reason: session.link == null ? noHubWords : askOffForParentWords, onSetUp: _setUp);
      case AskEntry.hidden:
        body = Padding(
          padding: const EdgeInsets.symmetric(horizontal: DenLayout.headingInset, vertical: Sp.s),
          child: ProblemLine(problem: gate ?? const HelperProblem.refused(helperOffWords), onRetry: () {}, kid: kid),
        );
      case AskEntry.open when exchanges.isEmpty:
        body = AskWelcome(
          greeting: askGreeting(me?.name, kid: kid),
          help: askHelpWords(kid: kid, stars: app.den.family?.pointsEnabled ?? true),
          suggestions: askSuggestions(app),
          onPick: _pick,
          kid: kid,
          gate: gate,
          onSetUp: gate?.kind == ProblemKind.refused ? setUp : null,
        );
      case AskEntry.open:
        body = Column(
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
          ],
        );
    }
    if (entry == AskEntry.open) {
      bar = gate == null
          ? AskBar(
              controller: _text,
              focus: _focus,
              onAsk: _ask,
              onSpeak: sources.canSpeak ? _speak : null,
              listening: _listening,
              busy: session.busy,
              kid: kid,
              hint: exchanges.isEmpty ? 'Ask anything' : 'Ask something else',
            )
          // Under a conversation it takes the field's place, unless the last answer just said it;
          // the welcome says it itself.
          : (exchanges.isEmpty || exchanges.last.problem?.message == gate.message
                ? null
                : ProblemLine(problem: gate, onRetry: () {}, kid: kid));
    }

    final scroller = SingleChildScrollView(
      controller: _scroll,
      child: ReadableWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
          child: body,
        ),
      ),
    );
    return Column(
      mainAxisSize: widget.panel ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(DenLayout.gutter, widget.panel ? Sp.l : 0, DenLayout.gutter, 0),
          child: _AskHeader(
            onNewChat: entry == AskEntry.open && exchanges.isNotEmpty ? _newChat : null,
            // On a device in several families, Ask acts in the family of the page it is on (the
            // one the device shows; in "All my families", the one last chosen) and says which.
            family: _family(context),
          ),
        ),
        if (widget.panel) Expanded(child: scroller) else Flexible(child: scroller),
        if (bar != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.gutter, Sp.s, DenLayout.gutter, Sp.s),
            child: bar,
          ),
      ],
    );
  }
}

/// Ask's top line: its title, "New chat" while there is a conversation, and "Done". The two
/// pills sit beside the title while they fit, and under it at large text sizes.
class _AskHeader extends StatelessWidget {
  const _AskHeader({this.onNewChat, this.family});

  final VoidCallback? onNewChat;

  /// The family Ask acts in, said under the title when the device holds several.
  final FamilyLog? family;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget pill(String label, VoidCallback onTap) => DenPressable(
          onTap: onTap,
          color: c.card,
          semanticLabel: label,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Targets.adult),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Sp.l + 2),
                child: Center(
                  widthFactor: 1,
                  child: Text(label, style: t.label(c.ink), maxLines: 1, softWrap: false),
                ),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, Sp.l),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Sp.m,
        runSpacing: Sp.s,
        children: [
          if (family == null)
            Semantics(header: true, child: Text('Ask', style: t.sheetTitle(c.ink)))
          else
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text('Ask', style: t.sheetTitle(c.ink))),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SourceTag(label: family!.name, color: family!.color, size: 18, semantics: false),
                    const SizedBox(width: Sp.s),
                    Flexible(child: Text('In ${family!.name}', style: t.meta(c.ink2))),
                  ],
                ),
              ],
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onNewChat != null) ...[pill(newChatLabel, onNewChat!), const SizedBox(width: Sp.s)],
              pill('Done', () => Navigator.of(context).maybePop()),
            ],
          ),
        ],
      ),
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
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AskedLine(member: me, words: x.asked),
          // "Asking Claude" after a second: it fades in, and gives way to the answer the same way.
          DenReveal(
            visible: asking != null,
            child: Padding(
              padding: const EdgeInsets.only(top: Sp.m),
              child: AskingLine(speaker: asking ?? ''),
            ),
          ),
        ],
      ),
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
