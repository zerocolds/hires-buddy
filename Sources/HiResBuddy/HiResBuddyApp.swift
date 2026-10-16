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
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // kill / Ctrl-C take the same way out as «Выход»: never leave the output stuck on HiRes Buddy.
        signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [controller] in MainActor.assumeIsolated { controller.quit() } }
            source.resume()
            return source
        }
        Task { await controller.refreshHeadphones() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasActiveSession else { return .terminateNow }
        controller.quit { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
