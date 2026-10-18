import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Reminders show even while Den is open, and a tap reaches flutter_local_notifications.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    GeneratedPluginRegistrant.register(with: self)
    // The background refresh (lib/background/background_refresh.dart): its engine gets the same
    // plugins, and iOS is asked to run it about hourly.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "family.den.refresh",
      earliestBeginInSeconds: NSNumber(value: 60 * 60)
    )
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
