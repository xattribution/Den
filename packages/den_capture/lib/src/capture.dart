import 'package:den_core/den_core.dart';

import 'check.dart';
import 'context.dart';
import 'draft.dart';
import 'input.dart';
import 'reader.dart';
import 'resolve.dart';

/// What one capture found and who read it.
class CaptureResult {
  const CaptureResult({required this.draft, required this.reader, required this.read, this.note});

  /// Resolved to the family and checked against the engine.
  final CaptureDraft draft;
  final ReaderInfo reader;

  /// The words the reader was given, after text was found in photos or pages; review shows
  /// them under "What Den read".
  final String read;

  /// Why a better reader wasn't used, when one was tried and failed.
  final String? note;
}

/// Runs a capture: picks the first reader that is available and can take the input (finding
/// text in photos and PDFs on the device for readers that can't see them), resolves what it
/// returns to the family, and checks it. Readers come in the family's order of preference, the
/// device's own first unless a parent chose otherwise; a reader that finds nothing, or fails,
/// hands over to the next.
class Capturer {
  Capturer({required this.readers, this.textFinder, this.pageText});

  final List<CaptureReader> readers;
  final TextFinder? textFinder;

  /// Fetches the readable text of a shared web page; null when it can't.
  final Future<String?> Function(Uri link)? pageText;

  Future<CaptureResult> read(CaptureInput input, Den den) async {
    if (input.isEmpty) throw const ReaderException('There\'s nothing to read.');
    var shared = input;
    final link = input.link;
    if (link != null && pageText != null) {
      final text = await pageText!(link);
      if (text != null && text.trim().isNotEmpty) shared = input.withText(text, dropFiles: false);
    }
    final context = CaptureContext.of(den);
    CaptureOrigin origin(ReaderInfo r) => CaptureOrigin(input.kind, reader: r.historyName);
    String? found;
    var looked = false;
    Future<String?> textInFiles() async {
      if (looked) return found;
      looked = true;
      final finder = textFinder;
      if (finder == null) return null;
      final parts = <String>[];
      for (final f in shared.files) {
        final t = await finder.textIn(f);
        if (t != null && t.trim().isNotEmpty) parts.add(t.trim());
      }
      return found = parts.isEmpty ? null : parts.join('\n\n');
    }

    CaptureResult? empty;
    ReaderException? failure;
    for (final reader in readers) {
      if (!await reader.available()) continue;
      final prepared = await _prepare(shared, reader.info, textInFiles);
      if (prepared == null) continue;
      try {
        final wire = await reader.read(ReadRequest(prepared, context));
        final draft = checkDraft(den, draftFrom(wire, context, origin: origin(reader.info)));
        final result = CaptureResult(draft: draft, reader: reader.info, read: prepared.words, note: failure?.message);
        if (!draft.isEmpty) return result;
        empty ??= result;
      } on ReaderException catch (e) {
        failure ??= e;
      }
    }
    if (empty != null) {
      return CaptureResult(draft: empty.draft, reader: empty.reader, read: empty.read, note: failure?.message);
    }
    if (failure != null) throw failure;
    throw ReaderException(_cantRead(shared));
  }

  /// The input as [reader] can take it, or null when it can't take any of it.
  static Future<CaptureInput?> _prepare(
    CaptureInput input,
    ReaderInfo reader,
    Future<String?> Function() textInFiles,
  ) async {
    final unseen = input.files.where(
      (f) => !(f.isImage && reader.reads(ReaderInput.image)) && !(f.isPdf && reader.reads(ReaderInput.pdf)),
    );
    if (unseen.isEmpty) return input;
    final text = await textInFiles();
    final kept = [for (final f in input.files) if (!unseen.contains(f)) f];
    final out = CaptureInput(
      kind: input.kind,
      text: [if (input.text.trim().isNotEmpty) input.text.trim(), ?text].join('\n\n'),
      files: kept,
      link: input.link,
      subject: input.subject,
    );
    return out.hasWords || out.files.isNotEmpty ? out : null;
  }

  static String _cantRead(CaptureInput input) {
    const connect = 'A parent can connect Claude or a home model under Settings, AI and automations.';
    if (input.hasPdfs) return 'This device can\'t read PDFs on its own. $connect';
    if (input.hasImages) return 'This device can\'t read photos on its own. $connect';
    return 'Den couldn\'t read that. $connect';
  }
}

/// Resolves and checks a reader's JSON without running a reader: for recorded responses and
/// for drafts that arrive already read (a hub, a test).
CaptureDraft draftFor(Den den, Map<String, Object?> wire, CaptureOrigin origin) =>
    checkDraft(den, draftFrom(wire, CaptureContext.of(den), origin: origin));
