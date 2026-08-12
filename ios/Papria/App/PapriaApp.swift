import SwiftUI

@main
struct PapriaApp: App {
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task {
                    await environment.reloadLocalLibrary()
                    if environment.isAuthenticated { await environment.refreshRemoteLibrary() }
                }
            case .background:
                Task { await environment.flushForBackground() }
            default:
                break
            }
        }
    }
}
