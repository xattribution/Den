import UIKit

/// Den in the share sheet. Keeps what was shared (text, a link, photos, PDFs) in the app
/// group's Inbox for Den to read the next time it's open, says so, and gets out of the way.
/// Reading happens in Den, with the readers the family chose.
final class ShareViewController: UIViewController {
  private static let appGroup = "group.family.den.denApp"
  private let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.082, green: 0.071, blue: 0.059, alpha: 1)
        : UIColor(red: 0.984, green: 0.980, blue: 0.969, alpha: 1)
    }
    label.text = "Saving for Den"
    label.font = .preferredFont(forTextStyle: .headline)
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
    ])
    collect { [weak self] share in
      guard let self = self else { return }
      let saved = share.isEmpty ? false : Self.save(share)
      self.label.text = saved ? "Saved. Open Den to add it." : "Den couldn't keep that."
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        self.extensionContext?.completeRequest(returningItems: nil)
      }
    }
  }

  private struct Share {
    var text: [String] = []
    var subject: String?
    var files: [(Data, String, String)] = []
    var isEmpty: Bool { text.isEmpty && files.isEmpty }
  }

  private func collect(_ done: @escaping (Share) -> Void) {
    var share = Share()
    let group = DispatchGroup()
    let lock = NSLock()
    func add(_ change: (inout Share) -> Void) {
      lock.lock()
      change(&share)
      lock.unlock()
    }
    for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
      if let title = item.attributedTitle?.string, !title.isEmpty { share.subject = title }
      if let body = item.attributedContentText?.string, !body.isEmpty { share.text.append(body) }
      for provider in item.attachments ?? [] {
        let name = provider.suggestedName
        if provider.hasItemConformingToTypeIdentifier("com.adobe.pdf") {
          group.enter()
          provider.loadItem(forTypeIdentifier: "com.adobe.pdf", options: nil) { item, _ in
            if let data = Self.data(item) { add { $0.files.append((data, "application/pdf", (name ?? "Shared") + ".pdf")) } }
            group.leave()
          }
        } else if provider.hasItemConformingToTypeIdentifier("public.image") {
          group.enter()
          provider.loadItem(forTypeIdentifier: "public.image", options: nil) { item, _ in
            var data = Self.data(item)
            if data == nil, let image = item as? UIImage { data = image.jpegData(compressionQuality: 0.85) }
            if let data = data {
              let type = Self.imageType(data)
              add { $0.files.append((data, type, (name ?? "Photo") + (type == "image/png" ? ".png" : ".jpg"))) }
            }
            group.leave()
          }
        } else if provider.hasItemConformingToTypeIdentifier("public.url") {
          group.enter()
          provider.loadItem(forTypeIdentifier: "public.url", options: nil) { item, _ in
            if let url = item as? URL, !url.isFileURL { add { $0.text.append(url.absoluteString) } }
            group.leave()
          }
        } else if provider.hasItemConformingToTypeIdentifier("public.plain-text") {
          group.enter()
          provider.loadItem(forTypeIdentifier: "public.plain-text", options: nil) { item, _ in
            if let text = item as? String { add { $0.text.append(text) } }
            group.leave()
          }
        }
      }
    }
    group.notify(queue: .main) { done(share) }
  }

  private static func data(_ item: NSSecureCoding?) -> Data? {
    if let url = item as? URL { return try? Data(contentsOf: url) }
    return item as? Data
  }

  private static func imageType(_ data: Data) -> String {
    let head = [UInt8](data.prefix(12))
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if head.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
    if head.count >= 12, String(bytes: head[4..<12], encoding: .ascii)?.hasPrefix("ftyphei") == true { return "image/heic" }
    return "image/jpeg"
  }

  /// Writes the files, then the manifest last, so Den never reads half a share.
  private static func save(_ share: Share) -> Bool {
    guard let inbox = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
      .appendingPathComponent("Inbox", isDirectory: true)
    else { return false }
    let stamp = String(format: "%.0f", Date().timeIntervalSince1970 * 1000)
    let folder = inbox.appendingPathComponent("\(stamp)-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      var files: [[String: String]] = []
      for (i, (data, type, name)) in share.files.prefix(10).enumerated() {
        let file = "f\(i)"
        try data.write(to: folder.appendingPathComponent(file))
        files.append(["file": file, "mimeType": type, "name": name])
      }
      var manifest: [String: Any] = ["files": files]
      if !share.text.isEmpty { manifest["text"] = share.text.joined(separator: "\n\n") }
      if let subject = share.subject { manifest["subject"] = subject }
      let json = try JSONSerialization.data(withJSONObject: manifest)
      try json.write(to: folder.appendingPathComponent("share.json"), options: .atomic)
      return true
    } catch {
      try? FileManager.default.removeItem(at: folder)
      return false
    }
  }
}
