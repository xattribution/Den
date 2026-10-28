import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps this app running in the background while it is the family's hub.
///
/// On Android, [start] runs a foreground service with a notification that stays while the hub
/// does ("Den is keeping the family online"), so the system doesn't stop the app when it leaves
/// the screen; the service also keeps the CPU and Wi-Fi awake, and the app's engine (where the
/// hub runs) outlives its window until [stop]. On a Mac the same channel keeps Den running when
/// its window is closed (the window goes to the Dock) and keeps the Mac from napping or sleeping
/// on its own. Windows and Linux keep running on their own, so there [HubKeepAlive.none] does
/// nothing.
abstract class HubKeepAlive {
  const HubKeepAlive();

  /// The right one for this platform.
  factory HubKeepAlive.platform({required bool android, bool mac = false}) =>
      android || mac ? AndroidHubKeepAlive() : const HubKeepAlive.none();

  /// Does nothing.
  const factory HubKeepAlive.none() = _NoKeepAlive;

  /// Starts keeping the app alive; [detail] is the notification's second line.
  Future<void> start(String detail);

  /// Changes the notification's second line.
  Future<void> update(String detail);

  /// Lets the app stop in the background again.
  Future<void> stop();
}

class _NoKeepAlive extends HubKeepAlive {
  const _NoKeepAlive();

  @override
  Future<void> start(String detail) async {}

  @override
  Future<void> update(String detail) async {}

  @override
  Future<void> stop() async {}
}

/// The Android foreground service, through the `den/hub_service` channel that `MainActivity`
/// answers: `start {text}`, `update {text}`, `stop`. The Mac's `HubService` (in
/// macos/Runner/MainFlutterWindow.swift) answers the same channel.
class AndroidHubKeepAlive extends HubKeepAlive {
  AndroidHubKeepAlive({MethodChannel channel = const MethodChannel('den/hub_service')}) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<void> start(String detail) => _call('start', detail);

  @override
  Future<void> update(String detail) => _call('update', detail);

  @override
  Future<void> stop() => _call('stop');

  /// The hub works without the service, just not reliably in the background, so a refusal is
  /// logged and nothing more.
  Future<void> _call(String method, [String? text]) async {
    try {
      await _channel.invokeMethod<void>(method, {'text': ?text});
    } on PlatformException catch (e) {
      debugPrint('hub service: $method refused (${e.code})');
    } on MissingPluginException {
      debugPrint('hub service: not available');
    }
  }
}

/// The notification's second line for [connected] devices.
String keepAliveDetail(int connected) => switch (connected) {
      0 => 'No other devices are connected right now.',
      1 => '1 device is connected.',
      _ => '$connected devices are connected.',
    };
