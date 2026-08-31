import UIKit
import receive_sharing_intent

/// Share-sheet entry: hand the shared image to the main app (via the app
/// group container) and open it straight into the recognition flow.
class ShareViewController: RSIShareViewController {
  // no compose UI — redirect to the app immediately
  override func shouldAutoRedirect() -> Bool {
    return true
  }

  override func saveAndRedirect(message: String? = nil) {
    // The plugin's redirect uses a responder-chain UIApplication.open hack
    // that newer iOS builds block inside share extensions. Bracket its
    // save with the official extension-context open: once before (the
    // context is certainly alive; the synchronous app-group save in super
    // lands ahead of any app-side read) and once after (in case the first
    // is refused while the request is still in flight).
    let url = URL(string: "ShareMedia-com.seechess.seechess:share")!
    extensionContext?.open(url, completionHandler: nil)
    super.saveAndRedirect(message: message)
    extensionContext?.open(url, completionHandler: nil)
  }
}
