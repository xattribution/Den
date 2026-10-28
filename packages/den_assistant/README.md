# den_assistant

The core of Den's optional in-app assistant, in pure Dart: it runs on Flutter (web included) and
in the hub. The assistant is **off by default**; a parent turns it on per person.

- `ChatModel`: one interface over five providers, each declaring where the data goes, whether it
  can see photos, its context size and its prices.
- `AssistantLoop`: model call, tool calls, results, model again, until the model answers in words
  or the turn has made 8 tool calls. It runs **on the person's own device**, against its own engine,
  so every write is signed by that device with exactly the app's permissions.
- `ContextPacker`: the system prompt, built from a plain `AssistantSnapshot` the app fills from the
  engine, within the budgets in the plan.

It depends only on `package:http`. It knows nothing about den_core; den_actions adapts its
`ActionSpec`s and `ActionRunner` to `AssistantTool` and `ToolExecutor`.

```dart
final model = chatModelFor(
  ModelProvider.anthropic,
  endpoint: ModelEndpoint.hub(hubUrl.resolve('/api/v1/assistant/model'), sign: device.sign),
);
final loop = AssistantLoop(model: model, tools: toolsForThisPerson, execute: runner.execute);

final packed = const ContextPacker().pack(snapshot, receipts: loop.receipts);
var turn = await loop.ask('Move soccer to 6 on Tuesday', system: packed.blocks);
if (turn.waiting) {
  // Show turn.pending!.preview on a "Do it / Not now" card.
  turn = await loop.decide(approve: tappedDoIt);
}
// turn.text to show or read aloud; turn.steps and turn.receipts for rows with Undo;
// turn.usage and turn.costUsd for the tally.

if (UndoIntent.matches(text)) {
  final receipt = loop.takeLastUndoable(); // undo it on the engine; no model call needed
}
```

## Providers

Model ids and prices live in one table, `modelTable` in `lib/src/providers.dart`; nothing else
names a model. Each provider has a small default and a bigger model ("Use the bigger model for
planning"). Prices are US dollars per million tokens: input / cached input / output.

| Provider | API | Data goes to | Default | Bigger | Photos |
| --- | --- | --- | --- | --- | --- |
| Anthropic | Messages, tool use, prompt caching | Anthropic | `claude-haiku-5-5` (0.10 / 0.01 / 0.50) | `claude-sonnet-5-5` (2 / 0.10 / 10) | yes |
| OpenAI | Responses, function tools, `store: false` | OpenAI | `gpt-6-luna` (0.10 / 0.01 / 0.50) | `gpt-6.1-sol` (2 / 0.10 / 10) | yes |
| Google | Gemini `generateContent`, function declarations | Google | `gemini-3.5-flash-lite` (0.30 / 0.03 / 2.50) | `gemini-3.8-flash` (0.75 / 0.075 / 3.75) | yes |
| xAI | Grok through the OpenAI adapter at `api.x.ai/v1` | xAI | `grok-4.20-0309-non-reasoning` (1.25 / 0.20 / 2.50) | `grok-4.7` (2 / 0.50 / 6) | off (not documented per model) |
| Ollama | `/api/chat` with tools, on a computer at home | home | `qwen3:8b` (free) | `qwen3.8:27b` (free) | bigger only |

Checked against the providers' docs on 2026-10-28:

- Anthropic: [models](https://platform.claude.com/docs/en/models/overview),
  [pricing](https://platform.claude.com/docs/en/about-claude/pricing),
  [prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
  [tool calls](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls),
  [thinking](https://platform.claude.com/docs/en/build-with-claude/thinking).
- OpenAI: [models](https://developers.openai.com/api/docs/models),
  [pricing](https://developers.openai.com/api/docs/pricing),
  [function calling](https://developers.openai.com/api/docs/guides/function-calling),
  [reasoning](https://developers.openai.com/api/docs/guides/reasoning),
  [prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).
- Google: [models](https://ai.google.dev/gemini-api/docs/models),
  [pricing](https://ai.google.dev/gemini-api/docs/pricing),
  [function calling](https://ai.google.dev/gemini-api/docs/generate-content/function-calling),
  [thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures),
  [API reference](https://ai.google.dev/api/generate-content).
- xAI: [models](https://docs.x.ai/developers/models),
  [Responses API](https://docs.x.ai/developers/rest-api-reference/inference/responses),
  [function calling](https://docs.x.ai/developers/tools/function-calling).
- Ollama: [chat API](https://docs.ollama.com/api/chat),
  [tool calling](https://docs.ollama.com/capabilities/tool-calling),
  [qwen3](https://ollama.com/library/qwen3), [qwen3.8](https://ollama.com/library/qwen3.8).

What each adapter does that the others don't:

- **Anthropic** puts `cache_control` on the last tool and on each cached system block (static
  rules, the family for the day), at most three, plus top-level automatic caching for the
  conversation so a turn's later calls read what its first call wrote. Claude's replies carry
  thinking blocks with signatures; they're kept in `ProviderState` and sent back unchanged.
- **OpenAI and xAI** are stateless (`store: false`): reasoning items (with their encrypted
  content) go back with the function outputs. OpenAI functions are sent with `strict: false`,
  because the Responses API makes them strict otherwise. Caching is automatic; a `cacheKey`
  becomes `prompt_cache_key`.
- **Gemini** gets its OpenAPI-style schema (`geminiSchemaFor`: upper-case types, no
  `additionalProperties`, no `parameters` for a tool without inputs). Its parts go back with their
  `thoughtSignature`; calls written by another provider get the stand-in signature Google
  documents.
- **Ollama** has no call ids or `tool_choice`: Den makes up ids, results go back as `tool`
  messages named by `tool_name`, and a turn out of tool calls is sent without tools. `num_ctx` is
  raised to 16k because Ollama's default is too small for the context and tools.

`Usage.inputTokens` is always input billed at the full price (cached input taken out), so a cost
is each count times its price; `Usage.costUsd(info.price)` does that.

## Tools

`AssistantTool` is provider-neutral: a name, a description, a JSON Schema input, an effect (read,
write, destructive) and whether every call waits for a tap. Schemas stay in a **portable subset**
every provider accepts: an object at the top, one type per value, string enums, `items` on every
array, properties on every nested object, no `anyOf`/`oneOf`/`$ref`, and `additionalProperties:
false` only at the top. `checkTool` and `checkPortableSchema` flag anything else; den_actions'
schema test should run them on every spec. `checkInput` checks a call's arguments before the
executor sees them, so mistakes go back to the model as sentences it can fix.

`ToolExecutor` runs one `ToolInvocation` in a `ToolMode`:

- `run`: run it, unless this call needs a tap (someone else's things, a whole series); then change
  nothing and return `ToolNeedsConfirmation(preview)`.
- `preview`: the tool is `ToolConfirm.tap`; change nothing and say what would happen (the fork).
- `confirmed`: the person tapped "Do it".

It returns `ToolDone(result, summary, receipt)`, `ToolNeedsConfirmation(preview)` or
`ToolFailed(message)`; a thrown error counts as a failure. Failures go back to the model.

## The hub proxy

Phones and the web app don't hold provider keys. With `ModelEndpoint.hub(url, sign: ...)` an
adapter writes its request exactly as it would for the provider, and POSTs it to the hub's
`/api/v1/assistant/model`, signed with the device's key, with `x-den-provider` and `x-den-model`
headers. The hub uses `ModelProxy`:

1. `check(providerId, model, body)` refuses a provider or model the hub isn't set up for, and
   returns `RequestFacts` (output cap, photos, tool count) for its policy: kids get no photos, the
   output cap holds.
2. `forward(model, body)` sends the body unchanged to the provider with the hub's key and returns
   the provider's answer for the device, with `usage` and `costUsd` for the family's budget.

The hub keeps no content and logs none. Its own refusals (assistant off, budget spent, a kid's
daily limit) come back as 402, 403 or 429 with a message, which the adapter shows as is.
`ModelEndpoint.direct(apiKey: ..., baseUrl: ...)` calls the provider (or a home computer, or a
compatible gateway) directly instead.

## Context

`ContextPacker.pack(snapshot, receipts:)` returns these system blocks:

| Block | Contents | Budget |
| --- | --- | --- |
| `static` (cached) | Den's job, tone, safety and tool rules; the kid version for kids | ~600 |
| `family` (cached) | name, zone, week start, today's date; members; categories; lists with open counts; rewards | ~800 |
| `speaker` | who is speaking and what they may do; a kid's reading level | ~150 |
| `today` | the time; today's events, chores and gaps; the next 7 days; pending requests | at most 1,500 |
| `recent` | the speaker's last 10 History entries; this conversation's receipts | at most 400 |

The whole is capped at 8k tokens by dropping week detail first, then history (tokens estimated
at four characters each). The family block holds the date but not the time, so it stays the same
all day and caches. Everything else comes through read tools.

## Tests

```bash
dart test
```

No test touches the network. `package:den_assistant/testing.dart` has `ScriptedChatModel` for
the loop and for packages that build on it. The fixtures in `test/fixtures` follow each
provider's documented response shape; they were written for these tests, not captured from live
calls.
