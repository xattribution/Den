/// Fractional index keys for ordering list items: strings that sort lexicographically, with a key
/// between any two. A key is an integer part (a head letter giving its length, then base-62
/// digits) and a fraction, so appending stays short while inserting between neighbors never needs
/// to renumber anything.
const String _digits = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
const String _zero = 'a0';
final String _smallestInteger = 'A${'0' * 26}';

int _integerLength(String head) {
  final c = head.codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7a) return c - 0x61 + 2;
  if (c >= 0x41 && c <= 0x5a) return 0x5a - c + 2;
  throw FormatException('Invalid order key head', head);
}

String _integerPart(String key) {
  final length = _integerLength(key[0]);
  if (length > key.length) throw FormatException('Invalid order key', key);
  return key.substring(0, length);
}

/// Whether [key] is a well-formed order key.
bool isOrderKey(String key) {
  try {
    _validate(key);
    return true;
  } on FormatException {
    return false;
  }
}

void _validate(String key) {
  if (key.isEmpty || key == _smallestInteger) throw FormatException('Invalid order key', key);
  for (final c in key.split('')) {
    if (!_digits.contains(c)) throw FormatException('Invalid order key', key);
  }
  final i = _integerPart(key);
  final f = key.substring(i.length);
  if (f.endsWith('0')) throw FormatException('Invalid order key', key);
}

String _midpoint(String a, String? b) {
  if (b != null && a.compareTo(b) >= 0) throw FormatException('$a is not before $b');
  if (a.endsWith('0') || (b != null && b.endsWith('0'))) throw const FormatException('Trailing zero');
  if (b != null) {
    var n = 0;
    while ((n < a.length ? a[n] : '0') == b[n]) {
      n++;
    }
    if (n > 0) return b.substring(0, n) + _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
  }
  final digitA = a.isNotEmpty ? _digits.indexOf(a[0]) : 0;
  final digitB = b != null ? _digits.indexOf(b[0]) : _digits.length;
  if (digitB - digitA > 1) return _digits[((digitA + digitB) / 2).round()];
  if (b != null && b.length > 1) return b.substring(0, 1);
  return _digits[digitA] + _midpoint(a.isEmpty ? '' : a.substring(1), null);
}

String? _increment(String x) {
  final head = x[0];
  final digits = x.substring(1).split('');
  var carry = true;
  for (var i = digits.length - 1; carry && i >= 0; i--) {
    final d = _digits.indexOf(digits[i]) + 1;
    if (d == _digits.length) {
      digits[i] = '0';
    } else {
      digits[i] = _digits[d];
      carry = false;
    }
  }
  if (carry) {
    if (head == 'Z') return 'a0';
    if (head == 'z') return null;
    final h = String.fromCharCode(head.codeUnitAt(0) + 1);
    if (h.compareTo('a') > 0) {
      digits.add('0');
    } else {
      digits.removeLast();
    }
    return h + digits.join();
  }
  return head + digits.join();
}

String? _decrement(String x) {
  final head = x[0];
  final digits = x.substring(1).split('');
  var borrow = true;
  for (var i = digits.length - 1; borrow && i >= 0; i--) {
    final d = _digits.indexOf(digits[i]) - 1;
    if (d == -1) {
      digits[i] = _digits[_digits.length - 1];
    } else {
      digits[i] = _digits[d];
      borrow = false;
    }
  }
  if (borrow) {
    if (head == 'a') return 'Z${_digits[_digits.length - 1]}';
    if (head == 'A') return null;
    final h = String.fromCharCode(head.codeUnitAt(0) - 1);
    if (h.compareTo('Z') < 0) {
      digits.add(_digits[_digits.length - 1]);
    } else {
      digits.removeLast();
    }
    return h + digits.join();
  }
  return head + digits.join();
}

/// A key strictly between [a] and [b]; either may be null for the open end. Malformed bounds are
/// treated as open.
String keyBetween(String? a, String? b) {
  if (a != null && !isOrderKey(a)) a = null;
  if (b != null && !isOrderKey(b)) b = null;
  if (a != null && b != null && a.compareTo(b) >= 0) b = null;
  if (a == null) {
    if (b == null) return _zero;
    final ib = _integerPart(b);
    final fb = b.substring(ib.length);
    if (ib == _smallestInteger) return ib + _midpoint('', fb);
    if (ib.compareTo(b) < 0) return ib;
    return _decrement(ib) ?? ib + _midpoint('', fb);
  }
  if (b == null) {
    final ia = _integerPart(a);
    final fa = a.substring(ia.length);
    return _increment(ia) ?? ia + _midpoint(fa, null);
  }
  final ia = _integerPart(a);
  final fa = a.substring(ia.length);
  final ib = _integerPart(b);
  final fb = b.substring(ib.length);
  if (ia == ib) return ia + _midpoint(fa, fb);
  final i = _increment(ia);
  if (i != null && i.compareTo(b) < 0) return i;
  return ia + _midpoint(fa, null);
}
