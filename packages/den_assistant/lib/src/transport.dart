import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'endpoint.dart';
import 'json.dart';
import 'model.dart';
import 'providers.dart';

/// An HTTP status and the JSON body that came with it.
typedef RawReply = ({int status, Map<String, Object?> json});

/// Posts adapters' JSON to the provider, or to the hub in the provider's format.
class ModelTransport {
  /// A transport for [provider] through [endpoint].
  ModelTransport({
    required this.provider,
    required this.endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
  }) : _http = client ?? http.Client();

  /// The API the bodies are written for.
  final ModelProvider provider;

  /// Direct or through the hub.
  final ModelEndpoint endpoint;

  /// How long to wait for an answer.
  final Duration timeout;

  final http.Client _http;

  /// Whether requests go through the hub.
  bool get viaHub => endpoint.viaHub;

  /// Where a request for [model] goes.
  Uri urlFor(String model) => endpoint.hubUrl ?? provider.endpoint(endpoint.baseUrl ?? provider.defaultBase, model);

  /// Posts [body] for [model]. [directHeaders] go only to the provider itself. Throws
  /// [ModelException] when nothing comes back.
  Future<RawReply> post(String model, Map<String, Object?> body, {Map<String, String> directHeaders = const {}}) async {
    final bytes = utf8.encode(jsonEncode(body));
    final url = urlFor(model);
    final headers = <String, String>{'content-type': 'application/json'};
    final http.Response response;
    try {
      if (endpoint.viaHub) {
        headers[HubHeaders.provider] = provider.id;
        headers[HubHeaders.model] = model;
        final sign = endpoint.sign;
        if (sign != null) headers.addAll(await sign('POST', url, bytes));
      } else {
        headers.addAll(provider.authHeaders(endpoint.apiKey));
        headers.addAll(directHeaders);
      }
      response = await _http.post(url, headers: headers, body: bytes).timeout(timeout);
    } on TimeoutException {
      throw ModelException(
        '${provider.speaker} took too long to answer. Try again.',
        kind: ModelFailure.timeout,
        retry: true,
      );
    } on Object catch (e) {
      throw ModelException(
        viaHub
            ? 'Couldn\'t reach the hub. Check the connection and try again.'
            : 'Couldn\'t reach ${provider.speaker}. Check the internet connection and try again.',
        kind: ModelFailure.network,
        retry: true,
        detail: '$e',
      );
    }
    return (status: response.statusCode, json: decodeObject(utf8.decode(response.bodyBytes, allowMalformed: true)));
  }
}

/// The error message in a provider's (or the hub's) error body.
String? errorMessage(Map<String, Object?> json) {
  final error = json['error'];
  if (error is String) return error;
  return asString(asMap(error)['message']);
}

/// A failed status from [provider] as an exception people can read.
ModelException failureFor(ModelProvider provider, String model, int status, Map<String, Object?> json, {bool viaHub = false}) {
  final detail = errorMessage(json);
  final who = provider.speaker;
  if (viaHub) {
    if (status == 401) {
      return ModelException(
        'The hub didn\'t recognize this device. Pair it again in Settings.',
        kind: ModelFailure.auth,
        status: status,
        detail: detail,
      );
    }
    if ((status == 402 || status == 403 || status == 429) && detail != null) {
      // The hub's own policy: assistant off, budget spent, daily limit. Its message is for people.
      return ModelException(
        detail,
        kind: status == 429 ? ModelFailure.rateLimited : ModelFailure.refused,
        status: status,
        retry: status == 429,
        detail: detail,
      );
    }
    if (status == 404) {
      return ModelException(
        'The hub doesn\'t run the assistant yet. Update the hub, then try again.',
        kind: ModelFailure.notFound,
        status: status,
        detail: detail,
      );
    }
  }
  if (provider == ModelProvider.ollama && status == 404) {
    return ModelException(
      'The home computer doesn\'t have the model "$model". Run "ollama pull $model" there.',
      kind: ModelFailure.notFound,
      status: status,
      detail: detail,
    );
  }
  return switch (status) {
    401 || 403 => ModelException(
        '$who didn\'t accept the API key. A parent can check it in Settings.',
        kind: ModelFailure.auth,
        status: status,
        detail: detail,
      ),
    404 => ModelException(
        '$who doesn\'t know the model "$model". A parent can pick another in Settings.',
        kind: ModelFailure.notFound,
        status: status,
        detail: detail,
      ),
    413 => ModelException(
        'That\'s too much for $who in one go. Try a shorter message.',
        kind: ModelFailure.tooBig,
        status: status,
        detail: detail,
      ),
    429 => ModelException(
        'Too many requests to $who right now. Try again in a minute.',
        kind: ModelFailure.rateLimited,
        status: status,
        retry: true,
        detail: detail,
      ),
    >= 500 => ModelException(
        '$who is busy right now. Try again in a minute.',
        kind: ModelFailure.busy,
        status: status,
        retry: true,
        detail: detail,
      ),
    _ => ModelException(
        '$who couldn\'t answer that${detail == null ? '' : ': $detail'}.',
        kind: ModelFailure.badRequest,
        status: status,
        detail: detail,
      ),
  };
}
