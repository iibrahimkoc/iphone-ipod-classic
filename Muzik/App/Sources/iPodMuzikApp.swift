import SwiftUI

@main
struct iPodMuzikApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    /// Both windows are managed by the AppDelegate, so the app has no scenes of its own.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// A menu bar app (LSUIElement: no Dock icon). The remote lives in an NSStatusItem popover
/// (SwiftUI's MenuBarExtra didn't respond to clicks in this setup), and the drag-and-drop
/// window is a plain NSWindow so it can be reopened after being closed. Started at login (see
/// LoginItem) the app gets "--gizli" and doesn't show the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let phone = Phone()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ContentView().environmentObject(Self.phone).frame(minWidth: 460, minHeight: 520)))
        window.title = "iPod Müzik"
        window.setContentSize(NSSize(width: 480, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RemoteView(openMain: openMain).environmentObject(Self.phone))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "ipod", accessibilityDescription: "iPod")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        if !CommandLine.arguments.contains("--gizli") { openMain() }
    }

    /// Closing the window keeps the menu bar remote running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Shows the drag-and-drop window (it is only hidden when closed).
    private func openMain() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opening the app again (e.g. from Finder) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain()
        return false
    }
}

/// "Mac açılınca başlat": a LaunchAgent that opens the app hidden at login.
enum LoginItem {
    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.ibrahimkoc.ipodmuzik.plist")
    }

    static var enabled: Bool {
        get { FileManager.default.fileExists(atPath: plist.path) }
        set {
            if newValue {
                let agent: [String: Any] = [
                    "Label": "com.ibrahimkoc.ipodmuzik",
                    "ProgramArguments": ["/usr/bin/open", "-g", "-j", Bundle.main.bundlePath, "--args", "--gizli"],
                    "RunAtLoad": true,
                ]
                try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                (agent as NSDictionary).write(to: plist, atomically: true)
            } else {
                try? FileManager.default.removeItem(at: plist)
            }
        }
    }
}
