import SwiftUI

@main
struct PapriaApp: App {
    @StateObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment()
        // BGTaskScheduler requires registration while the app is launching.
        // Registering from a view task is too late on a fresh simulator
        // process and prevents the root UI from becoming available.
        environment.registerBackgroundSync()
        _environment = StateObject(wrappedValue: environment)
    }

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
