import CoreImage.CIFilterBuiltins
import NetworkExtension
import SwiftUI
import UIKit

struct TransferView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TransferSessionScreen(transfer: environment.transfer)
    }
}

private struct TransferSessionScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var transfer: LocalTransferReceiver
    @State private var wifiName: String?
    @State private var showingStopConfirmation = false
    @State private var copiedAddress = false
    @State private var showingLibrary = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: PapriaDesign.space5) {
                    if transfer.isRunning {
                        runningContent
                        transferList
                        stopServiceButton
                    } else if transfer.isStarting {
                        startingContent
                    } else {
                        stoppedContent
                    }

                    if !transfer.isRunning, !transfer.transferSessions.isEmpty {
                        transferList
                    }

                    safetyNote
                }
                .padding(.horizontal, PapriaDesign.pageHorizontalInset)
                .padding(.vertical, PapriaDesign.space5)
            }
            .background(PapriaDesign.canvas.ignoresSafeArea())
            .navigationTitle("传书")
            .navigationBarTitleDisplayMode(.large)
            .tint(PapriaDesign.accent)
            .confirmationDialog(
                "停止 Wi-Fi 传书？",
                isPresented: $showingStopConfirmation,
                titleVisibility: .visible
            ) {
                Button("停止服务", role: .destructive) {
                    transfer.stop()
                }
                Button("继续传书", role: .cancel) {}
            } message: {
                Text(transfer.hasActiveTransfer
                    ? "停止服务会中断正在上传的文件；已加入书库的文件不会受影响。"
                    : "停止服务会关闭当前局域网地址；已加入书库的文件不会受影响。")
            }
            .sheet(isPresented: $showingLibrary) {
                TransferLibrarySheet()
                    .environmentObject(environment)
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                refreshWiFiName()
            }
            .onChange(of: transfer.isRunning) { isRunning in
                if isRunning {
                    refreshWiFiName()
                }
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private var stoppedContent: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space4) {
            VStack(alignment: .leading, spacing: PapriaDesign.space2) {
                Text("在同一 Wi-Fi 下传书")
                    .font(PapriaDesign.sectionTitle)
                    .foregroundStyle(PapriaDesign.ink)
                Text("启动后，用电脑或另一台设备打开局域网地址上传文件。文件只会导入本机书库。")
                    .font(PapriaDesign.rowBody)
                    .foregroundStyle(PapriaDesign.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = transferServiceError {
                TransferStatusMessage(
                    title: "传书服务不可用",
                    detail: error,
                    systemImage: "exclamationmark.triangle.fill",
                    color: PapriaDesign.error
                )
            }

            Button(action: startTransfer) {
                Label("启动传书", systemImage: "wifi")
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(PapriaDesign.accent)
            .accessibilityHint("在当前 Wi-Fi 网络启动局域网传书服务")
        }
    }

    private var startingContent: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space3) {
            TransferStatusMessage(
                title: "正在启动传书服务",
                detail: "正在获取当前 Wi-Fi 的局域网地址。",
                systemImage: "wifi",
                color: PapriaDesign.remote
            )
            ProgressView()
                .tint(PapriaDesign.accent)
                .accessibilityLabel("正在启动 Wi-Fi 传书服务")
        }
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space5) {
            VStack(alignment: .leading, spacing: PapriaDesign.space2) {
                TransferStatusMessage(
                    title: "传书服务运行中",
                    detail: currentWiFiDescription,
                    systemImage: "checkmark.circle.fill",
                    color: PapriaDesign.success
                )
                Text("保持应用在前台；可以切换页面，服务会保持运行，直到你选择停止。")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.inkSecondary)
            }

            if hasUsableTransferAddress {
                if let qr = QRCodeImage(value: transfer.displayAddress) {
                    HStack {
                        Spacer(minLength: 0)
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 208, height: 208)
                            .padding(PapriaDesign.space4)
                            .background(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: PapriaDesign.panelCornerRadius)
                                    .stroke(PapriaDesign.lineSubtle, lineWidth: 1)
                            )
                            .accessibilityLabel("Wi-Fi 传书二维码，扫描后打开局域网地址")
                        Spacer(minLength: 0)
                    }
                }

                addressSection
            } else {
                addressUnavailableState
            }
        }
    }

    private var stopServiceButton: some View {
        Button(role: .destructive) {
            showingStopConfirmation = true
        } label: {
            Label("停止服务", systemImage: "stop.circle")
                .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
        }
        .buttonStyle(.bordered)
        .tint(PapriaDesign.error)
        .accessibilityHint("停止服务前会提示正在上传的文件将中断")
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space2) {
            Text("局域网地址")
                .font(PapriaDesign.sectionTitle)
                .foregroundStyle(PapriaDesign.ink)
            HStack(alignment: .top, spacing: PapriaDesign.space2) {
                Text(transfer.displayAddress)
                    .font(PapriaDesign.metadata.monospaced())
                    .foregroundStyle(PapriaDesign.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("局域网地址")
                    .accessibilityValue(transfer.displayAddress)
                    .accessibilityHint("可长按选择完整地址；也可通过转子选择朗读地址")
                    .accessibilityAction(named: Text("朗读地址")) {
                        announceAddress()
                    }
                Spacer(minLength: 0)
                Button(action: copyAddress) {
                    Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                        .frame(width: PapriaDesign.minimumHitTarget, height: PapriaDesign.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .tint(PapriaDesign.remote)
                .accessibilityLabel(copiedAddress ? "地址已复制" : "复制局域网地址")
                .accessibilityHint("将完整局域网地址复制到剪贴板")
            }
            .padding(PapriaDesign.space3)
            .background(PapriaDesign.raised)
            .overlay(
                RoundedRectangle(cornerRadius: PapriaDesign.panelCornerRadius)
                    .stroke(PapriaDesign.lineSubtle, lineWidth: 1)
            )

            if copiedAddress {
                Label("地址已复制", systemImage: "checkmark.circle.fill")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.success)
            }
        }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space2) {
            HStack {
                Text("传输列表")
                    .font(PapriaDesign.sectionTitle)
                    .foregroundStyle(PapriaDesign.ink)
                Spacer()
                Text("\(completedSessionCount) 已完成")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.success)
                    .monospacedDigit()
            }

            if transfer.transferSessions.isEmpty {
                TransferStatusMessage(
                    title: "等待上传",
                    detail: "上传开始后会在这里显示导入状态。",
                    systemImage: "arrow.down.circle",
                    color: PapriaDesign.inkSecondary
                )
            } else {
                ForEach(transfer.transferSessions) { session in
                    TransferSessionRow(
                        session: session,
                        onCancel: { transfer.cancelTransfer(id: session.id) },
                        onRetry: { transfer.retryFailedImport(id: session.id) },
                        onRemove: { transfer.removeTransferRecord(id: session.id) },
                        onShowLibrary: { showingLibrary = true }
                    )
                }
            }
        }
    }

    private var completedSessionCount: Int {
        transfer.transferSessions.filter { $0.phase == .completed }.count
    }

    private var safetyNote: some View {
        Text("服务会保持运行，直到你选择停止。Wi-Fi 导入只保存到本机，不会上传 BookOrbit。")
            .font(PapriaDesign.metadata)
            .foregroundStyle(PapriaDesign.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("传书安全说明：服务会保持运行，直到你选择停止。Wi-Fi 导入只保存到本机，不会上传 BookOrbit")
    }

    private var currentWiFiDescription: String {
        if let wifiName, !wifiName.isEmpty {
            return "当前 Wi-Fi：\(wifiName)"
        }
        return "当前 Wi-Fi：系统未提供名称"
    }

    private var hasUsableTransferAddress: Bool {
        let value = transfer.displayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("http://") || value.hasPrefix("https://")
    }

    private var addressUnavailableState: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space3) {
            TransferStatusMessage(
                title: "局域网地址不可用",
                detail: "尚未获得可用于传书的局域网地址。请检查 Wi-Fi 后刷新，或停止服务。",
                systemImage: "wifi.exclamationmark",
                color: PapriaDesign.warning
            )
            Button(action: refreshUnavailableAddress) {
                Label("刷新网络", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
            }
            .buttonStyle(.bordered)
            .tint(PapriaDesign.remote)
            .accessibilityHint("在没有活动上传时重新启动传书服务并获取局域网地址")
        }
    }

    private var transferServiceError: String? {
        let address = transfer.displayAddress
        guard !address.isEmpty, address.hasPrefix("Wi-Fi 传书服务不可用：") else { return nil }
        return address
    }

    private func startTransfer() {
        copiedAddress = false
        refreshWiFiName()
        transfer.start()
    }

    private func refreshUnavailableAddress() {
        refreshWiFiName()
        guard !transfer.hasActiveTransfer else {
            showingStopConfirmation = true
            return
        }
        transfer.stop()
        transfer.start()
    }

    private func copyAddress() {
        UIPasteboard.general.string = transfer.displayAddress
        copiedAddress = true
        UIAccessibility.post(notification: .announcement, argument: "局域网地址已复制")
    }

    private func announceAddress() {
        UIAccessibility.post(
            notification: .announcement,
            argument: "局域网地址：\(transfer.displayAddress)"
        )
    }

    private func refreshWiFiName() {
        NEHotspotNetwork.fetchCurrent { network in
            DispatchQueue.main.async {
                wifiName = network?.ssid
            }
        }
    }
}

private struct TransferStatusMessage: View {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: PapriaDesign.space2) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PapriaDesign.space1) {
                Text(title)
                    .font(PapriaDesign.rowBody.weight(.medium))
                    .foregroundStyle(PapriaDesign.ink)
                Text(detail)
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PapriaDesign.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapriaDesign.raised)
        .overlay(
            RoundedRectangle(cornerRadius: PapriaDesign.panelCornerRadius)
                .stroke(PapriaDesign.lineSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct TransferSessionRow: View {
    let session: LocalTransferSession
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onShowLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapriaDesign.space2) {
            HStack(alignment: .firstTextBaseline, spacing: PapriaDesign.space2) {
                Text(displayFileName)
                    .font(PapriaDesign.rowBody.weight(.medium))
                    .foregroundStyle(PapriaDesign.ink)
                    .lineLimit(2)
                Spacer(minLength: PapriaDesign.space2)
                Label(statusTitle, systemImage: statusSymbol)
                    .font(PapriaDesign.label)
                    .foregroundStyle(statusColor)
                    .fixedSize()
            }
            Text(sizeDescription)
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)

            sessionState

            if session.phase.canCancel {
                Button("取消", role: .destructive, action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(PapriaDesign.error)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("取消接收此文件，并删除本机未完成的临时文件")
            } else if session.phase == .validating || session.phase == .importing {
                Text("校验或导入已经开始，无法安全取消。")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.inkSecondary)
                    .accessibilityLabel("校验或导入已经开始，此文件无法安全取消")
            } else if session.phase.canRetryImport && session.receivedBytes == session.sizeBytes {
                HStack(spacing: PapriaDesign.space2) {
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                        .tint(PapriaDesign.accent)
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                        .accessibilityHint("重新校验并导入已完整接收的文件")
                    Button("移除", role: .destructive, action: onRemove)
                        .buttonStyle(.bordered)
                        .tint(PapriaDesign.error)
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                        .accessibilityHint("删除失败传输的临时文件和记录")
                }
            } else if session.phase == .failed {
                Text("请在上传设备重新传输，或移除此失败记录。")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaDesign.inkSecondary)
                Button("移除", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .tint(PapriaDesign.error)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("删除失败传输的临时文件和记录")
            } else if session.phase == .cancelled {
                Button("移除", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .tint(PapriaDesign.error)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("移除此取消传输的记录")
            } else if session.phase == .completed {
                Button("查看书库", action: onShowLibrary)
                    .buttonStyle(.bordered)
                    .tint(PapriaDesign.remote)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityHint("打开本机书库，查看已加入的书籍")
            }
        }
        .padding(.vertical, PapriaDesign.space3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PapriaDesign.lineSubtle)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var sessionState: some View {
        switch session.phase {
        case .receiving:
            if let progress = session.progress {
                ProgressView(value: progress)
                    .tint(PapriaDesign.accent)
                    .accessibilityLabel("上传进度 \(progressText)")
            } else {
                ProgressView()
                    .accessibilityLabel("上传进度未知")
            }
            Text("上传中 \(progressText) · \(transferSizeText)")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
                .monospacedDigit()
        case .waitingForResume:
            Text("等待上传设备继续传输 · \(transferSizeText)")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
                .monospacedDigit()
        case .validating:
            staticProgress
            Text("正在导入（正在校验文件）· \(transferSizeText)")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        case .importing:
            staticProgress
            Text("正在导入，禁止重复打开此文件。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        case .completed:
            Text("已加入书库 · \(totalSizeText)")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.success)
        case .failed:
            Text("失败：\(session.failureReason ?? "未获得失败原因")")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.error)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text("已取消 · 未完成文件已从本机移除。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaDesign.inkSecondary)
        }
    }

    private var staticProgress: some View {
        Rectangle()
            .fill(PapriaDesign.lineSubtle)
            .frame(height: 2)
            .accessibilityLabel("正在处理，进度不可估算")
    }

    private var displayFileName: String {
        session.fileName.isEmpty ? "文件名未知（上传设备未提供）" : session.fileName
    }

    private var progressText: String {
        guard let progress = session.progress else { return "进度未知" }
        return "\(Int((progress * 100).rounded()))%"
    }

    private var transferSizeText: String {
        "\(ByteCountFormatter.string(fromByteCount: session.receivedBytes, countStyle: .file)) / \(totalSizeText)"
    }

    private var totalSizeText: String {
        guard session.sizeBytes > 0 else { return "总大小未知（上传设备未提供）" }
        return ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file)
    }

    private var sizeDescription: String {
        session.sizeBytes > 0 ? "文件大小：\(totalSizeText)" : "文件大小：未知（上传设备未提供）"
    }

    private var statusTitle: String {
        switch session.phase {
        case .waitingForResume: return "等待继续"
        case .receiving: return "上传中"
        case .validating: return "正在导入"
        case .importing: return "正在导入"
        case .completed: return "已加入书库"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var statusSymbol: String {
        switch session.phase {
        case .waitingForResume: return "pause.circle"
        case .receiving: return "arrow.up.circle"
        case .validating: return "checklist"
        case .importing: return "tray.and.arrow.down"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .completed: return PapriaDesign.success
        case .failed: return PapriaDesign.error
        case .receiving, .validating, .importing: return PapriaDesign.accent
        case .waitingForResume, .cancelled: return PapriaDesign.inkSecondary
        }
    }
}

private struct TransferLibrarySheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private var publications: [LocalPublication] {
        environment.publications
    }

    var body: some View {
        NavigationView {
            List {
                if publications.isEmpty {
                    Text("书库中还没有可显示的书籍。")
                        .foregroundStyle(PapriaDesign.inkSecondary)
                } else {
                    ForEach(publications) { publication in
                        VStack(alignment: .leading, spacing: PapriaDesign.space1) {
                            Text(publication.title)
                                .foregroundStyle(PapriaDesign.ink)
                                .lineLimit(2)
                            Text("\(publication.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: publication.sizeBytes, countStyle: .file))")
                                .font(PapriaDesign.metadata)
                                .foregroundStyle(PapriaDesign.inkSecondary)
                        }
                    }
                }
            }
            .navigationTitle("书库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成", action: dismiss.callAsFunction)
                }
            }
        }
        .task {
            await environment.reloadLocalLibrary()
        }
    }
}

private func QRCodeImage(value: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "H"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    let context = CIContext()
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
}
