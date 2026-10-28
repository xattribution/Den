/// MCP prompts: ready-made requests a person can pick in their assistant ("Plan the week",
/// "Make a shopping list"), each written to use Den's tools and to ask before changing
/// anything that needs a yes. A prompt is offered only when the caller may use every tool it
/// names.
library;

/// One argument of a prompt.
class McpPromptArgument {
  /// An argument called [name].
  const McpPromptArgument(this.name, this.description, {this.required = false});

  /// Its name.
  final String name;

  /// What to give.
  final String description;

  /// Whether the prompt needs it.
  final bool required;

  /// As `prompts/list` shows it.
  Map<String, Object?> toJson() => {'name': name, 'description': description, 'required': required};
}

/// One prompt.
class McpPrompt {
  /// A prompt called [name] that uses the tools in [needs] and writes its text with [build].
  const McpPrompt({
    required this.name,
    required this.title,
    required this.description,
    required this.needs,
    required this.build,
    this.arguments = const [],
  });

  /// Its name.
  final String name;

  /// What people see.
  final String title;

  /// What it does.
  final String description;

  /// Its arguments.
  final List<McpPromptArgument> arguments;

  /// The tools (MCP names) it uses; it is offered only when the caller may use them all.
  final Set<String> needs;

  /// The request's text from the arguments given.
  final String Function(Map<String, String> args) build;

  /// As `prompts/list` shows it.
  Map<String, Object?> toJson() => {
        'name': name,
        'title': title,
        'description': description,
        'arguments': [for (final a in arguments) a.toJson()],
      };
}

String _for(Map<String, String> args) {
  final person = args['person'];
  return person == null ? '' : ' for $person';
}

String _personOnly(Map<String, String> args) {
  final person = args['person'];
  return person == null ? '' : ' (person: "$person")';
}

String _personArg(Map<String, String> args) {
  final person = args['person'];
  return person == null ? '' : ', person: "$person"';
}

/// Den's prompts.
final List<McpPrompt> denPrompts = [
  McpPrompt(
    name: 'whats_today',
    title: 'What\'s on today',
    description: 'A short summary of today: events, chores and anything that needs someone.',
    arguments: const [McpPromptArgument('person', 'Only this person\'s day (a name).')],
    needs: const {'get_overview'},
    build: (a) => 'Use get_overview${_personOnly(a)} and tell me in a few short '
        'sentences what is happening today${_for(a)}: events with their times, who has which chores and which are '
        'still to do, and anything that needs someone (a ride, an overlap, a chore nobody has).',
  ),
  McpPrompt(
    name: 'plan_week',
    title: 'Plan the week',
    description: 'The next 7 days day by day, with the gaps to fill and suggestions for each.',
    arguments: const [McpPromptArgument('person', 'Only this person\'s week (a name).')],
    needs: const {'get_overview'},
    build: (a) => 'Look at our family\'s next 7 days with get_overview (days: 7${_personArg(a)}). Go through them day '
        'by day, briefly, and point out the gaps: events with no driver, events that overlap, chores nobody has. '
        'Suggest how to fill each one, but don\'t change anything until I say yes.',
  ),
  McpPrompt(
    name: 'shopping_list',
    title: 'Make a shopping list',
    description: 'Works out what to buy for some meals and adds only what is missing to a list.',
    arguments: const [
      McpPromptArgument('meals', 'The meals or recipes to shop for.', required: true),
      McpPromptArgument('list', 'The list to add to (default Groceries).'),
    ],
    needs: const {'get_lists', 'add_items'},
    build: (a) {
      final list = a['list'] ?? 'Groceries';
      return 'Work out what we need to buy for: ${a['meals']}. First read the "$list" list with get_lists, then add '
          'only what isn\'t on it yet with add_items, and tell me what you added.';
    },
  ),
  McpPrompt(
    name: 'chores_left',
    title: 'Who still has chores',
    description: 'Today\'s chores that are still to do, by person.',
    arguments: const [McpPromptArgument('person', 'Only this person\'s chores (a name).')],
    needs: const {'list_chores'},
    build: (a) => 'Use list_chores for today${_for(a)} and tell me, kindly and briefly, who still has chores to do and '
        'which ones.',
  ),
  McpPrompt(
    name: 'add_from_message',
    title: 'Add from a message',
    description: 'Adds the events, chores and list items in a message (a school email, a text) to Den.',
    arguments: const [McpPromptArgument('text', 'The message.', required: true)],
    needs: const {'add_from_text'},
    build: (a) => 'Add what is in this message to our family\'s Den with add_from_text, then tell me what was added '
        'and anything it couldn\'t add.\n\n<message>\n${a['text']}\n</message>',
  ),
];
