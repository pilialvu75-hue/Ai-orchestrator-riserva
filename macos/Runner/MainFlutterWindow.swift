import Cocoa
import FlutterMacOS
import CoreGraphics

/// Native, consent-gated Computer Use observation bridge.
/// Only Screen Recording status, explicit user request and PNG capture.
/// No desktop input, shell or remotely supplied application commands.
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "com.aiorchestrator/computer_use_mac",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getStatus":
        result([
          "supported": true,
          "authorized": CGPreflightScreenCaptureAccess()
        ])
      case "requestScreenRecording":
        // Only invoked from Flutter after a trusted user gesture.
        // macOS may require restarting the app after granting permission.
        result(CGRequestScreenCaptureAccess())
      case "captureScreenshot":
        guard CGPreflightScreenCaptureAccess() else {
          result(FlutterError(
            code: "SCREEN_CONSENT_REQUIRED",
            message: "Grant Screen Recording permission in macOS Settings.",
            details: nil
          ))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          guard let frame = CGDisplayCreateImage(CGMainDisplayID()),
                let png = NSBitmapImageRep(cgImage: frame).representation(
                  using: .png, properties: [:]
                ) else {
            DispatchQueue.main.async {
              result(FlutterError(
                code: "SCREEN_CAPTURE_FAILED",
                message: "macOS did not provide a display frame.",
                details: nil
              ))
            }
            return
          }
          DispatchQueue.main.async {
            result(FlutterStandardTypedData(bytes: png))
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
