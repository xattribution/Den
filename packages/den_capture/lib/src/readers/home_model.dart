import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../reader.dart';

/// A model the family runs on a computer at home, such as the hub's machine, through Ollama's
/// chat API with the schema as its output format. What is shared stays in the house. Reads
/// text; photos reach it as the text the device found in them.
class HomeModelReader implements CaptureReader {
  HomeModelReader({
    required this.base,
    this.model = defaultModel,
    http.Client? client,
    this.timeout = const Duration(minutes: 3),
  }) : _http = client ?? http.Client();

  static const defaultModel = 'llama3.2';
  static const defaultPort = 11434;

  /// `http://192.168.1.20:11434`.
  final Uri base;
  final String model;
  final Duration timeout;
  final http.Client _http;

  /// The address a person typed as a base URI, on Ollama's port unless they gave one.
  static Uri? baseFor(String address) {
    var text = address.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';
    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return null;
    return Uri(scheme: parsed.scheme, host: parsed.host, port: parsed.hasPort ? parsed.port : defaultPort);
  }

  @override
  ReaderInfo get info => const ReaderInfo(
        id: 'home',
        name: 'Home model',
        place: ReaderPlace.home,
        inputs: {ReaderInput.text},
        historyName: 'the home model',
      );

  @override
  Future<bool> available() async {
    try {
      final r = await _http.get(base.replace(path: '/api/tags')).timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } on Object {
      return false;
    }
  }

  Map<String, Object?> body(ReadRequest request) => {
        'model': model,
        'stream': false,
        'format': request.schema,
        'options': {'temperature': 0},
        'messages': [
          {'role': 'system', 'content': request.instructions},
          {'role': 'user', 'content': request.prompt},
        ],
      };

  @override
  Future<Map<String, Object?>> read(ReadRequest request) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            base.replace(path: '/api/chat'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body(request)),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const ReaderException('The home model took too long to answer.', retry: true);
    } on Object {
      throw ReaderException('Couldn\'t reach the home model at ${base.host}:${base.port}.', retry: true);
    }
    return parse(response.statusCode, response.body, model);
  }

  static Map<String, Object?> parse(int status, String responseBody, String model) {
    Map<String, Object?> json;
    try {
      json = Map<String, Object?>.from(jsonDecode(responseBody) as Map);
    } on Object {
      json = const {};
    }
    if (status == 404) {
      throw ReaderException('The home computer doesn\'t have the model "$model". Run "ollama pull $model" there.');
    }
    if (status != 200) throw ReaderException('The home model couldn\'t read that (${json['error'] ?? status}).');
    final message = json['message'];
    final content = message is Map ? message['content'] as String? ?? '' : '';
    return lenientJson(content) ?? (throw const ReaderException('The home model\'s answer didn\'t make sense to Den.'));
  }
}

/// The first JSON object in a model's text: on-device and home models sometimes wrap it in a
/// code fence or a sentence.
Map<String, Object?>? lenientJson(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final v = jsonDecode(text.substring(start, end + 1));
    return v is Map ? Map<String, Object?>.from(v) : null;
  } on FormatException {
    return null;
  }
}
