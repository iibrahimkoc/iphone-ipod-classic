import SwiftUI

@main
struct iPodMuzikApp: App {
    @StateObject private var phone = Phone()

    var body: some Scene {
        WindowGroup {
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
