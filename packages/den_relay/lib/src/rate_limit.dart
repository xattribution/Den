import 'dart:io';

import 'config.dart';

/// The key per-client limits and quotas use for a client [address]: an IPv4 address as it is,
/// an IPv6 address by its /64 (one subscriber's whole allocation, so rotating through it buys
/// nothing), an IPv4-mapped IPv6 address as its IPv4 address. Anything else is used as given.
String clientKeyOf(String address) {
  final parsed = InternetAddress.tryParse(address.trim());
  if (parsed == null) return address;
  if (parsed.type != InternetAddressType.IPv6) return parsed.address;
  final b = parsed.rawAddress;
  final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return '${b[12]}.${b[13]}.${b[14]}.${b[15]}';
  final groups = [for (var i = 0; i < 8; i += 2) ((b[i] << 8) | b[i + 1]).toRadixString(16)];
  return '${groups.join(':')}::/64';
}

/// A token bucket.
class TokenBucket {
  /// Creates a full bucket.
  TokenBucket(this.spec, int nowMillis)
      : _tokens = spec.capacity,
        _last = nowMillis;

  /// The bucket's shape.
  final RateSpec spec;
  double _tokens;
  int _last;

  void _refill(int now) {
    if (now > _last) {
      _tokens = (_tokens + (now - _last) / 1000 * spec.perSecond).clamp(0, spec.capacity).toDouble();
      _last = now;
    }
  }

  /// Takes one token; false when the bucket is empty.
  bool take(int now) {
    _refill(now);
    if (_tokens >= 1) {
      _tokens -= 1;
      return true;
    }
    return false;
  }

  /// Whole seconds until a token is available.
  int retryAfterSeconds(int now) {
    _refill(now);
    if (_tokens >= 1 || spec.perSecond <= 0) return spec.perSecond <= 0 ? 3600 : 0;
    return ((1 - _tokens) / spec.perSecond).ceil().clamp(1, 3600);
  }

  /// Whether the bucket has refilled completely (so forgetting it changes nothing).
  bool isFull(int now) {
    _refill(now);
    return _tokens >= spec.capacity;
  }
}

/// Token buckets per key (client address, mailbox id), forgetting idle ones.
class RateLimiter {
  /// Creates a limiter.
  RateLimiter(this.spec, this._now, {this.maxKeys = 100000});

  /// Each key's bucket shape.
  final RateSpec spec;

  /// Keys tracked before full buckets are dropped.
  final int maxKeys;

  final int Function() _now;
  final Map<String, TokenBucket> _buckets = {};

  /// Takes a token for [key]; on refusal returns the seconds to wait, else null.
  int? take(String key) {
    final now = _now();
    if (_buckets.length >= maxKeys) prune();
    final bucket = _buckets.putIfAbsent(key, () => TokenBucket(spec, now));
    if (bucket.take(now)) return null;
    return bucket.retryAfterSeconds(now);
  }

  /// Drops buckets that have refilled completely.
  void prune() {
    final now = _now();
    _buckets.removeWhere((_, b) => b.isFull(now));
  }

  /// Number of keys tracked.
  int get size => _buckets.length;
}
