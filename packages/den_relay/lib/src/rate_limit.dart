import 'config.dart';

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
