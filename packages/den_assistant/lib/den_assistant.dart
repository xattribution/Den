/// Den's optional in-app assistant, in pure Dart: one [ChatModel] over Anthropic, OpenAI,
/// Gemini, xAI and a model at home; the [AssistantLoop] that runs tools on the person's own
/// device with tap-to-confirm and undo receipts; and the [ContextPacker] that builds the system
/// prompt from a plain snapshot of the family.
library;

export 'src/adapters/anthropic.dart';
export 'src/adapters/factory.dart';
export 'src/adapters/gemini.dart';
export 'src/adapters/ollama.dart';
export 'src/adapters/openai.dart';
export 'src/context/packer.dart';
export 'src/context/prompts.dart' show kidStaticPrompt, readingLevel, staticPrompt;
export 'src/context/snapshot.dart';
export 'src/endpoint.dart';
export 'src/loop.dart';
export 'src/messages.dart';
export 'src/model.dart';
export 'src/providers.dart';
export 'src/proxy.dart';
export 'src/schema.dart';
export 'src/tools.dart';
export 'src/undo.dart';
