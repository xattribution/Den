import 'package:flutter/widgets.dart';

import '../../../app/actions.dart';
import '../../../app/den_scope.dart';

/// Calendars the family subscribes to by link (a school's, a team's), fetched by the hub. Each
/// change is a den_actions action.
class CalendarFeedActions {
  const CalendarFeedActions(this._actions);

  final AppActions _actions;

  /// Subscribes to [url] (https or webcal), named [label] when given, for everyone.
  Future<ActionResult> add(String url, {String? label}) =>
      _actions.run('save_calendar_feed', {'url': url, if (label != null && label.isNotEmpty) 'label': label});

  Future<ActionResult> remove(String feed) => _actions.run('remove_calendar_feed', {'feed': feed});
}

extension CalendarFeedActionsOf on BuildContext {
  CalendarFeedActions get calendarFeeds => CalendarFeedActions(actions);
}
