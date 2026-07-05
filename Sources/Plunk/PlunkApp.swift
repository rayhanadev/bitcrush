import AppKit
import SwiftUI

@main
struct PlunkApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      ContentView()
        .environmentObject(model)
    } label: {
      // dynamic glyph reflecting live state (idle / pulling / playing / out-of-sync)
      Image(systemName: model.menuBarSymbol)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
        .environmentObject(model)
    }
  }
}

/// plunk lives in the menu bar — run as an accessory (no Dock icon, no main menu).
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    configureImageCache()
    #if DEBUG
    if ProcessInfo.processInfo.environment["BITCRUSH_SHOT"] != nil {
      DeckShot.run()  // renders deck PNGs to /tmp and exits
    }
    if ProcessInfo.processInfo.environment["BITCRUSH_BPM"] != nil {
      DeckShot.probeBPM()  // analyzes cached tracks' BPM and exits
    }
    if ProcessInfo.processInfo.environment["BITCRUSH_VOCAL"] != nil {
      DeckShot.probeVocal()  // analyzes cached tracks' vocal register and exits
    }
    if ProcessInfo.processInfo.environment["BITCRUSH_FLIP"] != nil {
      DeckShot.probeFlip()  // renders vocal-flip A/B variants to /tmp and exits
    }
    if ProcessInfo.processInfo.environment["BITCRUSH_AUTOMIX"] != nil {
      DeckShot.probeAutomix()  // smoke-tests a dual-deck transition and exits
    }
    if ProcessInfo.processInfo.environment["BITCRUSH_DISCORD"] != nil {
      DeckShot.probeDiscord()  // exercises the Discord presence path and exits
    }
    #endif
    NSApp.setActivationPolicy(.accessory)
  }

  /// Persist fetched cover art / thumbnails to disk across launches (AsyncImage and
  /// URLSession both honor URLCache.shared) so they're not re-downloaded every time.
  private func configureImageCache() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let dir = caches?.appendingPathComponent("bitcrush/httpcache", isDirectory: true)
    URLCache.shared = URLCache(
      memoryCapacity: 32 << 20, diskCapacity: 256 << 20, directory: dir)
  }
}
