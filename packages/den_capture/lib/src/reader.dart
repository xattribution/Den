import 'context.dart';
import 'input.dart';
import 'wire.dart';

/// What a reader can take in directly. Photos and PDFs go to a reader that can't see them as
/// the text a [TextFinder] found in them.
enum ReaderInput { text, image, pdf }

/// Where a reader runs, which decides what leaves the device.
enum ReaderPlace {
  /// On this device: nothing is sent anywhere.
  device,

  /// On a computer in the home the family runs, such as the hub's machine.
  home,

  /// On a provider's servers, with a key a parent gave Den.
  provider,
}

class ReaderInfo {
  const ReaderInfo({required this.id, required this.name, required this.place, required this.inputs, this.historyName});

  /// `rules`, `apple`, `gemini-nano`, `home`, `claude`.
  final String id;

  /// As Settings shows it: "Claude", "Apple Intelligence".
  final String name;
  final ReaderPlace place;
  final Set<ReaderInput> inputs;

  /// As History says who read something ("read by Claude"); null for Den's own reader.
  final String? historyName;

  bool reads(ReaderInput input) => inputs.contains(input);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'place': place.name,
        'inputs': [for (final i in ReaderInput.values) if (inputs.contains(i)) i.name],
        'history_name': historyName,
      };

  /// Reads [toJson] output; null when it isn't one.
  static ReaderInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], name = raw['name'];
    final place = ReaderPlace.values.asNameMap()[raw['place']];
    if (id is! String || name is! String || place == null) return null;
    return ReaderInfo(
      id: id,
      name: name,
      place: place,
      inputs: {
        for (final i in (raw['inputs'] as List? ?? const [])) ?ReaderInput.values.asNameMap()[i],
      },
      historyName: raw['history_name'] as String?,
    );
  }
}

/// One request: what was shared, about which family, and the fixed instructions and schema
/// every reader is held to.
class ReadRequest {
  ReadRequest(this.input, this.context)
      : instructions = CaptureWire.instructions,
        prompt = CaptureWire.prompt(context, input),
        schema = CaptureWire.schema;

  final CaptureInput input;
  final CaptureContext context;
  final String instructions;
  final String prompt;
  final Map<String, Object?> schema;
}

/// Something that reads what a family shared and returns [CaptureWire]'s JSON. Implementations:
/// Den's own reader (pure Dart, always here), the platform's on-device model (Apple Foundation
/// Models, Gemini Nano) through the app, a model on a home computer, and Claude with a key.
abstract interface class CaptureReader {
  ReaderInfo get info;

  /// Whether it can run now: the model is on the device, the key is set, the home computer
  /// answers. Cheap; called before every capture.
  Future<bool> available();

  Future<Map<String, Object?>> read(ReadRequest request);
}

/// Finds the text in a photo or a PDF on the device: Vision on Apple platforms, ML Kit on
/// Android. Returns null when this device can't.
abstract interface class TextFinder {
  Future<String?> textIn(CaptureFile file);
}

/// A reader couldn't read something; [message] says why and what to do, for people.
class ReaderException implements Exception {
  const ReaderException(this.message, {this.retry = false});
  final String message;

  /// Whether trying again later may work (a timeout, a busy provider).
  final bool retry;

  @override
  String toString() => message;
}
