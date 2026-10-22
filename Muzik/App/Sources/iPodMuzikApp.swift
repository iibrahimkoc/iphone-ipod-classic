import SwiftUI

@main
struct iPodMuzikApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 460, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
