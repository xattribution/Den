/// MCP resources: the family's day, week, people, lists, chores and stars as read-only JSON
/// documents an assistant can attach or subscribe to. Each one is a read action's answer
/// (den_actions), so it shows exactly what that action would: the caller's member's view,
/// within the token's scopes.
library;

/// The URI scheme of Den's resources.
const String denScheme = 'den';

/// One fixed resource.
class McpResource {
  /// A resource at [uri] answered by read action [action] with [args].
  const McpResource({
    required this.uri,
    required this.name,
    required this.title,
    required this.description,
    required this.action,
    this.args = const {},
  });

  /// `den://...`.
  final String uri;

  /// A short name.
  final String name;

  /// What people see.
  final String title;

  /// What it holds.
  final String description;

  /// The read action (its MCP name) that answers it.
  final String action;

  /// The action's arguments.
  final Map<String, Object?> args;

  /// As `resources/list` shows it.
  Map<String, Object?> toJson() =>
      {'uri': uri, 'name': name, 'title': title, 'description': description, 'mimeType': 'application/json'};
}

/// A family of resources with one variable part, such as one list by name.
class McpResourceTemplate {
  /// A template [uriTemplate] (`den://lists/{list}`) answered by [action], whose variable goes
  /// to the action's [argument].
  const McpResourceTemplate({
    required this.prefix,
    required this.suffix,
    required this.variable,
    required this.name,
    required this.title,
    required this.description,
    required this.action,
    required this.argument,
    this.args = const {},
  });

  /// What comes before the variable (`den://lists/`).
  final String prefix;

  /// What comes after it (`/today`, or nothing).
  final String suffix;

  /// The variable's name.
  final String variable;

  /// A short name.
  final String name;

  /// What people see.
  final String title;

  /// What it holds.
  final String description;

  /// The read action that answers it.
  final String action;

  /// The action argument the variable fills.
  final String argument;

  /// Other arguments.
  final Map<String, Object?> args;

  /// The RFC 6570 template.
  String get uriTemplate => '$prefix{$variable}$suffix';

  /// As `resources/templates/list` shows it.
  Map<String, Object?> toJson() =>
      {'uriTemplate': uriTemplate, 'name': name, 'title': title, 'description': description, 'mimeType': 'application/json'};

  /// The variable in [uri], decoded, when [uri] is one of this template's; else null.
  String? match(String uri) {
    if (!uri.startsWith(prefix) || !uri.endsWith(suffix) || uri.length <= prefix.length + suffix.length) return null;
    final raw = uri.substring(prefix.length, uri.length - suffix.length);
    if (raw.contains('/')) return null;
    try {
      final value = Uri.decodeComponent(raw);
      return value.trim().isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  /// This template filled with [value].
  String expand(String value) => '$prefix${Uri.encodeComponent(value)}$suffix';
}

/// The fixed resources.
const List<McpResource> denResources = [
  McpResource(
    uri: 'den://today',
    name: 'today',
    title: 'Today',
    description: 'Today\'s events, chores by person, pinned and due lists, gaps that need someone, and what waits '
        'for a parent.',
    action: 'get_overview',
  ),
  McpResource(
    uri: 'den://week',
    name: 'week',
    title: 'This week',
    description: 'The next 7 days, day by day.',
    action: 'get_overview',
    args: {'days': 7},
  ),
  McpResource(
    uri: 'den://family',
    name: 'family',
    title: 'The family',
    description: 'The family\'s people with their roles, the event categories and settings, and what this '
        'connection may do.',
    action: 'get_family',
  ),
  McpResource(
    uri: 'den://lists',
    name: 'lists',
    title: 'Lists',
    description: 'Every list with what is still to get or do on it.',
    action: 'get_lists',
    args: {'include_checked': false},
  ),
  McpResource(
    uri: 'den://chores',
    name: 'chores',
    title: 'Today\'s chores',
    description: 'Today\'s chores, who has them and whether they are done.',
    action: 'list_chores',
  ),
  McpResource(
    uri: 'den://points',
    name: 'points',
    title: 'Stars and rewards',
    description: 'Star totals, goals, recent stars, rewards and requests waiting for a parent.',
    action: 'get_points',
  ),
];

/// The templates.
const List<McpResourceTemplate> denResourceTemplates = [
  McpResourceTemplate(
    prefix: 'den://lists/',
    suffix: '',
    variable: 'list',
    name: 'list',
    title: 'One list',
    description: 'One list (by its name or id) with all its items.',
    action: 'get_lists',
    argument: 'list',
  ),
  McpResourceTemplate(
    prefix: 'den://days/',
    suffix: '',
    variable: 'date',
    name: 'day',
    title: 'One day',
    description: 'One day (YYYY-MM-DD): its events, chores and gaps.',
    action: 'get_overview',
    argument: 'date',
  ),
  McpResourceTemplate(
    prefix: 'den://people/',
    suffix: '/today',
    variable: 'person',
    name: 'person-today',
    title: 'One person\'s day',
    description: 'Today for one person (by name or id): their events, events for everyone, and their chores.',
    action: 'get_overview',
    argument: 'person',
  ),
];

/// The read action and arguments that answer [uri], or null when Den has no such resource.
({String action, Map<String, Object?> args})? resourceAction(String uri) {
  for (final r in denResources) {
    if (r.uri == uri) return (action: r.action, args: r.args);
  }
  for (final t in denResourceTemplates) {
    final value = t.match(uri);
    if (value != null) return (action: t.action, args: {...t.args, t.argument: value});
  }
  return null;
}
