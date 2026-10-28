import 'dart:convert';

/// [value] as a JSON object, or an empty one. The result may be a read-only view.
Map<String, Object?> asMap(Object? value) => value is Map ? value.cast<String, Object?>() : const <String, Object?>{};

/// [value] as a JSON array, or an empty one.
List<Object?> asList(Object? value) => value is List ? value.cast<Object?>() : const <Object?>[];

/// [value] as a whole number, or 0.
int asInt(Object? value) => value is num ? value.toInt() : 0;

/// [value] when it is a string.
String? asString(Object? value) => value is String ? value : null;

/// The JSON object in [text], or an empty one when it isn't one.
Map<String, Object?> decodeObject(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    decoded = null;
  }
  return asMap(decoded);
}

/// [text] decoded when it is JSON, or [text] itself.
Object? decodeOrText(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

/// JSON text for [value]; anything JSON can't hold is written as its `toString()`.
String encodeJson(Object? value) => jsonEncode(value, toEncodable: (Object? o) => o.toString());

/// A copy of a JSON object without its null members, for sending back what a provider returned.
Object? withoutNulls(Object? value) {
  if (value is! Map) return value;
  return <String, Object?>{
    for (final entry in asMap(value).entries) entry.key: ?entry.value,
  };
}
