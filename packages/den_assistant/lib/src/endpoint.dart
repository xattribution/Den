/// Signs a request to the family's hub with this device's key (den_net's `DeviceRequest`), and
/// returns the headers to add.
typedef RequestSigner = Future<Map<String, String>> Function(String method, Uri url, List<int> body);

/// Headers an adapter adds when it talks to the hub instead of the provider. The hub forwards the
/// body unchanged to the provider it was set up with, adding its key.
abstract final class HubHeaders {
  /// The [ModelProvider] id the body is written for.
  static const provider = 'x-den-provider';

  /// The model id, which Gemini's body doesn't carry.
  static const model = 'x-den-model';
}

/// Where an adapter sends its requests.
class ModelEndpoint {
  /// Straight to the provider with a key kept on this device, or to [baseUrl] instead of the
  /// provider's own address (a home computer for Ollama, a compatible gateway).
  const ModelEndpoint.direct({this.apiKey, this.baseUrl})
      : hubUrl = null,
        sign = null;

  /// Through the family's hub: every request is POSTed to [hubUrl]
  /// (`.../api/v1/assistant/model`) in the provider's own format, signed with [sign], with
  /// [HubHeaders] naming the provider and model. The key stays on the hub.
  const ModelEndpoint.hub(Uri this.hubUrl, {this.sign})
      : apiKey = null,
        baseUrl = null;

  /// The provider's API key, when calling it directly.
  final String? apiKey;

  /// Replaces the provider's base address when calling directly.
  final Uri? baseUrl;

  /// The hub's model endpoint, when going through the hub.
  final Uri? hubUrl;

  /// Signs requests to the hub.
  final RequestSigner? sign;

  /// Whether requests go through the hub.
  bool get viaHub => hubUrl != null;
}
