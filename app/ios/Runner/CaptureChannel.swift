import Foundation
import ImageIO
import PDFKit
import Vision
#if os(iOS)
import Flutter
import UIKit
#else
import AppKit
import FlutterMacOS
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Den's capture channel on Apple platforms: the on-device model through Foundation Models,
/// Vision text recognition, PDFKit, JPEG conversion, and what the share extension saved.
/// Nothing here sends anything off the device.
final class CaptureChannel: NSObject, FlutterStreamHandler {
  static let appGroup = "group.family.den.denApp"
  private var sink: FlutterEventSink?

  static func register(with messenger: FlutterBinaryMessenger) -> CaptureChannel {
    let channel = CaptureChannel()
    FlutterMethodChannel(name: "family.den/capture", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in channel.handle(call, result: result) }
    FlutterEventChannel(name: "family.den/capture/shares", binaryMessenger: messenger).setStreamHandler(channel)
    return channel
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  /// Tells Den when the share extension left something while it was away.
  func sharesMayHaveArrived() {
    if !Inbox.waiting.isEmpty { sink?(nil) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "abilities":
      result(Self.abilities())
    case "prepareModel":
      result(nil)
    case "generate":
      guard let instructions = args["instructions"] as? String,
        let prompt = args["prompt"] as? String,
        let schema = args["schema"] as? String
      else {
        result(FlutterError(code: "args", message: "Den asked the model without a prompt.", details: nil))
        return
      }
      Self.generate(instructions: instructions, prompt: prompt, schema: schema, result: result)
    case "findText":
      guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
        result(nil)
        return
      }
      let type = args["mimeType"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        let text = type == "application/pdf" ? Self.pdfText(data) : Self.imageText(data)
        DispatchQueue.main.async { result(text) }
      }
    case "toJpeg":
      guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data else {
        result(nil)
        return
      }
      let side = args["maxSide"] as? Int ?? 2000
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = Self.jpeg(data, maxSide: side)
        DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    case "takeShares":
      result(Inbox.take())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: The on-device model

  static func abilities() -> [String: Any] {
    var state = "unavailable"
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: state = "available"
      case .unavailable(.modelNotReady): state = "downloading"
      default: state = "unavailable"
      }
    }
    #endif
    return [
      "model": state == "unavailable" ? NSNull() as Any : "apple" as Any,
      "modelName": "Apple Intelligence",
      "modelState": state,
      "text": true,
      "pdf": true,
    ]
  }

  static func generate(instructions: String, prompt: String, schema: String, result: @escaping FlutterResult) {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *) {
      Task {
        do {
          guard let json = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
          }
          let generationSchema = try GenerationSchema(root: SchemaBuilder.dynamic(json, name: "Capture"), dependencies: [])
          let rules = instructions
          let question = prompt
          let session = LanguageModelSession { rules }
          let response = try await session.respond(
            schema: generationSchema,
            includeSchemaInPrompt: true,
            options: GenerationOptions()
          ) { question }
          let text = response.content.jsonString
          await MainActor.run { result(text) }
        } catch {
          await MainActor.run {
            result(FlutterError(code: "generate", message: "Apple Intelligence couldn't read that.", details: "\(error)"))
          }
        }
      }
      return
    }
    #endif
    result(nil)
  }

  // MARK: Text in photos and PDFs

  static func imageText(_ data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let raw = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
    return recognize(VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]))
  }

  static func pdfText(_ data: Data) -> String? {
    guard let document = PDFDocument(data: data) else { return nil }
    if let text = document.string, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 { return text }
    // A scanned PDF has no text layer: read its first pages as pictures.
    var pages: [String] = []
    for i in 0..<min(document.pageCount, 5) {
      guard let page = document.page(at: i) else { continue }
      let bounds = page.bounds(for: .mediaBox)
      let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
      #if os(iOS)
      let cg = thumbnail.cgImage
      #else
      let cg = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #endif
      guard let image = cg, let text = recognize(VNImageRequestHandler(cgImage: image, options: [:])) else { continue }
      pages.append(text)
    }
    return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
  }

  /// Lines top to bottom, with a blank line where the picture leaves a gap, so a flyer's
  /// sections stay apart.
  static func recognize(_ handler: VNImageRequestHandler) -> String? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    do { try handler.perform([request]) } catch { return nil }
    let found = (request.results ?? []).compactMap { o -> (CGRect, String)? in
      guard let best = o.topCandidates(1).first else { return nil }
      return (o.boundingBox, best.string)
    }
    if found.isEmpty { return nil }
    let sorted = found.sorted { a, b in
      abs(a.0.midY - b.0.midY) < min(a.0.height, b.0.height) / 2 ? a.0.minX < b.0.minX : a.0.midY > b.0.midY
    }
    let heights = sorted.map { $0.0.height }.sorted()
    let typical = heights[heights.count / 2]
    var lines: [String] = []
    var current = ""
    var last: CGRect?
    for (box, text) in sorted {
      if let prev = last {
        if abs(prev.midY - box.midY) < min(prev.height, box.height) / 2 {
          current += " " + text
          last = prev.union(box)
          continue
        }
        lines.append(current)
        if prev.minY - box.maxY > typical * 1.2 { lines.append("") }
      }
      current = text
      last = box
    }
    lines.append(current)
    return lines.joined(separator: "\n")
  }

  /// A JPEG no larger than [maxSide] on its long side, turned upright.
  static func jpeg(_ data: Data, maxSide: Int) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSide,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? out as Data : nil
  }
}

#if canImport(FoundationModels)
/// Turns the JSON schema den_capture gives every reader into a Foundation Models schema:
/// objects keep the order their required list gives, a property that may be null is optional,
/// and string enums become choices.
@available(iOS 26.0, macOS 26.0, *)
enum SchemaBuilder {
  static func dynamic(_ json: [String: Any], name: String) -> DynamicGenerationSchema {
    if let options = json["anyOf"] as? [[String: Any]] {
      let value = options.first { ($0["type"] as? String) != "null" } ?? [:]
      return dynamic(value, name: name)
    }
    let description = json["description"] as? String
    switch json["type"] as? String {
    case "object":
      let properties = json["properties"] as? [String: Any] ?? [:]
      let order = (json["required"] as? [String] ?? []) + properties.keys.sorted()
      var seen = Set<String>()
      let fields: [DynamicGenerationSchema.Property] = order.compactMap { key in
        guard seen.insert(key).inserted, let schema = properties[key] as? [String: Any] else { return nil }
        let nullable = (schema["anyOf"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "null" } ?? false
        return DynamicGenerationSchema.Property(
          name: key,
          description: schema["description"] as? String,
          schema: dynamic(schema, name: "\(name)_\(key)"),
          isOptional: nullable
        )
      }
      return DynamicGenerationSchema(name: name, description: description, properties: fields)
    case "array":
      return DynamicGenerationSchema(
        arrayOf: dynamic(json["items"] as? [String: Any] ?? [:], name: "\(name)_item"),
        minimumElements: nil,
        maximumElements: nil
      )
    case "string":
      if let choices = json["enum"] as? [String] {
        return DynamicGenerationSchema(name: name, description: description, anyOf: choices)
      }
      return DynamicGenerationSchema(type: String.self, guides: [])
    case "integer":
      return DynamicGenerationSchema(type: Int.self, guides: [])
    case "number":
      return DynamicGenerationSchema(type: Double.self, guides: [])
    case "boolean":
      return DynamicGenerationSchema(type: Bool.self, guides: [])
    default:
      return DynamicGenerationSchema(type: String.self, guides: [])
    }
  }
}
#endif

/// What the share extension saved in the app group's Inbox: a folder per share with a
/// `share.json` (text, subject, files) and the files themselves. Handed to Den once.
enum Inbox {
  static var folder: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: CaptureChannel.appGroup)?
      .appendingPathComponent("Inbox", isDirectory: true)
  }

  static var waiting: [URL] {
    guard let folder = folder,
      let entries = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
    else { return [] }
    return entries.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  static func take() -> [[String: Any]] {
    var out: [[String: Any]] = []
    for share in waiting {
      let manifest = share.appendingPathComponent("share.json")
      guard let data = try? Data(contentsOf: manifest),
        let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        // Still being written by the extension, or abandoned long ago.
        let created = (try? share.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        if Date().timeIntervalSince(created) > 600 { try? FileManager.default.removeItem(at: share) }
        continue
      }
      var files: [[String: Any]] = []
      for f in m["files"] as? [[String: Any]] ?? [] {
        guard let file = f["file"] as? String, let bytes = try? Data(contentsOf: share.appendingPathComponent(file)) else {
          continue
        }
        files.append([
          "bytes": FlutterStandardTypedData(bytes: bytes),
          "mimeType": f["mimeType"] ?? NSNull(),
          "name": f["name"] ?? NSNull(),
        ])
      }
      out.append(["text": m["text"] ?? NSNull(), "subject": m["subject"] ?? NSNull(), "files": files])
      try? FileManager.default.removeItem(at: share)
    }
    return out
  }
}
