import SwiftUI

@main
struct iPodMuzikApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var phone = Phone()

    var body: some Scene {
        Window("iPod Müzik", id: "main") {
            ContentView()
                .environmentObject(phone)
                .frame(minWidth: 460, minHeight: 520)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            RemoteView()
                .environmentObject(phone)
        } label: {
            Image(systemName: "ipod")
        }
        .menuBarExtraStyle(.window)
    }
}

/// A menu bar app (LSUIElement: no Dock icon). Started at login (see LoginItem) it gets "--gizli"
/// and closes its window, leaving just the menu bar remote. Switching the activation policy at
/// runtime instead left the menu bar item unclickable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains("--gizli") else { return }
        DispatchQueue.main.async {
            NSApp.windows.filter { $0.identifier?.rawValue.contains("main") == true }.forEach { $0.close() }
        }
    }

    /// Closing the window keeps the menu bar remote running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
