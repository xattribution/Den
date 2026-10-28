import 'dart:async';
import 'dart:convert';

import 'package:den_capture/den_capture.dart';
import 'package:flutter/services.dart';
import '../capabilities.dart';

/// Whether this device's own model can run now.
enum ModelState { available, downloadable, downloading, unavailable }

/// What this device can do on its own, as its platform code reports it.
class DeviceAbilities {
  const DeviceAbilities({this.model, this.modelName, this.modelState = ModelState.unavailable, this.text = false, this.pdf = false});

  static const none = DeviceAbilities();

  /// `apple` (Foundation Models) or `gemini-nano` (ML Kit's Prompt API), or null.
  final String? model;

  /// "Apple Intelligence", "Gemini Nano".
  final String? modelName;
  final ModelState modelState;

  /// Finds text in photos (Vision, ML Kit text recognition).
  final bool text;

  /// Finds text in PDFs (PDFKit; Android renders the pages and finds text in them).
  final bool pdf;

  bool get hasModel => model != null && modelState == ModelState.available;

  static DeviceAbilities fromMap(Map<Object?, Object?>? m) {
    if (m == null) return none;
    return DeviceAbilities(
      model: m['model'] as String?,
      modelName: m['modelName'] as String?,
      modelState: ModelState.values.asNameMap()[m['modelState']] ?? ModelState.unavailable,
      text: m['text'] == true,
      pdf: m['pdf'] == true,
    );
  }
}

/// Something another app shared with Den through the system share sheet.
class SharedThing {
  const SharedThing({this.text, this.subject, this.files = const [], this.unread = 0});
  final String? text;
  final String? subject;
  final List<CaptureFile> files;

  /// Files that were shared but couldn't be opened.
  final int unread;

  CaptureInput get input => CaptureInput.shared(text: text, subject: subject, files: files);

  static SharedThing fromMap(Map<Object?, Object?> m) => SharedThing(
        text: m['text'] as String?,
        subject: m['subject'] as String?,
        unread: (m['unread'] as num?)?.toInt() ?? 0,
        files: [
          for (final f in (m['files'] as List? ?? const []))
            if (f is Map && f['bytes'] is Uint8List)
              CaptureFile(
                f['bytes'] as Uint8List,
                f['mimeType'] as String? ?? CaptureFile.mimeTypeFor(f['name'] as String? ?? '') ?? 'application/octet-stream',
                name: f['name'] as String?,
              ),
        ],
      );
}

/// The app's native capture code: the on-device model, text recognition, image conversion and
/// the share inbox. On platforms without it every call says "can't" instead of failing.
class PlatformCapture {
  const PlatformCapture();

  static const _channel = MethodChannel('family.den/capture');
  static const _shares = EventChannel('family.den/capture/shares');

  Future<T?> _call<T>(String method, [Object? args]) async {
    if (Capabilities.web) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      throw ReaderException(e.message ?? 'This device couldn\'t read that.');
    }
  }

  Future<DeviceAbilities> abilities() async {
    try {
      return DeviceAbilities.fromMap(await _call<Map<Object?, Object?>>('abilities'));
    } on ReaderException {
      return DeviceAbilities.none;
    }
  }

  /// Asks the device to fetch its model (Gemini Nano downloads on first use).
  Future<void> prepareModel() => _call<void>('prepareModel');

  Future<String?> findText(CaptureFile file) =>
      _call<String>('findText', {'bytes': file.bytes, 'mimeType': file.mimeType});

  /// The device model's answer to [prompt], held to [schema] where the model supports it.
  Future<String?> generate({required String instructions, required String prompt, required Map<String, Object?> schema}) =>
      _call<String>('generate', {'instructions': instructions, 'prompt': prompt, 'schema': jsonEncode(schema)});

  /// A photo as a JPEG no larger than [maxSide] pixels on its long side, for readers that take
  /// only common image types; null when the device can't convert it.
  Future<Uint8List?> toJpeg(Uint8List bytes, {int maxSide = 2000}) =>
      _call<Uint8List>('toJpeg', {'bytes': bytes, 'maxSide': maxSide});

  /// What was shared while Den wasn't looking, or that opened it; each is handed out once.
  Future<List<SharedThing>> takeShares() async {
    final raw = await _call<List<Object?>>('takeShares');
    return [for (final m in raw ?? const []) if (m is Map) SharedThing.fromMap(m)];
  }

  /// Fires when something is shared while Den is open.
  Stream<void> get sharesArrived {
    if (!Capabilities.deviceModel) {
      return const Stream.empty();
    }
    return _shares.receiveBroadcastStream().handleError((Object _) {}).map((_) {});
  }
}

/// This device's own model as a capture reader.
class DeviceModelReader implements CaptureReader {
  DeviceModelReader(this.abilities, {this.platform = const PlatformCapture()});
  final DeviceAbilities abilities;
  final PlatformCapture platform;

  @override
  ReaderInfo get info => ReaderInfo(
        id: abilities.model ?? 'device',
        name: abilities.modelName ?? 'This device',
        place: ReaderPlace.device,
        inputs: const {ReaderInput.text},
        historyName: abilities.modelName,
      );

  @override
  Future<bool> available() async => abilities.hasModel;

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    final text = await platform.generate(instructions: request.instructions, prompt: request.prompt, schema: request.schema);
    if (text == null) throw const ReaderException('This device\'s model isn\'t available right now.');
    return lenientJson(text) ?? (throw const ReaderException('This device\'s model gave an answer Den couldn\'t use.'));
  }
}

/// Text recognition on this device, as den_capture asks for it.
class DeviceTextFinder implements TextFinder {
  DeviceTextFinder(this.abilities, {this.platform = const PlatformCapture()});
  final DeviceAbilities abilities;
  final PlatformCapture platform;

  @override
  Future<String?> textIn(CaptureFile file) async {
    if (file.isImage && !abilities.text) return null;
    if (file.isPdf && !abilities.pdf) return null;
    return platform.findText(file);
  }
}
