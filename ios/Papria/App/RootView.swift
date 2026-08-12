import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Group {
            if environment.isRestoring {
                ProgressView("正在恢复本地状态")
            } else {
                // Local reading and Wi-Fi import are intentionally available
                // without a BookOrbit session. Remote books remain hidden
                // until the user connects from Settings.
                LibraryView()
            }
        }
        .task {
            environment.registerBackgroundSync()
            await environment.restoreSession()
        }
        .alert("无法继续", isPresented: Binding(
            get: { environment.globalError != nil },
            set: { if !$0 { environment.globalError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(environment.globalError ?? "未知错误")
        }
    }
}
