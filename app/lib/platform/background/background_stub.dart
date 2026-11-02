/// Browsers run one engine per tab and no background tasks: the lock is always free.
class EngineLock {
  EngineLock._();

  Future<void> Function()? onRefresh;

  static Future<EngineLock> acquire({Duration wait = Duration.zero}) async => EngineLock._();

  void release() {}
}

Future<void> scheduleBackgroundRefresh() async {}
