import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var capture: CaptureChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    capture = CaptureChannel.register(with: flutterViewController.engine.binaryMessenger)
    HubService.shared.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// While this Mac is the family's hub, closing the window sends it to the Dock instead, so Den
  /// (and the hub inside it) keeps running. Quitting from the menu still quits.
  override func close() {
    if HubService.shared.running {
      miniaturize(nil)
      return
    }
    super.close()
  }
}

/// Answers `den/hub_service` (lib/net/hub_keep_alive.dart): `start` keeps Den running and the
/// Mac awake while it is the family's hub, `stop` lets both go back to normal.
final class HubService {
  static let shared = HubService()

  private(set) var running = false
  private var activity: NSObjectProtocol?
  private var channel: FlutterMethodChannel?

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "den/hub_service", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        self?.start()
        result(nil)
      case "update":
        result(nil)
      case "stop":
        self?.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private func start() {
    running = true
    if activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled],
        reason: "Den is keeping the family online")
    }
  }

  private func stop() {
    running = false
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
    }
    activity = nil
  }
}
