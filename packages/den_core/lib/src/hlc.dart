/// Hybrid logical clock timestamp: wall-clock milliseconds, a counter for events within the same
/// millisecond, and the device id as the final tiebreaker. The string form sorts the same way as
/// [compareTo]: `"<millis 13 digits>-<counter 4 hex>-<deviceId>"`.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.device);

  final int millis;
  final int counter;
  final String device;

  static Hlc parse(String value) {
    final first = value.indexOf('-');
    final second = value.indexOf('-', first + 1);
    if (first != 13 || second != 18) {
      throw FormatException('Not an HLC timestamp', value);
    }
    return Hlc(
      int.parse(value.substring(0, first)),
      int.parse(value.substring(first + 1, second), radix: 16),
      value.substring(second + 1),
    );
  }

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return device.compareTo(other.device);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, device);

  @override
  String toString() =>
      '${millis.toString().padLeft(13, '0')}-${counter.toRadixString(16).padLeft(4, '0')}-$device';
}

/// Issues monotonically increasing [Hlc]s for one device and absorbs remote timestamps so local
/// time never runs behind what this device has seen.
class HlcClock {
  HlcClock(this.device, {int Function()? now}) : _now = now ?? _wallClock;

  final String device;
  final int Function() _now;
  int _millis = 0;
  int _counter = 0;

  static int _wallClock() => DateTime.now().toUtc().millisecondsSinceEpoch;

  Hlc next() {
    final wall = _now();
    if (wall > _millis) {
      _millis = wall;
      _counter = 0;
    } else if (_counter >= maxCounter) {
      _millis++;
      _counter = 0;
    } else {
      _counter++;
    }
    return Hlc(_millis, _counter, device);
  }

  /// The largest counter the 4-hex-digit string form holds; the clock moves to the next
  /// millisecond instead of passing it.
  static const int maxCounter = 0xffff;

  /// Moves the clock past a timestamp received from another device.
  void observe(Hlc remote) {
    if (remote.millis > _millis || (remote.millis == _millis && remote.counter > _counter)) {
      _millis = remote.millis;
      _counter = remote.counter > maxCounter ? maxCounter : remote.counter;
    }
  }
}
