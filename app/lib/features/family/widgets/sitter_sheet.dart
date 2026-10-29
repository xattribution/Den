import 'package:den_core/den_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/app_state.dart';
import '../../../design/layout.dart';
import '../../../design/motion.dart';
import '../../../design/sheet.dart';
import '../../../design/tokens.dart';
import '../../../design/widgets.dart';
import '../state/family_needs.dart';
import '../state/trust_actions.dart';
import '../words/family_words.dart';
import '../words/sitter.dart';
import 'family_parts.dart';
import 'person_sheets.dart' show ConfirmLine, sheetPadding;

enum _Last { none, sunday, day }

/// "Sam's last day": no end, until Sunday, or a day picked on the calendar, said before it saves;
/// and ending their access now. A parent's own device only, like the other trust decisions.
Future<void> showUntilSheet(BuildContext context, Member member) =>
    showDenSheet<void>(context, builder: (_) => _UntilSheet(member: member));

class _UntilSheet extends StatefulWidget {
  const _UntilSheet({required this.member});
  final Member member;

  @override
  State<_UntilSheet> createState() => _UntilSheetState();
}

class _UntilSheetState extends State<_UntilSheet> {
  late final AppState _app = DenScope.read(context);
  late final String _sunday = comingSunday(_app.formats, _app.today);
  late final String? _was = widget.member.until;
  late _Last _last = _was == null ? _Last.none : (_was == _sunday ? _Last.sunday : _Last.day);
  late String? _day = _last == _Last.day ? _was : null;
  bool _ending = false;
  bool _busy = false;
  String? _error;

  String get _name => widget.member.name;

  String? get _until => switch (_last) {
        _Last.none => null,
        _Last.sunday => _sunday,
        _Last.day => _day,
      };

  Future<void> _pickDay() async {
    final f = _app.formats;
    final today = f.dateTime(_app.today);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day == null ? f.dateTime(f.addDays(_app.today, 7)) : f.dateTime(_day!),
      firstDate: today,
      lastDate: DateTime(today.year + 2, today.month, today.day),
      helpText: '${FamilyWords.possessive(_name)} last day',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _day = DateFormat('yyyy-MM-dd').format(picked);
      _last = _Last.day;
      _error = null;
    });
  }

  Future<void> _write(Future<void> Function() write) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await tryWrite(write);
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = problem;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final f = app.formats;
    final m = app.den.member(widget.member.id) ?? widget.member;
    final changed = _until != _was && (_last != _Last.day || _day != null);
    final ended = m.accessEndedOn(app.today);
    final devices = devicesOf(app.den, m.id);
    final trust = context.trustActions;
    return SingleChildScrollView(
      padding: sheetPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: '${FamilyWords.possessive(_name)} last day'),
          GroupCard(
            child: ChoiceRows<_Last>(
              choices: [
                const Choice(_Last.none, 'No end'),
                Choice(_Last.sunday, 'Until ${dayWords(f, _sunday, app.today)}', detail: f.long(_sunday)),
                Choice(
                  _Last.day,
                  _day == null ? 'Until a day you pick' : 'Until ${f.short(_day!)}',
                  detail: _day == null ? null : 'Pick another day',
                ),
              ],
              value: _last,
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v == _Last.day) {
                        _pickDay();
                        return;
                      }
                      setState(() {
                        _last = v;
                        _error = null;
                      });
                    },
            ),
          ),
          DenReveal(
            visible: changed,
            child: !changed
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.fromLTRB(DenLayout.headingInset, Sp.l, DenLayout.headingInset, 0),
                    child: ConfirmLine(
                      message: untilChange(_name, _until, f, app.today, removed: ended),
                      error: _ending ? null : _error,
                      button: FilledButton(
                        onPressed: _busy ? null : () => _write(() => trust.setUntil(m.id, _until)),
                        child: const Text('Save', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ),
          ),
          if (!ended && devices.isNotEmpty) ...[
            const SizedBox(height: Sp.l),
            if (!_ending)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _ending = true),
                  style: TextButton.styleFrom(foregroundColor: context.colors.destructive),
                  icon: Icon(PhosphorIconsRegular.calendarX, size: 20, color: context.colors.destructive),
                  label: Text("End $_name's access now"),
                ),
              ),
            DenReveal(
              visible: _ending,
              child: !_ending
                  ? const SizedBox(width: double.infinity)
                  : ConfirmPanel(
                      message: "$_name's devices stop syncing and are removed now. To let $_name back in later, choose "
                          'a new last day and invite $_name again.',
                      confirmLabel: 'End access',
                      destructive: true,
                      busy: _busy,
                      error: _error,
                      onConfirm: () => _write(() => trust.endAccessNow(m.id)),
                      onCancel: () => setState(() {
                        _ending = false;
                        _error = null;
                      }),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// On a sitter's page once their last day has passed: that their access ended, and the way
/// back, which is a new last day and a new invite.
class AccessEndedNotice extends StatelessWidget {
  const AccessEndedNotice({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final app = context.watch(const {});
    final until = member.until;
    if (until == null) return const SizedBox.shrink();
    final name = member.name;
    return NoticeLine(
      icon: PhosphorIconsRegular.calendarX,
      message: '${accessEndedWords(name, until, app.formats, app.today)}. To let $name back in, choose a new last day, '
          'then invite $name again.',
    );
  }
}
