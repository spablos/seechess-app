import receive_sharing_intent

/// Share-sheet entry: hand the shared image to the main app (via the app
/// group container) and open it straight into the recognition flow.
class ShareViewController: RSIShareViewController {
  // no compose UI — redirect to the app immediately
  override func shouldAutoRedirect() -> Bool {
    return true
  }
}
