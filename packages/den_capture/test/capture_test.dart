import 'dart:typed_data';

import 'package:den_capture/den_capture.dart';
import 'package:den_core/den_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Choosing a reader: the family's order, what each can take, and handing over when one fails.
void main() {
  late Den den;
  setUpAll(() async => den = await demo());
  tearDownAll(() => den.close());

  final photo = CaptureFile(Uint8List(4), 'image/jpeg');
  final found = {
    ...empty,
    'items': [{'text': 'Milk', 'qty': null, 'store': null, 'list': null}],
  };

  test('the first reader that\'s ready and finds something wins', () async {
    final off = FixedReader(found, id: 'off', ready: false);
    final first = FixedReader(found, id: 'first');
    final second = FixedReader(found, id: 'second');
    final result = await Capturer(readers: [off, first, second]).read(CaptureInput.typed('milk'), den);
    expect(result.reader.id, 'first');
    expect((off.asked.length, second.asked.length), (0, 0));
    expect(result.draft.origin, const CaptureOrigin(CaptureKind.typed, reader: 'first'));
  });

  test('a reader that finds nothing hands over; one that fails leaves a note', () async {
    final nothing = FixedReader(empty, id: 'device');
    final broken = FixedReader(found, id: 'home', error: const ReaderException('The home model took too long to answer.'));
    final claude = FixedReader(found, id: 'claude');
    final result = await Capturer(readers: [nothing, broken, claude]).read(CaptureInput.typed('milk'), den);
    expect(result.reader.id, 'claude');
    expect(result.note, 'The home model took too long to answer.');
  });

  test('when every reader finds nothing, the first empty result comes back', () async {
    final result = await Capturer(readers: [FixedReader(empty, id: 'a'), FixedReader(empty, id: 'b')]).read(CaptureInput.typed('hmm'), den);
    expect((result.reader.id, result.draft.isEmpty), ('a', true));
  });

  test('photos reach a text-only reader as the text the device found, once', () async {
    final ocr = FixedText('Buy milk');
    final a = FixedReader(empty, id: 'a');
    final b = FixedReader(found, id: 'b');
    final result = await Capturer(readers: [a, b], textFinder: ocr).read(CaptureInput.shared(files: [photo], text: 'From the fridge'), den);
    expect(ocr.calls, 1);
    expect(a.asked.single.input.files, isEmpty);
    expect(a.asked.single.input.words, 'From the fridge\n\nBuy milk');
    expect(result.read, 'From the fridge\n\nBuy milk');
  });

  test('a reader that sees photos gets them as they are', () async {
    final vision = FixedReader(found, id: 'vision', inputs: const {ReaderInput.text, ReaderInput.image});
    final ocr = FixedText('unused');
    await Capturer(readers: [vision], textFinder: ocr).read(CaptureInput.shared(files: [photo]), den);
    expect((ocr.calls, vision.asked.single.input.files.length), (0, 1));
  });

  test('a photo with no way to read it says what a parent can do', () async {
    expect(
      () => Capturer(readers: const [RulesReader()]).read(CaptureInput.shared(files: [photo]), den),
      throwsA(isA<ReaderException>().having((e) => e.message, 'message', startsWith('This device can\'t read photos on its own.'))),
    );
    expect(
      () => Capturer(readers: const [RulesReader()]).read(const CaptureInput(kind: CaptureKind.typed), den),
      throwsA(isA<ReaderException>()),
    );
  });

  test('a shared link is read as the page\'s text', () async {
    final reader = FixedReader(found);
    final capturer = Capturer(readers: [reader], pageText: (uri) async => 'Spirit week starts Monday');
    final result = await capturer.read(CaptureInput.shared(text: 'https://oakgrove.example/news'), den);
    expect(result.draft.origin.kind, CaptureKind.link);
    expect(reader.asked.single.prompt, contains('https://oakgrove.example/news\nSpirit week starts Monday'));
  });
}
