import 'package:den_core/den_core.dart';

import '../context.dart';
import '../input.dart';
import '../resolve.dart';
import '../schema.dart';
import '../shapes.dart';
import '../spec.dart';
import '../times.dart';
import '../wire.dart';

const List<String> _weekdays = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];

/// Family settings, people (not their roles, permissions or sign-in), event categories and
/// subscribed calendars.
List<ActionSpec> familyActions() => [
      ActionSpec(
        name: 'family.save_category',
        mcpName: 'save_category',
        title: 'Add or change a category',
        description: 'Adds an event category (School, Sports, ...), or with "category" renames one or changes its '
            'picture.',
        input: S.input({
          'category': S.string('The category to change (name or id); leave out to add one.'),
          'name': S.string('Its name.', maxLength: 100),
          'icon': S.string('A pictogram.', oneOf: PictogramKeys.categories),
        }),
        output: S.output({'category': categoryShape}),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.destructive,
        confirm: Confirm.client,
        confirmWhen: (c, a) => a.has('category'),
        engine: const {'addCategory', 'updateCategory'},
        example: const {'name': 'Music', 'icon': 'music'},
        run: _saveCategory,
      ),
      ActionSpec(
        name: 'family.delete_category',
        mcpName: 'delete_category',
        title: 'Remove a category',
        description: 'Removes an event category. Its events stay, without a category.',
        input: S.input({'category': S.string('The category (name or id).')}, required: ['category']),
        output: S.output({'ok': Out.flag('It worked.'), 'category_id': Out.str('The category.')}),
        scopes: const {Scope.calendar},
        needs: const [DenAction.editEvents],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        ask: (c, a) => 'Remove the category ${_category(c, a.str('category', required: true)!).name}?',
        engine: const {'deleteCategory'},
        example: const {'category': 'Birthdays'},
        run: _deleteCategory,
      ),
      ActionSpec(
        name: 'family.update_settings',
        mcpName: 'update_family_settings',
        title: 'Change family settings',
        description: 'Changes the family\'s name, time zone, the first day of its week, whether stars are on, and '
            'whether what Den reads from photos and messages is added at once or waits for review. Who sees '
            'whose private things is set only in the Den app.',
        input: S.input({
          'name': S.string('The family\'s name.', maxLength: 100),
          'timezone': S.string('An IANA time zone, such as America/Chicago.', maxLength: 64),
          'week_start': S.string('The first day of the week.', oneOf: _weekdays),
          'points_enabled': S.boolean('Whether stars are on.'),
          'capture': S.string('direct: what Den reads is added at once; review: it waits for a look.', oneOf: ['direct', 'review']),
        }),
        output: S.output({'family': familyShape, 'settings': S.object({'capture': Out.str('direct or review.')})}),
        scopes: const {Scope.admin},
        needs: const [DenAction.manageFamily],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.client,
        engine: const {'updateFamily'},
        example: const {'name': 'The Carters'},
        run: _updateFamily,
      ),
      ActionSpec(
        name: 'family.save_member',
        mcpName: 'save_member',
        title: 'Add someone or change their details',
        description: 'Adds a person to the family, or with "member" changes their name, color, picture, birthday, '
            'age group or place in the order. Roles, permissions and sign-in change only in the Den app, on a '
            'parent\'s own device.',
        input: S.input({
          'member': S.string('The person to change (name or id); leave out to add someone.'),
          'name': S.string('Their name.', maxLength: 100),
          'role': S.string('For someone new: parent, adult, kid (default) or guest.', oneOf: [for (final r in Role.values) r.name]),
          'tier': S.string('For a kid: preReader, little, big or teen; empty for none.'),
          'color': S.string('Their color.', oneOf: [for (final m in Marker.values) m.name]),
          'picture': S.string('Their picture, by name from Den\'s pack, or "initial" for the first letter of their name.',
              oneOf: [...Picture.pack, Picture.initial]),
          'birthday': S.date('Their birthday; empty for none.'),
          'order': S.integer('Their place in the family\'s order.', min: 0, max: 1000),
        }),
        output: S.output({'member': memberShape}),
        scopes: const {Scope.admin},
        needs: const [DenAction.manageFamily],
        effect: Effect.destructive,
        confirm: Confirm.client,
        engine: const {'addMember', 'updateMember'},
        // Colors and pictures by name from their lists, whatever the palette and pack hold.
        example: {'name': 'Grandpa Joe', 'role': 'adult', 'color': Marker.values.last.name, 'picture': Picture.pack.first},
        run: _saveMember,
      ),
      ActionSpec(
        name: 'family.save_feed',
        mcpName: 'save_calendar_feed',
        title: 'Subscribe to a calendar',
        description: 'Subscribes the family to a calendar published on the web (an https or webcal ICS address, '
            'such as a school\'s or a team\'s), or with "feed" changes one. The hub fetches it and keeps its events '
            'in sync, read-only.',
        input: S.input({
          'feed': S.string('The subscription to change (its name or id); leave out to add one.'),
          'url': S.string('The calendar\'s https or webcal address.', maxLength: 2000),
          'label': S.string('A name for it.', maxLength: 200),
          'category': S.string('A category for its events (name or id); empty for none.'),
          'person': S.person('Who its events are for; empty for everyone.'),
          'who_can_see': S.string('"everyone" (default), "parents", or a person\'s name.'),
          'include': S.array(S.string('Words.', maxLength: 200), 'Only events with these words.', maxItems: 50),
          'exclude': S.array(S.string('Words.', maxLength: 200), 'Not events with these words.', maxItems: 50),
          'skip_all_day': S.boolean('Leave out all-day events.'),
        }),
        output: S.output({'feed': feedShape}),
        scopes: const {Scope.admin},
        needs: const [DenAction.manageFamily],
        effect: Effect.destructive,
        confirm: Confirm.server,
        ask: (c, a) => a.has('feed')
            ? 'Change the calendar subscription ${_feed(c, a.str('feed')!).label}?'
            : 'Subscribe the family to ${a.str('url') ?? 'that calendar'}? Its events will show for '
                '${a.str('who_can_see') ?? 'everyone'}.',
        engine: const {'addSubscription', 'updateSubscription'},
        example: const {'url': 'https://school.example.org/calendar.ics', 'label': 'Oak Grove School', 'category': 'School'},
        run: _saveFeed,
      ),
      ActionSpec(
        name: 'family.remove_feed',
        mcpName: 'remove_calendar_feed',
        title: 'Unsubscribe from a calendar',
        description: 'Stops a calendar subscription.',
        input: S.input({'feed': S.string('The subscription (its name or id).')}, required: ['feed']),
        output: S.output({'ok': Out.flag('It worked.'), 'feed_id': Out.str('The subscription.')}),
        scopes: const {Scope.admin},
        needs: const [DenAction.manageFamily],
        effect: Effect.destructive,
        idempotent: true,
        confirm: Confirm.server,
        ask: (c, a) => 'Stop the calendar subscription ${_feed(c, a.str('feed', required: true)!).label}?',
        engine: const {'removeSubscription'},
        example: const {'feed': 'School calendar'},
        run: _removeFeed,
      ),
    ];

EventCategory _category(ActionContext c, String query) =>
    pick(query, c.den.categories, id: (x) => x.id, name: (x) => x.name, kind: 'category');

Subscription _feed(ActionContext c, String query) => pick(
      query,
      c.den.subscriptions,
      id: (s) => s.id,
      name: (s) => s.label.isEmpty ? s.url : s.label,
      kind: 'calendar subscription',
    );

Future<ActionResult> _saveCategory(ActionContext c, ActionInput a) async {
  final String id;
  if (a.has('category')) {
    final category = _category(c, a.str('category')!);
    final patch = <String, Object?>{
      if (a.has('name')) 'name': a.str('name')!.trim(),
      if (a.has('icon')) 'icon': a.str('icon'),
    };
    if (patch.isEmpty) throw ActionError('Nothing to change: give a "name" or an "icon".');
    await c.den.updateCategory(category.id, patch);
    id = category.id;
  } else {
    if (!a.has('name')) throw ActionError('A new category needs a "name".', field: 'name');
    id = await c.den.addCategory(name: a.str('name', required: true)!.trim(), icon: a.str('icon') ?? 'calendar');
  }
  final category = c.den.category(id)!;
  return ActionResult(
    '${a.has('category') ? 'Changed' : 'Added'} the category ${category.name} [category $id].',
    {'category': Wire.category(category)},
  );
}

Future<ActionResult> _deleteCategory(ActionContext c, ActionInput a) async {
  final category = _category(c, a.str('category', required: true)!);
  await c.den.deleteCategory(category.id);
  return ActionResult('Removed the category ${category.name}.', {'ok': true, 'category_id': category.id});
}

Future<ActionResult> _updateFamily(ActionContext c, ActionInput a) async {
  final tz = a.str('timezone')?.trim();
  if (tz != null && !isZone(tz)) throw ActionError('Den doesn\'t know the time zone "$tz".', field: 'timezone');
  final patch = <String, Object?>{
    if (a.has('name')) 'name': a.str('name')!.trim(),
    'timezone': ?tz,
    if (a.has('week_start')) 'weekStart': _weekdays.indexOf(a.str('week_start')!),
    if (a.has('points_enabled')) 'pointsEnabled': a.flag('points_enabled'),
    if (a.has('capture')) 'capture': a.str('capture'),
  };
  if (patch.isEmpty) throw ActionError('Nothing to change: give a setting such as name or week_start.');
  await c.den.updateFamily(patch);
  final f = c.den.family!;
  final said = [
    if (a.has('name')) 'the name to ${f.name}',
    if (tz != null) 'the time zone to ${f.timezone}',
    if (a.has('week_start')) 'the first day of the week to ${a.str('week_start')}',
    if (a.has('points_enabled')) f.pointsEnabled ? 'stars on' : 'stars off',
    if (a.has('capture')) f.captureNeedsReview ? 'what Den reads to wait for a look' : 'what Den reads to be added at once',
  ];
  return ActionResult('Set ${joinNames(said)}.', {
    'family': c.wire.family(),
    'settings': {'capture': f.captureNeedsReview ? 'review' : 'direct'},
  });
}

T? _named<T extends Enum>(List<T> values, String? name) {
  if (name == null || name.trim().isEmpty) return null;
  for (final v in values) {
    if (v.name.toLowerCase() == name.trim().toLowerCase()) return v;
  }
  throw ActionError('"$name" must be one of ${values.map((v) => v.name).join(', ')}.');
}

Future<ActionResult> _saveMember(ActionContext c, ActionInput a) async {
  final tierText = a.str('tier');
  final tier = _named(Tier.values, tierText);
  final birthday = a.str('birthday')?.trim();
  final String id;
  if (a.has('member')) {
    final member = c.people.one(a.str('member')!);
    if (a.has('role')) {
      throw ActionError.denied('A person\'s role changes only in the Den app, on a parent\'s own device.');
    }
    final patch = <String, Object?>{
      if (a.has('name')) 'name': a.str('name')!.trim(),
      if (tierText != null) 'tier': tier?.name,
      if (a.has('color')) 'marker': a.str('color'),
      if (a.has('picture')) 'picture': a.str('picture'),
      if (birthday != null) 'birthday': birthday.isEmpty ? null : toolDate(birthday, c.zone, 'birthday'),
      if (a.has('order')) 'order': a.integer('order'),
    };
    if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as name, color or birthday.');
    await c.den.updateMember(member, patch);
    id = member;
  } else {
    if (!a.has('name')) throw ActionError('Someone new needs a "name".', field: 'name');
    id = await c.den.addMember(
      name: a.str('name', required: true)!.trim(),
      role: _named(Role.values, a.str('role')) ?? Role.kid,
      tier: tier,
      marker: _named(Marker.values, a.str('color')),
      picture: a.str('picture') ?? Picture.initial,
      birthday: birthday == null || birthday.isEmpty ? null : toolDate(birthday, c.zone, 'birthday'),
    );
    if (a.has('order')) await c.den.updateMember(id, {'order': a.integer('order')});
  }
  final m = c.den.member(id)!;
  return ActionResult(
    a.has('member') ? 'Changed ${m.name}\'s details [member $id].' : 'Added ${m.name} (${m.role.name}) to the family [member $id].',
    {'member': Wire.member(m)},
  );
}

/// The https address of a calendar to subscribe to, refusing anything but a public host: a
/// subscription makes the hub fetch the address, and an assistant mustn't point it at the
/// home's own network.
String feedAddress(String raw) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    throw ActionError('That isn\'t a web address.', field: 'url');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'http') throw ActionError('Use the calendar\'s https address.', field: 'url');
  if (scheme != 'https' && scheme != 'webcal' && scheme != 'webcals') {
    throw ActionError('A calendar address starts with https:// or webcal://.', field: 'url');
  }
  final host = uri.host.toLowerCase();
  final labels = host.split('.');
  // A name on the public web: dotted, ending in a real top-level domain (letters, never digits,
  // which an IP address or a resolver's shorthand like 0x7f.1 would be), and not one of the
  // names homes and offices keep for themselves.
  final public = labels.length >= 2 &&
      labels.every((l) => l.isNotEmpty) &&
      RegExp(r'^[a-z][a-z0-9-]*[a-z0-9]$').hasMatch(labels.last) &&
      !const {'local', 'localhost', 'internal', 'lan', 'home', 'arpa', 'intranet', 'corp', 'invalid', 'test'}
          .contains(labels.last);
  if (!public || uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != 443)) {
    throw ActionError('Den subscribes only to calendars on the public web, at their usual https address.', field: 'url');
  }
  return uri.replace(scheme: 'https').toString();
}

Future<ActionResult> _saveFeed(ActionContext c, ActionInput a) async {
  final category = a.str('category')?.trim();
  final person = a.str('person')?.trim();
  final categoryId = category == null || category.isEmpty ? null : c.category(category);
  final assignee = person == null || person.isEmpty ? null : c.people.one(person);
  final String id;
  if (a.has('feed')) {
    final feed = _feed(c, a.str('feed')!);
    final patch = <String, Object?>{
      if (a.has('url')) 'url': feedAddress(a.str('url')!),
      if (a.has('label')) 'label': a.str('label')!.trim(),
      if (category != null) 'category': categoryId,
      if (person != null) 'assignee': assignee,
      if (a.has('who_can_see')) 'space': c.space(a.raw['who_can_see']),
      if (a.has('include')) 'include': a.list('include'),
      if (a.has('exclude')) 'exclude': a.list('exclude'),
      if (a.has('skip_all_day')) 'skipAllDay': a.flag('skip_all_day'),
    };
    if (patch.isEmpty) throw ActionError('Nothing to change: give a field such as label or url.');
    await c.den.updateSubscription(feed.id, patch);
    id = feed.id;
  } else {
    if (!a.has('url')) throw ActionError('A subscription needs the calendar\'s "url".', field: 'url');
    id = await c.den.addSubscription(
      url: feedAddress(a.str('url')!),
      label: a.str('label')?.trim() ?? '',
      category: categoryId,
      assignee: assignee,
      space: c.space(a.raw['who_can_see']),
      include: [for (final w in a.list('include') ?? const []) '$w'],
      exclude: [for (final w in a.list('exclude') ?? const []) '$w'],
      skipAllDay: a.flag('skip_all_day') ?? false,
    );
  }
  final s = c.den.subscription(id)!;
  return ActionResult(
    '${a.has('feed') ? 'Changed the subscription to' : 'Subscribed the family to'} ${s.label.isEmpty ? s.url : s.label}. '
    'The hub fetches it in a minute or two [feed $id].',
    {'feed': feedJson(s)},
  );
}

/// A subscription as the actions answer with it.
Map<String, Object?> feedJson(Subscription s) => {
      'id': s.id,
      'url': s.url,
      'label': s.label,
      'category': s.category,
      'assignee': s.assignee,
      ...Wire.spaceFields(s.targetSpace),
      'include': s.include,
      'exclude': s.exclude,
      'skip_all_day': s.skipAllDay,
      'status': s.status,
    };

Future<ActionResult> _removeFeed(ActionContext c, ActionInput a) async {
  final feed = _feed(c, a.str('feed', required: true)!);
  await c.den.removeSubscription(feed.id);
  return ActionResult(
    'Stopped the subscription to ${feed.label.isEmpty ? feed.url : feed.label}. Events it brought in stay until the hub tidies them.',
    {'ok': true, 'feed_id': feed.id},
  );
}
