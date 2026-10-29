import 'dart:convert';

import 'model.dart';
import 'rrule.dart';
import 'time.dart';

/// Checks one field value; returns a message for people, or null when it's fine.
typedef FieldCheck = String? Function(String label, Object? value);

const int maxTitle = 200;
const int maxNotes = 5000;
const int maxItemText = 300;
const int maxName = 100;
const int maxSteps = 30;

final RegExp _idRe = RegExp(r'^[A-Za-z0-9_\-:@.]{1,80}$');
final RegExp _orderRe = RegExp(r'^[0-9A-Za-z]{1,120}$');
final RegExp _zoneRe = RegExp(r'^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)*$');
final RegExp _hexRe = RegExp(r'^[0-9a-f]{64}$');
final RegExp _keyRe = RegExp(r'^[A-Za-z0-9_\-]{20,100}$');

FieldCheck text({int min = 0, int max = maxTitle, bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! String) return '$label must be text';
      if (v.trim().length < min) return min <= 1 ? '$label is empty' : '$label is too short';
      if (v.length > max) return '$label is too long ($max characters at most)';
      return null;
    };

FieldCheck number({int? min, int? max, bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! int) return '$label must be a whole number';
      if (min != null && v < min) return '$label must be at least $min';
      if (max != null && v > max) return '$label must be at most $max';
      return null;
    };

FieldCheck flag({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return v is bool ? null : '$label must be true or false';
    };

FieldCheck oneOf(Iterable<String> values, {bool nullable = false}) {
  final allowed = values.toSet();
  return (label, v) {
    if (v == null) return nullable ? null : '$label is missing';
    return v is String && allowed.contains(v) ? null : '$label must be one of ${allowed.join(', ')}';
  };
}

FieldCheck names<T extends Enum>(List<T> values, {bool nullable = false}) =>
    oneOf(values.map((v) => v.name), nullable: nullable);

FieldCheck id({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return v is String && _idRe.hasMatch(v) ? null : '$label is not a valid id';
    };

FieldCheck localDate({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return isLocalDate(v) ? null : '$label must be a date like 2026-10-17';
    };

FieldCheck localTime({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return isLocalTime(v) ? null : '$label must be a time like 07:30';
    };

FieldCheck rule({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! String || v.length > 500) return '$label is not a repeat rule Den understands';
      return RecurrenceRule.isValid(v) ? null : '$label is not a repeat rule Den understands';
    };

FieldCheck zoneName({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return v is String && v.length <= 64 && _zoneRe.hasMatch(v) ? null : '$label is not a time zone';
    };

FieldCheck orderKey() => (label, v) => v is String && _orderRe.hasMatch(v) ? null : '$label is not an order key';

FieldCheck hex64({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return v is String && _hexRe.hasMatch(v) ? null : '$label is not a SHA-256 hash';
    };

FieldCheck keyText({bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      return v is String && _keyRe.hasMatch(v) ? null : '$label is not a key';
    };

FieldCheck space() => (label, v) => v is String &&
        (v == Space.family || v == Space.parents || (Space.isMember(v) && _idRe.hasMatch(v.substring(2))))
    ? null
    : '$label is not a space';

FieldCheck listOf(FieldCheck item, {int max = 50, bool nullable = false, bool unique = false}) =>
    (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! List) return '$label must be a list';
      if (v.length > max) return '$label has too many entries ($max at most)';
      for (final e in v) {
        final err = item(label, e);
        if (err != null) return err;
      }
      if (unique && v.toSet().length != v.length) return '$label has repeated entries';
      return null;
    };

/// A map with a fixed set of keys.
FieldCheck shape(Map<String, FieldCheck> keys, {Set<String> required = const {}, bool nullable = false}) =>
    (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! Map) return '$label must be a map';
      for (final k in v.keys) {
        if (k is! String || !keys.containsKey(k)) return '$label has an unknown part "$k"';
      }
      for (final r in required) {
        if (v[r] == null) return '$label is missing "$r"';
      }
      for (final e in keys.entries) {
        if (v.containsKey(e.key)) {
          final err = e.value('$label ${e.key}', v[e.key]);
          if (err != null) return err;
        }
      }
      return null;
    };

/// A map from ids to values.
FieldCheck dict(FieldCheck value, {int maxKeys = 50, bool nullable = false}) => (label, v) {
      if (v == null) return nullable ? null : '$label is missing';
      if (v is! Map) return '$label must be a map';
      if (v.length > maxKeys) return '$label has too many entries';
      for (final e in v.entries) {
        if (e.key is! String || !_idRe.hasMatch(e.key as String)) return '$label has a bad key';
        final err = value(label, e.value);
        if (err != null) return err;
      }
      return null;
    };

/// One record type: its fields, which are required when the record is created, the space it must
/// live in (null for any), and map fields whose entries may be written one at a time.
class TypeSpec {
  const TypeSpec(this.fields, {this.required = const {}, this.space, this.entries = const {}});
  final Map<String, FieldCheck> fields;
  final Set<String> required;
  final String? space;
  final Map<String, EntryCheck> entries;
}

/// Checks one entry of a map field written on its own, as `"<field>.<key>"`.
typedef EntryCheck = String? Function(String key, Object? value);

/// One overridden event field of an occurrence; null clears the override.
String? _patchEntry(String key, Object? value) {
  if (!patchableEventFields.contains(key)) return 'An occurrence can\'t change "$key" on its own';
  return value == null ? null : eventFields[key]!(_label(key), value);
}

final FieldCheck _reminders = listOf(number(min: 0, max: 40320), max: 10);
final FieldCheck _rides = listOf(
  shape({'leg': oneOf(['to', 'from']), 'driver': id(nullable: true)}, required: {'leg'}),
  max: 4,
);
final FieldCheck _memberIds = listOf(id(), max: 50, unique: true);

final Map<String, FieldCheck> eventFields = {
  'title': text(min: 1),
  'notes': text(max: maxNotes),
  'location': text(max: 300),
  'category': id(nullable: true),
  'start': number(min: 0),
  'end': number(min: 0),
  'allDay': flag(),
  'tz': zoneName(),
  'rrule': rule(nullable: true),
  'assignees': _memberIds,
  'reminders': _reminders,
  'source': shape({
    'kind': oneOf(['manual', 'ics', 'device']),
    'ref': text(max: 1000, nullable: true),
    'label': text(max: maxTitle, nullable: true),
  }, required: {'kind'}),
  'rides': _rides,
  'countdown': flag(),
};

/// Event fields an occurrence may override on its own.
const Set<String> patchableEventFields = {
  'title', 'notes', 'location', 'category', 'start', 'end', 'allDay', 'assignees', 'reminders', 'rides',
};

String? _choreOwner(String label, Object? v) {
  if (v is! Map) return '$label must say who the chore belongs to';
  return switch (v['kind']) {
    'member' => shape({'kind': oneOf(['member']), 'id': id()}, required: {'id'})(label, v),
    'anyone' => shape({'kind': oneOf(['anyone'])})(label, v),
    'rotation' => shape({
        'kind': oneOf(['rotation']),
        'ids': (l, ids) => ids is List && ids.isEmpty ? '$l needs at least one person' : _memberIds(l, ids),
        'every': oneOf(['day', 'week']),
        'anchor': localDate(),
      }, required: {'ids', 'every', 'anchor'})(label, v),
    _ => '$label must be a member, anyone, or a rotation',
  };
}

String? _schedule(String label, Object? v) {
  if (v is! Map) return '$label must be a schedule';
  if (v.containsKey('once')) return shape({'once': localDate()}, required: {'once'})(label, v);
  return shape({'rrule': rule(), 'start': localDate()}, required: {'rrule', 'start'})(label, v);
}

String? _steps(String label, Object? v) {
  final err = listOf(
    shape({
      'id': id(),
      'text': text(min: 1, max: maxTitle),
      'owner': id(nullable: true),
      'points': number(min: 0, max: 1000),
      'icon': text(max: 40, nullable: true),
    }, required: {'id', 'text'}),
    max: maxSteps,
  )(label, v);
  if (err != null) return err;
  final ids = [for (final s in v as List) (s as Map)['id']];
  return ids.toSet().length == ids.length ? null : '$label has two steps with the same id';
}

/// A member's picture: a pack id or `initial` (see [Picture]).
String? _picture(String label, Object? v) {
  if (v == null) return null;
  return Picture.valid(v) ? null : '$label is not a picture Den knows';
}

/// A parent's recovery key (`member.recovery`) or the hub's the family lets help
/// (`family.recovery`), with the devices the key it replaces had let in; and the proof a device
/// let in by recovery carries (`device.recovery`). See recovery.dart.
FieldCheck _recoveryKey(String name) => shape({name: keyText(nullable: true), 'kept': listOf(id(), unique: true)});
final FieldCheck _recoveryProof = shape({
  'kind': oneOf(['words', 'hub']),
  'member': id(),
  'key': keyText(),
  'nonce': keyText(),
  'expires': number(min: 0),
  'sig': keyText(),
}, required: {'kind', 'member', 'key', 'nonce', 'expires', 'sig'});

/// One entry of `family.oversight`: a person's privacy (`<memberId>`: `{parentsSeePrivate}`),
/// or one of their other settings (`<memberId>.<setting>`: a bool, null for the default).
String? _oversightEntry(String key, Object? v) {
  final dot = key.indexOf('.');
  if (dot < 0) return shape({'parentsSeePrivate': flag()})('Oversight', v);
  final setting = key.substring(dot + 1);
  if (dot == 0 || !OversightSetting.all.contains(setting)) return 'Oversight has an unknown setting "$setting"';
  return v == null || v is bool ? null : 'Oversight $setting must be true or false';
}

String? _oversight(String label, Object? v) {
  if (v is! Map) return '$label must be a map';
  if (v.length > 200) return '$label has too many entries';
  for (final e in v.entries) {
    if (e.key is! String || !_idRe.hasMatch(e.key as String)) return '$label has a bad key';
    final err = _oversightEntry(e.key as String, e.value);
    if (err != null) return err;
  }
  return null;
}

/// What a photo's bytes are: their format and size in pixels, read from the headers; null when
/// they are neither a JPEG nor a WebP Den can read.
({String mime, int width, int height})? photoFormat(List<int> b) {
  int u16be(int i) => (b[i] << 8) | b[i + 1];
  int u16le(int i) => b[i] | (b[i + 1] << 8);
  int u24le(int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
  bool ascii(int at, String text) {
    if (at + text.length > b.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 3 < b.length) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) return null;
      final length = u16be(i + 2);
      if (length < 2) return null;
      final sof = marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;
      if (sof) {
        if (i + 9 > b.length) return null;
        return (mime: Photo.jpeg, height: u16be(i + 5), width: u16be(i + 7));
      }
      i += 2 + length;
    }
    return null;
  }
  if (b.length >= 30 && ascii(0, 'RIFF') && ascii(8, 'WEBP')) {
    if (ascii(12, 'VP8 ') && b[23] == 0x9D && b[24] == 0x01 && b[25] == 0x2A) {
      return (mime: Photo.webp, width: u16le(26) & 0x3FFF, height: u16le(28) & 0x3FFF);
    }
    if (ascii(12, 'VP8L') && b[20] == 0x2F) {
      final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
      return (mime: Photo.webp, width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
    }
    if (ascii(12, 'VP8X')) return (mime: Photo.webp, width: u24le(24) + 1, height: u24le(27) + 1);
  }
  return null;
}

/// The bytes of a photo's `data`, or null when it isn't base64.
List<int>? photoBytes(Object? data) {
  if (data is! String) return null;
  try {
    return base64.decode(data);
  } on FormatException {
    return null;
  }
}

String? _photoData(String label, Object? v) {
  if (v is! String) return '$label must be text';
  if (v.length > (Photo.maxBytes + 2) ~/ 3 * 4) return 'The photo is too big (${Photo.maxBytes ~/ 1024} KB at most)';
  final bytes = photoBytes(v);
  if (bytes == null) return '$label isn\'t a photo';
  if (bytes.length > Photo.maxBytes) return 'The photo is too big (${Photo.maxBytes ~/ 1024} KB at most)';
  final format = photoFormat(bytes);
  if (format == null) return 'A photo must be a JPEG or WebP';
  if (format.width != Photo.side || format.height != Photo.side) {
    return 'A photo must be ${Photo.side} by ${Photo.side} pixels';
  }
  return null;
}

final FieldCheck _signIn = shape({
  'kind': oneOf(['pin', 'pattern', 'none']),
  'salt': text(max: 100, nullable: true),
  'hash': text(max: 200, nullable: true),
}, required: {'kind'});

/// Stars a chore or step is worth.
final FieldCheck _points = number(min: 0, max: 1000);

String? _checker(String label, Object? v) => v == null || (v is String && (v.isEmpty || _idRe.hasMatch(v)))
    ? null
    : '$label is not a member';

final Map<String, TypeSpec> typeSpecs = {
  RecordType.family: TypeSpec({
    'name': text(min: 1, max: maxName),
    'timezone': zoneName(),
    'weekStart': number(min: 0, max: 6),
    'founderDevice': id(),
    'capture': oneOf(['direct', 'review']),
    'pointsEnabled': flag(),
    'oversight': _oversight,
    'assistant': shape({
      'enabled': flag(),
      'members': listOf(id(), max: 50, unique: true),
      'kidDailyLimit': number(min: 0, max: 1000),
      'budgetCents': number(min: 0, max: 100000),
    }, required: {'enabled'}),
    'recovery': _recoveryKey('serverKey'),
  }, required: {'name', 'timezone', 'founderDevice'}, space: Space.family, entries: {
    'oversight': _oversightEntry,
  }),
  RecordType.member: TypeSpec({
    'name': text(min: 1, max: maxName),
    'role': names(Role.values),
    'tier': names(Tier.values, nullable: true),
    'marker': oneOf(Marker.allNames),
    'animal': names(Animal.values),
    'picture': _picture,
    'birthday': localDate(nullable: true),
    'until': localDate(nullable: true),
    'grants': listOf(names(Grant.values), max: 4, unique: true),
    'signIn': _signIn,
    'order': number(),
    'recovery': _recoveryKey('key'),
  }, required: {'name', 'role'}, space: Space.family),
  RecordType.signInTries: TypeSpec({
    'device': id(),
    'member': id(),
    'tries': number(min: 1, max: 1000000),
  }, required: {'device', 'member', 'tries'}, space: Space.family),
  RecordType.device: TypeSpec({
    'name': text(min: 1, max: maxName),
    'kind': names(DeviceKind.values),
    'pubkey': keyText(),
    'xpub': keyText(nullable: true),
    'member': id(nullable: true),
    'mode': names(DeviceMode.values),
    'approved': flag(),
    'approvedBy': id(nullable: true),
    'revoked': flag(),
    'revokedAfter': number(min: 0),
    'display': shape({'layout': names(DisplayLayout.values), 'openCheckoff': flag()}),
    'recovery': _recoveryProof,
  }, required: {'name', 'kind', 'pubkey', 'mode'}, space: Space.family),
  RecordType.category: TypeSpec({
    'name': text(min: 1, max: maxName),
    'icon': text(max: 40),
  }, required: {'name'}, space: Space.family),
  RecordType.event: TypeSpec(eventFields, required: {'title', 'start', 'end'}),
  RecordType.eventException: TypeSpec({
    'event': id(),
    'occurrence': number(min: 0),
    'cancelled': flag(),
    'patch': (label, v) {
      if (v is! Map) return '$label must be a map';
      for (final e in v.entries) {
        final err = _patchEntry(e.key as String, e.value);
        if (err != null) return err;
      }
      return null;
    },
  }, required: {'event', 'occurrence'}, entries: {'patch': _patchEntry}),
  RecordType.chore: TypeSpec({
    'title': text(min: 1),
    'notes': text(max: maxNotes),
    'icon': text(max: 40),
    'owner': _choreOwner,
    'schedule': _schedule,
    'dueTime': localTime(nullable: true),
    'points': _points,
    'steps': _steps,
    'reminders': _reminders,
    'active': flag(),
  }, required: {'title', 'owner', 'schedule'}),
  RecordType.completion: TypeSpec({
    'chore': id(),
    'date': localDate(),
    'done': flag(),
    'doneBy': id(nullable: true),
    'owner': id(nullable: true),
    'steps': dict(_checker, maxKeys: maxSteps),
    'points': _points,
    'stepPoints': dict(_points, maxKeys: maxSteps),
  }, required: {'chore', 'date'}, entries: {
    'steps': (key, v) => _checker('Steps', v),
    'stepPoints': (key, v) => _points('Step points', v),
  }),
  RecordType.adjustment: TypeSpec({
    'member': id(),
    'delta': (label, v) => v == 0 ? '$label can\'t be zero' : number(min: -10000, max: 10000)(label, v),
    'reason': text(max: maxTitle),
    'by': id(nullable: true),
  }, required: {'member', 'delta'}, space: Space.family),
  RecordType.goal: TypeSpec({
    'title': text(min: 1),
    'mode': names(GoalMode.values),
    'target': number(min: 1, max: 100000),
    'members': listOf(id(), nullable: true, unique: true),
    'start': localDate(),
    'end': localDate(nullable: true),
    'repeat': names(GoalRepeat.values),
    'reward': text(max: maxTitle),
  }, required: {'title', 'target', 'start'}, space: Space.family),
  RecordType.reward: TypeSpec({
    'title': text(min: 1),
    'cost': number(min: 0, max: 100000),
    'icon': text(max: 40),
    'needsApproval': flag(),
    'active': flag(),
  }, required: {'title', 'cost'}, space: Space.family),
  RecordType.redemption: TypeSpec({
    'reward': id(),
    'member': id(),
    'cost': number(min: 0, max: 100000),
    'status': names(RedemptionStatus.values),
    'decidedBy': id(nullable: true),
  }, required: {'reward', 'member', 'cost', 'status'}, space: Space.family),
  RecordType.list: TypeSpec({
    'title': text(min: 1),
    'icon': text(max: 40),
    'kind': names(ListKind.values),
    'lifecycle': names(ListLifecycle.values),
    'needBy': localDate(nullable: true),
    'event': id(nullable: true),
    'pinned': flag(),
    'order': orderKey(),
  }, required: {'title'}),
  RecordType.item: TypeSpec({
    'list': id(),
    'text': text(min: 1, max: maxItemText),
    'qty': text(max: 50, nullable: true),
    'store': text(max: maxName, nullable: true),
    'checked': flag(),
    'checkedBy': id(nullable: true),
    'order': orderKey(),
    'toGroceries': flag(),
  }, required: {'list', 'text'}),
  RecordType.subscription: TypeSpec({
    'url': text(min: 1, max: 2000),
    'label': text(max: maxTitle),
    'category': id(nullable: true),
    'assignee': id(nullable: true),
    'space': space(),
    'include': listOf(text(max: maxTitle)),
    'exclude': listOf(text(max: maxTitle)),
    'skipAllDay': flag(),
    'status': text(max: 500),
  }, required: {'url'}, space: Space.parents),
  RecordType.connection: TypeSpec({
    'label': text(min: 1),
    'kind': names(ConnectionKind.values),
    'scopes': listOf(names(Scope.values), max: 6, unique: true),
    'member': id(nullable: true),
    'tokenHash': hex64(nullable: true),
    'client': text(max: maxTitle, nullable: true),
    'status': names(ConnectionStatus.values),
    'expires': number(min: 0, nullable: true),
  }, required: {'label', 'kind', 'scopes', 'status'}, space: Space.parents),
  RecordType.photo: TypeSpec({
    'member': id(),
    'mime': oneOf(const [Photo.jpeg, Photo.webp]),
    'data': _photoData,
  }, required: {'member', 'mime', 'data'}, space: Space.family),
};

/// `_from` on a change: what a capture read, and who read it.
final FieldCheck _origin = shape({
  'kind': names(CaptureKind.values),
  'reader': text(max: maxName, nullable: true),
}, required: {'kind'});

String _label(String field) {
  final spaced = field.replaceAllMapped(RegExp(r'[A-Z]'), (m) => ' ${m[0]!.toLowerCase()}');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// Validates a change's fields against its type. [creating] demands the required fields.
String? checkFields(String type, Map<String, Object?> fields, {required bool creating}) {
  final spec = typeSpecs[type];
  if (spec == null) return 'Den doesn\'t know records of type "$type"';
  if (fields.isEmpty) return 'Nothing to change';
  final deleting = fields['_deleted'];
  if (deleting != null && deleting is! bool) return 'Removal must be true or false';
  if (deleting == true && fields.keys.any((k) => k != '_deleted' && k != '_via')) {
    return 'A removal can\'t change other fields';
  }
  for (final e in fields.entries) {
    final name = e.key;
    if (name == '_deleted') continue;
    if (name == '_via') {
      final err = text(min: 1, max: maxTitle)('Via', e.value);
      if (err != null) return err;
      continue;
    }
    if (name == '_from') {
      final err = _origin('Source', e.value);
      if (err != null) return err;
      continue;
    }
    final dot = name.indexOf('.');
    if (dot > 0) {
      final check = spec.entries[name.substring(0, dot)];
      final key = name.substring(dot + 1);
      if (check == null || !_idRe.hasMatch(key)) return 'Unknown field "$name"';
      final err = check(key, e.value);
      if (err != null) return err;
      continue;
    }
    final check = spec.fields[name];
    if (check == null) return 'Unknown field "$name"';
    final err = check(_label(name), e.value);
    if (err != null) return err;
  }
  if (creating && deleting != true) {
    for (final r in spec.required) {
      if (fields[r] == null) return '${_label(r)} is missing';
    }
  }
  return null;
}
