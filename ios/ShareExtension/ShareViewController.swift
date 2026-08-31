import UIKit
import UniformTypeIdentifiers

/// Self-contained share extension: saves the shared image into the app
/// group using receive_sharing_intent's storage schema (the app side of
/// that plugin picks it up), then opens Seechess. Written defensively —
/// any failure shows its reason instead of a silent black flash.
class ShareViewController: UIViewController {
  private let appGroupId = "group.com.seechess.seechess"
  private let hostURL = URL(string: "ShareMedia-com.seechess.seechess:share")!
  private var finished = false

  /// Mirrors the plugin's SharedMediaFile JSON (key "ShareKey").
  private struct SharedFile: Codable {
    var path: String
    var mimeType: String?
    var thumbnail: String?
    var duration: Double?
    var message: String?
    var type: String
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !finished else { return }
    processAttachment()
  }

  private func processAttachment() {
    let providers =
      (extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? [])
      .flatMap { $0.attachments ?? [] }
    guard
      let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
      })
    else {
      fail("No image found in the shared content.")
      return
    }
    provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
      [weak self] data, error in
      DispatchQueue.main.async {
        guard let self, !self.finished else { return }
        if let error {
          self.fail("Couldn't load the image: \(error.localizedDescription)")
          return
        }
        do {
          try self.save(data)
        } catch {
          self.fail(error.localizedDescription)
          return
        }
        self.openHostAppThenFinish()
      }
    }
  }

  private func save(_ data: Any?) throws {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId)
    else {
      throw err("App group \(appGroupId) is unavailable — provisioning issue.")
    }
    var ext = "png"
    var mime = "image/png"
    let dest: URL
    if let url = data as? URL {
      let e = url.pathExtension.lowercased()
      if !e.isEmpty { ext = e }
      mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic",
              "webp": "image/webp"][ext] ?? "image/png"
      dest = container.appendingPathComponent("SharedImage.\(ext)")
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.copyItem(at: url, to: dest)
    } else if let image = data as? UIImage {
      guard let png = image.pngData() else { throw err("PNG encode failed.") }
      dest = container.appendingPathComponent("SharedImage.png")
      try? FileManager.default.removeItem(at: dest)
      try png.write(to: dest)
    } else if let raw = data as? Data {
      dest = container.appendingPathComponent("SharedImage.png")
      try? FileManager.default.removeItem(at: dest)
      try raw.write(to: dest)
    } else {
      throw err("Unsupported shared item type.")
    }
    guard let defaults = UserDefaults(suiteName: appGroupId) else {
      throw err("App group defaults unavailable.")
    }
    let file = SharedFile(
      path: dest.absoluteString.removingPercentEncoding ?? dest.absoluteString,
      mimeType: mime, thumbnail: nil, duration: nil, message: nil,
      type: "image")
    defaults.set(try JSONEncoder().encode([file]), forKey: "ShareKey")
    defaults.removeObject(forKey: "ShareMessageKey")
  }

  private func openHostAppThenFinish() {
    finished = true
    // legacy responder-chain first — harmless when blocked
    var responder: UIResponder? = self
    let sel = sel_registerName("openURL:")
    while let r = responder {
      if let app = r as? UIApplication {
        app.open(hostURL, options: [:], completionHandler: nil)
        break
      }
      if r.responds(to: sel) {
        _ = r.perform(sel, with: hostURL)
        break
      }
      responder = r.next
    }
    // official path; complete only AFTER the open resolves (completing
    // first tears the extension down and cancels the launch)
    guard let ctx = extensionContext else { return }
    ctx.open(hostURL) { _ in
      DispatchQueue.main.async {
        ctx.completeRequest(returningItems: [], completionHandler: nil)
      }
    }
    // safety net: never hang the share sheet
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
      ctx.completeRequest(returningItems: [], completionHandler: nil)
    }
  }

  private func fail(_ message: String) {
    finished = true
    let alert = UIAlertController(
      title: "Seechess", message: message, preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: "OK", style: .default) { [weak self] _ in
        self?.extensionContext?.cancelRequest(
          withError: self?.err(message) ?? NSError())
      })
    present(alert, animated: true)
  }

  private func err(_ m: String) -> NSError {
    NSError(
      domain: "com.seechess.share", code: 1,
      userInfo: [NSLocalizedDescriptionKey: m])
  }
}
