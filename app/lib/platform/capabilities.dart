import 'package:flutter/foundation.dart';

/// What this device can do. Every check of "is this a browser" or "which operating system" lives
/// here, so the rest of the app asks a question with a name ("can it scan a QR code?") instead
/// of testing platforms. Getters, not constants, so tests can set
/// `debugDefaultTargetPlatformOverride`.
abstract final class Capabilities {
  /// Running in a browser: the Home Screen web app, or a desktop browser.
  static bool get web => kIsWeb;

  static bool _is(TargetPlatform p) => !kIsWeb && defaultTargetPlatform == p;

  static bool get iOS => _is(TargetPlatform.iOS);
  static bool get android => _is(TargetPlatform.android);
  static bool get macOS => _is(TargetPlatform.macOS);
  static bool get windows => _is(TargetPlatform.windows);
  static bool get linux => _is(TargetPlatform.linux);

  /// A native phone or tablet app.
  static bool get mobile => iOS || android;

  /// A native desktop app.
  static bool get desktop => macOS || windows || linux;

  /// Apple's own apps are at hand (Maps for addresses).
  static bool get apple => !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS);

  /// The operating system schedules local notifications for Den.
  static bool get schedulesNotifications => iOS || android || macOS || windows;

  /// Den can wake up in the background to refresh reminders and calendars.
  static bool get backgroundRefresh => mobile;

  /// The phone's own calendars can be read and written.
  static bool get phoneCalendars => mobile;

  /// The camera can scan a QR code.
  static bool get scanQr => mobile;

  /// A photo can be taken from inside Add.
  static bool get snapPhotos => mobile;

  /// Speech can be turned into text on the device.
  static bool get speech => mobile || macOS;

  /// Text can be read from images and PDFs on the device.
  static bool get readsPagesOnDevice => !kIsWeb;

  /// The device may have its own language model (Apple Intelligence, Gemini Nano).
  static bool get deviceModel => !kIsWeb && !windows && !linux;

  /// The device can run the family's hub itself.
  static bool get runsHub => android || windows || macOS || linux;

  /// A download can be saved straight to a folder.
  static bool get savesToFolder => desktop;
}
