import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    configureBundledLlamaRuntime()
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func configureBundledLlamaRuntime() {
    let environment = ProcessInfo.processInfo.environment
    if let configured = environment["LLAMA_CPP_EXECUTABLE"], !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return
    }

    guard let executableURL = Bundle.main.executableURL else {
      return
    }

    let helperURL = executableURL
      .deletingLastPathComponent()
      .appendingPathComponent("llama-cli", isDirectory: false)

    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      return
    }

    setenv("LLAMA_CPP_EXECUTABLE", helperURL.path, 0)
  }
}
