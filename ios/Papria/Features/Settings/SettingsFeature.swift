import Foundation
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("papria.onlyWiFiDownloads") private var onlyWiFiDownloads = false
    @State private var conflicts: [SyncConflict] = []
    @State private var authenticationRequest: AuthenticationRequest?
    @State private var pendingResolution: PendingResolution?
    @State private var deferredConflictIDs: Set<String> = []
    @State private var resolutionMessage: String?
    @State private var showingDisconnectConfirmation = false
    /// This is an in-memory recovery point for the immediate alert action.
    /// It is deliberately not presented as persisted sync metadata.
    @State private var recoveryPoint: PendingResolution?

    var body: some View {
        NavigationView {
            List {
                if !environment.isNetworkAvailable {
                    Section {
                        OfflineBanner()
                            .listRowInsets(EdgeInsets(top: PapriaDesign.space2, leading: PapriaDesign.space4, bottom: PapriaDesign.space2, trailing: PapriaDesign.space4))
                            .listRowBackground(PapriaDesign.canvas)
                            .listRowSeparator(.hidden)
                    }
                }

                serverSection
                displaySection
                downloadsSection
                syncSection
                aboutSection
            }
            .listStyle(.plain)
            .listRowSeparatorTint(PapriaDesign.lineSubtle)
            .listSectionSeparatorTint(PapriaDesign.lineSubtle)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .tint(PapriaDesign.accent)
            .background(PapriaDesign.canvas.ignoresSafeArea())
            .task { await reloadConflicts() }
            .refreshable { await reloadConflicts() }
            .sheet(item: $authenticationRequest) { request in
                AuthenticationView(
                    serverURL: request.serverURL,
                    username: request.username,
                    certificateSha256: request.certificateSha256,
                    title: request.title,
                    buttonTitle: request.buttonTitle
                )
                .environmentObject(environment)
            }
            .confirmationDialog(
                "断开 BookOrbit？",
                isPresented: $showingDisconnectConfirmation,
                titleVisibility: .visible
            ) {
                Button("断开并保留离线缓存") {
                    Task { await environment.disconnect(keepOfflineCache: true) }
                }
                Button("断开并清除远程缓存", role: .destructive) {
                    Task { await environment.disconnect(keepOfflineCache: false) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("选择是否保留 BookOrbit 的离线书目和文件信息。已下载到本机的书籍始终保留。")
            }
            .confirmationDialog(
                pendingResolution?.title ?? "确认同步进度",
                isPresented: Binding(
                    get: { pendingResolution != nil },
                    set: { if !$0 { pendingResolution = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let resolution = pendingResolution {
                    Button(resolution.title, role: resolution.keepLocal ? nil : .destructive) {
                        resolve(resolution)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pendingResolution?.message ?? "")
            }
            .alert("同步进度已处理", isPresented: Binding(
                get: { resolutionMessage != nil },
                set: { if !$0 { resolutionMessage = nil } }
            )) {
                if recoveryPoint != nil {
                    Button("撤销") { undoLastResolution() }
                }
                Button("知道了", role: .cancel) {}
            } message: {
                Text(resolutionMessage ?? "")
            }
        }
    }

    private var serverSection: some View {
        Section {
            if environment.isAuthenticated {
                SettingsValueRow("服务器") {
                    Text(environment.serverURL)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaDesign.inkSecondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                SettingsValueRow("账号") {
                    Text(environment.username)
                        .foregroundStyle(PapriaDesign.inkSecondary)
                        .lineLimit(1)
                }
                authenticatedServerStatus
                Button("编辑服务器") {
                    authenticationRequest = AuthenticationRequest(
                        serverURL: environment.serverURL,
                        username: environment.username,
                        certificateSha256: environment.serverCertificateSha256,
                        title: "编辑 BookOrbit 服务器",
                        buttonTitle: "保存并重新登录"
                    )
                }
                Button("重新登录") {
                    authenticationRequest = AuthenticationRequest(
                        serverURL: environment.serverURL,
                        username: environment.username,
                        certificateSha256: environment.serverCertificateSha256,
                        title: "重新登录 BookOrbit",
                        buttonTitle: "重新登录"
                    )
                }
                Button("断开连接", role: .destructive) {
                    showingDisconnectConfirmation = true
                }
                .accessibilityHint("断开当前 BookOrbit 服务器连接；会先确认是否保留离线缓存")
            } else {
                SettingsValueRow("服务器") {
                    Text(environment.serverURL.isEmpty ? "未配置" : environment.serverURL)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaDesign.inkSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                unauthenticatedServerStatus
                if environment.serverURL.isEmpty {
                    Button("连接 BookOrbit") {
                        authenticationRequest = AuthenticationRequest(
                            serverURL: "",
                            username: "",
                            certificateSha256: nil,
                            title: "连接 BookOrbit",
                            buttonTitle: "连接并登录"
                        )
                    }
                        .accessibilityHint("配置并连接 BookOrbit 服务器")
                } else {
                    Button("重新登录") {
                        authenticationRequest = AuthenticationRequest(
                            serverURL: environment.serverURL,
                            username: environment.username,
                            certificateSha256: environment.serverCertificateSha256,
                            title: "重新登录 BookOrbit",
                            buttonTitle: "重新登录"
                        )
                    }
                    .accessibilityHint("使用已保存的服务器和账号重新登录 BookOrbit")
                }
            }
        } header: {
            SettingsSectionHeader("BookOrbit 服务器")
        }
        .listRowBackground(PapriaDesign.canvas)
    }

    private var displaySection: some View {
        Section {
            SettingsValueRow("显示模式") {
                Text("普通屏幕")
                    .foregroundStyle(PapriaDesign.inkSecondary)
            }
            Text("iOS 使用普通屏幕模式，并遵循系统文字大小与安全区。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        } header: {
            SettingsSectionHeader("阅读显示")
        }
        .listRowBackground(PapriaDesign.canvas)
    }

    @ViewBuilder
    private var authenticatedServerStatus: some View {
        if !environment.isNetworkAvailable {
            StatusLabel(
                title: "离线",
                systemImage: "wifi.slash",
                color: PapriaDesign.remote
            )
        } else if environment.isLoadingLibrary {
            StatusLabel(
                title: "正在刷新服务器书目",
                systemImage: "arrow.triangle.2.circlepath",
                color: PapriaDesign.remote
            )
        } else if environment.bookOrbitConnectionError != nil {
            StatusLabel(
                title: "连接失败",
                systemImage: "exclamationmark.circle",
                color: PapriaDesign.error
            )
        } else {
            // This branch is reached only after authentication has been
            // restored or established, the network path is available, and no
            // real BookOrbit request has reported an error.
            StatusLabel(
                title: "已连接",
                systemImage: "checkmark.circle.fill",
                color: PapriaDesign.success
            )
        }
    }

    @ViewBuilder
    private var unauthenticatedServerStatus: some View {
        if !environment.isNetworkAvailable {
            StatusLabel(
                title: "离线",
                systemImage: "wifi.slash",
                color: PapriaDesign.remote
            )
        } else {
            StatusLabel(
                title: "未连接",
                systemImage: "circle",
                color: PapriaDesign.inkSecondary
            )
        }
    }

    private var downloadsSection: some View {
        Section {
            Toggle("仅 Wi-Fi 下载", isOn: $onlyWiFiDownloads)
                .tint(PapriaDesign.accent)
                .accessibilityHint("启用后，新的 BookOrbit 下载会等待 Wi-Fi")
            SettingsValueRow("本地书籍") {
                Text("\(environment.publications.count) 本")
                    .foregroundStyle(PapriaDesign.inkSecondary)
            }
            SettingsValueRow("本地内容占用") {
                Text(localContentSize)
                    .foregroundStyle(PapriaDesign.inkSecondary)
                    .monospacedDigit()
                    .accessibilityLabel("本地内容占用 \(localContentSize)")
            }
            Text("已下载内容保留在设备上；Wi-Fi 传书内容不会上传至 BookOrbit。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        } header: {
            SettingsSectionHeader("下载与存储")
        }
        .listRowBackground(PapriaDesign.canvas)
    }

    private var syncSection: some View {
        Section {
            SettingsValueRow("最后成功同步") {
                Text(lastSuccessfulSyncDescription)
                    .foregroundStyle(PapriaDesign.inkSecondary)
            }
            SettingsValueRow("待处理冲突") {
                Text(conflicts.isEmpty ? "无" : "\(conflicts.count) 项")
                    .foregroundStyle(conflicts.isEmpty ? PapriaDesign.success : PapriaDesign.warning)
                    .monospacedDigit()
            }

            if conflicts.isEmpty {
                Text("没有待处理的本地/服务器进度冲突")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.inkSecondary)
            } else {
                ForEach(conflicts) { conflict in
                    ConflictRow(
                        conflict: conflict,
                        deferred: deferredConflictIDs.contains(conflict.id),
                        keepLocal: { requestResolution(for: conflict, keepLocal: true) },
                        keepServer: { requestResolution(for: conflict, keepLocal: false) },
                        deferResolution: { deferredConflictIDs.insert(conflict.id) }
                    )
                    .listRowInsets(EdgeInsets(top: PapriaDesign.space2, leading: PapriaDesign.space4, bottom: PapriaDesign.space2, trailing: PapriaDesign.space4))
                    .listRowBackground(PapriaDesign.canvas)
                }
            }
        } header: {
            SettingsSectionHeader("同步")
        }
        .listRowBackground(PapriaDesign.canvas)
    }

    private var aboutSection: some View {
        Section {
            SettingsValueRow("BookOrbit") {
                Text("v2.5.0")
                    .foregroundStyle(PapriaDesign.inkSecondary)
            }
            Text("服务器地址、账号和证书指纹保存在本地 SQLite；访问令牌和 refresh cookie 仅保存在 Keychain。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        } header: {
            SettingsSectionHeader("关于")
        }
        .listRowBackground(PapriaDesign.canvas)
    }

    private var localContentSize: String {
        let bytes = environment.publications.reduce(Int64(0)) { total, publication in
            total + max(Int64(0), publication.sizeBytes)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var lastSuccessfulSyncDescription: String {
        // AppEnvironment does not expose a persisted successful-sync record.
        // A cached catalog, connection state, conflict.createdAt, or a
        // progress payload's updatedAt is not equivalent to that record.
        // Keep this value explicit until a real existing source is available;
        // do not infer or introduce a new persistence field here.
        "数据未提供"
    }

    private func reloadConflicts() async {
        conflicts = await environment.pendingProgressConflicts()
        deferredConflictIDs.formIntersection(Set(conflicts.map(\.id)))
    }

    private func requestResolution(for conflict: SyncConflict, keepLocal: Bool) {
        pendingResolution = PendingResolution(conflict: conflict, keepLocal: keepLocal)
    }

    private func resolve(_ resolution: PendingResolution) {
        pendingResolution = nil
        recoveryPoint = nil
        Task {
            await environment.resolveProgressConflict(resolution.conflict, keepLocal: resolution.keepLocal)
            await reloadConflicts()
            if conflicts.contains(where: { $0.id == resolution.conflict.id }) {
                resolutionMessage = "未能处理该冲突，原进度仍保留等待处理。"
            } else {
                recoveryPoint = resolution
                resolutionMessage = resolution.keepLocal
                    ? "已保留本地进度。此设置页面仍打开时可立即撤销。"
                    : "已使用服务器进度。此设置页面仍打开时可立即撤销。"
            }
        }
    }

    private func undoLastResolution() {
        guard let resolution = recoveryPoint else { return }
        recoveryPoint = nil
        Task {
            if resolution.keepLocal {
                // Restoring the stored remote snapshot also removes the forced
                // local outbox item created by the original choice.
                await environment.resolveProgressConflict(resolution.conflict, keepLocal: false)
            } else {
                // The original local snapshot is still present in the conflict
                // payload. Feed it back through the existing server-choice path
                // so no new progress schema or environment API is introduced.
                let restoreLocal = SyncConflict(
                    kind: resolution.conflict.kind,
                    resourceId: resolution.conflict.resourceId,
                    localPayload: resolution.conflict.remotePayload,
                    remotePayload: resolution.conflict.localPayload,
                    createdAt: resolution.conflict.createdAt
                )
                await environment.resolveProgressConflict(restoreLocal, keepLocal: false)
                await environment.resolveProgressConflict(resolution.conflict, keepLocal: true)
            }
            await reloadConflicts()
        }
    }
}

private struct AuthenticationRequest: Identifiable {
    let id = UUID()
    let serverURL: String
    let username: String
    let certificateSha256: String?
    let title: String
    let buttonTitle: String
}

private struct OfflineBanner: View {
    var body: some View {
        Label("离线：仅显示已缓存内容", systemImage: "wifi.slash")
            .font(PapriaDesign.metadata.weight(.medium))
            .foregroundStyle(PapriaDesign.remote)
            .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget, alignment: .leading)
            .padding(.horizontal, PapriaDesign.space3)
            .background(PapriaDesign.raised)
            .overlay(
                RoundedRectangle(cornerRadius: PapriaDesign.controlCornerRadius)
                    .stroke(PapriaDesign.remote, lineWidth: PapriaDesign.ruleWidth)
            )
            .accessibilityLabel("离线：仅显示已缓存内容")
    }
}

private struct SettingsSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(PapriaDesign.sectionTitle)
            .foregroundStyle(PapriaDesign.ink)
            .textCase(nil)
            .padding(.top, PapriaDesign.space3)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(PapriaDesign.metadata.weight(.medium))
            .foregroundStyle(color)
            .accessibilityLabel("服务器状态：\(title)")
    }
}

private struct SettingsValueRow<Content: View>: View {
    @Environment(\.sizeCategory) private var sizeCategory

    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            if sizeCategory.isAccessibilityCategory {
                VStack(alignment: .leading, spacing: PapriaDesign.space1) {
                    rowTitle
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, PapriaDesign.space1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: PapriaDesign.space3) {
                    rowTitle
                    Spacer(minLength: PapriaDesign.space3)
                    content()
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var rowTitle: some View {
        Text(title)
            .font(PapriaDesign.rowBody)
            .foregroundStyle(PapriaDesign.ink)
    }
}

private struct ConflictRow: View {
    @Environment(\.sizeCategory) private var sizeCategory

    let conflict: SyncConflict
    let deferred: Bool
    let keepLocal: () -> Void
    let keepServer: () -> Void
    let deferResolution: () -> Void

    private var title: String {
        conflict.kind == "audio_progress" ? "有声书进度冲突" : "阅读进度冲突"
    }

    private var localSnapshot: ProgressSnapshot {
        ProgressSnapshot(
            payload: conflict.localPayload,
            kind: conflict.kind,
            deviceDescription: localDeviceDescription
        )
    }

    private var serverSnapshot: ProgressSnapshot {
        ProgressSnapshot(
            payload: conflict.remotePayload,
            kind: conflict.kind,
            deviceDescription: "服务器未提供设备名"
        )
    }

    private var localDeviceDescription: String {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "本机未提供设备名" : "本机设备：\(name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space3) {
            HStack(alignment: .firstTextBaseline, spacing: PapriaDesign.space2) {
                Text(title)
                    .font(PapriaDesign.sectionTitle)
                    .foregroundStyle(PapriaDesign.ink)
                Spacer(minLength: PapriaDesign.space2)
                if deferred {
                    Text("稍后处理")
                        .font(PapriaDesign.label)
                        .foregroundStyle(PapriaDesign.warning)
                }
            }

            Text("资源 \(conflict.resourceId) 的本地进度与服务器进度不同。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)

            Text("冲突记录时间：\(ProgressSnapshot.formattedDate(conflict.createdAt) ?? "未提供")")
                .font(PapriaDesign.label)
                .foregroundStyle(PapriaDesign.inkSecondary)

            snapshotComparison
            .padding(.vertical, PapriaDesign.space2)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PapriaDesign.lineSubtle)
                    .frame(height: PapriaDesign.ruleWidth)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PapriaDesign.lineSubtle)
                    .frame(height: PapriaDesign.ruleWidth)
            }

            VStack(spacing: PapriaDesign.space2) {
                Button("保留本地进度", action: keepLocal)
                    .buttonStyle(.borderedProminent)
                    .tint(PapriaDesign.accent)
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("覆盖服务器进度前需要确认")
                Button("使用服务器进度", action: keepServer)
                    .buttonStyle(.bordered)
                    .tint(PapriaDesign.accent)
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("覆盖本地进度前需要确认")
                Button("稍后处理", action: deferResolution)
                    .font(PapriaDesign.metadata.weight(.medium))
                    .foregroundStyle(PapriaDesign.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
            }
        }
        .padding(.vertical, PapriaDesign.space3)
    }

    @ViewBuilder
    private var snapshotComparison: some View {
        if sizeCategory.isAccessibilityCategory {
            VStack(alignment: .leading, spacing: 0) {
                ProgressSnapshotColumn(title: "本地阅读位置", snapshot: localSnapshot)
                Divider().overlay(PapriaDesign.lineSubtle)
                ProgressSnapshotColumn(title: "服务器阅读位置", snapshot: serverSnapshot)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ProgressSnapshotColumn(title: "本地阅读位置", snapshot: localSnapshot)
                Divider().overlay(PapriaDesign.lineSubtle)
                ProgressSnapshotColumn(title: "服务器阅读位置", snapshot: serverSnapshot)
            }
        }
    }
}

private struct ProgressSnapshotColumn: View {
    let title: String
    let snapshot: ProgressSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space1) {
            Text(title)
                .font(PapriaDesign.label)
                .foregroundStyle(PapriaDesign.inkSecondary)
            Text(snapshot.position)
                .font(PapriaDesign.rowBody.weight(.medium))
                .foregroundStyle(PapriaDesign.ink)
                .lineLimit(2)
            Text("更新时间：\(snapshot.updatedAt ?? "数据未提供")")
                .font(PapriaDesign.label)
                .foregroundStyle(PapriaDesign.inkSecondary)
            Text(snapshot.deviceDescription)
                .font(PapriaDesign.label)
                .foregroundStyle(PapriaDesign.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PapriaDesign.space3)
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressSnapshot {
    let position: String
    let updatedAt: String?
    let deviceDescription: String

    init(payload: String, kind: String, deviceDescription: String) {
        self.deviceDescription = deviceDescription
        if kind == "audio_progress", let progress = try? JSONDecoder().decode(AudioProgressPayload.self, from: Data(payload.utf8)) {
            position = "\(Int(progress.percentage.rounded()))% · \(Self.duration(progress.positionSeconds))"
            updatedAt = Self.formattedDate(progress.updatedAt)
            return
        }
        if let progress = try? JSONDecoder().decode(FileProgressPayload.self, from: Data(payload.utf8)) {
            if let pageNumber = progress.pageNumber {
                position = "第 \(pageNumber) 页 · \(Int(progress.percentage.rounded()))%"
            } else {
                position = "\(Int(progress.percentage.rounded()))%"
            }
            updatedAt = Self.formattedDate(progress.updatedAt)
            return
        }
        position = "未提供可读位置"
        updatedAt = nil
    }

    private static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func formattedDate(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct PendingResolution: Identifiable {
    let conflict: SyncConflict
    let keepLocal: Bool

    var id: String { "\(conflict.id):\(keepLocal)" }

    var title: String {
        keepLocal ? "保留本地进度？" : "使用服务器进度？"
    }

    var message: String {
        keepLocal
            ? "将保留本地阅读位置，并在下一次同步时覆盖服务器当前进度。"
            : "将保留服务器阅读位置，并覆盖设备上的当前本地进度。"
    }
}
