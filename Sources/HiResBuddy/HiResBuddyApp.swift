import AppKit
import HiResBuddyCore
import SwiftUI

@main
struct HiResBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("HiRes Buddy", systemImage: "headphones") {
            PanelView(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the controller and keeps the process alive until the headphones are back with macOS on any quit path
/// (the panel's «Выход», logout, `osascript -e 'quit app "HiRes Buddy"'`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SessionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await controller.refreshHeadphones() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasActiveSession else { return .terminateNow }
        controller.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
