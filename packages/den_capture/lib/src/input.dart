import 'dart:typed_data';

import 'package:den_core/den_core.dart';

/// One file a capture carries: a photo, a screenshot, a PDF.
class CaptureFile {
  const CaptureFile(this.bytes, this.mimeType, {this.name});

  final Uint8List bytes;

  /// `image/jpeg`, `image/png`, `image/heic`, `application/pdf`, ...
  final String mimeType;
  final String? name;

  bool get isImage => mimeType.startsWith('image/');
  bool get isPdf => mimeType == 'application/pdf';

  /// The type for a file name's extension, or null when Den can't read that kind of file.
  static String? mimeTypeFor(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    return switch (name.substring(dot + 1).toLowerCase()) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      'pdf' => 'application/pdf',
      _ => null,
    };
  }
}

/// What someone gave Den to read: words they typed or said, an email or message shared from
/// another app, a link, photos, screenshots or PDFs.
class CaptureInput {
  const CaptureInput({required this.kind, this.text = '', this.files = const [], this.link, this.subject});

  /// Words someone typed into Add.
  factory CaptureInput.typed(String text) => CaptureInput(kind: CaptureKind.typed, text: text);

  /// What on-device speech recognition heard.
  factory CaptureInput.spoken(String text) => CaptureInput(kind: CaptureKind.voice, text: text);

  /// Something another app shared: what it is follows from what arrived.
  factory CaptureInput.shared({String? text, List<CaptureFile> files = const [], String? subject}) {
    final body = text?.trim() ?? '';
    final link = _onlyLink(body);
    return CaptureInput(
      kind: guessKind(text: body, files: files, subject: subject),
      text: link == null ? body : '',
      files: files,
      link: link,
      subject: subject?.trim().isEmpty ?? true ? null : subject!.trim(),
    );
  }

  final CaptureKind kind;
  final String text;
  final List<CaptureFile> files;

  /// A shared web page. The app fetches its text before reading when it can.
  final Uri? link;

  /// An email's subject or a share's title.
  final String? subject;

  bool get hasWords => text.trim().isNotEmpty || (subject?.isNotEmpty ?? false);
  bool get hasImages => files.any((f) => f.isImage);
  bool get hasPdfs => files.any((f) => f.isPdf);
  bool get isEmpty => !hasWords && files.isEmpty && link == null;

  /// The words to read: the subject, then the text.
  String get words => [?subject, if (text.trim().isNotEmpty) text.trim()].join('\n\n');

  /// This input with [extracted] text in place of the files it came from (text recognized in
  /// photos, text pulled from a PDF or a web page).
  CaptureInput withText(String extracted, {bool dropFiles = true}) => CaptureInput(
        kind: kind,
        text: [if (text.trim().isNotEmpty) text.trim(), if (extracted.trim().isNotEmpty) extracted.trim()].join('\n\n'),
        files: dropFiles ? const [] : files,
        link: dropFiles ? null : link,
        subject: subject,
      );

  /// A photo, a screenshot (by name), a PDF, a link, an email (it has a subject or mail
  /// headers), else a message.
  static CaptureKind guessKind({String text = '', List<CaptureFile> files = const [], String? subject}) {
    if (files.any((f) => f.isPdf)) return CaptureKind.pdf;
    if (files.any((f) => f.isImage)) {
      final named = files.map((f) => f.name?.toLowerCase() ?? '');
      return named.any((n) => n.contains('screenshot') || n.contains('screen shot'))
          ? CaptureKind.screenshot
          : CaptureKind.photo;
    }
    if (_onlyLink(text) != null) return CaptureKind.link;
    final mailHeaders = RegExp(r'^(from|to|subject|sent|date):\s', caseSensitive: false, multiLine: true);
    if ((subject?.trim().isNotEmpty ?? false) || mailHeaders.allMatches(text).length >= 2) return CaptureKind.email;
    return CaptureKind.message;
  }

  static Uri? _onlyLink(String text) {
    final t = text.trim();
    if (t.contains(RegExp(r'\s'))) return null;
    final uri = Uri.tryParse(t);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty ? uri : null;
  }
}
