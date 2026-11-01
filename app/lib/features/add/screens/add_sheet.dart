import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../app/household.dart';
import '../../../app/log_scope.dart';
import '../../../app/redirect.dart' show mergedFamilies;
import '../../../app/words.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../../../design/words.dart';
import '../../../platform/capabilities.dart';
import '../../../platform/capture/capture_sources.dart';
import '../../../platform/web/web_app.dart';
import '../../assistant/assistant.dart';
import '../../calendar/calendar_words.dart';
import '../state/capture_service.dart';
import '../state/quick_add.dart';
import '../words/capture_words.dart';

/// Whether the person acting may add anything Add finds.
bool _canCapture(AppState app) =>
    app.allows(DenAction.editEvents) || app.allows(DenAction.editChores) || app.allows(DenAction.editLists);

/// Opens Add over whatever is showing (Add.dc.html): type or say anything and Den shows what it
/// found as you go, with When, Who and Repeats to adjust; Add puts it where it goes, with Undo
/// in place. Or add one thing by hand.
///
/// When a parent has turned the AI helper on for the person, the field reads "Add or ask
/// anything": Den's own reader still adds plain things at once, and a question, a change to
/// something already there, or words Den can't place go to the helper (`/ask`), going on from the
/// conversation Ask is keeping. "Open Ask" under the rest opens that conversation as it is.
/// Photos and files still go to the review page. See DESIGN.md, "AI helper".
///
/// In "All my families", opened from the app's own places, Add says which family it adds to
/// ("Adding to Kotvas") and offers the others: everything it adds, and every page it opens,
/// is that family's. Opened from a family's own page, it adds there.
Future<void> showAddSheet(BuildContext context) {
  final router = GoRouter.of(context);
  final home = Household.maybeOf(context);
  // The field takes the focus as the sheet opens, so the keyboard comes up with it. In a
  // browser that has to start in this tap, the only time Safari raises the keyboard.
  final app = DenScope.read(context);
  if (_canCapture(app) || helperOn(app, linked: Assistant.linkFor(context, app) != null)) WebApp.keyboardNow();
  if (home != null && home.showingAll && SheetScope.of(context) == null) {
    return showDenSheet<void>(
      context,
      closeLabel: 'Close Add',
      builder: (_) => _AddToFamily(home: home, router: router is ScopedRouter ? router.inner : router),
    );
  }
  return showDenSheet<void>(
    context,
    closeLabel: 'Close Add',
    builder: (_) => AddSheet(open: (route, {extra}) => router.push(route, extra: extra)),
  );
}

/// Add in "All my families": the family it adds to, which the person can change, and Add in
/// that family's scope.
class _AddToFamily extends StatefulWidget {
  const _AddToFamily({required this.home, required this.router});

  final Household home;
  final GoRouter router;

  @override
  State<_AddToFamily> createState() => _AddToFamilyState();
}

class _AddToFamilyState extends State<_AddToFamily> {
  late FamilyLog _log = _first();

  /// The family the device showed last, when "All my families" merges it.
  FamilyLog _first() {
    final families = mergedFamilies(widget.home);
    return families.contains(widget.home.active) ? widget.home.active : families.firstOrNull ?? widget.home.active;
  }

  /// Opens [route] in [log]'s family. Ask stays with the family the device shows, so asking in
  /// another one shows that family first.
  void _open(FamilyLog log, String route, {Object? extra}) {
    // A family page opens in that family; Ask, which is always the family shown, shows it first.
    ScopedRouter(widget.router, log.id, show: () async {
      if (!identical(widget.home.active, log)) await widget.home.choose(log);
    }).push<void>(route, extra: extra);
  }

  @override
  Widget build(BuildContext context) {
    final families = mergedFamilies(widget.home);
    final log = _log;
    return LogScope(
      log: log,
      child: AddSheet(
        key: ValueKey(log.id),
        addingTo: families.length < 2 ? null : _AddingTo(families: families, chosen: log, onChoose: (l) => setState(() => _log = l)),
        open: (route, {extra}) => _open(log, route, extra: extra),
      ),
    );
  }
}

/// "Adding to Kotvas", and each family to choose instead.
class _AddingTo extends StatelessWidget {
  const _AddingTo({required this.families, required this.chosen, required this.onChoose});

  final List<FamilyLog> families;
  final FamilyLog chosen;
  final ValueChanged<FamilyLog> onChoose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, 0, DenLayout.headingInset, Sp.s),
          child: Semantics(liveRegion: true, child: Text('Adding to ${chosen.name}', style: t.label(c.ink))),
        ),
        ChipRow(
          inset: 0,
          children: [
            for (final log in families)
              PersonPill(
                face: SourceTag(label: log.name, color: log.color, size: 28, semantics: false),
                name: log.name,
                selected: identical(log, chosen),
                onTap: () => onChoose(log),
              ),
          ],
        ),
        const SizedBox(height: Sp.l),
      ],
    );
  }
}

/// The Add sheet. [open] opens a route behind it once it has closed.
class AddSheet extends StatefulWidget {
  const AddSheet({super.key, required this.open, this.addingTo});

  final void Function(String route, {Object? extra}) open;

  /// Which family it adds to, with the others to choose ("All my families").
  final Widget? addingTo;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  late final QuickAdd _add = QuickAdd(context.actions);
  final _text = TextEditingController();
  final _focus = FocusNode();
  CaptureSources? _sources;
  bool _listening = false;
  bool _spoken = false;
  String _heard = '';

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      if (_spoken && _text.text != _heard) _spoken = false;
      _add.setText(_text.text, spoken: _spoken);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sources ??= Capture.of(context).sources;
  }

  @override
  void dispose() {
    if (_listening) unawaited(_sources?.stopListening());
    _add.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop();

  /// Leaves for the review page with [input]: a photo, a PDF, a long message.
  void _review(CaptureInput input) {
    _close();
    widget.open('/capture', extra: input);
  }

  /// Sends the words to the AI helper: Add closes and Ask opens with the answer.
  void _askNow() {
    final words = _text.text.trim();
    if (words.isEmpty) return;
    final spoken = _spoken;
    _close();
    widget.open('/ask', extra: AskRequest(words, spoken: spoken));
  }

  /// Opens Ask as it is, with nothing to send.
  void _openAsk() {
    _close();
    widget.open('/ask', extra: AskRequest.open());
  }

  /// Adds what Den found; the field clears for the next thing.
  Future<void> _addFound() async {
    if (await _add.add() && mounted) _text.clear();
  }

  /// Takes the last add back; its words come back to change.
  Future<void> _undoAdded() async {
    final words = _add.added?.text;
    final spoken = _add.added?.spoken ?? false;
    if (await _add.undo() && mounted && words != null) _setWords(words, spoken: spoken);
  }

  void _setWords(String words, {required bool spoken}) {
    _heard = words;
    _spoken = spoken;
    _text.value = TextEditingValue(text: words, selection: TextSelection.collapsed(offset: words.length));
    _add.setText(words, spoken: spoken);
  }

  Future<void> _file(Future<CaptureFile?> Function() source) async {
    try {
      final file = await source();
      if (file != null && mounted) _review(CaptureInput.shared(files: [file], text: _text.text));
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } on Object {
      if (mounted) showNote(context, 'Den couldn\'t open that. Try another photo or file.');
    }
  }

  Future<void> _paste() async {
    final pasted = await WebApp.paste();
    if (!mounted) return;
    if (pasted.bytes != null) {
      _review(CaptureInput.shared(files: [CaptureFile(Uint8List.fromList(pasted.bytes!), pasted.type ?? 'image/png')]));
      return;
    }
    final text = pasted.text ?? (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      showNote(context, 'There\'s nothing to paste. Copy some text or a picture first, then try again.');
      return;
    }
    // A long message or an email goes to the review page; a line stays here.
    if (text.length > 280 || text.contains('\n')) {
      _review(CaptureInput.shared(text: text));
      return;
    }
    _setWords(text.trim(), spoken: false);
  }

  Future<void> _speak() async {
    final sources = _sources!;
    if (_listening) {
      await sources.stopListening();
      return;
    }
    setState(() => _listening = true);
    try {
      final words = await sources.listen(onWords: (w) {
        if (mounted) _setWords(w, spoken: true);
      });
      if (words != null && mounted) _setWords(words, spoken: true);
    } on ReaderException catch (e) {
      if (mounted) showNote(context, e.message);
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {RecordType.list, RecordType.item, RecordType.event, RecordType.chore});
    final c = context.colors;
    final t = context.text;
    final sources = _sources!;
    final capture = _canCapture(app);
    final helper = helperOn(app, linked: Assistant.linkFor(context, app) != null);
    final today = app.today;
    final choices = [
      if (app.allows(DenAction.editEvents))
        NavRow(icon: PhosphorIconsRegular.calendarBlank, label: 'Event', onTap: () => _go('/event/new?date=$today')),
      if (app.allows(DenAction.editChores))
        NavRow(icon: PhosphorIconsRegular.checkCircle, label: 'Chore', onTap: () => _go('/chore/new')),
      if (app.canChangeItems)
        NavRow(icon: PhosphorIconsRegular.shoppingCart, label: 'Grocery item', onTap: () => _go('/lists/groceries/add')),
    ];
    final ask = askAddRow(context, app, onOpen: _openAsk);

    return ListenableBuilder(
      listenable: _add,
      builder: (context, _) {
        // Where the words go while the helper is on: a question or a change goes to it at once;
        // anything else waits for Den's own reader, which adds what it found and hands the
        // helper what it couldn't place. Null: nothing to send yet.
        final words = _add.text.trim();
        final read = !capture || (!_add.reading && (_add.draft != null || _add.problem != null));
        final route = !helper || words.isEmpty || (!soundsLikeAsking(words) && !read)
            ? null
            : addOrAsk(words, found: capture && (_add.draft?.entries.isNotEmpty ?? false));
        return Padding(
        padding: EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, MediaQuery.viewInsetsOf(context).bottom + Sp.xl),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.xs, 0, Sp.l),
                child: Row(
                  children: [
                    Expanded(child: Semantics(header: true, child: Text('Add', style: t.sheetTitle(c.ink)))),
                    DenPressable(
                      onTap: _close,
                      color: c.card,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: Targets.adult),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Sp.l),
                          child: Center(widthFactor: 1, child: Text('Done', style: t.label(c.ink))),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ?widget.addingTo,
              if (capture || helper) ...[
                _Entry(
                  controller: _text,
                  focus: _focus,
                  listening: _listening,
                  label: capture ? (helper ? 'Add or ask anything' : 'Type or say anything') : 'Ask anything',
                  hint: helper ? (capture ? 'Milk, or what’s on Saturday?' : 'What are my chores today?') : null,
                  onSpeak: sources.canSpeak ? _speak : null,
                  onSnap: capture && sources.canSnap ? () => _file(sources.snap) : null,
                  onPick: capture ? () => _file(sources.pick) : null,
                  onPaste: capture && Capabilities.web ? _paste : null,
                ),
                if (route == AddRoute.ask)
                  _AskOffer(onAsk: _askNow)
                else if (capture)
                  _Found(
                    add: _add,
                    onReview: () => _review(_add.spoken ? CaptureInput.spoken(_add.text) : CaptureInput.typed(_add.text)),
                    onAdd: _addFound,
                    onUndo: _undoAdded,
                    onAskInstead: helper && route == AddRoute.add ? _askNow : null,
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.l),
                  child: NoticeLine(
                    icon: PhosphorIconsRegular.lockSimple,
                    message: '${app.me?.name ?? 'You'} can\'t add events, chores or lists here. A parent can change that in Family.',
                  ),
                ),
              if (choices.isNotEmpty) ...[
                const SizedBox(height: DenLayout.sectionGap),
                Padding(
                  padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, 0, DenLayout.headingInset, Sp.s),
                  child: Text('Or add one thing', style: t.meta(c.ink2)),
                ),
                GroupCard(child: Column(children: ruled(choices, indent: 36))),
              ],
              if (ask != null) ...[const SizedBox(height: DenLayout.sectionGap), ask],
            ],
          ),
        ),
      );
      },
    );
  }

  void _go(String route) {
    _close();
    widget.open(route);
  }
}

/// The words and the ways in: the field, Say it, a photo, Paste.
class _Entry extends StatelessWidget {
  const _Entry({
    required this.controller,
    required this.focus,
    required this.listening,
    this.label = 'Type or say anything',
    this.hint,
    this.onPick,
    this.onSpeak,
    this.onSnap,
    this.onPaste,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool listening;

  /// "Type or say anything", or with the AI helper on, "Add or ask anything".
  final String label;
  final String? hint;
  final VoidCallback? onSpeak;
  final VoidCallback? onSnap;

  /// Null when the person can only ask, not add.
  final VoidCallback? onPick;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.text;
    Widget way(IconData icon, String label, VoidCallback onTap, {bool on = false}) => OutlinedButton.icon(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            backgroundColor: on ? c.primary : null,
            foregroundColor: on ? c.onPrimary : null,
          ),
          icon: Icon(icon, size: 20),
          // Side by side on a phone the longest ("Photo of a flyer") may need a little less.
          label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, softWrap: false)),
        );
    // Add.dc.html: Say it and Photo of a flyer, side by side. A phone's camera comes first; a
    // file (a PDF, a screenshot) is the quiet way under them. Without a camera (a browser, a
    // desktop) the file picker takes the photo's place, and Paste joins on the web.
    final ways = [
      if (onSpeak != null) way(PhosphorIconsRegular.microphone, listening ? 'Stop' : 'Say it', onSpeak!, on: listening),
      if (onSnap != null)
        way(PhosphorIconsRegular.camera, 'Photo of a flyer', onSnap!)
      else if (onPick != null)
        way(PhosphorIconsRegular.filePlus, 'Photo or PDF', onPick!),
      if (onPaste != null) way(PhosphorIconsRegular.clipboardText, 'Paste', onPaste!),
    ];
    final file = onSnap == null || onPick == null
        ? null
        : Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: onPick,
              icon: const Icon(PhosphorIconsRegular.filePlus, size: 18),
              label: const Text('Or choose a photo or PDF'),
            ),
          );
    return GroupCard(
      padding: const EdgeInsets.all(DenLayout.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(listening ? 'Listening' : label, style: t.meta(c.ink2)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            focusNode: focus,
            // Add is for typing: the keyboard comes up with the sheet (showAddSheet).
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            style: t.body(c.ink).copyWith(fontSize: 20 * t.scale, height: 1.3),
            decoration: InputDecoration(
              filled: false,
              isCollapsed: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: hint ?? 'Soccer Wednesday at 5 for Leo',
              hintStyle: t.body(c.ink3).copyWith(fontSize: 20 * t.scale, height: 1.3),
            ),
          ),
          if (ways.isNotEmpty) ...[
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                // Side by side while they fit; otherwise one under another.
                final scale = MediaQuery.textScalerOf(context).scale(1);
                if (scale <= 1.35 && (ways.length <= 2 && constraints.maxWidth >= 300 || constraints.maxWidth >= 160.0 * ways.length)) {
                  return Row(
                    children: [
                      for (final (i, w) in ways.indexed) ...[if (i > 0) const SizedBox(width: Sp.s), Expanded(child: w)],
                    ],
                  );
                }
                return Wrap(spacing: Sp.s, runSpacing: Sp.s, children: ways);
              },
            ),
          ],
          if (file != null) ...[const SizedBox(height: Sp.xs), file],
        ],
      ),
    );
  }
}

/// What Den found in the words, to adjust and add; or what was just added, with Undo.
class _Found extends StatelessWidget {
  const _Found({required this.add, required this.onReview, required this.onAdd, required this.onUndo, this.onAskInstead});

  final QuickAdd add;
  final VoidCallback onReview;
  final VoidCallback onAdd;
  final VoidCallback onUndo;

  /// With the AI helper on: send the words to it instead of adding what Den found.
  final VoidCallback? onAskInstead;

  @override
  Widget build(BuildContext context) {
    final app = DenScope.read(context);
    final c = context.colors;
    final t = context.text;
    final added = add.added;
    final draft = add.draft;
    final problem = add.problem;

    Widget? body;
    if (added != null) {
      body = Padding(
        key: const ValueKey('added'),
        padding: const EdgeInsets.only(top: Sp.l),
        child: GroupCard(
          child: DoneRow(
            message: _addedWords(app, added),
            onUndo: added.receipt?.undoable == true ? onUndo : null,
          ),
        ),
      );
    } else if (draft != null && draft.entries.isNotEmpty) {
      final ready = add.ready;
      body = Column(
        key: const ValueKey('found'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Sp.l),
          Padding(
            padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, 0, DenLayout.headingInset, Sp.s),
            child: Text('Den found', style: t.meta(c.ink2)),
          ),
          for (final e in draft.entries) ...[
            _FoundEntry(entry: e, add: add, onReview: onReview),
            const SizedBox(height: Sp.s),
          ],
          if (draft.unclear.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, 0, DenLayout.headingInset, Sp.s),
              child: Text('Den couldn\'t place: ${draft.unclear.join('; ')}', style: t.meta(c.ink2)),
            ),
          const SizedBox(height: Sp.xs),
          FilledButton(
            onPressed: ready.isEmpty || add.adding ? null : onAdd,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: Text(_addLabel(app, ready), maxLines: 1, softWrap: false, overflow: TextOverflow.fade),
          ),
          if (onAskInstead != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: onAskInstead,
                icon: const Icon(PhosphorIconsRegular.chatCircle, size: 18),
                label: const Text('Ask instead'),
              ),
            ),
        ],
      );
    } else if (draft != null && add.text.trim().isNotEmpty && !add.reading) {
      body = Padding(
        key: const ValueKey('nothing'),
        padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.l, DenLayout.headingInset, 0),
        child: Text('Den couldn\'t tell what this is. Add a day or a time, or pick one thing below.', style: t.meta(c.ink2)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DenCrossfade(child: body ?? const SizedBox(key: ValueKey('empty'), width: double.infinity)),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.s),
            child: ErrorState(message: problem, actionLabel: 'Look closer', onAction: onReview),
          ),
      ],
    );
  }

  static String _addLabel(AppState app, List<DraftEntry> ready) {
    if (ready.isEmpty) return 'Add';
    if (ready.every((e) => e is DraftItem)) {
      final lists = {for (final e in ready.cast<DraftItem>()) itemList(app, e).$1};
      if (lists.length == 1) return 'Add to ${lists.single}';
    }
    if (ready.length == 1) {
      return switch (ready.single) {
        DraftEvent() => 'Add to calendar',
        DraftChore() => 'Add chore',
        DraftReminder() => 'Add reminder',
        DraftItem() => 'Add',
      };
    }
    return addWords(ready.length);
  }

  static String _addedWords(AppState app, AddedNote note) {
    final entries = note.entries;
    if (entries.length == 1) {
      final e = entries.single;
      return switch (e) {
        DraftItem() => 'Added ${e.text} to ${itemList(app, e).$1}',
        DraftEvent() => 'Added ${e.title}${_forWhom(app, e.people)}',
        DraftChore() => 'Added ${e.title}${_forWhom(app, entryPeople(e))}',
        DraftReminder() => 'Added a reminder: ${e.text}',
      };
    }
    return 'Added ${joinWords(note.titles)}';
  }

  static String _forWhom(AppState app, List<String> people) {
    final names = [for (final id in people) ?app.memberById(id)?.name];
    return names.isEmpty ? '' : ' for ${joinWords(names)}';
  }
}

/// The words go to the AI helper: one button, the helper's word.
class _AskOffer extends StatelessWidget {
  const _AskOffer({required this.onAsk});

  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Sp.l),
        child: FilledButton.icon(
          onPressed: onAsk,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(PhosphorIconsRegular.chatCircle, size: 22),
          label: const Text('Ask', maxLines: 1, softWrap: false),
        ),
      );
}

/// One thing Den found: who it's for, what it is, when; and the chips to change those.
class _FoundEntry extends StatelessWidget {
  const _FoundEntry({required this.entry, required this.add, required this.onReview});

  final DraftEntry entry;
  final QuickAdd add;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final app = DenScope.read(context);
    final c = context.colors;
    final t = context.text;
    final e = entry;
    final people = entryPeople(e);
    final first = people.isEmpty ? null : app.memberById(people.first);
    // The chips say when, who and how often; the line under the title says the rest.
    final (title, detail) = switch (e) {
      DraftEvent() => (
          e.title,
          [
            if (e.start != null && e.end != null) '${clockWords(e.start!)} to ${clockWords(e.end!)}',
            if (e.location.isNotEmpty) e.location,
          ].join(' · '),
        ),
      DraftChore() => (e.title, e.dueTime == null ? '' : 'By ${clockWords(e.dueTime!)}'),
      DraftReminder() => (e.text, reminderWhen(app, e)),
      DraftItem() => (e.text, [itemList(app, e).$1, if (itemDetail(e).isNotEmpty) itemDetail(e)].join(' · ')),
    };
    final leading = first != null
        ? DenAvatar(first, size: 40)
        : SizedBox.square(
            dimension: 40,
            child: Icon(
              switch (e) {
                DraftEvent() => PhosphorIconsRegular.calendarBlank,
                DraftChore() => PhosphorIconsRegular.checkCircle,
                DraftReminder() => PhosphorIconsRegular.bell,
                DraftItem() => PhosphorIconsRegular.shoppingCart,
              },
              size: 24,
              color: c.ink,
            ),
          );
    final chips = _chips(context, app, e);
    final issues = e.issues.where((i) => i.holds || i.blocking).toList();
    return GroupCard(
      padding: const EdgeInsets.all(DenLayout.cardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              leading,
              const SizedBox(width: Sp.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tidy(title), style: t.rowTitle(c.ink).copyWith(fontSize: 18 * t.scale)),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(tidy(detail), style: t.meta(c.ink2)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: Sp.m),
            Wrap(spacing: Sp.s, runSpacing: Sp.s, children: chips),
          ],
          for (final i in issues) ...[
            const SizedBox(height: Sp.s),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(PhosphorIconsBold.question, size: 18, color: c.ink),
                ),
                const SizedBox(width: Sp.s),
                Expanded(child: Text(i.message, style: t.meta(c.ink))),
              ],
            ),
          ],
          if (e.blocked) ...[
            const SizedBox(height: Sp.s),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton(onPressed: onReview, child: const Text('Change')),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _chips(BuildContext context, AppState app, DraftEntry e) {
    final f = app.formats;
    final today = app.today;
    switch (e) {
      case DraftEvent():
        final day = f.relative(e.date, today);
        final when = e.allDay ? '$day, all day' : '$day at ${clockWords(e.start!)}';
        final names = [for (final id in e.people) ?app.memberById(id)?.name];
        final repeat = describeRrule(e.rrule, f, startDate: e.date, weekStart: app.den.family?.weekStart ?? 0);
        return [
          ValueChip(icon: PhosphorIconsRegular.clock, label: 'When', value: when, onTap: () => _when(context, app, e)),
          ValueChip(
            icon: PhosphorIconsRegular.user,
            label: 'Who',
            value: names.isEmpty ? 'Everyone' : joinWords(names),
            onTap: () => _who(context, app, e),
          ),
          ValueChip(
            icon: PhosphorIconsRegular.repeat,
            label: 'Repeats',
            value: repeat ?? 'Once',
            onTap: () => _repeat(context, app, e),
          ),
        ];
      case DraftChore():
        return [
          ValueChip(
            icon: PhosphorIconsRegular.user,
            label: 'Who',
            value: ownerWords(app, e.owner),
            onTap: () => _choreWho(context, app, e),
          ),
          ValueChip(
            icon: PhosphorIconsRegular.calendarBlank,
            label: 'When',
            value: e.rrule == null
                ? f.relative(e.date, today)
                : describeRrule(e.rrule, f, startDate: e.date, weekStart: app.den.family?.weekStart ?? 0) ?? 'Repeats',
            onTap: () => _choreDay(context, app, e),
          ),
        ];
      case DraftItem() || DraftReminder():
        return const [];
    }
  }

  Future<void> _when(BuildContext context, AppState app, DraftEvent e) async {
    final f = app.formats;
    final d = f.dateTime(e.date);
    final date = await showDatePicker(
      context: context,
      builder: carryTransition(context),
      initialDate: DateTime(d.year, d.month, d.day),
      firstDate: DateTime(d.year - 1),
      lastDate: DateTime(d.year + 3),
      helpText: e.title,
    );
    if (date == null || !context.mounted) return;
    final day = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    if (e.allDay) {
      add.replace(e.copyWith(date: day));
      return;
    }
    final start = f.parseHhmm(e.start)!;
    final picked = await showTimePicker(
      context: context,
      builder: carryTransition(context),
      initialTime: TimeOfDay(hour: start ~/ 60, minute: start % 60),
      helpText: e.title,
    );
    if (!context.mounted) return;
    final from = picked == null ? start : picked.hour * 60 + picked.minute;
    final end = e.end == null ? null : f.parseHhmm(e.end);
    final length = end == null ? null : (end - start) % (24 * 60);
    add.replace(e.copyWith(
      date: day,
      start: f.hhmm(from),
      end: length == null ? null : f.hhmm((from + length) % (24 * 60)),
    ));
  }

  Future<void> _who(BuildContext context, AppState app, DraftEvent e) async {
    final pick = await showPeoplePicker(
      context,
      title: 'Who is it for?',
      people: app.den.members,
      current: e.people.length == 1 ? e.people.single : null,
      anyoneLabel: 'Everyone',
      anyoneCurrent: e.people.isEmpty,
    );
    if (pick == null) return;
    add.replace(e.copyWith(people: pick.anyone ? const [] : [pick.member!]));
  }

  Future<void> _repeat(BuildContext context, AppState app, DraftEvent e) async {
    final rule = await _pickRepeat(context, app, date: e.date, current: e.rrule);
    if (rule == null) return;
    add.replace(e.copyWith(rrule: rule.isEmpty ? null : rule));
  }

  Future<void> _choreWho(BuildContext context, AppState app, DraftChore e) async {
    final pick = await showPeoplePicker(
      context,
      title: 'Whose chore?',
      people: app.den.members,
      current: switch (e.owner) {
        OwnerMember(:final id) => id,
        _ => null,
      },
      anyoneLabel: 'Anyone',
      anyoneCurrent: e.owner is OwnerAnyone,
    );
    if (pick == null) return;
    add.replace(e.copyWith(owner: pick.anyone ? const OwnerAnyone() : OwnerMember(pick.member!)));
  }

  Future<void> _choreDay(BuildContext context, AppState app, DraftChore e) async {
    final rule = await _pickRepeat(context, app, date: e.date, current: e.rrule, onceLabel: 'Just that day');
    if (rule == null) return;
    add.replace(e.copyWith(rrule: rule.isEmpty ? null : rule));
  }
}

/// A sheet of the usual ways to repeat from [date]: not at all, every day, every week on its
/// weekday, every other week, every month on its date. Completes with the rule (empty for not
/// at all), or null when closed.
Future<String?> _pickRepeat(BuildContext context, AppState app, {required String date, String? current, String onceLabel = 'Doesn\'t repeat'}) {
  final f = app.formats;
  final weekStart = app.den.family?.weekStart ?? 0;
  final weekday = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'][f.dateTime(date).weekday - 1];
  final usual = [
    'FREQ=DAILY',
    'FREQ=WEEKLY;BYDAY=$weekday',
    'FREQ=WEEKLY;INTERVAL=2;BYDAY=$weekday',
    'FREQ=MONTHLY;BYMONTHDAY=${int.parse(date.substring(8))}',
  ];
  final rules = [
    ...usual,
    // What Den heard, when it's none of the usual ones ("Mondays and Thursdays").
    if (current != null && current.isNotEmpty && !usual.contains(current)) current,
  ];
  final options = <(String, String)>[
    ('', onceLabel),
    for (final rule in rules) (rule, describeRrule(rule, f, startDate: date, weekStart: weekStart) ?? 'Repeats'),
  ];
  return showDenSheet<String>(
    context,
    builder: (sheet) {
      final c = sheet.colors;
      return Padding(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.s, DenLayout.headingInset, Sp.l),
              child: Semantics(header: true, child: Text('Repeats', style: sheet.text.sheetTitle(c.ink))),
            ),
            GroupCard(
              child: Column(
                children: ruled([
                  for (final (rule, label) in options)
                    NavRow(
                      label: label,
                      chevron: false,
                      leading: rule == (current ?? '')
                          ? Icon(PhosphorIconsBold.check, size: 22, color: c.ink)
                          : const SizedBox(width: 22),
                      onTap: () => Navigator.of(sheet).pop(rule),
                    ),
                ], indent: 34),
              ),
            ),
          ],
        ),
      );
    },
  );
}
