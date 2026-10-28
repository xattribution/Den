import 'dart:async';

import 'package:den_capture/den_capture.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../capabilities.dart';

/// Where the Add sheet gets what to read: the camera, a file, the microphone. Each returns null
/// when the person backs out.
abstract interface class CaptureSources {
  bool get canSnap;
  bool get canSpeak;
  Future<CaptureFile?> snap();
  Future<CaptureFile?> pick();

  /// Listens on the device, sending the words heard so far to [onWords] and finishing with the
  /// last of them. Throws [ReaderException] when this device can't recognize speech offline.
  Future<String?> listen({required void Function(String words) onWords});
  Future<void> stopListening();
}

class DeviceCaptureSources implements CaptureSources {
  DeviceCaptureSources();

  final _picker = ImagePicker();
  final _speech = SpeechToText();
  Completer<String?>? _listening;
  String _heard = '';

  static bool get _mobile => Capabilities.snapPhotos;

  @override
  bool get canSnap => _mobile;

  /// Speech stays on the device: the browser's speech recognition sends audio away, and Windows
  /// and Linux have none Den can use.
  @override
  bool get canSpeak => Capabilities.speech;

  @override
  Future<CaptureFile?> snap() async {
    final shot = await _picker.pickImage(source: ImageSource.camera, maxWidth: 2000, maxHeight: 2000, imageQuality: 85);
    if (shot == null) return null;
    return CaptureFile(await shot.readAsBytes(), shot.mimeType ?? CaptureFile.mimeTypeFor(shot.name) ?? 'image/jpeg', name: shot.name);
  }

  @override
  Future<CaptureFile?> pick() async {
    const group = XTypeGroup(
      label: 'Photos and PDFs',
      extensions: ['jpg', 'jpeg', 'png', 'heic', 'webp', 'gif', 'pdf'],
      mimeTypes: ['image/*', 'application/pdf'],
      uniformTypeIdentifiers: ['public.image', 'com.adobe.pdf'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return null;
    final type = file.mimeType ?? CaptureFile.mimeTypeFor(file.name);
    if (type == null) throw const ReaderException('Den reads photos and PDFs. Choose one of those.');
    return CaptureFile(await file.readAsBytes(), type, name: file.name);
  }

  @override
  Future<String?> listen({required void Function(String words) onWords}) async {
    final ready = await _speech.initialize(onError: _failed, onStatus: _status);
    if (!ready) {
      throw const ReaderException('Den needs the microphone and speech recognition. Turn them on for Den in Settings.');
    }
    _heard = '';
    final done = _listening = Completer<String?>();
    await _speech.listen(
      onResult: (SpeechRecognitionResult r) {
        _heard = r.recognizedWords;
        onWords(_heard);
        if (r.finalResult) _finish();
      },
      listenOptions: SpeechListenOptions(
        onDevice: true,
        partialResults: true,
        listenMode: ListenMode.dictation,
        autoPunctuation: true,
        cancelOnError: true,
      ),
    );
    return done.future;
  }

  void _status(String status) {
    if (status == SpeechToText.doneStatus || status == SpeechToText.notListeningStatus) _finish();
  }

  void _failed(SpeechRecognitionError e) {
    final listening = _listening;
    if (listening == null || listening.isCompleted) return;
    _listening = null;
    if (e.errorMsg.contains('no_match') || e.errorMsg.contains('speech_timeout')) {
      listening.complete(_heard.isEmpty ? null : _heard);
    } else {
      listening.completeError(const ReaderException(
        'This device can\'t recognize speech without the internet. Type it instead, or turn on offline speech in its settings.',
      ));
    }
  }

  void _finish() {
    final listening = _listening;
    if (listening == null || listening.isCompleted) return;
    _listening = null;
    listening.complete(_heard.trim().isEmpty ? null : _heard.trim());
  }

  @override
  Future<void> stopListening() async {
    await _speech.stop();
    _finish();
  }
}
