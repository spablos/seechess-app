import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Offline-match Wi-Fi automation. iOS can only JOIN a hotspot named in
    // a scanned QR (NEHotspotConfiguration); it cannot start one — the
    // Dart side knows and never asks.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "seechess.hotspot")
    else { return }
    let channel = FlutterMethodChannel(
      name: "seechess/hotspot", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "guestJoin":
        guard let args = call.arguments as? [String: Any],
          let ssid = args["ssid"] as? String,
          let pass = args["pass"] as? String
        else {
          result(false)
          return
        }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = true  // dropped when the app goes away
        NEHotspotConfigurationManager.shared.apply(config) { error in
          if let error = error as NSError?,
            error.code != NEHotspotConfigurationError.alreadyAssociated.rawValue
          {
            result(false)
          } else {
            result(true)
          }
        }
      case "guestLeave":
        // join-once configurations need no explicit removal
        result(nil)
      case "hostStart", "hostStop":
        result(FlutterError(code: "unsupported", message: "iOS has no hotspot API", details: nil))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
