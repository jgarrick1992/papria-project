import SwiftUI
import PDFKit
import UIKit
import AVFoundation

/// Compact native reading surface. Format engines remain behind this boundary;
/// position persistence uses the same file/page semantics required by BookOrbit.
struct ReaderView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    let publication: LocalPublication
    @State private var percentage = 0.0
    @State private var pageNumber = 1
    @State private var cfi: String?
    @State private var koboLocationSource: String?
    @State private var koboLocationType: String?
    @State private var koboLocationValue: String?
    @State private var koboContentSourceProgressPercent: Double?
    @State private var koreaderProgress: String?
    @State private var totalPages = 0
    /// Becomes true only after the persisted progress read has finished. The
    /// format views must not publish their default position before this point:
    /// doing so would replace an externally supplied EPUB CFI with page one.
    @State private var progressLoaded = false

    init(publication: LocalPublication) { self.publication = publication }

    var body: some View {
        readerScreen
        .task {
            guard !progressLoaded else { return }
            if let progress = await environment.progressForOpening(fileId: publication.progressFileId, remoteFileId: publication.remoteFileId) {
                percentage = progress.percentage
                pageNumber = progress.pageNumber ?? 1
                cfi = progress.cfi
                koboLocationSource = progress.koboLocationSource
                koboLocationType = progress.koboLocationType
                koboLocationValue = progress.koboLocationValue
                koboContentSourceProgressPercent = progress.koboContentSourceProgressPercent
                koreaderProgress = progress.koreaderProgress
            }
            progressLoaded = true
        }
        .onChange(of: scenePhase) { phase in
            if phase == .inactive || phase == .background { savePosition() }
        }
        .onDisappear { savePosition() }
    }

    private var isPaged: Bool { ["pdf", "cbz", "cbr", "cb7"].contains(publication.format.lowercased()) }
    private var iconName: String {
        switch publication.format.lowercased() {
        case "pdf": return "doc.richtext"
        case "cbz", "cbr", "cb7": return "rectangle.stack"
        case "m4b", "m4a", "mp3", "ogg", "opus", "flac": return "headphones"
        default: return "book"
        }
    }

    private func savePosition() {
        guard progressLoaded else { return }
        // AudioPlaybackService owns audiobook progress and writes the exact
        // currentFileId/positionSeconds payload. A ReaderView lifecycle event
        // must not create a second document-progress outbox row for audio.
        guard !["mp3", "m4a", "m4b", "ogg", "opus", "flac"].contains(publication.format.lowercased()) else { return }
        let fileId = publication.progressFileId
        Task {
            let payload = FileProgressPayload(
                percentage: percentage,
                cfi: cfi,
                pageNumber: isPaged ? pageNumber : nil,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                dirty: publication.remoteFileId != nil,
                koboLocationSource: koboLocationSource,
                koboLocationType: koboLocationType,
                koboLocationValue: koboLocationValue,
                koboContentSourceProgressPercent: koboContentSourceProgressPercent,
                koreaderProgress: koreaderProgress
            )
            if publication.remoteFileId != nil {
                await environment.saveReadingPosition(fileId: fileId, progress: payload)
            } else {
                try? await environment.localStore.saveProgress(fileId: fileId, progress: payload, enqueue: false)
            }
        }
    }

    @ViewBuilder
    private var readerScreen: some View {
        switch publication.format.lowercased() {
        case "epub", "kepub":
            EpubReaderView(
                url: URL(fileURLWithPath: publication.filePath),
                storageKey: publication.fileHash,
                progressLoaded: progressLoaded,
                percentage: $percentage,
                pageNumber: $pageNumber,
                cfi: $cfi,
                onProgress: savePosition
            )
        case "txt", "md":
            TextFileView(
                url: URL(fileURLWithPath: publication.filePath),
                title: publication.title,
                progressLoaded: progressLoaded,
                percentage: $percentage,
                pageNumber: $pageNumber,
                onProgress: savePosition
            )
        case "fb2":
            ConvertedEpubReaderView(url: URL(fileURLWithPath: publication.filePath), format: "fb2", storageKey: publication.fileHash, progressLoaded: $progressLoaded, percentage: $percentage, pageNumber: $pageNumber, cfi: $cfi, onProgress: savePosition)
        case "mobi", "azw", "azw3":
            ConvertedEpubReaderView(url: URL(fileURLWithPath: publication.filePath), format: publication.format, storageKey: publication.fileHash, progressLoaded: $progressLoaded, percentage: $percentage, pageNumber: $pageNumber, cfi: $cfi, onProgress: savePosition)
        case "mp3", "m4a", "m4b", "ogg", "opus", "flac":
            AudioReaderControls(publication: publication)
        default:
            ReaderDocumentShell(
                title: publication.title,
                format: publication.format,
                percentage: percentage,
                pageNumber: pageNumber,
                totalPages: totalPages,
                onPrevious: {
                    pageNumber = max(1, pageNumber - 1)
                    savePosition()
                },
                onNext: {
                    pageNumber = totalPages > 0 ? min(totalPages, pageNumber + 1) : pageNumber + 1
                    savePosition()
                }
            ) {
                readerSurface
            }
        }
    }

    @ViewBuilder
    private var readerSurface: some View {
        switch publication.format.lowercased() {
        case "pdf":
            PDFReaderContainer(
                url: URL(fileURLWithPath: publication.filePath),
                storageKey: publication.fileHash,
                progressLoaded: progressLoaded,
                pageNumber: $pageNumber,
                totalPages: $totalPages,
                percentage: $percentage,
                onProgress: savePosition
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReaderUI.paperCanvas)
        case "cbz", "cbr", "cb7":
            ComicReaderView(url: URL(fileURLWithPath: publication.filePath), format: publication.format, storageKey: publication.fileHash, pageNumber: $pageNumber, totalPages: $totalPages, percentage: $percentage, onProgress: savePosition)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReaderUI.paperCanvas)
        default:
            Rectangle()
                .fill(ReaderUI.paperCanvas)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: iconName).font(.system(size: 42))
                        Text("已保存，可继续阅读")
                            .font(.headline)
                        Text("当前系统阅读器已接入 EPUB、FB2、PalmDOC、PDF、CBZ、CBR、CB7、文本和音频；DRM 文件拒绝打开。")
                            .font(.footnote)
                            .foregroundStyle(ReaderUI.inkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Reader-only UI tokens. They deliberately live at the feature boundary so
/// this visual change does not alter any shared model, API, or persistence key.
private enum ReaderUI {
    static let paperCanvas = Color(red: 247.0 / 255.0, green: 242.0 / 255.0, blue: 232.0 / 255.0)
    static let paperRaised = Color(red: 1.0, green: 252.0 / 255.0, blue: 246.0 / 255.0)
    static let inkPrimary = Color(red: 32.0 / 255.0, green: 34.0 / 255.0, blue: 31.0 / 255.0)
    static let inkSecondary = Color(red: 111.0 / 255.0, green: 108.0 / 255.0, blue: 99.0 / 255.0)
    static let subtleLine = Color(red: 216.0 / 255.0, green: 208.0 / 255.0, blue: 195.0 / 255.0)
    static let primaryAction = Color(red: 183.0 / 255.0, green: 70.0 / 255.0, blue: 50.0 / 255.0)
    static let success = Color(red: 45.0 / 255.0, green: 113.0 / 255.0, blue: 104.0 / 255.0)
    static let topBarHeight: CGFloat = 56
    static let bottomBarHeight: CGFloat = 138
    static let hitTarget: CGFloat = 44
}

/// Adjustable reading text uses the user's Dynamic Type scale before it is
/// bridged to the selected iOS text design. The reader's 19pt default remains
/// the baseline; it is not a fixed accessibility size. Reader body text
/// defaults to the platform serif design (Songti-like for Chinese content),
/// while chrome, symbols, and media controls keep their native styles.
private enum ReaderDynamicTextFont {
    static func make(size: CGFloat, design: UIFontDescriptor.SystemDesign? = .serif) -> Font {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        let descriptor = design.flatMap { base.withDesign($0) } ?? base
        return Font(UIFont(descriptor: descriptor, size: size))
    }
}

/// Keeps the 56pt reading chrome stable while retaining Dynamic Type semantics.
/// Long titles remain available to VoiceOver through their untruncated value.
private struct ReaderChromeTitle: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A compact, semantic label for the fixed-height reader paging controls.
/// The visual label never wraps into a second line, while the enclosing Button
/// remains a 44pt target and exposes its complete label to VoiceOver.
private struct ReaderPagingLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .frame(minHeight: ReaderUI.hitTarget)
    }
}

/// A recoverable reader error deliberately keeps the source filename, a
/// user-actionable reason, and both escape routes visible. It is shared by
/// format engines so no parser can accidentally turn a failure into blank
/// reading content.
private struct ReaderFailureView: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    let title: String
    let reason: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(ReaderUI.primaryAction)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(fileURL.lastPathComponent)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(ReaderUI.inkSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("返回书库") { dismiss() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: ReaderUI.hitTarget)
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderUI.primaryAction)
                    .frame(minHeight: ReaderUI.hitTarget)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReaderUI.paperCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)：\(fileURL.lastPathComponent)。\(reason)")
    }
}

/// Shared chrome for formats whose engines own their own document layout
/// (PDF and comics). The content always reserves the chrome height, so a tap
/// only fades the controls and never shifts or reflows the document.
private struct ReaderDocumentShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let format: String
    let percentage: Double
    let pageNumber: Int
    let totalPages: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    private let content: Content
    @State private var controlsVisible = true
    @State private var showingContents = false
    @State private var showingDisplaySettings = false

    init(
        title: String,
        format: String,
        percentage: Double,
        pageNumber: Int,
        totalPages: Int,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.format = format
        self.percentage = percentage
        self.pageNumber = pageNumber
        self.totalPages = totalPages
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.content = content()
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                ReaderUI.paperCanvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    Color.clear.frame(height: ReaderUI.topBarHeight)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
                            },
                            including: .gesture
                        )
                    Color.clear.frame(height: ReaderUI.bottomBarHeight)
                }
                .padding(.horizontal, 16)

                if controlsVisible {
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 0)
                        bottomBar
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .navigationBarHidden(true)
        .sheet(isPresented: $showingContents) {
            NavigationView {
                List {
                    Text("此格式使用系统目录或页码导航。")
                        .foregroundStyle(ReaderUI.inkSecondary)
                }
                .navigationTitle("目录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showingContents = false } } }
            }
        }
        .sheet(isPresented: $showingDisplaySettings) {
            NavigationView {
                Form {
                    Section("阅读显示") {
                        Label("保留系统缩放、平移、页码与阅读方向控制", systemImage: "arrow.up.left.and.arrow.down.right")
                        Text("PDF 和漫画继续使用各自的原生缩放及阅读方向能力。")
                            .font(.footnote)
                            .foregroundStyle(ReaderUI.inkSecondary)
                    }
                }
                .navigationTitle("显示设置")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showingDisplaySettings = false } } }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("返回书库")

            ReaderChromeTitle(value: title)

            Button { showingContents = true } label: {
                Image(systemName: "list.bullet")
                    .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("目录")

            Button { showingDisplaySettings = true } label: {
                Image(systemName: "textformat.size")
                    .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("显示设置")
        }
        .foregroundStyle(ReaderUI.inkPrimary)
        .frame(height: ReaderUI.topBarHeight)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(format.uppercased()) · 阅读位置")
                .font(.footnote.weight(.medium))
                .foregroundStyle(ReaderUI.inkPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(ReaderUI.primaryAction)
                .accessibilityLabel("阅读进度")
                .accessibilityValue("\(Int(percentage.rounded()))%，第 \(pageNumber) 页")
            HStack {
                Text("\(Int(percentage.rounded()))%")
                Spacer()
                Text("\(pageNumber) / \(max(max(totalPages, pageNumber), 1)) 页")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ReaderUI.inkSecondary)
            HStack(spacing: 8) {
                Button(action: onPrevious) { ReaderPagingLabel(title: "上一页", systemImage: "chevron.left") }
                    .buttonStyle(.bordered)
                    .disabled(pageNumber <= 1)
                    .accessibilityLabel("上一页")
                Spacer(minLength: 4)
                Button(action: onNext) { ReaderPagingLabel(title: "下一页", systemImage: "chevron.right") }
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderUI.primaryAction)
                    .accessibilityLabel("下一页")
                Button { showingDisplaySettings = true } label: {
                    Image(systemName: "textformat.size")
                        .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
                }
                .accessibilityLabel("字体和显示设置")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: ReaderUI.bottomBarHeight, alignment: .top)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .top) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
        .foregroundStyle(ReaderUI.inkPrimary)
    }
}

private struct PDFReaderView: UIViewRepresentable {
    let url: URL
    let displayMode: PDFDisplayMode
    let displayDirection: PDFDisplayDirection
    let zoomMode: PDFZoomMode
    let zoom: CGFloat
    let rotation: Int
    let resetRequest: UUID
    @Binding var pageNumber: Int
    let onPageChanged: (Int, Int) -> Void
    let onZoomChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayBox = .cropBox
        view.minScaleFactor = 0.5
        view.maxScaleFactor = 5
        view.isUserInteractionEnabled = true
        view.document = PDFDocument(url: url)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.displayMode = displayMode
        view.displayDirection = displayDirection
        switch zoomMode {
        case .fitPage:
            view.autoScales = true
        case .fitWidth:
            view.autoScales = false
            guard let document = view.document else { return }
            let page = view.currentPage ?? document.page(at: 0)
            if let page, page.bounds(for: view.displayBox).width > 0, view.bounds.width > 0 {
                view.scaleFactor = view.bounds.width / page.bounds(for: view.displayBox).width
            }
        case .manual:
            view.autoScales = false
            view.scaleFactor = zoom
        }

        if context.coordinator.consumeResetRequest(resetRequest) {
            view.autoScales = true
            if let page = view.currentPage {
                view.go(to: page)
            }
        }

        if let document = view.document, let page = document.page(at: max(0, pageNumber - 1)), view.currentPage !== page {
            view.go(to: page)
        }
    }

    final class Coordinator: NSObject {
        let onPageChanged: (Int, Int) -> Void
        let onZoomChanged: (CGFloat) -> Void
        private var pageObserver: NSObjectProtocol?
        private var latestResetRequest: UUID?

        init(
            onPageChanged: @escaping (Int, Int) -> Void,
            onZoomChanged: @escaping (CGFloat) -> Void
        ) {
            self.onPageChanged = onPageChanged
            self.onZoomChanged = onZoomChanged
        }

        func observe(_ view: PDFView) {
            pageObserver = NotificationCenter.default.addObserver(forName: Notification.Name.PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, let view, let document = view.document, let page = view.currentPage else { return }
                let index = document.index(for: page)
                self.onPageChanged(index + 1, document.pageCount)
            }
        }

        func consumeResetRequest(_ request: UUID) -> Bool {
            guard latestResetRequest != request else { return false }
            latestResetRequest = request
            return true
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PDFView else { return }
            let fitScale = max(view.minScaleFactor, 0.5)
            let targetScale = view.scaleFactor > fitScale * 1.25
                ? fitScale
                : min(view.maxScaleFactor, fitScale * 2)
            view.autoScales = false
            view.scaleFactor = targetScale
            onZoomChanged(targetScale)
        }

        deinit {
            if let pageObserver {
                NotificationCenter.default.removeObserver(pageObserver)
            }
        }
    }
}

private struct PDFReaderContainer: View {
    private enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let url: URL
    let storageKey: String
    let progressLoaded: Bool
    @Binding var pageNumber: Int
    @Binding var totalPages: Int
    @Binding var percentage: Double
    let onProgress: () -> Void
    @State private var displayMode: PDFDisplayMode = .singlePageContinuous
    @State private var displayDirection: PDFDisplayDirection = .vertical
    @State private var zoomMode: PDFZoomMode = .fitPage
    @State private var zoom: CGFloat = 1
    @State private var rotation = 0
    @State private var resetRequest = UUID()
    @State private var loadState: LoadState = .loading
    @State private var loadAttempt = UUID()

    init(url: URL, storageKey: String, progressLoaded: Bool, pageNumber: Binding<Int>, totalPages: Binding<Int>, percentage: Binding<Double>, onProgress: @escaping () -> Void) {
        self.url = url
        self.storageKey = storageKey
        self.progressLoaded = progressLoaded
        self._pageNumber = pageNumber
        self._totalPages = totalPages
        self._percentage = percentage
        self.onProgress = onProgress
        let preferences = PDFReaderPreferences.load(storageKey: storageKey)
        _displayMode = State(initialValue: preferences.continuous ? .singlePageContinuous : .singlePage)
        _displayDirection = State(initialValue: preferences.horizontal ? .horizontal : .vertical)
        _zoomMode = State(initialValue: preferences.zoomMode)
        _zoom = State(initialValue: preferences.zoomScale)
        _rotation = State(initialValue: preferences.rotation)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("正在打开 PDF…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在打开 \(url.lastPathComponent)")
            case .failed(let reason):
                ReaderFailureView(
                    fileURL: url,
                    title: "无法打开 PDF",
                    reason: reason,
                    retry: retryLoading
                )
            case .ready:
                reader
            }
        }
        .task(id: loadAttempt) {
            validatePDF()
        }
    }

    private var reader: some View {
        VStack(spacing: 8) {
            PDFReaderView(
                url: url,
                displayMode: displayMode,
                displayDirection: displayDirection,
                zoomMode: zoomMode,
                zoom: zoom,
                rotation: rotation,
                resetRequest: resetRequest,
                pageNumber: $pageNumber,
                onPageChanged: { page, total in
                    pageNumber = page
                    totalPages = total
                    percentage = total > 0 ? Double(page) / Double(total) * 100 : 0
                    if progressLoaded { onProgress() }
                },
                onZoomChanged: { scale in
                    zoom = scale
                    zoomMode = .manual
                    savePreferences()
                }
            )
            .rotationEffect(.degrees(Double(rotation)))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("重置缩放") { resetZoom() }
                    Button("适合页面") { fitPage() }
                    Button(zoomMode == .fitWidth ? "适合页面" : "适合宽度") {
                        zoomMode = zoomMode == .fitWidth ? .fitPage : .fitWidth
                        savePreferences()
                    }
                    Button(displayMode == .singlePage ? "连续" : "单页") {
                        displayMode = displayMode == .singlePage ? .singlePageContinuous : .singlePage
                        savePreferences()
                    }
                    Button(displayDirection == .vertical ? "横向" : "纵向") {
                        displayDirection = displayDirection == .vertical ? .horizontal : .vertical
                        savePreferences()
                    }
                    Button("旋转") {
                        rotation = (rotation + 90) % 360
                        savePreferences()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.horizontal, 16)
            }
            .frame(minHeight: ReaderUI.hitTarget)
        }
    }

    private func validatePDF() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadState = .failed("文件已不存在或无法访问。")
            return
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            loadState = .failed("文件不是有效的 PDF，或其中没有可阅读页面。")
            return
        }
        totalPages = document.pageCount
        loadState = .ready
    }

    private func retryLoading() {
        loadState = .loading
        loadAttempt = UUID()
    }

    private func fitPage() {
        zoomMode = .fitPage
        savePreferences()
    }

    private func resetZoom() {
        zoom = 1
        zoomMode = .fitPage
        resetRequest = UUID()
        savePreferences()
    }

    private func savePreferences() {
        PDFReaderPreferences(
            zoomMode: zoomMode,
            zoomScale: zoom,
            rotation: rotation,
            continuous: displayMode != .singlePage,
            horizontal: displayDirection == .horizontal
        ).save(storageKey: storageKey)
    }
}

private struct TextFileView: View {
    private enum TextReadError: LocalizedError {
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .emptyContent:
                return "文件中没有可显示的文本内容。"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String
    let progressLoaded: Bool
    @Binding var percentage: Double
    @Binding var pageNumber: Int
    let onProgress: () -> Void
    let transform: (String) -> String
    @State private var text = ""
    @State private var isLoading = true
    @State private var failureReason: String?
    @State private var loadAttempt = UUID()
    @State private var pageIndex = 0
    @State private var fontSize = 19.0
    /// A serif body is the documented iOS reading baseline. Users can still
    /// choose the other explicit display-font options in the settings sheet.
    @State private var fontChoice = 1
    /// 19pt × 1.72 line height leaves 13.68pt between SwiftUI baselines.
    @State private var lineSpacing = 13.68
    @State private var margin = 16.0
    @State private var paperTone: EpubPaperTone = .warm
    @State private var controlsVisible = true
    @State private var showingContents = false
    @State private var showingDisplaySettings = false
    /// Default body text remains 19pt; the multiplier follows the user's
    /// system text-size setting without allowing fixed reader chrome to grow.
    @ScaledMetric(relativeTo: .body) private var readerTextScale: CGFloat = 1

    init(
        url: URL,
        title: String,
        progressLoaded: Bool,
        percentage: Binding<Double>,
        pageNumber: Binding<Int>,
        onProgress: @escaping () -> Void,
        transform: @escaping (String) -> String = { $0 }
    ) {
        self.url = url
        self.title = title
        self.progressLoaded = progressLoaded
        self._percentage = percentage
        self._pageNumber = pageNumber
        self.onProgress = onProgress
        self.transform = transform
    }

    var body: some View {
        Group {
            if let failureReason {
                ReaderFailureView(
                    fileURL: url,
                    title: "无法打开文本文件",
                    reason: failureReason,
                    retry: retryLoading
                )
            } else if isLoading {
                ProgressView("正在读取文本…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(paperTone.color)
                    .accessibilityLabel("正在读取 \(url.lastPathComponent)")
            } else {
                GeometryReader { _ in
                    ZStack {
                        paperTone.color.ignoresSafeArea()
                        VStack(spacing: 0) {
                            Color.clear.frame(height: ReaderUI.topBarHeight)
                            textPage
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
                                    },
                                    including: .gesture
                                )
                            Color.clear.frame(height: ReaderUI.bottomBarHeight)
                        }

                        if controlsVisible {
                            VStack(spacing: 0) {
                                topBar
                                Spacer(minLength: 0)
                                bottomBar
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .foregroundStyle(paperTone.ink)
        .navigationBarHidden(true)
        .task(id: loadAttempt) {
            loadText()
        }
        .onChange(of: progressLoaded) { _ in restorePage() }
        .onChange(of: text) { _ in restorePage() }
        .onChange(of: readerTextScale) { _ in normalizePageForTextSize() }
        .sheet(isPresented: $showingContents) {
            NavigationView {
                List { Text("此文本文件没有内嵌目录。") }
                    .navigationTitle("目录")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showingContents = false } } }
            }
        }
        .sheet(isPresented: $showingDisplaySettings) {
            ReaderTextSettings(
                fontSize: $fontSize,
                fontChoice: $fontChoice,
                lineSpacing: $lineSpacing,
                margin: $margin,
                paperTone: $paperTone,
                dismiss: { showingDisplaySettings = false }
            )
        }
    }

    private var pages: [String] {
        ReaderTextPaginator.pages(text, fontSize: Double(effectiveFontSize), lineSpacing: Double(effectiveLineSpacing), margin: margin)
    }

    private var textPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("正文")
                    .font(.title3.weight(.semibold))
                Text(pages[safe: pageIndex] ?? text)
                    .font(readerFont)
                    .lineSpacing(effectiveLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, margin)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("返回书库")
            ReaderChromeTitle(value: title)
            Button { showingContents = true } label: {
                Image(systemName: "list.bullet").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("目录")
            Button { showingDisplaySettings = true } label: {
                Image(systemName: "textformat.size").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("显示设置")
        }
        .frame(height: ReaderUI.topBarHeight)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("正文")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(ReaderUI.primaryAction)
                .accessibilityLabel("阅读进度")
                .accessibilityValue("\(Int(percentage.rounded()))%，第 \(pageIndex + 1) 页")
            HStack {
                Text("\(Int(percentage.rounded()))%")
                Spacer()
                Text("\(pageIndex + 1) / \(max(pages.count, 1)) 页")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ReaderUI.inkSecondary)
            HStack(spacing: 8) {
                Button { previousPage() } label: { ReaderPagingLabel(title: "上一页", systemImage: "chevron.left") }
                    .buttonStyle(.bordered)
                    .disabled(pageIndex <= 0)
                    .accessibilityLabel("上一页")
                Spacer(minLength: 4)
                Button { nextPage() } label: { ReaderPagingLabel(title: "下一页", systemImage: "chevron.right") }
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderUI.primaryAction)
                    .disabled(pageIndex >= pages.count - 1)
                    .accessibilityLabel("下一页")
                Button { showingDisplaySettings = true } label: {
                    Image(systemName: "textformat.size").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
                }
                .accessibilityLabel("字体和显示设置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: ReaderUI.bottomBarHeight, alignment: .top)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .top) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private var readerFont: Font {
        switch fontChoice {
        case 0: return ReaderDynamicTextFont.make(size: effectiveFontSize, design: nil)
        case 1: return ReaderDynamicTextFont.make(size: effectiveFontSize, design: .serif)
        case 2: return ReaderDynamicTextFont.make(size: effectiveFontSize, design: .monospaced)
        default: return ReaderDynamicTextFont.make(size: effectiveFontSize)
        }
    }

    private var effectiveFontSize: CGFloat { CGFloat(fontSize) * readerTextScale }
    private var effectiveLineSpacing: CGFloat { CGFloat(lineSpacing) * readerTextScale }

    private func restorePage() {
        guard progressLoaded, !isLoading, failureReason == nil else { return }
        pageIndex = min(max(0, pageNumber - 1), max(pages.count - 1, 0))
        updateProgress(save: false)
    }

    private func previousPage() {
        pageIndex = max(0, pageIndex - 1)
        updateProgress(save: true)
    }

    private func nextPage() {
        pageIndex = min(max(pages.count - 1, 0), pageIndex + 1)
        updateProgress(save: true)
    }

    private func updateProgress(save: Bool) {
        percentage = Double(pageIndex + 1) / Double(max(pages.count, 1)) * 100
        pageNumber = pageIndex + 1
        if save, progressLoaded { onProgress() }
    }

    private func normalizePageForTextSize() {
        pageIndex = min(pageIndex, max(pages.count - 1, 0))
        updateProgress(save: false)
    }

    private func loadText() {
        isLoading = true
        failureReason = nil
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let transformed = transform(source)
            guard !transformed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TextReadError.emptyContent
            }
            text = transformed
            isLoading = false
            restorePage()
        } catch {
            text = ""
            isLoading = false
            failureReason = textFailureReason(error)
        }
    }

    private func retryLoading() {
        isLoading = true
        failureReason = nil
        loadAttempt = UUID()
    }

    private func textFailureReason(_ error: Error) -> String {
        if let readerError = error as? TextReadError {
            return readerError.localizedDescription
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain {
            switch cocoaError.code {
            case NSFileNoSuchFileError:
                return "文件已不存在或无法访问。"
            case NSFileReadNoPermissionError:
                return "没有读取该文件的权限。"
            case NSFileReadInapplicableStringEncodingError:
                return "文件不是 UTF-8 文本，或当前编码无法读取。"
            default:
                break
            }
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty || detail == "The operation couldn’t be completed."
            ? "无法读取文本内容。"
            : "无法读取文本内容：\(detail)"
    }
}

private enum ReaderTextPaginator {
    static func pages(_ value: String, fontSize: Double, lineSpacing: Double, margin: Double) -> [String] {
        guard !value.isEmpty, value != "正在读取…" else { return [value] }
        let maxCharacters = Int(max(550, min(1_650, 2_600 - fontSize * 65 - lineSpacing * 12 - margin * 8)))
        var result: [String] = []
        var start = value.startIndex
        while start < value.endIndex {
            var end = value.index(start, offsetBy: min(maxCharacters, value.distance(from: start, to: value.endIndex)), limitedBy: value.endIndex) ?? value.endIndex
            if end < value.endIndex, let split = value[..<end].lastIndex(where: { $0 == " " || $0 == "\n" }), split > start { end = split }
            result.append(String(value[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
            while start < value.endIndex, value[start].isWhitespace { start = value.index(after: start) }
        }
        return result.isEmpty ? [""] : result
    }
}

private struct EpubReaderView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let storageKey: String
    let progressLoaded: Bool
    @Binding var percentage: Double
    @Binding var pageNumber: Int
    @Binding var cfi: String?
    let onProgress: () -> Void
    @State private var book: EpubBookModel?
    @State private var chapterIndex = 0
    @State private var pageIndex = 0
    @State private var fontSize = 19.0
    /// A serif body is the documented iOS reading baseline. Users can still
    /// choose the other explicit display-font options in the settings sheet.
    @State private var fontChoice = 1
    /// 19pt text with a 1.72 line-height leaves 13.68pt of extra spacing.
    @State private var lineSpacing = 13.68
    @State private var paragraphSpacing = 0.0
    @State private var margin = 16.0
    @State private var scrolling = false
    @State private var showToc = false
    @State private var showDisplaySettings = false
    @State private var controlsVisible = true
    @State private var error: String?
    @State private var isLoading = true
    @State private var paperTone: EpubPaperTone
    /// The 19pt specification is the default. This multiplier follows Dynamic
    /// Type and is also used for pagination so saved reading locations stay in
    /// sync with what is actually rendered.
    @ScaledMetric(relativeTo: .body) private var readerTextScale: CGFloat = 1

    init(url: URL, storageKey: String, progressLoaded: Bool, percentage: Binding<Double>, pageNumber: Binding<Int>, cfi: Binding<String?>, onProgress: @escaping () -> Void) {
        self.url = url
        self.storageKey = storageKey
        self.progressLoaded = progressLoaded
        self._percentage = percentage
        self._pageNumber = pageNumber
        self._cfi = cfi
        self.onProgress = onProgress
        _paperTone = State(initialValue: EpubReaderPreferences.load(storageKey: storageKey).paperTone)
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                paperTone.color.ignoresSafeArea()
                if let book {
                    let pages = book.pages(chapter: chapterIndex, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin)
                    VStack(spacing: 0) {
                        Color.clear.frame(height: ReaderUI.topBarHeight)
                        chapterPage(book: book, pages: pages)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() }
                                },
                                including: .gesture
                            )
                        Color.clear.frame(height: ReaderUI.bottomBarHeight)
                    }

                    if controlsVisible {
                        VStack(spacing: 0) {
                            topBar(book: book)
                            Spacer(minLength: 0)
                            bottomBar(book: book, pages: pages)
                        }
                        .transition(.opacity)
                    }
                } else if isLoading {
                    ProgressView("正在读取 EPUB…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("正在读取 \(url.lastPathComponent)")
                } else {
                    ReaderFailureView(
                        fileURL: url,
                        title: "无法打开 EPUB",
                        reason: error ?? "文件无法读取。",
                        retry: loadBook
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
        .foregroundStyle(paperTone.ink)
        .navigationBarHidden(true)
        .task(id: progressLoaded) {
            guard progressLoaded, book == nil else { return }
            loadBook()
        }
        .onChange(of: cfi) { _ in
            guard progressLoaded, let book else { return }
            restoreLocation(in: book)
        }
        .onChange(of: paperTone) { _ in savePreferences() }
        .onChange(of: fontSize) { _ in normalizePage() }
        .onChange(of: lineSpacing) { _ in normalizePage() }
        .onChange(of: margin) { _ in normalizePage() }
        .onChange(of: readerTextScale) { _ in restorePageForDynamicType() }
        .sheet(isPresented: $showToc) {
            NavigationView {
                List {
                    if let book, !book.toc.isEmpty {
                        ForEach(Array(book.toc.enumerated()), id: \.offset) { _, item in
                            Button(item.title) {
                                if let target = book.page(for: item.href, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin) {
                                    chapterIndex = target.chapter
                                    pageIndex = target.page
                                    showToc = false
                                    updateProgress(book)
                                }
                            }
                            .padding(.leading, CGFloat(item.depth * 12))
                        }
                    } else {
                        Text("此书没有可用目录。")
                    }
                }
                .navigationTitle("目录")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showToc = false } } }
            }
        }
        .sheet(isPresented: $showDisplaySettings) {
            ReaderTextSettings(
                fontSize: $fontSize,
                fontChoice: $fontChoice,
                lineSpacing: $lineSpacing,
                margin: $margin,
                paperTone: $paperTone,
                dismiss: { showDisplaySettings = false }
            )
        }
    }

    @ViewBuilder
    private func chapterPage(book: EpubBookModel, pages: [String]) -> some View {
        if scrolling {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(book.chapters[safe: chapterIndex]?.title ?? "章节")
                        .font(.title3.weight(.semibold))
                    Text(book.chapters[safe: chapterIndex]?.text ?? "此章节没有可读文字")
                        .font(readerFont)
                        .lineSpacing(CGFloat(layoutLineSpacing))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 12)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(book.chapters[safe: chapterIndex]?.title ?? "章节")
                        .font(.title3.weight(.semibold))
                    Text(pages[safe: pageIndex] ?? "此章节没有可读文字")
                        .font(readerFont)
                        .lineSpacing(CGFloat(layoutLineSpacing))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 12)
            }
        }
    }

    private func topBar(book: EpubBookModel) -> some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("返回书库")
            ReaderChromeTitle(value: book.title)
            Button { showToc = true } label: {
                Image(systemName: "list.bullet").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("目录")
            Button { showDisplaySettings = true } label: {
                Image(systemName: "textformat.size").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("显示设置")
        }
        .frame(height: ReaderUI.topBarHeight)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private func bottomBar(book: EpubBookModel, pages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.chapters[safe: chapterIndex]?.title ?? "章节")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(ReaderUI.primaryAction)
                .accessibilityLabel("阅读进度")
                .accessibilityValue("\(Int(percentage.rounded()))%，第 \(pageIndex + 1) 页")
            HStack {
                Text("\(Int(percentage.rounded()))%")
                Spacer()
                Text("\(pageIndex + 1) / \(max(pages.count, 1)) 页")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ReaderUI.inkSecondary)
            HStack(spacing: 8) {
                Button { retreat(book: book) } label: { ReaderPagingLabel(title: "上一页", systemImage: "chevron.left") }
                    .buttonStyle(.bordered)
                    .disabled(chapterIndex == 0 && pageIndex == 0)
                    .accessibilityLabel("上一页")
                Spacer(minLength: 4)
                Button { advance(book: book, pages: pages) } label: { ReaderPagingLabel(title: "下一页", systemImage: "chevron.right") }
                    .buttonStyle(.borderedProminent)
                    .tint(ReaderUI.primaryAction)
                    .disabled(chapterIndex == book.chapters.count - 1 && pageIndex >= pages.count - 1)
                    .accessibilityLabel("下一页")
                Button { showDisplaySettings = true } label: {
                    Image(systemName: "textformat.size").frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
                }
                .accessibilityLabel("字体和显示设置")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(height: ReaderUI.bottomBarHeight, alignment: .top)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .top) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private func advance(book: EpubBookModel, pages: [String]) {
        if pageIndex + 1 < pages.count { pageIndex += 1 }
        else if chapterIndex + 1 < book.chapters.count { chapterIndex += 1; pageIndex = 0 }
        updateProgress(book)
    }

    private func retreat(book: EpubBookModel) {
        if pageIndex > 0 { pageIndex -= 1 }
        else if chapterIndex > 0 { chapterIndex -= 1; pageIndex = max(0, book.pages(chapter: chapterIndex, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin).count - 1) }
        updateProgress(book)
    }

    private func updateProgress(_ book: EpubBookModel) {
        updateDisplayedProgress(book)
        cfi = book.cfiForPage(chapter: chapterIndex, page: pageIndex, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin)
        if progressLoaded { onProgress() }
    }

    private func updateDisplayedProgress(_ book: EpubBookModel) {
        let total = book.chapters.indices.reduce(0) { $0 + book.pages(chapter: $1, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin).count }
        let before = book.chapters.indices.prefix(chapterIndex).reduce(0) { $0 + book.pages(chapter: $1, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin).count }
        percentage = min(100, max(0, Double(before + pageIndex + 1) / Double(max(total, 1)) * 100))
        pageNumber = pageIndex + 1
    }

    private func restoreLocation(in book: EpubBookModel) {
        if let cfi, let target = book.page(forCFI: cfi, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin) {
            chapterIndex = target.chapter
            pageIndex = target.page
            return
        }
        // There is no private-locator migration here. If a server lacks a
        // point CFI, the existing page field is the only generic fallback.
        chapterIndex = 0
        let pageCount = book.pages(chapter: chapterIndex, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin).count
        pageIndex = min(max(0, pageNumber - 1), max(pageCount - 1, 0))
    }

    private var readerFont: Font {
        switch fontChoice {
        case 0: return ReaderDynamicTextFont.make(size: CGFloat(layoutFontSize), design: nil)
        case 1: return ReaderDynamicTextFont.make(size: CGFloat(layoutFontSize), design: .serif)
        case 2: return ReaderDynamicTextFont.make(size: CGFloat(layoutFontSize), design: .monospaced)
        default: return ReaderDynamicTextFont.make(size: CGFloat(layoutFontSize))
        }
    }

    private var layoutFontSize: Double { fontSize * Double(readerTextScale) }
    private var layoutLineSpacing: Double { lineSpacing * Double(readerTextScale) }

    private func normalizePage() {
        guard let book else { return }
        let count = book.pages(chapter: chapterIndex, fontSize: layoutFontSize, lineSpacing: layoutLineSpacing, paragraphSpacing: paragraphSpacing, margin: margin).count
        pageIndex = min(pageIndex, max(count - 1, 0))
        updateProgress(book)
    }

    /// A Dynamic Type change repaginates the chapter. Restore from the stored
    /// CFI first so the reader stays at the same text location instead of
    /// treating the previous visual page number as a new reading position.
    private func restorePageForDynamicType() {
        guard let book else { return }
        restoreLocation(in: book)
        updateDisplayedProgress(book)
    }

    private func loadBook() {
        isLoading = true
        error = nil
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let loaded = try EpubBookModel(url: url)
            book = loaded
            restoreLocation(in: loaded)
            updateDisplayedProgress(loaded)
            isLoading = false
        } catch let caughtError {
            book = nil
            isLoading = false
            error = epubFailureReason(caughtError)
        }
    }

    private func epubFailureReason(_ error: Error) -> String {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSFileNoSuchFileError {
            return "文件已不存在或无法访问。"
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty || detail == "The operation couldn’t be completed."
            ? "文件可能已损坏、受保护，或不是有效的 EPUB。"
            : "无法读取 EPUB：\(detail)"
    }

    private func savePreferences() {
        EpubReaderPreferences(paperTone: paperTone).save(storageKey: storageKey)
    }
}

private struct ReaderTextSettings: View {
    @Binding var fontSize: Double
    @Binding var fontChoice: Int
    @Binding var lineSpacing: Double
    @Binding var margin: Double
    @Binding var paperTone: EpubPaperTone
    let dismiss: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("文字") {
                    Stepper("字号 \(Int(fontSize))pt", value: $fontSize, in: 14...28, step: 1)
                    Stepper("行距 \((1 + lineSpacing / max(fontSize, 1)), specifier: "%.2f")x", value: $lineSpacing, in: 7...20, step: 1)
                    Stepper("页面边距 \(Int(margin))pt", value: $margin, in: 8...32, step: 2)
                    Picker("字体", selection: $fontChoice) {
                        Text("无衬线").tag(0)
                        Text("宋体／衬线（默认）").tag(1)
                        Text("等宽").tag(2)
                    }
                }
                Section("页面") {
                    Picker("页面颜色", selection: $paperTone) {
                        ForEach(EpubPaperTone.allCases, id: \.self) { tone in
                            Text(tone.label).tag(tone)
                        }
                    }
                }
            }
            .tint(ReaderUI.primaryAction)
            .navigationTitle("显示设置")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成", action: dismiss) } }
        }
    }
}

private struct ConvertedEpubReaderView: View {
    private enum ConversionState {
        case loading
        case failed(reason: String)
        case ready(URL)
    }

    @Environment(\.dismiss) private var dismiss
    let url: URL
    let format: String
    let storageKey: String
    @Binding var progressLoaded: Bool
    @Binding var percentage: Double
    @Binding var pageNumber: Int
    @Binding var cfi: String?
    let onProgress: () -> Void
    @State private var conversionState: ConversionState = .loading
    @State private var conversionAttempt = UUID()

    var body: some View {
        Group {
            switch conversionState {
            case .ready(let convertedURL):
                EpubReaderView(url: convertedURL, storageKey: storageKey, progressLoaded: progressLoaded, percentage: $percentage, pageNumber: $pageNumber, cfi: $cfi, onProgress: onProgress)
            case .loading:
                VStack(spacing: 12) {
                    ProgressView("正在转换为 EPUB…")
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text("正在准备 \(format.uppercased()) 阅读内容。")
                        .font(.footnote)
                        .foregroundStyle(ReaderUI.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("正在转换 \(url.lastPathComponent) 为 EPUB")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReaderUI.paperCanvas)
            case .failed(let reason):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(ReaderUI.primaryAction)
                        .accessibilityHidden(true)
                    Text("无法转换此文件")
                        .font(.headline)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(ReaderUI.inkSecondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("返回书库") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("重试") { retryConversion() }
                            .buttonStyle(.borderedProminent)
                            .tint(ReaderUI.primaryAction)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ReaderUI.paperCanvas)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("转换失败：\(url.lastPathComponent)。\(reason)")
            }
        }
        .task(id: conversionAttempt) {
            guard case .loading = conversionState else { return }
            do {
                guard let convertedURL = try FormatCoreNativeBridge.convertToInternalEpubFile(source: url, format: format) else {
                    throw FormatCoreNativeBridgeError.invalidResult
                }
                guard FileManager.default.fileExists(atPath: convertedURL.path) else { throw FormatCoreNativeBridgeError.invalidResult }
                conversionState = .ready(convertedURL)
            } catch {
                conversionState = .failed(reason: conversionFailureReason(error))
            }
        }
    }

    private func retryConversion() {
        conversionState = .loading
        conversionAttempt = UUID()
    }

    private func conversionFailureReason(_ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail == "The operation couldn’t be completed." {
            return "文件可能已损坏、受保护，或该 \(format.uppercased()) 变体暂不支持。"
        }
        return "\(detail)"
    }
}

private enum InternalEpubWriter {
    private struct Entry { let name: String; let data: Data }
    private struct MobiImage {
        let name: String
        let mediaType: String
        let data: Data
        var extensionName: String { name.split(separator: ".").last.map(String.init) ?? "bin" }
    }

    private static func write(source: URL, text: String, images: [MobiImage] = []) throws -> URL {
        let bytes = text.data(using: .utf8) ?? Data()
        guard !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024 else { throw WriterError.invalid }
        let rendered = replaceMobiImages(in: text, images: images)
        let title = source.deletingPathExtension().lastPathComponent.xmlEscaped
        let escapedText = rendered.xmlEscaped
            .replacingOccurrences(of: "&lt;img src=&quot;", with: "<img src=\"")
            .replacingOccurrences(of: "&quot; alt=&quot;&quot;/&gt;", with: "\" alt=\"\"/>")
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
        let chapter = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(title)</title></head><body><p>\(escapedText)</p></body></html>"
        var manifest = "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>"
        for (index, image) in images.enumerated() {
            manifest += "<item id=\"image-\(index)\" href=\"Images/\(image.name)\" media-type=\"\(image.mediaType.xmlEscaped)\"/>"
        }
        let opf = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:papria:\(source.lastPathComponent.hashValue)</dc:identifier><dc:title>\(title)</dc:title><dc:language>und</dc:language></metadata><manifest>\(manifest)</manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        let container = "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"
        var entries = [Entry(name: "mimetype", data: Data("application/epub+zip".utf8)), Entry(name: "META-INF/container.xml", data: Data(container.utf8)), Entry(name: "OEBPS/content.opf", data: Data(opf.utf8)), Entry(name: "OEBPS/chapter.xhtml", data: Data(chapter.utf8))]
        entries.append(contentsOf: images.map { Entry(name: "OEBPS/Images/\($0.name)", data: $0.data) })
        let output = try writeZip(entries)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Papria/Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(source.lastPathComponent.hashValue).epub")
        try output.write(to: destination, options: .atomic)
        return destination
    }

    static func writeMobi(source: URL, text: String, input: Data) throws -> URL {
        try write(source: source, text: text, images: mobiImages(input))
    }

    private static func replaceMobiImages(in value: String, images: [MobiImage]) -> String {
        guard !images.isEmpty,
              let regex = try? NSRegularExpression(pattern: "(?is)<img\\b[^>]*>") else { return value }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else { return value }
        var output = ""
        var cursor = value.startIndex
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: value) else { continue }
            output += value[cursor..<range.lowerBound]
            if let image = images[safe: index] {
                output += "<img src=\"Images/\(image.name)\" alt=\"\"/>"
            }
            cursor = range.upperBound
        }
        output += value[cursor...]
        return output
    }

    private static func mobiImages(_ input: Data) -> [MobiImage] {
        guard input.count <= 256 * 1024 * 1024, input.count >= 78 else { return [] }
        let recordCount = Int(input.u16be(at: 76))
        guard recordCount >= 2, input.count >= 78 + recordCount * 8 else { return [] }
        var offsets = (0..<recordCount).map { Int(input.u32be(at: 78 + $0 * 8)) }
        offsets.append(input.count)
        guard offsets.enumerated().dropFirst().allSatisfy({ offsets[$0.offset - 1] <= $0.element && $0.element <= input.count }) else { return [] }
        let first = offsets[0]
        let mobiHeader = first + 16
        guard mobiHeader + 96 <= input.count,
              String(data: input[mobiHeader..<(mobiHeader + 4)], encoding: .ascii) == "MOBI" else { return [] }
        let firstImageIndex = Int(input.u32be(at: mobiHeader + 92))
        guard firstImageIndex >= 0, firstImageIndex < recordCount else { return [] }
        var result: [MobiImage] = []
        var totalBytes = 0
        for index in firstImageIndex..<recordCount {
            let data = input[offsets[index]..<offsets[index + 1]]
            let mediaType: String
            let extensionName: String
            if data.starts(with: [0xff, 0xd8, 0xff]) {
                mediaType = "image/jpeg"; extensionName = "jpg"
            } else if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
                mediaType = "image/png"; extensionName = "png"
            } else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
                mediaType = "image/gif"; extensionName = "gif"
            } else if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WEBP".utf8) {
                mediaType = "image/webp"; extensionName = "webp"
            } else if data.starts(with: Data("BM".utf8)) {
                mediaType = "image/bmp"; extensionName = "bmp"
            } else {
                continue
            }
            guard result.count < 256, data.count <= 32 * 1024 * 1024, totalBytes <= 32 * 1024 * 1024 - data.count else { return [] }
            totalBytes += data.count
            result.append(MobiImage(name: String(format: "mobi-%04d.%@", result.count, extensionName), mediaType: mediaType, data: Data(data)))
        }
        return result
    }

    static func writeFB2(source: URL) throws -> URL {
        let raw = try String(contentsOf: source, encoding: .utf8)
        guard raw.utf8.count <= 256 * 1024 * 1024 else { throw WriterError.invalid }
        struct Binary { let id: String; let mediaType: String; let data: Data; var extensionName: String { switch mediaType.lowercased() { case "image/jpeg", "image/jpg": return "jpg"; case "image/png": return "png"; case "image/gif": return "gif"; case "image/webp": return "webp"; default: return "bin" } } }
        var binaries: [String: Binary] = [:]
        let binaryRegex = try NSRegularExpression(pattern: "(?is)<binary\\b([^>]*)>(.*?)</binary>")
        for match in binaryRegex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let attrs = Range(match.range(at: 1), in: raw).map({ String(raw[$0]) }),
                  let encoded = Range(match.range(at: 2), in: raw).map({ String(raw[$0]) }),
                  let id = attribute("id", in: attrs),
                  let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]), data.count <= 32 * 1024 * 1024 else { continue }
            let media = attribute("content-type", in: attrs) ?? "application/octet-stream"
            binaries[id] = Binary(id: id, mediaType: media, data: data)
        }
        let body = (try? NSRegularExpression(pattern: "(?is)<body\\b[^>]*>(.*?)</body>").firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))).flatMap { Range($0.range(at: 1), in: raw).map { String(raw[$0]) } } ?? raw
        var markup = body
        var imageReplacements: [String: String] = [:]
        let imageRegex = try NSRegularExpression(pattern: "(?is)<image\\b[^>]*?/?>")
        let matches = imageRegex.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)).reversed()
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: markup) else { continue }
            let tag = String(markup[range])
            let href = attribute("l:href", in: tag) ?? attribute("href", in: tag)
            guard let id = href?.hasPrefix("#") == true ? String(href!.dropFirst()) : nil, let binary = binaries[id] else { markup.replaceSubrange(range, with: ""); continue }
            let token = "__PAPRIA_IMAGE_\(index)__"
            imageReplacements[token] = "<img src=\"Images/\(binary.id).\(binary.extensionName)\" alt=\"\"/>"
            markup.replaceSubrange(range, with: token)
        }
        var text = plainMarkupText(markup)
        imageReplacements.forEach { text = text.replacingOccurrences(of: $0.key, with: $0.value) }
        guard !text.isEmpty else { throw WriterError.invalid }
        let title = (try? NSRegularExpression(pattern: "(?is)<book-title\\b[^>]*>(.*?)</book-title>").firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))).flatMap { Range($0.range(at: 1), in: raw).map { plainMarkupText(String(raw[$0])) } }?.ifBlank(source.deletingPathExtension().lastPathComponent) ?? source.deletingPathExtension().lastPathComponent
        let titleXML = title.xmlEscaped
        let renderedText = text.xmlEscaped
            .replacingOccurrences(of: "&lt;img ", with: "<img ")
            .replacingOccurrences(of: "/&gt;", with: "/>")
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
        let chapter = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(titleXML)</title></head><body><p>\(renderedText)</p></body></html>"
        var entries = [Entry(name: "mimetype", data: Data("application/epub+zip".utf8)), Entry(name: "META-INF/container.xml", data: Data("<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8))]
        entries.append(Entry(name: "OEBPS/chapter.xhtml", data: Data(chapter.utf8)))
        var manifest = "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>"
        for binary in binaries.values {
            let href = "Images/\(binary.id).\(binary.extensionName)"
            entries.append(Entry(name: "OEBPS/\(href)", data: binary.data))
            manifest += "<item id=\"img-\(binary.id.xmlEscaped)\" href=\"\(href)\" media-type=\"\(binary.mediaType.xmlEscaped)\"/>"
        }
        let opf = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:papria:\(source.lastPathComponent.hashValue)</dc:identifier><dc:title>\(titleXML)</dc:title><dc:language>und</dc:language></metadata><manifest>\(manifest)<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        let nav = "<?xml version=\"1.0\"?><!DOCTYPE html><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml\">\(titleXML)</a></li></ol></nav></body></html>"
        entries.append(Entry(name: "OEBPS/content.opf", data: Data(opf.utf8)))
        entries.append(Entry(name: "OEBPS/nav.xhtml", data: Data(nav.utf8)))
        let output = try writeZip(entries)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Papria/Converted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(source.lastPathComponent.hashValue)-fb2.epub")
        try output.write(to: destination, options: .atomic)
        return destination
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\\\"([^\\\"]+)\\\"", options: [.caseInsensitive]).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)).flatMap { Range($0.range(at: 1), in: value).map { String(value[$0]) } }
    }

    private static func writeZip(_ entries: [Entry]) throws -> Data {
        var output = Data(); var central = Data()
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.name.utf8); let offset = output.count; let crc = crc32(entry.data)
            output.appendUInt32(0x04034b50); output.appendUInt16(20); output.appendUInt16(0); output.appendUInt16(0); output.appendUInt16(0); output.appendUInt16(0); output.appendUInt32(crc); output.appendUInt32(UInt32(entry.data.count)); output.appendUInt32(UInt32(entry.data.count)); output.appendUInt16(UInt16(name.count)); output.appendUInt16(0); output.append(name); output.append(entry.data)
            central.appendUInt32(0x02014b50); central.appendUInt16(20); central.appendUInt16(20); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt32(crc); central.appendUInt32(UInt32(entry.data.count)); central.appendUInt32(UInt32(entry.data.count)); central.appendUInt16(UInt16(name.count)); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt16(0); central.appendUInt32(0); central.appendUInt32(UInt32(offset)); central.append(name)
            if index > 65_535 { throw WriterError.invalid }
        }
        let centralOffset = output.count; output.append(central); output.appendUInt32(0x06054b50); output.appendUInt16(0); output.appendUInt16(0); output.appendUInt16(UInt16(entries.count)); output.appendUInt16(UInt16(entries.count)); output.appendUInt32(UInt32(central.count)); output.appendUInt32(UInt32(centralOffset)); output.appendUInt16(0)
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 } }
        return ~crc
    }

    private enum WriterError: Error { case invalid }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)]) }
    mutating func appendUInt32(_ value: UInt32) { append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]) }
}

/// Point EPUB CFI support for the reader's progress field. It intentionally
/// accepts only document locations: this reader has no highlights or notes,
/// so range, temporal, and spatial CFIs do not describe a restorable view.
struct EpubCFILocator: Equatable {
    struct Point: Equatable {
        let spineIndex: Int
        let idref: String?
        let contentPath: [Int]
        let contentID: String?
        let textOffset: Int
    }

    private struct Step {
        let number: Int
        let assertion: String?
    }

    private struct Path {
        let steps: [Step]
        let textOffset: Int?
    }

    static func make(spineIndex: Int, idref: String?, contentPath: [Int], textOffset: Int) -> String {
        let safeSpineIndex = max(0, spineIndex)
        // /6 selects the spine element; in the package-document CFI tree
        // its first itemref is /4, yielding the standard /6/14 route for
        // later spine items.
        let spineStep = 2 * (safeSpineIndex + 2)
        let packageAssertion = idref.map { "[\(escapeAssertion($0))]" } ?? ""
        let path = contentPath.filter { $0 > 0 }.map(String.init).joined(separator: "/")
        let content = path.isEmpty ? "/4/2/1" : "/\(path)"
        return "epubcfi(/6/\(spineStep)\(packageAssertion)!\(content):\(max(0, textOffset)))"
    }

    static func parse(_ value: String) -> Point? {
        guard value.hasPrefix("epubcfi("), value.hasSuffix(")") else { return nil }
        let start = value.index(value.startIndex, offsetBy: "epubcfi(".count)
        let body = String(value[start..<value.index(before: value.endIndex)])
        guard let separator = topLevelIndex(of: "!", in: body),
              topLevelIndex(of: "!", in: String(body[body.index(after: separator)...])) == nil else { return nil }
        let package = parsePath(String(body[..<separator]))
        let content = parsePath(String(body[body.index(after: separator)...]))
        guard let package, let content,
              package.steps.count == 2,
              package.steps[0].number == 6,
              package.steps[1].number > 0,
              package.steps[1].number.isMultiple(of: 2),
              !content.steps.isEmpty else { return nil }
        let spineIndex = package.steps[1].number / 2 - 2
        guard spineIndex >= 0 else { return nil }
        return Point(
            spineIndex: spineIndex,
            idref: package.steps[1].assertion,
            contentPath: content.steps.map(\.number),
            contentID: content.steps.reversed().compactMap(\.assertion).first,
            textOffset: content.textOffset ?? 0
        )
    }

    private static func parsePath(_ input: String) -> Path? {
        guard input.first == "/" else { return nil }
        var index = input.startIndex
        var steps: [Step] = []
        var offset: Int?

        while index < input.endIndex {
            guard input[index] == "/" else { return nil }
            index = input.index(after: index)
            let digitStart = index
            while index < input.endIndex, input[index].isNumber { index = input.index(after: index) }
            guard digitStart < index, let number = Int(input[digitStart..<index]), number > 0 else { return nil }

            var assertion: String?
            if index < input.endIndex, input[index] == "[" {
                guard let parsed = parseAssertion(in: input, afterOpeningBracket: index) else { return nil }
                assertion = parsed.value
                index = parsed.nextIndex
            }
            steps.append(Step(number: number, assertion: assertion))

            if index < input.endIndex, input[index] == ":" {
                guard offset == nil else { return nil }
                index = input.index(after: index)
                let offsetStart = index
                while index < input.endIndex, input[index].isNumber { index = input.index(after: index) }
                guard offsetStart < index, let parsedOffset = Int(input[offsetStart..<index]), parsedOffset >= 0 else { return nil }
                offset = parsedOffset
                if index < input.endIndex, input[index] == ";" {
                    let suffix = input[index...]
                    guard suffix == ";s=a" || suffix == ";s=b" else { return nil }
                    index = input.endIndex
                }
                guard index == input.endIndex else { return nil }
            }
        }
        return Path(steps: steps, textOffset: offset)
    }

    private static func parseAssertion(in input: String, afterOpeningBracket opening: String.Index) -> (value: String, nextIndex: String.Index)? {
        var index = input.index(after: opening)
        var escaped = false
        var value = ""
        while index < input.endIndex {
            let character = input[index]
            if escaped {
                value.append(character)
                escaped = false
            } else if character == "^" {
                escaped = true
            } else if character == "]" {
                return (value, input.index(after: index))
            } else if character == "[" {
                return nil
            } else {
                value.append(character)
            }
            index = input.index(after: index)
        }
        return nil
    }

    private static func topLevelIndex(of needle: Character, in value: String) -> String.Index? {
        var escaped = false
        var brackets = 0
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "^" {
                escaped = true
            } else if character == "[" {
                brackets += 1
            } else if character == "]" {
                brackets -= 1
                if brackets < 0 { return nil }
            } else if character == needle, brackets == 0 {
                return index
            }
        }
        return brackets == 0 && !escaped ? nil : nil
    }

    private static func escapeAssertion(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "^[](),;=!".contains(character) { result.append("^") }
            result.append(character)
        }
    }
}

/// Keeps the reader's flattened text and the corresponding XHTML text-node
/// paths together. A CFI offset uses DOM UTF-16 coordinates; layout keeps its
/// existing Swift character offsets and translates only at this boundary.
struct EpubContentCFIIndex {
    struct Location {
        let path: [Int]
        let utf16Offset: Int
    }

    private struct Run {
        var text: String
        var displayStart: Int
        let sourcePath: [Int]?
        var sourceUTF16Start: Int?

        var displayEnd: Int { displayStart + text.count }
    }

    private struct BuildResult {
        let text: String
        let anchors: [String: Int]
        let runs: [Run]
    }

    private struct ElementFrame {
        let name: String
        let path: [Int]
        var elementChildren = 0
        var textChildren = 0
        let suppressText: Bool
    }

    private final class TextBuilder {
        private var output = ""
        private var runs: [Run] = []
        private var outputLength = 0
        private var trailingNewlines = 0

        var currentOffset: Int { outputLength }

        func appendSynthetic(_ value: String) {
            append(value, sourcePath: nil)
        }

        func appendSource(_ value: String, path: [Int]) {
            append(value, sourcePath: path)
        }

        func finish(anchors: [String: Int]) -> BuildResult {
            let leading = output.prefix { isTrimmable($0) }.count
            let trailing = output.reversed().prefix { isTrimmable($0) }.count
            let keptLength = max(0, outputLength - leading - trailing)
            let start = output.index(output.startIndex, offsetBy: min(leading, output.count))
            let end = output.index(output.endIndex, offsetBy: -min(trailing, max(0, output.count - leading)))
            let text = start <= end ? String(output[start..<end]) : ""

            var adjusted: [Run] = []
            for run in runs {
                let keepStart = max(run.displayStart, leading)
                let keepEnd = min(run.displayEnd, leading + keptLength)
                guard keepStart < keepEnd else { continue }
                let prefixLength = keepStart - run.displayStart
                let length = keepEnd - keepStart
                let prefixEnd = run.text.index(run.text.startIndex, offsetBy: prefixLength)
                let keptEnd = run.text.index(prefixEnd, offsetBy: length)
                var kept = Run(text: String(run.text[prefixEnd..<keptEnd]), displayStart: keepStart - leading, sourcePath: run.sourcePath, sourceUTF16Start: run.sourceUTF16Start)
                if let sourceStart = run.sourceUTF16Start {
                    kept.sourceUTF16Start = sourceStart + String(run.text[..<prefixEnd]).utf16.count
                }
                adjusted.append(kept)
            }
            let rebasedAnchors = anchors.reduce(into: [String: Int]()) { result, entry in
                result[entry.key] = min(keptLength, max(0, entry.value - leading))
            }
            return BuildResult(text: text, anchors: rebasedAnchors, runs: adjusted)
        }

        private func append(_ value: String, sourcePath: [Int]?) {
            var sourceOffset = 0
            for character in value {
                defer { sourceOffset += String(character).utf16.count }
                if character == " " || character == "\t" {
                    guard output.last != " " else { continue }
                    appendOutput(" ", sourcePath: sourcePath, sourceUTF16Offset: sourcePath == nil ? nil : sourceOffset)
                } else if character == "\n" {
                    guard trailingNewlines < 2 else { continue }
                    appendOutput(character, sourcePath: sourcePath, sourceUTF16Offset: sourcePath == nil ? nil : sourceOffset)
                } else {
                    appendOutput(character, sourcePath: sourcePath, sourceUTF16Offset: sourcePath == nil ? nil : sourceOffset)
                }
            }
        }

        private func appendOutput(_ character: Character, sourcePath: [Int]?, sourceUTF16Offset: Int?) {
            let string = String(character)
            if character == "\n" {
                trailingNewlines += 1
            } else {
                trailingNewlines = 0
            }
            if var last = runs.last,
               last.sourcePath == sourcePath,
               (sourcePath == nil || (last.sourceUTF16Start.map { $0 + last.text.utf16.count } == sourceUTF16Offset)) {
                last.text.append(character)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(text: string, displayStart: outputLength, sourcePath: sourcePath, sourceUTF16Start: sourceUTF16Offset))
            }
            output.append(character)
            outputLength += 1
        }

        private func isTrimmable(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
        }
    }

    let text: String
    let anchors: [String: Int]
    private let runs: [Run]

    init(markup: String) {
        let result = Self.build(markup: markup)
        text = result.text
        anchors = result.anchors
        runs = result.runs
    }

    func location(forDisplayOffset requestedOffset: Int) -> Location? {
        guard let lastSource = runs.last(where: { $0.sourcePath != nil }) else { return nil }
        let offset = min(max(0, requestedOffset), text.count)
        let run = runs.first { $0.sourcePath != nil && offset >= $0.displayStart && offset < $0.displayEnd }
            ?? runs.first { $0.sourcePath != nil && $0.displayStart >= offset }
            ?? lastSource
        guard let path = run.sourcePath, let sourceStart = run.sourceUTF16Start else { return nil }
        let characterOffset = min(max(0, offset - run.displayStart), run.text.count)
        let index = run.text.index(run.text.startIndex, offsetBy: characterOffset)
        return Location(path: path, utf16Offset: sourceStart + String(run.text[..<index]).utf16.count)
    }

    func displayOffset(forPath path: [Int], utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0 else { return nil }
        let matching = runs.filter { run in
            guard let sourcePath = run.sourcePath else { return false }
            return sourcePath == path || (path.last?.isMultiple(of: 2) == true && sourcePath.starts(with: path))
        }
        for run in matching {
            guard let sourceStart = run.sourceUTF16Start else { continue }
            let sourceEnd = sourceStart + run.text.utf16.count
            guard utf16Offset >= sourceStart, utf16Offset <= sourceEnd else { continue }
            let view = run.text.utf16
            let utf16Index = view.index(view.startIndex, offsetBy: utf16Offset - sourceStart)
            guard let stringIndex = String.Index(utf16Index, within: run.text) else { return nil }
            return run.displayStart + run.text.distance(from: run.text.startIndex, to: stringIndex)
        }
        return nil
    }

    private static func build(markup: String) -> BuildResult {
        let builder = TextBuilder()
        var anchors: [String: Int] = [:]
        var frames = [ElementFrame(name: "__root__", path: [], suppressText: false)]
        var index = markup.startIndex

        while index < markup.endIndex {
            guard markup[index] == "<" else {
                let end = markup[index...].firstIndex(of: "<") ?? markup.endIndex
                if !frames.last!.suppressText {
                    frames[frames.count - 1].textChildren += 1
                    let path = frames.last!.path + [frames.last!.textChildren * 2 - 1]
                    builder.appendSource(decodeEntities(String(markup[index..<end])), path: path)
                }
                index = end
                continue
            }

            if markup[index...].hasPrefix("<!--") {
                let searchStart = markup.index(index, offsetBy: 4)
                if let closing = markup.range(of: "-->", range: searchStart..<markup.endIndex) {
                    if !frames.last!.suppressText { builder.appendSynthetic(" ") }
                    index = closing.upperBound
                } else {
                    break
                }
                continue
            }

            guard let end = tagEnd(in: markup, from: index) else {
                if !frames.last!.suppressText {
                    frames[frames.count - 1].textChildren += 1
                    let path = frames.last!.path + [frames.last!.textChildren * 2 - 1]
                    builder.appendSource(decodeEntities(String(markup[index...])), path: path)
                }
                break
            }
            let tag = String(markup[index...end])
            index = markup.index(after: end)
            handle(tag: tag, frames: &frames, anchors: &anchors, builder: builder)
        }
        return builder.finish(anchors: anchors)
    }

    private static func handle(tag: String, frames: inout [ElementFrame], anchors: inout [String: Int], builder: TextBuilder) {
        guard tag.count >= 3 else { return }
        let inside = String(tag.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inside.isEmpty else { return }
        if inside.first == "!" || inside.first == "?" {
            if !frames.last!.suppressText { builder.appendSynthetic(" ") }
            return
        }

        let isClosing = inside.first == "/"
        let rawName = isClosing ? String(inside.dropFirst()) : inside
        guard let name = tagName(rawName) else {
            if !frames.last!.suppressText { builder.appendSynthetic(" ") }
            return
        }
        let isVoid = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"].contains(name)
        let isSelfClosing = inside.hasSuffix("/") || isVoid

        if isClosing {
            guard let frameIndex = frames.lastIndex(where: { $0.name == name }) else {
                if !frames.last!.suppressText { builder.appendSynthetic(" ") }
                return
            }
            let frame = frames[frameIndex]
            frames.removeSubrange(frameIndex..<frames.count)
            guard !frame.suppressText else { return }
            if ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "section", "article", "tr", "title"].contains(name) {
                builder.appendSynthetic("\n\n")
            } else {
                builder.appendSynthetic(" ")
            }
            return
        }

        let suppressed = frames.last!.suppressText
        if name == "br" {
            if !suppressed { builder.appendSynthetic("\n") }
            return
        }
        let path: [Int]
        if name == "html", frames.count == 1 {
            // CFI paths are relative to the content document root. Its
            // element children therefore start at /2; with a normal XHTML
            // head before body, body is /4 and its first paragraph is /2.
            path = []
        } else {
            frames[frames.count - 1].elementChildren += 1
            path = frames.last!.path + [frames.last!.elementChildren * 2]
        }
        let suppressText = suppressed || name == "script" || name == "style" || name == "head" || name == "title"
        if !suppressed && !suppressText { builder.appendSynthetic(" ") }
        if !suppressed && !suppressText,
           let anchor = attribute("id", in: tag) ?? attribute("name", in: tag),
           !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           anchors[anchor] == nil {
            anchors[anchor] = builder.currentOffset
        }
        if !isSelfClosing {
            frames.append(ElementFrame(name: name, path: path, suppressText: suppressText))
        }
    }

    private static func tagEnd(in markup: String, from start: String.Index) -> String.Index? {
        var index = markup.index(after: start)
        var quote: Character?
        while index < markup.endIndex {
            let character = markup[index]
            if quote != nil {
                if character == quote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = markup.index(after: index)
        }
        return nil
    }

    private static func tagName(_ input: String) -> String? {
        let name = input.drop { $0.isWhitespace || $0 == "/" }.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "_" || $0 == "-" }
        guard !name.isEmpty else { return nil }
        return name.lowercased()
    }

    private static func attribute(_ name: String, in value: String) -> String? {
        try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(['\\\"])(.*?)\\1", options: [.caseInsensitive]).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)).flatMap { Range($0.range(at: 2), in: value).map { decodeEntities(String(value[$0])) } }
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

private extension String {
    var xmlEscaped: String { replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
}

struct EpubBookModel {
    struct Chapter {
        let id: String
        let spineIndex: Int
        let href: String
        let title: String
        let text: String
        let anchors: [String: Int]
        fileprivate let cfiIndex: EpubContentCFIIndex
    }
    struct TocItem { let title: String; let href: String; let depth: Int }
    private struct ManifestItem {
        let href: String
        let mediaType: String
        let properties: Set<String>
    }
    let title: String
    let chapters: [Chapter]
    let toc: [TocItem]

    init(url: URL) throws {
        let archive = try PapriaZipArchive(url: url)
        if archive.entries.contains(where: { $0.name == "META-INF/rights.xml" || $0.name == "META-INF/encryption.xml" }) {
            throw EpubError.encrypted
        }
        guard let containerEntry = archive.entries.first(where: { $0.name == "META-INF/container.xml" }) else { throw EpubError.invalid }
        let container = try String(decoding: archive.data(for: containerEntry), as: UTF8.self)
        guard let opfPath = Self.attribute("full-path", in: container) else { throw EpubError.invalid }
        guard let opfEntry = archive.entries.first(where: { $0.name == Self.safePath(opfPath) }) else { throw EpubError.invalid }
        let opf = try String(decoding: archive.data(for: opfEntry), as: UTF8.self)
        let base = opfPath.split(separator: "/").dropLast().joined(separator: "/")
        var manifest: [String: ManifestItem] = [:]
        var navigationHref: String?
        let itemRegex = try NSRegularExpression(pattern: "<item\\b([^>]*)/?>", options: [.caseInsensitive])
        for match in itemRegex.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
            guard let raw = Range(match.range(at: 1), in: opf).map({ String(opf[$0]) }), let id = Self.attribute("id", in: raw), let href = Self.attribute("href", in: raw), let media = Self.attribute("media-type", in: raw) else { continue }
            let properties = Set(Self.attribute("properties", in: raw)?.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init) ?? [])
            manifest[id] = ManifestItem(href: Self.safePath(Self.resolve(base, href)), mediaType: media, properties: properties)
            if properties.contains("nav") {
                navigationHref = Self.safePath(Self.resolve(base, href))
            }
        }
        let spine = try NSRegularExpression(pattern: "<itemref\\b[^>]*\\bidref\\s*=\\s*\"([^\"]+)\"", options: [.caseInsensitive])
        let ids = spine.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)).compactMap { Range($0.range(at: 1), in: opf).map { String(opf[$0]) } }
        chapters = ids.enumerated().compactMap { spineIndex, id in
            guard let item = manifest[id], ["application/xhtml+xml", "text/html", "application/x-dtbook+xml"].contains(item.mediaType), let entry = archive.entries.first(where: { $0.name == item.href }), let markup = try? String(decoding: archive.data(for: entry), as: UTF8.self) else { return nil }
            let cfiIndex = EpubContentCFIIndex(markup: markup)
            return Chapter(id: id, spineIndex: spineIndex, href: item.href, title: Self.title(from: markup).ifBlank(id), text: cfiIndex.text, anchors: cfiIndex.anchors, cfiIndex: cfiIndex)
        }
        let titleRegex = try NSRegularExpression(pattern: "<dc:title\\b[^>]*>(.*?)</dc:title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        title = titleRegex.firstMatch(in: opf, range: NSRange(opf.startIndex..., in: opf)).flatMap { Range($0.range(at: 1), in: opf).map { plainMarkupText(String(opf[$0])) } }?.ifBlank(url.deletingPathExtension().lastPathComponent) ?? url.deletingPathExtension().lastPathComponent
        if let navigationHref, let navEntry = archive.entries.first(where: { $0.name == navigationHref }), let navMarkup = try? String(decoding: archive.data(for: navEntry), as: UTF8.self) {
            let navBase = navigationHref.split(separator: "/").dropLast().joined(separator: "/")
            let linkRegex = try? NSRegularExpression(pattern: "<a\\b[^>]*href\\s*=\\s*\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let navItems: [TocItem] = linkRegex?.matches(in: navMarkup, range: NSRange(navMarkup.startIndex..., in: navMarkup)).compactMap { match in
                guard let href = Range(match.range(at: 1), in: navMarkup).map({ String(navMarkup[$0]) }), let rawTitle = Range(match.range(at: 2), in: navMarkup).map({ String(navMarkup[$0]) }) else { return nil }
                let title = plainMarkupText(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return TocItem(title: title, href: Self.safePath(Self.resolve(navBase, href)), depth: 0)
            } ?? []
            if !navItems.isEmpty {
                toc = navItems
            } else {
                toc = Self.ncxToc(archive: archive, manifest: manifest, spine: opf)
            }
        } else {
            // EPUB 2 uses an NCX file referenced by spine@toc. Keep the
            // parser bounded and dependency-free; navigation links still
            // resolve to XHTML anchors and retain their hierarchy depth.
            let spineTag = (try? NSRegularExpression(pattern: "<spine\\b([^>]*)>", options: [.caseInsensitive]))?.firstMatch(in: opf, range: NSRange(opf.startIndex..., in: opf)).flatMap { Range($0.range(at: 1), in: opf).map { String(opf[$0]) } }
            toc = Self.ncxToc(archive: archive, manifest: manifest, spine: spineTag ?? "")
        }
    }

    func pages(chapter index: Int, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> [String] {
        guard let text = chapters[safe: index]?.text else { return [""] }
        let maxChars = Int(max(600, min(1800, 2600 - fontSize * 65 - lineSpacing * 12 - paragraphSpacing * 24 - margin * 8)))
        var result: [String] = []; var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: min(maxChars, text.distance(from: start, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let split = text[..<end].lastIndex(where: { $0 == " " || $0 == "\n" }), split > start { end = split }
            result.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)); start = end
            while start < text.endIndex, text[start].isWhitespace { start = text.index(after: start) }
        }
        return result.isEmpty ? [""] : result
    }

    func offsetForPage(chapter index: Int, page: Int, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> Int {
        guard let text = chapters[safe: index]?.text else { return 0 }
        let maxChars = Int(max(600, min(1800, 2600 - fontSize * 65 - lineSpacing * 12 - paragraphSpacing * 24 - margin * 8)))
        guard !text.isEmpty else { return 0 }
        var current = text.startIndex; var pageIndex = 0
        while current < text.endIndex {
            if pageIndex >= page { return text.distance(from: text.startIndex, to: current) }
            var end = text.index(current, offsetBy: min(maxChars, text.distance(from: current, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let split = text[..<end].lastIndex(where: { $0 == " " || $0 == "\n" }), split > current { end = split }
            current = end
            while current < text.endIndex, text[current].isWhitespace { current = text.index(after: current) }
            pageIndex += 1
        }
        return text.distance(from: text.startIndex, to: current)
    }

    func pageForOffset(chapter index: Int, offset: Int, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> Int {
        guard let text = chapters[safe: index]?.text, !text.isEmpty else { return 0 }
        let target = min(max(0, offset), text.count)
        let maxChars = Int(max(600, min(1800, 2600 - fontSize * 65 - lineSpacing * 12 - paragraphSpacing * 24 - margin * 8)))
        var current = text.startIndex; var page = 0
        while current < text.endIndex {
            let startOffset = text.distance(from: text.startIndex, to: current)
            if startOffset > target { return max(0, page - 1) }
            var end = text.index(current, offsetBy: min(maxChars, text.distance(from: current, to: text.endIndex)), limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let split = text[..<end].lastIndex(where: { $0 == " " || $0 == "\n" }), split > current { end = split }
            current = end
            while current < text.endIndex, text[current].isWhitespace { current = text.index(after: current) }
            page += 1
        }
        return max(0, page - 1)
    }

    func chapterIndex(for href: String) -> Int {
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? href
        return chapters.firstIndex { $0.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) == path } ?? -1
    }

    func page(for href: String, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> (chapter: Int, page: Int)? {
        let chapter = chapterIndex(for: href)
        guard chapter >= 0 else { return nil }
        let fragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init) ?? ""
        return (chapter, pageForOffset(chapter: chapter, offset: chapters[chapter].anchors[fragment] ?? 0, fontSize: fontSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, margin: margin))
    }

    func cfiForPage(chapter: Int, page: Int, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> String {
        cfiForOffset(chapter: chapter, offset: offsetForPage(chapter: chapter, page: page, fontSize: fontSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, margin: margin))
    }

    /// Emits a point EPUB CFI rooted in the OPF spine and the XHTML text node.
    /// The text offset is UTF-16, matching DOM Range offsets used by native
    /// EPUB engines rather than Swift's grapheme-count paginator.
    func cfiForOffset(chapter index: Int, offset: Int) -> String {
        guard let chapter = chapters[safe: index],
              let content = chapter.cfiIndex.location(forDisplayOffset: offset) else {
            return EpubCFILocator.make(spineIndex: 0, idref: nil, contentPath: [4, 2, 1], textOffset: 0)
        }
        return EpubCFILocator.make(spineIndex: chapter.spineIndex, idref: chapter.id, contentPath: content.path, textOffset: content.utf16Offset)
    }

    /// Restores a standard point CFI from BookOrbit or another EPUB reader.
    /// Selection/range CFIs deliberately stay outside this non-annotation
    /// reader; an unsupported CFI returns nil and the caller falls back to
    /// the generic percentage/page position.
    func page(forCFI value: String, fontSize: Double, lineSpacing: Double = 6, paragraphSpacing: Double = 0, margin: Double = 12) -> (chapter: Int, page: Int)? {
        guard let locator = EpubCFILocator.parse(value) else { return nil }
        let chapterIndex = locator.idref.flatMap { id in chapters.firstIndex { $0.id == id } }
            ?? chapters.firstIndex { $0.spineIndex == locator.spineIndex }
        guard let chapterIndex, let chapter = chapters[safe: chapterIndex] else { return nil }
        let offset = chapter.cfiIndex.displayOffset(forPath: locator.contentPath, utf16Offset: locator.textOffset)
            ?? locator.contentID.flatMap { chapter.anchors[$0] }.map { anchor in min(chapter.text.count, anchor + locator.textOffset) }
        guard let offset else { return nil }
        return (chapterIndex, pageForOffset(chapter: chapterIndex, offset: offset, fontSize: fontSize, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing, margin: margin))
    }

    private enum EpubError: Error { case invalid, encrypted }
    private static func attribute(_ name: String, in value: String) -> String? {
        try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(['\\\"])(.*?)\\1", options: [.caseInsensitive]).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)).flatMap { Range($0.range(at: 2), in: value).map { String(value[$0]) } }
    }
    private static func resolve(_ base: String, _ href: String) -> String {
        let fragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map { "#\($0)" } ?? ""
        let path = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
        let resolved = (base.isEmpty ? path : "\(base)/\(path)").split(separator: "/").reduce(into: [String]()) { part, item in if item == ".." { _ = part.popLast() } else if item != "." { part.append(String(item).removingPercentEncoding ?? String(item)) } }.joined(separator: "/")
        return safePath(resolved + fragment)
    }
    private static func safePath(_ path: String) -> String { path.replacingOccurrences(of: "%20", with: " ").split(separator: "/").filter { !$0.isEmpty && $0 != ".." }.joined(separator: "/") }
    private static func title(from markup: String) -> String { (try? NSRegularExpression(pattern: "<title\\b[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])).flatMap { $0.firstMatch(in: markup, range: NSRange(markup.startIndex..., in: markup)).flatMap { Range($0.range(at: 1), in: markup).map { plainMarkupText(String(markup[$0])) } } } ?? "" }

    private static func anchors(from markup: String, text: String) -> [String: Int] {
        guard !markup.isEmpty, !text.isEmpty, let regex = try? NSRegularExpression(pattern: "(?is)<[A-Za-z][^>]*\\b(?:id|name)\\s*=\\s*([\"'])(.*?)\\1[^>]*>") else { return [:] }
        var result: [String: Int] = [:]
        for match in regex.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)) {
            guard let id = Range(match.range(at: 2), in: markup).map({ String(markup[$0]) })?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let prefix = Range(NSRange(location: 0, length: match.range.location), in: markup) else { continue }
            result[id] = result[id] ?? min(text.count, plainMarkupText(String(markup[prefix])).count)
        }
        return result
    }

    private static func parseNCX(_ markup: String, base: String) -> [TocItem] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)</?navPoint\\b[^>]*>|<text\\b[^>]*>(.*?)</text>|<content\\b([^>]*)/?>") else { return [] }
        var result: [TocItem] = []; var depth = 0; var pending = ""
        for match in regex.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)) {
            guard let whole = Range(match.range, in: markup).map({ String(markup[$0]) }) else { continue }
            if whole.hasPrefix("</") { depth = max(0, depth - 1) }
            else if whole.lowercased().hasPrefix("<navpoint") { depth += 1 }
            else if whole.lowercased().hasPrefix("<text"), let raw = Range(match.range(at: 1), in: markup).map({ String(markup[$0]) }) { pending = plainMarkupText(raw).trimmingCharacters(in: .whitespacesAndNewlines) }
            else if whole.lowercased().hasPrefix("<content"), let attrs = Range(match.range(at: 2), in: markup).map({ String(markup[$0]) }), let src = attribute("src", in: attrs), !pending.isEmpty {
                result.append(TocItem(title: pending, href: resolve(base, src), depth: max(0, depth - 1))); pending = ""
            }
        }
        return result
    }

    private static func ncxToc(archive: PapriaZipArchive, manifest: [String: ManifestItem], spine: String) -> [TocItem] {
        let ncxID = attribute("toc", in: spine)
        let ncxItem = ncxID.flatMap { manifest[$0] } ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }
        guard let ncxItem, let ncxEntry = archive.entries.first(where: { $0.name == ncxItem.href }), let ncxMarkup = try? String(decoding: archive.data(for: ncxEntry), as: UTF8.self) else { return [] }
        let ncxBase = ncxItem.href.split(separator: "/").dropLast().joined(separator: "/")
        return parseNCX(ncxMarkup, base: ncxBase)
    }
}

private extension String {
    func ifBlank(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self }
}

private struct PalmDocTextView: View {
    let url: URL
    @State private var text = "正在读取…"
    var body: some View {
        ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .task {
                do { text = try palmDocText(Data(contentsOf: url)) }
                catch { text = "无法读取 MOBI/AZW：\(error.localizedDescription)" }
            }
    }
}

enum EpubPaperTone: String, Codable, CaseIterable {
    case warm
    case moss
    case night

    var label: String {
        switch self {
        case .warm: return "纸色：暖白"
        case .moss: return "纸色：护眼"
        case .night: return "纸色：夜读"
        }
    }

    var next: EpubPaperTone {
        let tones = Self.allCases
        guard let index = tones.firstIndex(of: self) else { return .warm }
        return tones[(index + 1) % tones.count]
    }

    var color: Color {
        switch self {
        case .warm: return ReaderUI.paperCanvas
        case .moss: return Color(red: 0.91, green: 0.94, blue: 0.84)
        case .night: return Color(red: 0.08, green: 0.10, blue: 0.12)
        }
    }

    var ink: Color {
        self == .night ? Color(red: 0.91, green: 0.93, blue: 0.95) : ReaderUI.inkPrimary
    }
}

struct EpubReaderPreferences: Codable, Equatable {
    let paperTone: EpubPaperTone

    static func load(storageKey: String) -> EpubReaderPreferences {
        guard let data = UserDefaults.standard.data(forKey: key(storageKey)),
              let value = try? JSONDecoder().decode(EpubReaderPreferences.self, from: data) else {
            return EpubReaderPreferences(paperTone: .warm)
        }
        return value
    }

    func save(storageKey: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(storageKey))
    }

    static func key(_ storageKey: String) -> String { "papria.reader.epub.settings.\(storageKey)" }
}

enum PDFZoomMode: String, Codable, Equatable {
    case fitPage
    case fitWidth
    case manual
}

/// PDF page position remains the strict BookOrbit `pageNumber` value in
/// reading_progress. These local settings persist the other half of a PDF
/// reading position—the scale and fit policy—without adding protocol fields.
struct PDFReaderPreferences: Codable, Equatable {
    let zoomMode: PDFZoomMode
    let zoomScale: CGFloat
    let rotation: Int
    let continuous: Bool
    let horizontal: Bool

    static func load(storageKey: String) -> PDFReaderPreferences {
        guard let data = UserDefaults.standard.data(forKey: key(storageKey)),
              let value = try? JSONDecoder().decode(PDFReaderPreferences.self, from: data) else {
            return PDFReaderPreferences(zoomMode: .fitPage, zoomScale: 1, rotation: 0, continuous: true, horizontal: false)
        }
        return value
    }

    func save(storageKey: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(storageKey))
    }

    static func key(_ storageKey: String) -> String { "papria.reader.pdf.settings.\(storageKey)" }
}

/// Reader display preferences are local UI state, not BookOrbit progress
/// fields. Keeping them in UserDefaults lets PDF/comic pages restore fit,
/// rotation and direction without changing the strict progress contract.
private struct ReaderDisplayPreferences: Codable {
    let fitWidth: Bool
    let rotation: Int
    let continuous: Bool
    let horizontal: Bool
    let zoom: CGFloat
    let reverse: Bool

    static func load(storageKey: String) -> ReaderDisplayPreferences {
        let key = "papria.reader.display.\(storageKey)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(ReaderDisplayPreferences.self, from: data) else {
            return ReaderDisplayPreferences(fitWidth: true, rotation: 0, continuous: false, horizontal: false, zoom: 0, reverse: false)
        }
        return value
    }

    func save(storageKey: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: "papria.reader.display.\(storageKey)")
    }
}

private struct ComicReaderView: View {
    let url: URL
    let format: String
    let storageKey: String
    @Binding var pageNumber: Int
    @Binding var totalPages: Int
    @Binding var percentage: Double
    let onProgress: () -> Void
    @State private var archive: ComicArchiveModel?
    @State private var entries: [ComicArchiveModel.Entry] = []
    @State private var image: UIImage?
    @State private var scale = 1.0
    @State private var offset = CGSize.zero
    @State private var fitWidth = false
    @State private var continuous = false
    @State private var reverse = false
    @State private var rotation = 0
    @State private var isLoading = true
    @State private var failureReason: String?
    @State private var loadAttempt = UUID()

    init(url: URL, format: String, storageKey: String, pageNumber: Binding<Int>, totalPages: Binding<Int>, percentage: Binding<Double>, onProgress: @escaping () -> Void) {
        self.url = url
        self.format = format
        self.storageKey = storageKey
        self._pageNumber = pageNumber
        self._totalPages = totalPages
        self._percentage = percentage
        self.onProgress = onProgress
        let preferences = ReaderDisplayPreferences.load(storageKey: storageKey)
        _fitWidth = State(initialValue: preferences.fitWidth)
        _continuous = State(initialValue: preferences.continuous)
        _reverse = State(initialValue: preferences.reverse)
        _rotation = State(initialValue: preferences.rotation)
        _scale = State(initialValue: preferences.zoom > 0 ? preferences.zoom : 1)
    }

    var body: some View {
        Group {
            if let failureReason {
                ReaderFailureView(
                    fileURL: url,
                    title: "无法打开漫画",
                    reason: failureReason,
                    retry: retryLoading
                )
            } else if isLoading {
                ProgressView("正在读取漫画…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在读取 \(url.lastPathComponent)")
            } else {
                comicReader
            }
        }
        .task(id: loadAttempt) {
            do {
                let loaded = try ComicArchiveModel(url: url, format: format)
                guard !loaded.entries.isEmpty else {
                    throw ComicReaderError.noImages
                }
                archive = loaded
                entries = loaded.entries
                totalPages = entries.count
                pageNumber = min(max(pageNumber, 1), max(entries.count, 1))
                updatePercentage()
                loadPage()
                isLoading = false
            } catch {
                archive = nil
                entries = []
                image = nil
                isLoading = false
                failureReason = comicFailureReason(error)
            }
        }
        .onChange(of: pageNumber) { _ in
            guard !isLoading, failureReason == nil else { return }
            loadPage()
        }
    }

    private var comicReader: some View {
        VStack(spacing: 8) {
            if continuous, let archive {
                continuousReader(archive: archive)
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: fitWidth ? .infinity : 380)
                    .scaleEffect(scale)
                    .offset(offset)
                    .rotationEffect(.degrees(Double(rotation)))
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture().onChanged { scale = min(5, max(1, $0)) },
                            DragGesture().onChanged { offset = $0.translation },
                        )
                    )
                    .onTapGesture(count: 2) {
                        scale = scale > 1.2 ? 1 : 2
                        if scale == 1 { offset = .zero }
                        savePreferences()
                    }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PapriaDesign.space2) {
                    Button("上一页") { pageNumber = max(1, pageNumber - 1); loadPage(); onProgress() }
                        .disabled(pageNumber <= 1)
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Text("\(pageNumber) / \(max(entries.count, 1))")
                        .monospacedDigit()
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button("下一页") { pageNumber = min(max(entries.count, 1), pageNumber + 1); loadPage(); onProgress() }
                        .disabled(pageNumber >= entries.count)
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button("适合页面") { scale = 1; offset = .zero; fitWidth = false; savePreferences() }
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button(fitWidth ? "适合页面" : "适合宽度") { fitWidth.toggle(); scale = 1; offset = .zero; savePreferences() }
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button(continuous ? "单页" : "连续") { continuous.toggle(); savePreferences() }
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button(reverse ? "从左到右" : "从右到左") { reverse.toggle(); loadPage(); savePreferences() }
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                    Button("旋转") { rotation = (rotation + 90) % 360; savePreferences() }
                        .frame(minHeight: PapriaDesign.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minHeight: PapriaDesign.minimumHitTarget)
                .padding(.horizontal, PapriaDesign.space4)
            }
        }
    }

    private func continuousReader(archive: ComicArchiveModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(entries.indices, id: \.self) { visibleIndex in
                    let archiveIndex = reverse ? entries.count - visibleIndex - 1 : visibleIndex
                    let displayedPage = visibleIndex + 1
                    if let entry = entries[safe: archiveIndex] {
                        ComicContinuousPage(
                            archive: archive,
                            entry: entry,
                            pageNumber: displayedPage,
                            rotation: rotation,
                            onFailure: { reason in
                                failureReason = reason
                            }
                        )
                        .onAppear {
                            guard pageNumber != displayedPage else { return }
                            pageNumber = displayedPage
                            updatePercentage()
                            onProgress()
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func loadPage() {
        updatePercentage()
        let visualIndex = reverse ? entries.count - pageNumber : pageNumber - 1
        guard let entry = entries[safe: visualIndex], let archive else {
            failureReason = "找不到当前漫画页面。"
            return
        }
        do {
            let data = try archive.data(for: entry)
            guard let decodedImage = UIImage(data: data) else {
                failureReason = "第 \(pageNumber) 页图像无法解码。"
                return
            }
            image = decodedImage
        } catch {
            failureReason = comicFailureReason(error, pageNumber: pageNumber)
        }
    }

    private func updatePercentage() {
        percentage = entries.isEmpty ? 0 : Double(pageNumber) / Double(entries.count) * 100
    }

    private func savePreferences() {
        ReaderDisplayPreferences(
            fitWidth: fitWidth,
            rotation: rotation,
            continuous: continuous,
            horizontal: false,
            zoom: scale,
            reverse: reverse
        ).save(storageKey: storageKey)
    }

    private func retryLoading() {
        archive = nil
        entries = []
        image = nil
        failureReason = nil
        isLoading = true
        loadAttempt = UUID()
    }

    private func comicFailureReason(_ error: Error, pageNumber: Int? = nil) -> String {
        let prefix = pageNumber.map { "第 \($0) 页" } ?? "该漫画文件"
        if let archiveError = error as? ComicArchiveModel.Error {
            switch archiveError {
            case .invalid:
                return "\(prefix) 不是有效的漫画压缩包，或文件已损坏。"
            case .encrypted:
                return "\(prefix) 受密码保护，当前无法打开。"
            case .compressed:
                return "\(prefix) 使用了当前不支持的压缩方式。"
            case .unsupported:
                return "\(prefix) 的格式暂不支持。"
            case .tooLarge:
                return "\(prefix) 超出设备可安全打开的大小限制。"
            }
        }
        if let readerError = error as? ComicReaderError {
            return readerError.localizedDescription
        }
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty || detail == "The operation couldn’t be completed."
            ? "\(prefix) 无法读取。"
            : "\(prefix) 无法读取：\(detail)"
    }
}

private enum ComicReaderError: LocalizedError {
    case noImages

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "文件中没有可阅读的漫画图像。"
        }
    }
}

/// A lazy single-page decoder keeps continuous comic scrolling bounded: only
/// visible pages are decoded, while the parent reader remains responsible for
/// saving the current logical page number.
private struct ComicContinuousPage: View {
    let archive: ComicArchiveModel
    let entry: ComicArchiveModel.Entry
    let pageNumber: Int
    let rotation: Int
    let onFailure: (String) -> Void
    @State private var image: UIImage?
    @State private var failureReason: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .rotationEffect(.degrees(Double(rotation)))
                    .accessibilityLabel("漫画第 \(pageNumber) 页")
            } else if let failureReason {
                Label(failureReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(ReaderUI.primaryAction)
                    .multilineTextAlignment(.center)
                    .padding(16)
            } else {
                ProgressView("正在载入第 \(pageNumber) 页…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task(id: entry.name) {
            do {
                let data = try archive.data(for: entry)
                guard let decoded = UIImage(data: data) else {
                    throw ComicContinuousPageError.cannotDecode
                }
                image = decoded
            } catch {
                let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = detail.isEmpty || detail == "The operation couldn’t be completed."
                    ? "第 \(pageNumber) 页图像无法解码。"
                    : "第 \(pageNumber) 页无法读取：\(detail)"
                failureReason = reason
                onFailure(reason)
            }
        }
    }
}

private enum ComicContinuousPageError: LocalizedError {
    case cannotDecode

    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "图像数据无法解码"
        }
    }
}

/// iOS comic archive boundary. ZIP uses the bounded Swift reader and RAR/7z
/// use Apple's system libarchive decoder. Files are streamed one member at a
/// time with an explicit size limit; encrypted archives are rejected.
final class ComicArchiveModel {
    struct Entry { let name: String; let size: Int64 }
    enum Error: Swift.Error { case invalid, encrypted, compressed, unsupported, tooLarge }
    private let url: URL
    private let format: String
    let entries: [Entry]

    init(url: URL, format: String) throws {
        self.url = url; self.format = format.lowercased()
        switch self.format {
        case "cbz":
            try FormatCoreNativeBridge.inspectComicArchive(source: url, expectedKind: "ZIP")
            let zip = try PapriaZipArchive(url: url)
            entries = zip.entries.filter(Self.isImage).map { Entry(name: $0.name, size: Int64($0.uncompressedSize)) }.sorted { $0.name < $1.name }
        case "cbr":
            try FormatCoreNativeBridge.inspectComicArchive(source: url, expectedKind: "RAR")
            entries = try LibArchiveComic.entries(at: url)
        case "cb7":
            try FormatCoreNativeBridge.inspectComicArchive(source: url, expectedKind: "SEVEN_ZIP")
            entries = try LibArchiveComic.entries(at: url)
        default:
            throw Error.unsupported
        }
    }

    func data(for entry: Entry) throws -> Data {
        if format == "cbz" {
            let zip = try PapriaZipArchive(url: url)
            guard let original = zip.entries.first(where: { $0.name == entry.name }) else { throw Error.invalid }
            return try zip.data(for: original)
        }
        return try LibArchiveComic.data(at: url, named: entry.name, maxBytes: Self.MAX_IMAGE_BYTES)
    }
    private static func isImage(_ entry: PapriaZipArchive.Entry) -> Bool { isImageName(entry.name) && entry.uncompressedSize <= 256 * 1024 * 1024 }
    static func isImageName(_ name: String) -> Bool { let parts = name.split(separator: "/"); guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."), let suffix = name.split(separator: ".").last?.lowercased() else { return false }; return ["jpg", "jpeg", "png", "webp", "gif", "bmp"].contains(suffix) }
    private static let MAX_IMAGE_BYTES: Int64 = 256 * 1024 * 1024
}

enum LibArchiveComic {
    static func validate(at url: URL) throws { _ = try entries(at: url) }
    static func entries(at url: URL) throws -> [ComicArchiveModel.Entry] {
        let reader = try open(url)
        defer { close(reader) }
        var result: [ComicArchiveModel.Entry] = []
        var names = Set<String>()
        var entryCount = 0
        var totalUncompressed: Int64 = 0
        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let pointer = archive_entry_pathname(entry), let name = String(validatingUTF8: pointer) else { if status != ARCHIVE_OK { throw ComicArchiveModel.Error.invalid }; continue }
            entryCount += 1
            guard entryCount <= 10_000, isSafeMember(name) else { throw ComicArchiveModel.Error.invalid }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= 256 * 1024 * 1024 else { throw ComicArchiveModel.Error.tooLarge }
            let total = totalUncompressed.addingReportingOverflow(size)
            guard !total.overflow, total.partialValue <= 1024 * 1024 * 1024 else { throw ComicArchiveModel.Error.tooLarge }
            totalUncompressed = total.partialValue
            guard names.insert(name).inserted else { throw ComicArchiveModel.Error.invalid }
            if ComicArchiveModel.isImageName(name) {
                result.append(ComicArchiveModel.Entry(name: name, size: size))
            }
            _ = archive_read_data_skip(reader)
        }
        return result.sorted { $0.name < $1.name }
    }

    static func data(at url: URL, named name: String, maxBytes: Int64) throws -> Data {
        let reader = try open(url)
        defer { close(reader) }
        while true {
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { throw ComicArchiveModel.Error.invalid }
            guard status == ARCHIVE_OK, let entry, let pointer = archive_entry_pathname(entry), let current = String(validatingUTF8: pointer) else { throw ComicArchiveModel.Error.invalid }
            if current != name { _ = archive_read_data_skip(reader); continue }
            let declared = archive_entry_size(entry)
            guard declared >= 0, declared <= maxBytes else { throw ComicArchiveModel.Error.tooLarge }
            var output = Data(); output.reserveCapacity(Int(declared))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in archive_read_data(reader, raw.baseAddress, raw.count) }
                if count == 0 { break }
                guard count > 0 else { throw ComicArchiveModel.Error.invalid }
                output.append(contentsOf: buffer[0..<Int(count)])
                guard Int64(output.count) <= maxBytes else { throw ComicArchiveModel.Error.tooLarge }
            }
            return output
        }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        guard let reader = archive_read_new() else { throw ComicArchiveModel.Error.invalid }
        guard archive_read_support_filter_all(reader) == ARCHIVE_OK, archive_read_support_format_all(reader) == ARCHIVE_OK else { close(reader); throw ComicArchiveModel.Error.unsupported }
        let status = url.path.withCString { archive_read_open_filename(reader, $0, 64 * 1024) }
        guard status == ARCHIVE_OK else { close(reader); throw ComicArchiveModel.Error.invalid }
        return reader
    }

    private static func close(_ reader: OpaquePointer) { _ = archive_read_close(reader); _ = archive_read_free(reader) }

    private static func isSafeMember(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") &&
            !name.split(separator: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) &&
            !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    }
}

private let ARCHIVE_OK: Int32 = 0
private let ARCHIVE_EOF: Int32 = 1

@_silgen_name("archive_read_new") private func archive_read_new() -> OpaquePointer?
@_silgen_name("archive_read_support_filter_all") private func archive_read_support_filter_all(_ archive: OpaquePointer) -> Int32
@_silgen_name("archive_read_support_format_all") private func archive_read_support_format_all(_ archive: OpaquePointer) -> Int32
@_silgen_name("archive_read_open_filename") private func archive_read_open_filename(_ archive: OpaquePointer, _ filename: UnsafePointer<CChar>, _ blockSize: Int) -> Int32
@_silgen_name("archive_read_next_header") private func archive_read_next_header(_ archive: OpaquePointer, _ entry: UnsafeMutablePointer<OpaquePointer?>) -> Int32
@_silgen_name("archive_entry_pathname") private func archive_entry_pathname(_ entry: OpaquePointer) -> UnsafePointer<CChar>?
@_silgen_name("archive_entry_size") private func archive_entry_size(_ entry: OpaquePointer) -> Int64
@_silgen_name("archive_read_data") private func archive_read_data(_ archive: OpaquePointer, _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int64
@_silgen_name("archive_read_data_skip") private func archive_read_data_skip(_ archive: OpaquePointer) -> Int32
@_silgen_name("archive_read_close") private func archive_read_close(_ archive: OpaquePointer) -> Int32
@_silgen_name("archive_read_free") private func archive_read_free(_ archive: OpaquePointer) -> Int32

private func plainMarkupText(_ value: String) -> String {
    value.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|section|article|tr|title)>", with: "\n\n", options: .regularExpression)
        // Keep one space for ordinary tags, matching Android's bounded text
        // normalizer. This makes anchor offsets portable between platforms.
        .replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

private func palmDocText(_ input: Data) throws -> String {
    enum PalmError: Error { case invalid, encrypted, unsupported }
    guard input.count >= 78 else { throw PalmError.invalid }
    let records = Int(input.u16be(at: 76)); guard records >= 2, input.count >= 78 + records * 8 else { throw PalmError.invalid }
    var offsets = (0..<records).map { Int(input.u32be(at: 78 + $0 * 8)) }; offsets.append(input.count)
    guard offsets.enumerated().dropFirst().allSatisfy({ offsets[$0.offset - 1] <= $0.element && $0.element <= input.count }) else { throw PalmError.invalid }
    let first = offsets[0]; guard first + 16 <= input.count else { throw PalmError.invalid }
    let compression = input.u16be(at: first); let length = Int(input.u32be(at: first + 4)); let textRecords = min(Int(input.u16be(at: first + 8)), records - 1)
    guard input.u32be(at: first + 12) == 0 else { throw PalmError.encrypted }
    guard compression == 1 || compression == 2 else { throw PalmError.unsupported }
    var output = Data(capacity: min(length, 32 * 1024 * 1024))
    for record in 1...textRecords {
        let bytes = input[offsets[record]..<offsets[record + 1]]
        if compression == 1 { output.append(contentsOf: bytes) }
        else {
            var i = bytes.startIndex
            while i < bytes.endIndex {
                let value = bytes[i]; i = bytes.index(after: i)
                if value == 0 { output.append(0) }
                else if value <= 8 { for _ in 0..<Int(value) where i < bytes.endIndex { output.append(bytes[i]); i = bytes.index(after: i) } }
                else if value <= 0x7f { output.append(value) }
                else if value <= 0xbf, i < bytes.endIndex {
                    let next = bytes[i]; i = bytes.index(after: i); let distance = Int((value & 0x3f) << 5 | (next >> 3)); let count = Int(next & 7) + 3
                    guard distance > 0, distance <= output.count else { throw PalmError.invalid }
                    for _ in 0..<count { output.append(output[output.count - distance]) }
                } else { output.append(0x20); output.append(value ^ 0x80) }
            }
        }
        if output.count >= 32 * 1024 * 1024 { break }
    }
    if output.count > length { output = output.prefix(length) }
    guard let value = String(data: output, encoding: .utf8) else { throw PalmError.invalid }
    return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
}

private extension Data {
    func u16be(at offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    func u32be(at offset: Int) -> UInt32 { UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3]) }
}

private enum AudioSleepOption: String, CaseIterable, Identifiable {
    case off
    case fifteenMinutes
    case thirtyMinutes
    case chapterEnd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .chapterEnd: return "本章结束"
        }
    }
}

private struct AudioReaderControls: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let publication: LocalPublication
    @State private var selectedSleep: AudioSleepOption = .off
    @State private var sleepNotice: String?
    @State private var focusNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    cover
                    titleAndChapter
                    progressSection
                    playbackControls
                    playbackOptions
                    playbackState
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .background(ReaderUI.paperCanvas.ignoresSafeArea())
        .foregroundStyle(ReaderUI.inkPrimary)
        .navigationBarHidden(true)
        .task { await preparePlayback() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard environment.audioPlayback.hasActiveTrack,
                  let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  rawType == AVAudioSession.InterruptionType.began.rawValue else { return }
            focusNotice = "播放因系统音频焦点中断而暂停。"
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
            guard environment.audioPlayback.hasActiveTrack,
                  let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
            focusNotice = "耳机或蓝牙设备已断开，播放已暂停。"
        }
        .onChange(of: environment.audioPlayback.isPlaying) { isPlaying in
            if isPlaying { focusNotice = nil }
        }
        .onDisappear {
            persistSettings()
            // Do not stop or detach the global player when SwiftUI destroys
            // this view. Lock-screen/background playback and progress flushes
            // must continue until the user explicitly stops the player.
            environment.audioPlayback.persistCurrentState()
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("返回书库")
            ReaderChromeTitle(value: "音频阅读")
            Menu {
                ForEach(AudioSleepOption.allCases) { option in
                    Button("睡眠计时：\(option.label)") { applySleep(option) }
                }
                if environment.audioPlayback.playbackError != nil {
                    Button("重新载入音频") { Task { await preparePlayback() } }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: ReaderUI.hitTarget, height: ReaderUI.hitTarget)
            }
            .accessibilityLabel("更多播放选项")
        }
        .frame(height: ReaderUI.topBarHeight)
        .background(ReaderUI.paperRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(ReaderUI.subtleLine).frame(height: 1) }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(ReaderUI.paperRaised)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "headphones")
                        .font(.system(size: 40, weight: .light))
                    Text(publication.title)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if let author = publication.author, !author.isEmpty {
                        Text(author)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    Text(publication.format.uppercased())
                        .font(.caption.monospaced().weight(.semibold))
                }
                .padding(PapriaDesign.pageHorizontalInset)
                .foregroundStyle(ReaderUI.inkSecondary)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderUI.subtleLine, lineWidth: 1))
            .frame(maxWidth: 268)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityLabel("音频书籍封面")
    }

    private var titleAndChapter: some View {
        VStack(spacing: 6) {
            Text(publication.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(currentChapter)
                .font(.footnote)
                .foregroundStyle(ReaderUI.inkSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if environment.audioPlayback.trackTitles.count > 1 {
                Menu {
                    ForEach(Array(environment.audioPlayback.trackTitles.enumerated()), id: \.offset) { index, title in
                        Button(title) { _ = environment.audioPlayback.selectTrack(at: index) }
                    }
                } label: {
                    Label("章节 \(environment.audioPlayback.currentTrackIndex + 1) / \(environment.audioPlayback.trackTitles.count)", systemImage: "list.bullet")
                        .font(.footnote.weight(.medium))
                }
                .accessibilityLabel("选择章节")
            }
        }
    }

    private var progressSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(clock(environment.audioPlayback.positionSeconds))
                Spacer()
                Text(clock(environment.audioPlayback.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(ReaderUI.inkSecondary)

            Slider(
                value: Binding(
                    get: { min(max(environment.audioPlayback.positionSeconds, 0), max(environment.audioPlayback.durationSeconds, 1)) },
                    set: { environment.audioPlayback.seek(to: $0) }
                ),
                in: 0...max(environment.audioPlayback.durationSeconds, 1)
            )
            .tint(ReaderUI.primaryAction)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(clock(environment.audioPlayback.positionSeconds)) / \(clock(environment.audioPlayback.durationSeconds))")
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 20) {
            Button { environment.audioPlayback.jump(by: -15) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "gobackward.15")
                    Text("后退 15 秒").font(.caption2)
                }
                .frame(minWidth: 72, minHeight: ReaderUI.hitTarget)
            }
            .accessibilityLabel("后退 15 秒")

            Button { environment.audioPlayback.toggle() } label: {
                Image(systemName: environment.audioPlayback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(ReaderUI.paperRaised)
                    .background(ReaderUI.primaryAction, in: Circle())
            }
            .accessibilityLabel(environment.audioPlayback.isPlaying ? "暂停" : "播放")

            Button { environment.audioPlayback.jump(by: 15) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "goforward.15")
                    Text("前进 15 秒").font(.caption2)
                }
                .frame(minWidth: 72, minHeight: ReaderUI.hitTarget)
            }
            .accessibilityLabel("前进 15 秒")
        }
    }

    private var playbackOptions: some View {
        VStack(spacing: 1) {
            Menu {
                ForEach(supportedRates, id: \.self) { rate in
                    Button(rateLabel(rate)) {
                        environment.audioPlayback.rate = rate
                        persistSettings()
                    }
                }
            } label: {
                optionRow(title: "倍速", value: rateLabel(nearestSupportedRate(environment.audioPlayback.rate)), icon: "speedometer")
            }
            .accessibilityLabel("播放倍速")

            Divider().overlay(ReaderUI.subtleLine)

            Menu {
                ForEach(AudioSleepOption.allCases) { option in
                    Button(option.label) { applySleep(option) }
                }
            } label: {
                optionRow(title: "睡眠计时", value: selectedSleep.label, icon: "moon")
            }
            .accessibilityLabel("睡眠计时")
        }
        .background(ReaderUI.paperRaised)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderUI.subtleLine, lineWidth: 1))
    }

    private var playbackState: some View {
        VStack(alignment: .leading, spacing: 8) {
            let status = currentStatus
            Label(status.message, systemImage: status.icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(status.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let playbackError = environment.audioPlayback.playbackError {
                Text(playbackError)
                    .font(.footnote)
                    .foregroundStyle(ReaderUI.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let focusNotice {
                Text(focusNotice)
                    .font(.footnote)
                    .foregroundStyle(ReaderUI.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !environment.audioPlayback.isPlaying && environment.audioPlayback.hasActiveTrack {
                Text("播放已暂停。")
                    .font(.footnote)
                    .foregroundStyle(ReaderUI.inkSecondary)
            }
            if let sleepNotice {
                Text(sleepNotice)
                    .font(.footnote)
                    .foregroundStyle(ReaderUI.inkSecondary)
            }
        }
        .padding(12)
        .background(ReaderUI.paperRaised)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ReaderUI.subtleLine, lineWidth: 1))
    }

    private var currentChapter: String {
        let titles = environment.audioPlayback.trackTitles
        if let chapter = titles[safe: environment.audioPlayback.currentTrackIndex] { return chapter }
        if !environment.audioPlayback.title.isEmpty { return environment.audioPlayback.title }
        return "正在准备章节"
    }

    private var currentStatus: (icon: String, message: String, color: Color) {
        if let playbackError = environment.audioPlayback.playbackError {
            return ("exclamationmark.triangle.fill", "播放失败：\(playbackError)", ReaderUI.primaryAction)
        }
        if let focusNotice {
            return ("pause.circle.fill", focusNotice, ReaderUI.inkSecondary)
        }
        if FileManager.default.fileExists(atPath: publication.filePath) {
            return ("checkmark.circle.fill", "已缓存，可离线播放", ReaderUI.success)
        }
        return ("wifi.exclamationmark", "离线未缓存：需要联网后播放", ReaderUI.inkSecondary)
    }

    private var supportedRates: [Float] { [0.8, 1.0, 1.25, 1.5, 2.0] }

    private func optionRow(title: String, value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(ReaderUI.inkSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(ReaderUI.inkSecondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(minHeight: ReaderUI.hitTarget)
        .contentShape(Rectangle())
    }

    private func rateLabel(_ rate: Float) -> String {
        switch rate {
        case 0.8: return "0.8x"
        case 1.0: return "1.0x"
        case 1.25: return "1.25x"
        case 1.5: return "1.5x"
        default: return "2.0x"
        }
    }

    private func nearestSupportedRate(_ rate: Float) -> Float {
        supportedRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 1.0
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainder = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%02d:%02d", minutes, remainder)
    }

    private func applySleep(_ option: AudioSleepOption) {
        selectedSleep = option
        sleepNotice = nil
        switch option {
        case .off:
            environment.audioPlayback.setSleepTimer(minutes: nil)
        case .fifteenMinutes:
            environment.audioPlayback.setSleepTimer(minutes: 15)
        case .thirtyMinutes:
            environment.audioPlayback.setSleepTimer(minutes: 30)
        case .chapterEnd:
            let remaining = environment.audioPlayback.durationSeconds - environment.audioPlayback.positionSeconds
            guard remaining.isFinite, remaining > 1 else {
                environment.audioPlayback.setSleepTimer(minutes: nil)
                sleepNotice = "无法取得本章时长，睡眠计时未开启。"
                persistSettings()
                return
            }
            environment.audioPlayback.setSleepTimer(until: Date().addingTimeInterval(remaining))
        }
        persistSettings()
    }

    private func preparePlayback() async {
        let bookId = publication.remoteBookId ?? publication.progressFileId
        let localTrackId = publication.remoteFileId ?? publication.progressFileId
        var restoredSleepUntil: Date?
        if let settings = await environment.audioSettingsForOpening(bookId: bookId) {
            environment.audioPlayback.rate = nearestSupportedRate(Float(settings.rate))
            restoredSleepUntil = settings.sleepUntil
            if let restoredSleepUntil {
                selectedSleep = restoredSleepUntil.timeIntervalSinceNow <= 22 * 60 ? .fifteenMinutes : .thirtyMinutes
            }
        }
        let saved = await environment.audioProgressForOpening(bookId: bookId, remoteBookId: publication.remoteBookId)
        var tracks = (try? await environment.localStore.publications())?
            .filter { candidate in
                let sameBook = publication.remoteBookId.map { candidate.remoteBookId == $0 } ?? (candidate.id == publication.id)
                return sameBook && ["mp3", "m4a", "m4b", "ogg", "opus", "flac"].contains(candidate.format.lowercased())
            }
            .sorted { ($0.remoteFileId ?? $0.progressFileId, $0.fileNameForSorting) < ($1.remoteFileId ?? $1.progressFileId, $1.fileNameForSorting) }
            .map { AudioPlaybackService.Track(url: URL(fileURLWithPath: $0.filePath), title: $0.title, fileId: $0.remoteFileId ?? $0.progressFileId) } ?? []
        if tracks.isEmpty {
            tracks = [AudioPlaybackService.Track(url: URL(fileURLWithPath: publication.filePath), title: publication.title, fileId: localTrackId)]
        }
        installProgressHandler(bookId: bookId, validFileIds: Set(tracks.map(\.fileId)))
        let targetFileId = saved?.currentFileId ?? localTrackId
        // The service is application-owned. Re-entering the reader should
        // reconnect the controls to an existing track instead of seeking
        // it back to the last database snapshot or starting a duplicate.
        guard !(environment.audioPlayback.hasActiveTrack && environment.audioPlayback.currentFileId == targetFileId) else {
            environment.audioPlayback.setSleepTimer(until: restoredSleepUntil)
            return
        }
        if tracks.count > 1 {
            let startIndex = tracks.firstIndex { $0.fileId == targetFileId } ?? 0
            environment.audioPlayback.play(tracks: tracks, startIndex: startIndex, startAt: saved?.currentFileId == tracks[startIndex].fileId ? (saved?.positionSeconds ?? 0) : 0)
        } else {
            environment.audioPlayback.play(tracks: tracks, startIndex: 0, startAt: saved?.currentFileId == tracks[0].fileId ? (saved?.positionSeconds ?? 0) : 0)
        }
        environment.audioPlayback.setSleepTimer(until: restoredSleepUntil)
    }

    private func persistSettings() {
        let bookId = publication.remoteBookId ?? publication.progressFileId
        let rate = Double(environment.audioPlayback.rate)
        let sleepUntil = environment.audioPlayback.sleepUntil
        Task { await environment.saveAudioSettings(bookId: bookId, rate: rate, sleepUntil: sleepUntil) }
    }

    private func installProgressHandler(bookId: Int64, validFileIds: Set<Int64>) {
        environment.audioPlayback.onProgress = { fileId, position, percentage in
            // Bind callbacks to this book's exact file IDs. While another
            // book is being opened asynchronously, a still-playing previous
            // track must never be written into the new book's progress row.
            guard validFileIds.contains(fileId) else { return }
            let remote = publication.remoteBookId != nil
            let payload = AudioProgressPayload(percentage: percentage, currentFileId: fileId, positionSeconds: position, updatedAt: ISO8601DateFormatter().string(from: Date()), dirty: remote)
            Task {
                try? await environment.localStore.saveAudioProgress(bookId: bookId, progress: payload, enqueue: remote)
            }
        }
    }
}

private extension LocalPublication {
    var fileNameForSorting: String { title.lowercased() + "|" + filePath.lowercased() }
}
