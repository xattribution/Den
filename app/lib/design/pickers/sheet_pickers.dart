import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../layout.dart';
import '../sheet.dart';
import '../tokens.dart';
import '../widgets/choices.dart';
import '../widgets/section.dart';
import '../widgets/sheet_header.dart';
import '../widgets/states.dart';

/// The pickers an editor opens, as Den sheets rather than Material menus and dialogs: they rise
/// and close on the sheet spring, follow a drag, and become centered form sheets on iPad.

/// One of [choices], checked at [value]; a tap picks and closes. [empty] says why there is
/// nothing to pick when there isn't. Null when closed without a pick.
Future<T?> showChoiceSheet<T>(
  BuildContext context, {
  required String title,
  required List<Choice<T>> choices,
  required T value,
  String empty = 'There is nothing to pick yet.',
}) =>
    showDenSheet<T>(
      context,
      builder: (sheet) => _SheetFrame(
        title: title,
        child: GroupCard(
          child: choices.isEmpty
              ? EmptyState(compact: true, message: empty)
              : ChoiceRows<T>(
                  choices: choices,
                  value: value,
                  onChanged: (picked) => Navigator.of(sheet).pop(picked),
                ),
        ),
      ),
    );

/// A day, from a month calendar: [initial] picked, from [first] to [last]; Done keeps the day
/// last tapped (a year or a month only moves the calendar). [yearFirst] opens on the years, for
/// a birthday. Null when closed without Done.
Future<DateTime?> showDayPicker(
  BuildContext context, {
  required String title,
  required DateTime initial,
  required DateTime first,
  required DateTime last,
  bool yearFirst = false,
}) {
  var picked = initial;
  return showDenSheet<DateTime>(
    context,
    builder: (sheet) => _SheetFrame(
      title: title,
      action: 'Done',
      onAction: () => Navigator.of(sheet).pop(picked),
      child: GroupCard(
        padding: const EdgeInsets.symmetric(horizontal: Sp.s),
        child: CalendarDatePicker(
          initialDate: initial,
          firstDate: first,
          lastDate: last,
          initialCalendarMode: yearFirst ? DatePickerMode.year : DatePickerMode.day,
          onDateChanged: (day) => picked = day,
        ),
      ),
    ),
  );
}

/// A time of day on the wheel iPhone people know, starting at [initial]; Done keeps it. Null when
/// closed without Done.
Future<TimeOfDay?> showTimeWheel(BuildContext context, {required String title, required TimeOfDay initial}) {
  var picked = initial;
  return showDenSheet<TimeOfDay>(
    context,
    builder: (sheet) {
      final c = sheet.colors;
      return _SheetFrame(
        title: title,
        action: 'Done',
        onAction: () => Navigator.of(sheet).pop(picked),
        child: GroupCard(
          child: SizedBox(
            height: 216,
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: c.brightness,
                textTheme: CupertinoTextThemeData(dateTimePickerTextStyle: sheet.text.section(c.ink).regular),
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.time,
                minuteInterval: 5,
                initialDateTime: DateTime(2000, 1, 1, initial.hour, initial.minute - initial.minute % 5),
                onDateTimeChanged: (t) => picked = TimeOfDay(hour: t.hour, minute: t.minute),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A picker sheet's frame: the title with Close (or [action], in ink), and its content under it
/// on the page gutter, scrolling when it's taller than the sheet.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.child, this.action, this.onAction});

  final String title;
  final Widget child;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(DenLayout.gutter, 0, DenLayout.gutter, Sp.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetHeader(title: title, actionLabel: action ?? 'Close', onAction: onAction, primary: action != null),
            Flexible(child: SingleChildScrollView(child: child)),
          ],
        ),
      );
}
