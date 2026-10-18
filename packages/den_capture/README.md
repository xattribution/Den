# den_capture

A photo of the school flyer, a forwarded team email, a shared link or "soccer every Wednesday at
5 for Leo" becomes events, chores, list items and reminders the family confirms in one tap.

```dart
final capturer = Capturer(
  readers: [deviceModel, const RulesReader(), if (key != null) ClaudeReader(apiKey: key)],
  textFinder: phoneOcr,
);
final result = await capturer.read(CaptureInput.shared(files: [photo]), den);
final receipt = await writeDraft(den, result.draft); // what needs no look; or pass keys
await receipt.undo(den); // if they change their mind
```

- `CaptureReader`: Den's own rules (`RulesReader`, pure Dart, offline), a home model through
  Ollama (`HomeModelReader`), Claude with a parent's key (`ClaudeReader`, structured output,
  photos and PDFs read directly). The app adds the device's model (Apple Foundation Models,
  Gemini Nano) and text recognition through its platform channel.
- `CaptureWire`: the one JSON shape every reader returns, its schema and instructions.
- `draftFrom`: resolves names, lists, repeats and categories for the family.
- `checkDraft`: holds every entry to den_core's schemas and permissions, and flags what's over
  or already there, before anything is written.
- `writeDraft`: adds entries through the engine as the acting member, each change carrying
  `_from` so History says "from a photo, read by Claude".

```bash
dart test
dart run tool/probe.dart test/fixtures/flyer_ocr.txt   # what Den's own reader makes of a text
```

The Claude responses in `test/fixtures` follow the Messages API's documented response shape;
they were written for these tests, not captured from a live call.
