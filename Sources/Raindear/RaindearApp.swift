import AppKit
import SwiftUI

@main
struct RaindearApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = RainPlayer()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(player)
        } label: {
            Image(systemName: player.isPlaying ? "drop.fill" : "drop")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement, but `swift run` has no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }
}
