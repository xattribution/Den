import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../reader.dart';

/// Claude, with an API key a parent gave Den. Reads text, photos and PDFs directly, held to
/// [ReadRequest.schema] with structured output. What is shared, and the family's first names
/// and list names, go to Anthropic; nothing else does.
class ClaudeReader implements CaptureReader {
  ClaudeReader({
    required this.apiKey,
    this.model = defaultModel,
    http.Client? client,
    this.browser = false,
    Uri? endpoint,
    this.timeout = const Duration(minutes: 2),
  })  : _http = client ?? http.Client(),
        endpoint = endpoint ?? Uri.parse('https://api.anthropic.com/v1/messages');

  /// The model Den uses unless a parent picks another in Settings.
  static const defaultModel = 'claude-opus-5-5';

  /// The models Settings offers, most capable first.
  static const models = {
    'claude-opus-5-5': 'Claude Opus 5.5',
    'claude-sonnet-5-5': 'Claude Sonnet 5.5',
    'claude-haiku-5-5': 'Claude Haiku 5.5',
  };

  /// Image types the API accepts; others are converted on the device first.
  static const imageTypes = {'image/jpeg', 'image/png', 'image/gif', 'image/webp'};

  final String apiKey;
  final String model;

  /// Running in a browser, where the API asks for an explicit opt-in to direct calls.
  final bool browser;
  final Uri endpoint;
  final Duration timeout;
  final http.Client _http;

  @override
  ReaderInfo get info => const ReaderInfo(
        id: 'claude',
        name: 'Claude',
        place: ReaderPlace.provider,
        inputs: {ReaderInput.text, ReaderInput.image, ReaderInput.pdf},
        historyName: 'Claude',
      );

  @override
  Future<bool> available() async => apiKey.trim().isNotEmpty;

  /// The Messages API request body for [request].
  Map<String, Object?> body(ReadRequest request) => {
        'model': model,
        'max_tokens': 16000,
        'system': request.instructions,
        // Opus and Sonnet 5.5 can decline a request on a safety classifier's call; this lets the
        // API re-run it on its recommended fallback instead of returning nothing.
        if (model != 'claude-haiku-5-5') 'fallbacks': 'default',
        'output_config': {
          'effort': 'medium',
          'format': {'type': 'json_schema', 'schema': request.schema},
        },
        'messages': [
          {
            'role': 'user',
            'content': [
              for (final f in request.input.files)
                if (f.isImage && imageTypes.contains(f.mimeType))
                  {
                    'type': 'image',
                    'source': {'type': 'base64', 'media_type': f.mimeType, 'data': base64Encode(f.bytes)},
                  }
                else if (f.isPdf)
                  {
                    'type': 'document',
                    'source': {'type': 'base64', 'media_type': 'application/pdf', 'data': base64Encode(f.bytes)},
                  },
              {'type': 'text', 'text': request.prompt},
            ],
          },
        ],
      };

  Map<String, String> get headers => {
        'content-type': 'application/json',
        'x-api-key': apiKey.trim(),
        'anthropic-version': '2023-06-01',
        if (model != 'claude-haiku-5-5') 'anthropic-beta': 'server-side-fallback-2026-07-01',
        if (browser) 'anthropic-dangerous-direct-browser-access': 'true',
      };

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    for (final f in request.input.files) {
      if (f.isImage && !imageTypes.contains(f.mimeType)) {
        throw const ReaderException('Claude can\'t read that kind of image. Share it as a JPEG or PNG.');
      }
    }
    final http.Response response;
    try {
      response = await _http.post(endpoint, headers: headers, body: jsonEncode(body(request))).timeout(timeout);
    } on TimeoutException {
      throw const ReaderException('Claude took too long to answer. Try again.', retry: true);
    } on Object {
      throw const ReaderException(
        'Couldn\'t reach Claude. Check the internet connection; nothing was added.',
        retry: true,
      );
    }
    return parse(response.statusCode, response.body);
  }

  /// The reader's JSON from a Messages API response, or the reason there is none.
  static Map<String, Object?> parse(int status, String responseBody) {
    Map<String, Object?> json;
    try {
      json = Map<String, Object?>.from(jsonDecode(responseBody) as Map);
    } on Object {
      json = const {};
    }
    if (status != 200) {
      final error = json['error'] is Map ? Map<String, Object?>.from(json['error']! as Map) : const <String, Object?>{};
      final message = error['message'] as String?;
      throw switch (status) {
        401 || 403 => const ReaderException(
            'Claude didn\'t accept the API key. A parent can check it under Settings, AI and automations.',
          ),
        413 => const ReaderException('That\'s too big for Claude to read in one go. Try fewer pages or a smaller photo.'),
        429 => const ReaderException('Claude is getting too many requests from this key. Try again in a minute.', retry: true),
        529 || 503 || 500 || 502 => const ReaderException('Claude is busy right now. Try again in a minute.', retry: true),
        _ => ReaderException('Claude couldn\'t read that${message == null ? '' : ': $message'}.'),
      };
    }
    switch (json['stop_reason']) {
      case 'refusal':
        throw const ReaderException('Claude declined to read that.');
      case 'max_tokens':
        throw const ReaderException('There was too much to read in one go. Try sharing part of it.');
    }
    final text = [
      for (final block in (json['content'] as List? ?? const []))
        if (block is Map && block['type'] == 'text') block['text'] as String? ?? '',
    ].join();
    try {
      return Map<String, Object?>.from(jsonDecode(text) as Map);
    } on Object {
      throw const ReaderException('Claude\'s answer didn\'t make sense to Den. Try again.', retry: true);
    }
  }
}
