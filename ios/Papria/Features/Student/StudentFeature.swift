import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The iOS 0.1.0 root information architecture.  The TabView intentionally
/// stays native so iOS owns the tab bar height, selection feedback and safe
/// area behaviour on every supported device.
struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedTab: PapriaRootTab = .library
    @State private var showingImporter = false

    var body: some View {
        TabView(selection: $selectedTab) {
            PapriaNavigationContainer {
                LocalLibraryScreen(
                    showingImporter: $showingImporter,
                    selectedTab: $selectedTab
                )
            }
            .tabItem { Label("书库", systemImage: "books.vertical") }
            .tag(PapriaRootTab.library)

            PapriaNavigationContainer {
                BookOrbitCatalogScreen()
            }
            .tabItem { Label("BookOrbit", systemImage: "cloud") }
            .tag(PapriaRootTab.bookOrbit)

            TransferView()
                .tabItem { Label("传书", systemImage: "wifi") }
                .tag(PapriaRootTab.transfer)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(PapriaRootTab.settings)
        }
        .tint(PapriaIOSDesign.actionPrimary)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessed { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        _ = try await environment.localStore.importLocalFile(
                            at: url,
                            title: url.deletingPathExtension().lastPathComponent,
                            source: "local"
                        )
                    } catch {
                        environment.globalError = error.localizedDescription
                    }
                }
                await environment.reloadLocalLibrary()
            }
        }
    }
}

private enum PapriaRootTab: Hashable {
    case library
    case bookOrbit
    case transfer
    case settings
}

/// NavigationStack is the normal iOS 16+ path.  The iOS 15 fallback keeps
/// native navigation for the project's current deployment target.
private struct PapriaNavigationContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - Local library

private struct LocalLibraryScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Binding var showingImporter: Bool
    @Binding var selectedTab: PapriaRootTab

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var formatFilter: LocalFormatFilter = .all
    @State private var progressByPublicationID: [String: LibraryProgress] = [:]
    @State private var pendingDeletion: LocalPublication?

    private var localBooks: [LocalPublication] {
        environment.publications.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredBooks: [LocalPublication] {
        localBooks.filter { publication in
            formatFilter.includes(publication) &&
            (searchQuery.isEmpty || publication.title.localizedCaseInsensitiveContains(searchQuery) ||
             (publication.author?.localizedCaseInsensitiveContains(searchQuery) ?? false))
        }
    }

    private var librarySectionTitle: String {
        if !searchQuery.isEmpty { return "搜索结果" }
        return formatFilter == .all ? "最近导入" : "筛选结果"
    }

    private var resultAndFilterStatus: String {
        let resultLabel = searchQuery.isEmpty ? "当前书籍" : "搜索结果"
        return "\(resultLabel)：\(filteredBooks.count) 本 · 当前筛选：\(formatFilter.title)"
    }

    private var continueReading: LocalPublication? {
        localBooks.first { (progressByPublicationID[$0.id]?.percentage ?? 0) > 0 } ?? localBooks.first
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                libraryList.scrollContentBackground(.hidden)
            } else {
                libraryList
            }
        }
        .background(PapriaIOSDesign.canvas)
        .navigationTitle("书库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { libraryToolbar }
        .task(id: environment.publications.map(\.id).joined(separator: ",")) {
            await loadProgress()
        }
        .refreshable {
            await environment.reloadLocalLibrary()
            await loadProgress()
        }
        .confirmationDialog(
            "仅删除本地副本？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { publication in
            Button("删除本地副本", role: .destructive) {
                Task { await environment.deletePublication(publication) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { publication in
            if publication.remoteBookId != nil {
                Text("这只会删除本机文件。BookOrbit 上的远程副本会保留。")
            } else {
                Text("这只会删除本机文件，删除后无法在书库中打开。")
            }
        }
    }

    private var libraryList: some View {
        List {
            if !environment.isNetworkAvailable {
                Section {
                    DownloadStatusLine(
                        icon: "wifi.slash",
                        text: "离线：本地书籍仍可阅读",
                        color: PapriaIOSDesign.statusWarning
                    )
                }
                .listRowBackground(PapriaIOSDesign.canvas)
            }

            if isSearchVisible {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("搜索书名或作者", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: PapriaDesign.minimumHitTarget)
                            .accessibilityLabel("搜索书库")
                        Text(resultAndFilterStatus)
                            .font(PapriaDesign.metadata)
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                            .accessibilityLabel("\(resultAndFilterStatus)")
                    }
                }
                .listRowBackground(PapriaIOSDesign.raised)
            } else if formatFilter != .all {
                Section {
                    Label(resultAndFilterStatus, systemImage: "line.3.horizontal.decrease.circle")
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.inkSecondary)
                        .accessibilityLabel(resultAndFilterStatus)
                }
                .listRowBackground(PapriaIOSDesign.raised)
            }

            if let publication = continueReading, searchQuery.isEmpty, formatFilter == .all {
                Section("继续阅读") {
                    ContinueReadingCard(
                        publication: publication,
                        progress: progressByPublicationID[publication.id],
                        isFileAvailable: isFileAvailable(publication)
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(PapriaIOSDesign.canvas)
                }
            }

            Section(librarySectionTitle) {
                if localBooks.isEmpty {
                    LocalLibraryEmptyState(
                        onImport: { showingImporter = true },
                        onTransfer: { selectedTab = .transfer }
                    )
                    .listRowBackground(PapriaIOSDesign.canvas)
                } else if filteredBooks.isEmpty {
                    SearchEmptyState(
                        query: searchQuery.isEmpty ? formatFilter.title : searchQuery,
                        collectionName: "本地"
                    )
                        .listRowBackground(PapriaIOSDesign.canvas)
                } else {
                    ForEach(filteredBooks) { publication in
                        LocalBookRow(
                            publication: publication,
                            progress: progressByPublicationID[publication.id],
                            isFileAvailable: isFileAvailable(publication),
                            onRecheck: { Task { await environment.reloadLocalLibrary() } }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = publication
                            } label: {
                                Label("仅删除本地副本", systemImage: "trash")
                            }
                            .accessibilityLabel("仅删除本地副本")
                        }
                        .listRowBackground(PapriaIOSDesign.canvas)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                isSearchVisible = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("搜索")

            Menu {
                ForEach(LocalFormatFilter.allCases) { filter in
                    Button {
                        formatFilter = filter
                    } label: {
                        if filter == formatFilter {
                            Label(filter.title, systemImage: "checkmark")
                        } else {
                            Text(filter.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("筛选")
        }
    }

    private func loadProgress() async {
        var values: [String: LibraryProgress] = [:]
        for publication in environment.publications {
            if let progress = try? await environment.localStore.loadProgress(fileId: publication.progressFileId) {
                values[publication.id] = LibraryProgress(
                    percentage: progress.percentage,
                    pageNumber: progress.pageNumber
                )
            }
        }
        progressByPublicationID = values
    }

    private func isFileAvailable(_ publication: LocalPublication) -> Bool {
        FileManager.default.fileExists(atPath: publication.filePath)
    }
}

private struct ContinueReadingCard: View {
    let publication: LocalPublication
    let progress: LibraryProgress?
    let isFileAvailable: Bool

    private var percentage: Double { min(max(progress?.percentage ?? 0, 0), 100) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PublicationCover(format: publication.format, title: publication.title, width: 76, height: 108)

            VStack(alignment: .leading, spacing: 8) {
                Text(publication.title)
                    .font(PapriaDesign.sectionTitle)
                    .foregroundStyle(PapriaIOSDesign.inkPrimary)
                    .lineLimit(2)
                if let author = publication.author, !author.isEmpty {
                    Text(author)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.inkSecondary)
                        .lineLimit(1)
                }
                Text(readingPositionText)
                    .font(PapriaDesign.metadata.weight(.medium))
                    .foregroundStyle(PapriaIOSDesign.inkSecondary)
                    .monospacedDigit()
                ProgressView(value: percentage, total: 100)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .accessibilityLabel("阅读进度")
                    .accessibilityValue("\(Int(percentage))%")

                if isFileAvailable {
                    NavigationLink {
                        ReaderView(publication: publication)
                    } label: {
                        Text("继续阅读")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .accessibilityLabel("继续阅读，\(publication.title)")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("文件不可用", systemImage: "exclamationmark.triangle")
                        Text("找不到本机文件。")
                    }
                    .font(PapriaDesign.metadata.weight(.medium))
                    .foregroundStyle(PapriaIOSDesign.statusError)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(PapriaIOSDesign.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PapriaIOSDesign.lineSubtle, lineWidth: 1)
        }
    }

    private var readingPositionText: String {
        if let pageNumber = progress?.pageNumber {
            return "\(Int(percentage))% · 第 \(pageNumber) 页"
        }
        return percentage > 0 ? "\(Int(percentage))% · 阅读中" : "尚未开始阅读"
    }
}

private struct LocalBookRow: View {
    let publication: LocalPublication
    let progress: LibraryProgress?
    let isFileAvailable: Bool
    let onRecheck: () -> Void

    private var percentage: Double { min(max(progress?.percentage ?? 0, 0), 100) }

    var body: some View {
        Group {
            if isFileAvailable {
                NavigationLink {
                    ReaderView(publication: publication)
                } label: {
                    rowContent
                }
                .accessibilityLabel("打开 \(publication.title)")
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            PublicationCover(format: publication.format, title: publication.title, width: 52, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(publication.title)
                    .font(PapriaDesign.rowBody)
                    .foregroundStyle(PapriaIOSDesign.inkPrimary)
                    .lineLimit(2)
                if let author = publication.author, !author.isEmpty {
                    Text(author)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.inkSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(publication.format.uppercased())
                    Text(ByteCountFormatter.string(fromByteCount: publication.sizeBytes, countStyle: .file))
                }
                .font(PapriaDesign.label)
                .foregroundStyle(PapriaIOSDesign.inkSecondary)

                if isFileAvailable {
                    HStack(spacing: 6) {
                        Label(
                            publication.remoteBookId == nil ? "本地文件" : "BookOrbit 已下载",
                            systemImage: publication.remoteBookId == nil ? "internaldrive" : "arrow.down.circle"
                        )
                        if percentage > 0 {
                            Text("\(Int(percentage))%")
                                .monospacedDigit()
                        }
                    }
                    .font(PapriaDesign.label)
                    .foregroundStyle(publication.remoteBookId == nil ? PapriaIOSDesign.inkSecondary : PapriaIOSDesign.statusRemote)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("文件不可用", systemImage: "exclamationmark.triangle")
                        Text("找不到本机文件。")
                        Button("重新检查", action: onRecheck)
                    }
                    .font(PapriaDesign.label)
                    .foregroundStyle(PapriaIOSDesign.statusError)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct LocalLibraryEmptyState: View {
    let onImport: () -> Void
    let onTransfer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
                .accessibilityHidden(true)
            Text("还没有书籍")
                .font(PapriaDesign.sectionTitle)
                .foregroundStyle(PapriaIOSDesign.inkPrimary)
            Text("从文件导入，或通过 Wi-Fi 传书把书籍加入本地书库。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("从文件导入", action: onImport)
                    .buttonStyle(.borderedProminent)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: 44)
                Button("传书", action: onTransfer)
                    .buttonStyle(.bordered)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
    }
}

private struct SearchEmptyState: View {
    let query: String
    let collectionName: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
            Text("没有找到书籍")
                .font(PapriaDesign.sectionTitle)
            Text("没有与“\(query)”匹配的\(collectionName)书名或作者。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
    }
}

private enum LocalFormatFilter: String, CaseIterable, Identifiable {
    case all
    case epub
    case pdf
    case audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部格式"
        case .epub: return "EPUB / 文本"
        case .pdf: return "PDF / 漫画"
        case .audio: return "音频"
        }
    }

    func includes(_ publication: LocalPublication) -> Bool {
        let format = publication.format.lowercased()
        switch self {
        case .all: return true
        case .epub: return ["epub", "kepub", "txt", "md", "fb2", "mobi", "azw", "azw3"].contains(format)
        case .pdf: return ["pdf", "cbz", "cbr", "cb7"].contains(format)
        case .audio: return PapriaFileKinds.isAudio(format)
        }
    }
}

private struct LibraryProgress: Equatable {
    let percentage: Double
    let pageNumber: Int?
}

// MARK: - BookOrbit catalog and detail

private struct BookOrbitCatalogScreen: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var showingAuthentication = false

    private var displayedBooks: [RemoteBookRecord] {
        environment.remoteBooks.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var activeTaskCount: Int {
        activeDownloadTaskCount(environment.downloadStates)
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                catalogList.scrollContentBackground(.hidden)
            } else {
                catalogList
            }
        }
        .background(PapriaIOSDesign.canvas)
        .navigationTitle("BookOrbit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { catalogToolbar }
        .sheet(isPresented: $showingAuthentication) {
            AuthenticationView()
                .environmentObject(environment)
        }
        .task {
            if environment.isAuthenticated && environment.remoteBooks.isEmpty {
                await environment.refreshRemoteLibrary()
            }
        }
        .refreshable {
            if environment.isAuthenticated {
                await environment.refreshRemoteLibrary()
            }
        }
    }

    private var catalogList: some View {
        List {
            Section {
                BookOrbitConnectionBanner(
                    isAuthenticated: environment.isAuthenticated,
                    isOnline: environment.isNetworkAvailable,
                    isLoading: environment.isLoadingLibrary,
                    serverURL: environment.serverURL,
                    hasCachedCatalog: !environment.remoteBooks.isEmpty,
                    failureMessage: environment.bookOrbitConnectionError
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(PapriaIOSDesign.canvas)
            }

            if isSearchVisible {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("搜索 BookOrbit 书目", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: PapriaDesign.minimumHitTarget)
                            .accessibilityLabel("搜索 BookOrbit")
                        Text("\(displayedBooks.count) 个结果")
                            .font(PapriaDesign.metadata)
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                            .accessibilityLabel("搜索结果 \(displayedBooks.count) 本")
                    }
                }
                .listRowBackground(PapriaIOSDesign.raised)
            }

            if !environment.isAuthenticated && environment.remoteBooks.isEmpty {
                Section {
                    BookOrbitDisconnectedState { showingAuthentication = true }
                        .listRowBackground(PapriaIOSDesign.canvas)
                }
            } else if environment.isLoadingLibrary && environment.remoteBooks.isEmpty {
                Section("缓存书目") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在载入书目")
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                    }
                    .frame(minHeight: 72)
                    .listRowBackground(PapriaIOSDesign.canvas)
                }
            } else if displayedBooks.isEmpty {
                Section(searchText.isEmpty ? "缓存书目" : "搜索结果") {
                    SearchEmptyState(
                        query: searchText.isEmpty ? "BookOrbit" : searchText,
                        collectionName: "BookOrbit"
                    )
                        .listRowBackground(PapriaIOSDesign.canvas)
                }
            } else {
                Section("缓存书目") {
                    ForEach(displayedBooks) { book in
                        NavigationLink {
                            RemoteBookDetailView(book: book)
                        } label: {
                            RemoteBookRow(book: book)
                        }
                        .listRowBackground(PapriaIOSDesign.canvas)
                        .task { await environment.loadCover(bookId: book.id) }
                        .accessibilityLabel("打开 BookOrbit 书籍 \(book.title)")
                        .accessibilityHint("查看远程文件和下载状态")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var catalogToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            NavigationLink {
                DownloadTaskCenterView()
            } label: {
                DownloadTaskToolbarIcon(count: activeTaskCount)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(activeTaskCount == 0 ? "下载任务" : "下载任务，\(activeTaskCount) 项未完成")

            Button {
                isSearchVisible = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("搜索")

            Button {
                Task { await environment.refreshRemoteLibrary() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 44, height: 44)
            }
            .disabled(!environment.isAuthenticated || !environment.isNetworkAvailable || environment.isLoadingLibrary)
            .accessibilityLabel("刷新 BookOrbit 书目")
        }
    }
}

private struct BookOrbitConnectionBanner: View {
    let isAuthenticated: Bool
    let isOnline: Bool
    let isLoading: Bool
    let serverURL: String
    let hasCachedCatalog: Bool
    let failureMessage: String?

    private var state: (icon: String, text: String, color: Color) {
        if !isOnline {
            return ("wifi.slash", "离线：仅显示已缓存内容", PapriaIOSDesign.statusWarning)
        }
        if isLoading {
            return ("arrow.triangle.2.circlepath", "正在连接", PapriaIOSDesign.statusRemote)
        }
        if failureMessage != nil {
            return ("exclamationmark.triangle", "无法连接", PapriaIOSDesign.statusError)
        }
        if isAuthenticated {
            return ("checkmark.circle", "已连接", PapriaIOSDesign.statusSuccess)
        }
        if hasCachedCatalog {
            return ("exclamationmark.triangle", "未连接：仅显示已缓存内容", PapriaIOSDesign.statusWarning)
        }
        return ("exclamationmark.triangle", "未连接", PapriaIOSDesign.statusError)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.icon)
                .foregroundStyle(state.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.text)
                    .font(PapriaDesign.metadata.weight(.semibold))
                    .foregroundStyle(PapriaIOSDesign.inkPrimary)
                Text(displayServerName(serverURL))
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaIOSDesign.inkSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let failureMessage {
                    Text(failureMessage)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.statusError)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(PapriaIOSDesign.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PapriaIOSDesign.lineSubtle, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BookOrbitDisconnectedState: View {
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.slash")
                .font(.system(size: 34))
                .foregroundStyle(PapriaIOSDesign.statusRemote)
            Text("连接 BookOrbit 后查看远程书目")
                .font(PapriaDesign.sectionTitle)
                .foregroundStyle(PapriaIOSDesign.inkPrimary)
                .multilineTextAlignment(.center)
            Text("已下载的书籍始终在“书库”中可用。")
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
            Button("连接并登录", action: onConnect)
                .buttonStyle(.borderedProminent)
                .tint(PapriaIOSDesign.actionPrimary)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowSeparator(.hidden)
    }
}

private struct RemoteBookRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    let book: RemoteBookRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteCover(bookID: book.id, title: book.title, width: 52, height: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(PapriaDesign.rowBody)
                    .foregroundStyle(PapriaIOSDesign.inkPrimary)
                    .lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.inkSecondary)
                        .lineLimit(1)
                }
                Label("远程书目", systemImage: "cloud")
                    .font(PapriaDesign.label)
                    .foregroundStyle(PapriaIOSDesign.statusRemote)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct RemoteBookDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    let book: RemoteBookRecord
    @AppStorage("papria.onlyWiFiDownloads") private var onlyWiFiDownloads = false

    @State private var detail: BookOrbitBookDetail?
    @State private var loadError: String?

    /// The environment is the source of truth for both a successfully cached
    /// BookOrbit detail and active/persisted download tasks.  Both are local
    /// data, so an offline detail never needs to invent remote file rows.
    private var cachedFiles: [RemoteFileRecord] {
        var files = Dictionary(
            uniqueKeysWithValues: (environment.cachedBookOrbitDetail(bookID: book.id)?.files ?? [])
                .map { ($0.id, $0) }
        )
        let taskFiles = environment.downloadTaskItems
            .filter { $0.bookID == book.id }
            .map(\.file)
        for file in taskFiles {
            files[file.id] = file
        }
        return files.values.sorted {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    private var files: [RemoteFileRecord] {
        detail?.files ?? cachedFiles
    }

    private var isShowingCachedFiles: Bool {
        detail == nil && !cachedFiles.isEmpty
    }

    private var hasDisplayableDetail: Bool {
        detail != nil || !cachedFiles.isEmpty
    }

    private var displayTitle: String {
        detail?.title ?? book.title
    }

    private var displayAuthor: String? {
        detail?.author ?? book.author
    }

    private var activeTaskCount: Int {
        activeDownloadTaskCount(environment.downloadStates)
    }

    private var summary: String? {
        let phases = environment.downloadTaskItems.compactMap { environment.downloadStates[$0.id] }
        let downloading = phases.filter {
            if case .downloading(_, _) = $0 { return true }
            return false
        }.count
        let waitingForWiFi = phases.filter {
            if case .waitingForWiFi(_, _) = $0 { return true }
            return false
        }.count
        let waitingForNetwork = phases.filter {
            if case .waitingForNetwork(_, _) = $0 { return true }
            return false
        }.count
        guard downloading > 0 || waitingForWiFi > 0 || waitingForNetwork > 0 else { return nil }
        var parts: [String] = []
        if downloading > 0 { parts.append("\(downloading) 项下载中") }
        if waitingForWiFi > 0 { parts.append("\(waitingForWiFi) 项等待 Wi-Fi") }
        if waitingForNetwork > 0 { parts.append("\(waitingForNetwork) 项等待网络") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                detailList.scrollContentBackground(.hidden)
            } else {
                detailList
            }
        }
        .background(PapriaIOSDesign.canvas)
        .navigationTitle("BookOrbit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    DownloadTaskCenterView()
                } label: {
                    DownloadTaskToolbarIcon(count: activeTaskCount)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(activeTaskCount == 0 ? "下载任务" : "下载任务，\(activeTaskCount) 项未完成")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let summary {
                TaskSummaryBanner(summary: summary)
            }
        }
        .task(id: book.id) {
            await loadDetail()
        }
        .refreshable {
            await loadDetail(force: true)
        }
    }

    private var detailList: some View {
        List {
            Section {
                BookOrbitConnectionBanner(
                    isAuthenticated: environment.isAuthenticated,
                    isOnline: environment.isNetworkAvailable,
                    isLoading: environment.isLoadingLibrary,
                    serverURL: environment.serverURL,
                    hasCachedCatalog: !environment.remoteBooks.isEmpty || !cachedFiles.isEmpty,
                    failureMessage: environment.bookOrbitConnectionError
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(PapriaIOSDesign.canvas)
            }

            if hasDisplayableDetail {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        RemoteCover(bookID: book.id, title: displayTitle, width: 92, height: 128)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayTitle)
                                .font(PapriaDesign.detailTitle)
                                .foregroundStyle(PapriaIOSDesign.inkPrimary)
                                .lineLimit(2)
                            if let author = displayAuthor, !author.isEmpty {
                                Text(author)
                                    .font(PapriaDesign.metadata)
                                    .foregroundStyle(PapriaIOSDesign.inkSecondary)
                                    .lineLimit(2)
                            }
                            Label("远程资源", systemImage: "cloud")
                                .font(PapriaDesign.metadata.weight(.medium))
                                .foregroundStyle(PapriaIOSDesign.statusRemote)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(PapriaIOSDesign.canvas)
                }

                if isShowingCachedFiles || loadError != nil {
                    Section {
                        RemoteDetailCacheNotice(
                            message: loadError ?? "离线：正在显示已缓存的文件信息。",
                            canRetry: environment.isAuthenticated && environment.isNetworkAvailable,
                            isOffline: !environment.isNetworkAvailable,
                            retry: { Task { await loadDetail(force: true) } }
                        )
                        .listRowBackground(PapriaIOSDesign.canvas)
                    }
                }

                Section {
                    Toggle("仅 Wi-Fi 下载", isOn: $onlyWiFiDownloads)
                        .tint(PapriaIOSDesign.actionPrimary)
                        .accessibilityHint("开启后，新的下载会等待 Wi-Fi 网络")
                } footer: {
                    Text("此设置用于此页面和下载任务中心中新加入或继续的任务。")
                }
                .listRowBackground(PapriaIOSDesign.canvas)

                Section("文件") {
                    ForEach(files) { file in
                        RemoteFileRow(
                            bookID: book.id,
                            file: file
                        )
                        .listRowBackground(PapriaIOSDesign.canvas)
                    }
                }
            } else if let loadError {
                Section {
                    RemoteDetailFailure(
                        message: loadError,
                        canRetry: environment.isAuthenticated && environment.isNetworkAvailable,
                        retry: { Task { await loadDetail(force: true) } }
                    )
                        .listRowBackground(PapriaIOSDesign.canvas)
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在获取文件")
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                    }
                    .frame(minHeight: 96)
                    .listRowBackground(PapriaIOSDesign.canvas)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func loadDetail(force: Bool = false) async {
        guard detail == nil || force else { return }
        guard environment.isAuthenticated else {
            loadError = hasDisplayableDetail
                ? "当前未连接 BookOrbit，正在显示已缓存的文件信息。"
                : "连接 BookOrbit 后可查看文件列表。"
            return
        }
        guard environment.isNetworkAvailable else {
            loadError = hasDisplayableDetail
                ? "离线：正在显示已缓存的文件信息。"
                : "离线：没有可用的缓存文件列表。"
            return
        }
        loadError = nil
        do {
            let loaded = try await environment.apiClient.bookDetail(id: book.id)
            detail = loaded
            await environment.rememberRemoteFiles(bookId: book.id, files: loaded.files)
        } catch {
            loadError = hasDisplayableDetail
                ? "无法刷新文件列表：\(error.localizedDescription)。正在显示已缓存的文件信息。"
                : "无法获取文件列表：\(error.localizedDescription)"
        }
    }
}

private struct RemoteFileRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    let bookID: Int64
    let file: RemoteFileRecord
    /// Set only by the task center. Detail pages intentionally show the file
    /// state without assigning a queue position outside the active queue.
    let waitingQueuePosition: Int?
    let completedStatusText: String
    @AppStorage("papria.onlyWiFiDownloads") private var onlyWiFiDownloads = false
    @State private var showingRemoveFromDeviceConfirmation = false

    init(
        bookID: Int64,
        file: RemoteFileRecord,
        waitingQueuePosition: Int? = nil,
        completedStatusText: String = "已下载"
    ) {
        self.bookID = bookID
        self.file = file
        self.waitingQueuePosition = waitingQueuePosition
        self.completedStatusText = completedStatusText
    }

    private var phase: AppEnvironment.DownloadPhase? {
        environment.downloadStates[file.id]
    }

    private var localPublication: LocalPublication? {
        environment.publications.first { $0.remoteFileId == file.id }
    }

    private var downloadButtonTitle: String {
        environment.isNetworkAvailable ? "下载" : "等待网络"
    }

    private var currentDownloadRate: Double? {
        guard let bytesPerSecond = environment.downloadBytesPerSecond[file.id], bytesPerSecond > 0 else {
            return nil
        }
        return Double(bytesPerSecond)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                FormatBadge(format: file.format)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName)
                        .font(PapriaDesign.rowBody)
                        .foregroundStyle(PapriaIOSDesign.inkPrimary)
                        .lineLimit(2)
                    Text("\(file.format.uppercased()) · \(byteCount(file.sizeBytes))")
                        .font(PapriaDesign.metadata)
                        .foregroundStyle(PapriaIOSDesign.inkSecondary)
                }
                Spacer(minLength: 0)
            }

            if onlyWiFiDownloads && !isCompleted {
                Label("仅 Wi-Fi", systemImage: "wifi")
                    .font(PapriaDesign.label)
                    .foregroundStyle(PapriaIOSDesign.statusWarning)
            }

            statusAndActions
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "从设备移除 \(file.fileName)？",
            isPresented: $showingRemoveFromDeviceConfirmation,
            titleVisibility: .visible
        ) {
            if let localPublication {
                Button("从设备移除", role: .destructive) {
                    Task { await environment.removeDownloadedFile(localPublication) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这只会删除本机副本。BookOrbit 上的远程文件会保留。")
        }
    }

    @ViewBuilder
    private var statusAndActions: some View {
        if let phase {
            switch phase {
            case .waitingForNetwork(let received, let total):
                DownloadProgressDetail(
                    status: waitingStatus("等待网络"),
                    received: received,
                    total: total,
                    color: PapriaIOSDesign.statusWarning,
                    showsProgress: false
                )
                Button("取消") { environment.cancelDownload(fileId: file.id) }
                    .buttonStyle(.bordered)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: 44)
            case .waitingForWiFi(let received, let total):
                DownloadProgressDetail(
                    status: waitingStatus("等待 Wi-Fi"),
                    received: received,
                    total: total,
                    color: PapriaIOSDesign.statusWarning,
                    showsProgress: false
                )
                Button("取消") { environment.cancelDownload(fileId: file.id) }
                    .buttonStyle(.bordered)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: 44)
            case .downloading(let received, let total):
                DownloadProgressDetail(
                    status: "下载中",
                    received: received,
                    total: total,
                    color: PapriaIOSDesign.actionPrimary,
                    showsProgress: true,
                    speedBytesPerSecond: currentDownloadRate
                )
                VStack(spacing: 8) {
                    Button("暂停") { environment.pauseDownload(fileId: file.id) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    Button("取消") { environment.cancelDownload(fileId: file.id) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                }
                .buttonStyle(.bordered)
                .tint(PapriaIOSDesign.actionPrimary)
            case .paused(let received, let total):
                DownloadProgressDetail(
                    status: "已暂停",
                    received: received,
                    total: total,
                    color: PapriaIOSDesign.statusWarning,
                    showsProgress: false
                )
                VStack(spacing: 8) {
                    Button("继续") { environment.resumeDownload(fileId: file.id, bookId: bookID) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    Button("取消") { environment.cancelDownload(fileId: file.id) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(PapriaIOSDesign.actionPrimary)
            case .failed(let message, let received, let total):
                DownloadProgressDetail(
                    status: "失败：\(message)",
                    received: received,
                    total: total,
                    color: PapriaIOSDesign.statusError,
                    showsProgress: false
                )
                VStack(spacing: 8) {
                    Button("重试") { environment.startDownload(file: file, bookId: bookID) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    Button("删除") { environment.deleteFailedDownload(fileId: file.id) }
                        .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(PapriaIOSDesign.actionPrimary)
            case .completed:
                completedActions
            }
        } else if let localPublication {
            completedActions(for: localPublication)
        } else if environment.isAuthenticated {
            VStack(alignment: .leading, spacing: 8) {
                Button(downloadButtonTitle) {
                    environment.startDownload(file: file, bookId: bookID)
                }
                .buttonStyle(.borderedProminent)
                .tint(PapriaIOSDesign.actionPrimary)
                .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                .accessibilityLabel(environment.isNetworkAvailable ? "下载 \(file.fileName)" : "等待网络后下载 \(file.fileName)")
                .accessibilityHint(environment.isNetworkAvailable ? "开始下载" : "加入等待网络的下载队列")

                if PapriaFileKinds.isAudio(file.format), environment.isNetworkAvailable {
                    Button("在线播放") {
                        Task { await environment.playRemoteAudio(bookId: bookID, file: file) }
                    }
                    .buttonStyle(.bordered)
                    .tint(PapriaIOSDesign.statusRemote)
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityLabel("在线播放 \(file.fileName)")
                } else if PapriaFileKinds.isAudio(file.format) {
                    DownloadStatusLine(
                        icon: "wifi.slash",
                        text: "离线：下载完成后可播放",
                        color: PapriaIOSDesign.statusWarning
                    )
                }
            }
        } else {
            DownloadStatusLine(icon: "person.crop.circle.badge.exclamationmark", text: "连接 BookOrbit 后可下载", color: PapriaIOSDesign.statusWarning)
        }
    }

    @ViewBuilder
    private var completedActions: some View {
        if let localPublication {
            completedActions(for: localPublication)
        } else {
            DownloadStatusLine(
                icon: "exclamationmark.triangle",
                text: "文件不可用：本机副本不存在",
                color: PapriaIOSDesign.statusError
            )
            Button("重新下载") {
                environment.startDownload(file: file, bookId: bookID)
            }
            .buttonStyle(.borderedProminent)
            .tint(PapriaIOSDesign.actionPrimary)
            .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
            .accessibilityLabel("重新下载 \(file.fileName)")
        }
    }

    private func completedActions(for publication: LocalPublication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DownloadStatusLine(icon: "checkmark.circle", text: completedStatusText, color: PapriaIOSDesign.statusSuccess)
            NavigationLink {
                ReaderView(publication: publication)
            } label: {
                Text("打开")
                    .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
            }
            .buttonStyle(.bordered)
            .tint(PapriaIOSDesign.actionPrimary)
            .accessibilityLabel("打开 \(file.fileName)")
            Button("从设备移除") {
                showingRemoveFromDeviceConfirmation = true
            }
            .buttonStyle(.bordered)
            .tint(PapriaIOSDesign.statusError)
            .frame(maxWidth: .infinity, minHeight: PapriaDesign.minimumHitTarget)
        }
    }

    private var isCompleted: Bool {
        if case .completed? = phase { return true }
        return localPublication != nil
    }

    private func waitingStatus(_ status: String) -> String {
        guard let waitingQueuePosition else { return status }
        return "\(status) · 队列 #\(waitingQueuePosition)"
    }
}

private struct DownloadProgressDetail: View {
    let status: String
    let received: Int64
    let total: Int64
    let color: Color
    let showsProgress: Bool
    let speedBytesPerSecond: Double?

    init(
        status: String,
        received: Int64,
        total: Int64,
        color: Color,
        showsProgress: Bool,
        speedBytesPerSecond: Double? = nil
    ) {
        self.status = status
        self.received = received
        self.total = total
        self.color = color
        self.showsProgress = showsProgress
        self.speedBytesPerSecond = speedBytesPerSecond
    }

    private var resolvedTotal: Int64 { max(total, 1) }
    private var percent: Int {
        min(100, max(0, Int((Double(received) / Double(resolvedTotal) * 100).rounded(.down))))
    }

    private var progressDescription: String {
        var values = ["\(status)", "\(percent)%", "\(byteCount(received)) / \(byteCount(resolvedTotal))"]
        if let speedBytesPerSecond, speedBytesPerSecond.isFinite, speedBytesPerSecond > 0 {
            let roundedRate = min(speedBytesPerSecond.rounded(), Double(Int64.max))
            values.append("\(byteCount(Int64(roundedRate))) / 秒")
        }
        return values.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsProgress {
                ProgressView(value: Double(received), total: Double(resolvedTotal))
                    .tint(color)
                    .accessibilityLabel("下载进度")
                    .accessibilityValue("\(percent)%")
            }
            Text(progressDescription)
                .font(PapriaDesign.metadata.weight(.medium))
                .foregroundStyle(color)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
        }
    }
}

private struct DownloadStatusLine: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(PapriaDesign.metadata.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(3)
            .accessibilityElement(children: .combine)
    }
}

private struct RemoteDetailFailure: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("无法获取文件", systemImage: "exclamationmark.triangle")
                .font(PapriaDesign.sectionTitle)
                .foregroundStyle(PapriaIOSDesign.statusError)
            Text(message)
                .font(PapriaDesign.metadata)
                .foregroundStyle(PapriaIOSDesign.inkSecondary)
            if canRetry {
                Button("重试", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
            } else {
                Text("连接网络后可重试。")
                    .font(PapriaDesign.metadata)
                    .foregroundStyle(PapriaIOSDesign.inkSecondary)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct RemoteDetailCacheNotice: View {
    let message: String
    let canRetry: Bool
    let isOffline: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DownloadStatusLine(
                icon: isOffline ? "wifi.slash" : "exclamationmark.triangle",
                text: message,
                color: PapriaIOSDesign.statusWarning
            )
            if canRetry {
                Button("重新获取文件列表", action: retry)
                    .buttonStyle(.bordered)
                    .tint(PapriaIOSDesign.actionPrimary)
                    .frame(minHeight: PapriaDesign.minimumHitTarget)
                    .accessibilityLabel("重新获取 BookOrbit 文件列表")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadTaskCenterView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("papria.onlyWiFiDownloads") private var onlyWiFiDownloads = false
    @State private var showingClearCompletedConfirmation = false

    private var tasks: [AppEnvironment.DownloadTaskItem] {
        environment.downloadTaskItems
    }

    private var completedTaskIDs: [Int64] {
        tasks.compactMap { item in
            if case .completed? = environment.downloadStates[item.id] { return item.id }
            return nil
        }
    }

    private var hasUnfinishedTasks: Bool {
        tasks.contains { item in
            guard let phase = environment.downloadStates[item.id] else { return true }
            if case .completed = phase { return false }
            return true
        }
    }

    /// `downloadTaskItems` is already ordered by AppEnvironment's actual
    /// restored/enqueued task order. Count only genuine waiting phases so the
    /// number means this task's current place among waiting downloads.
    private var waitingTaskIDs: [Int64] {
        tasks.compactMap { item in
            switch environment.downloadStates[item.id] {
            case .waitingForNetwork, .waitingForWiFi:
                return item.id
            default:
                return nil
            }
        }
    }

    private func waitingQueuePosition(for item: AppEnvironment.DownloadTaskItem) -> Int? {
        guard let index = waitingTaskIDs.firstIndex(of: item.id) else { return nil }
        return index + 1
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                taskList.scrollContentBackground(.hidden)
            } else {
                taskList
            }
        }
        .background(PapriaIOSDesign.canvas)
        .navigationTitle("下载任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingClearCompletedConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .frame(width: PapriaDesign.minimumHitTarget, height: PapriaDesign.minimumHitTarget)
                }
                .disabled(completedTaskIDs.isEmpty)
                .accessibilityLabel("清除已完成任务")
                .accessibilityHint("清除所有已完成下载任务记录，不会删除本地文件")
            }
        }
        .confirmationDialog(
            "清除已完成任务？",
            isPresented: $showingClearCompletedConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除已完成", role: .destructive) {
                environment.clearCompletedDownloadTasks()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if hasUnfinishedTasks {
                Text("队列中仍有未完成下载。清除已完成任务不会取消这些下载，本地文件也会保留。")
            } else {
                Text("将清除 \(completedTaskIDs.count) 个已完成任务记录；本地文件会保留。")
            }
        }
    }

    private var taskList: some View {
        List {
            Section {
                Toggle("仅 Wi-Fi 下载", isOn: $onlyWiFiDownloads)
                    .tint(PapriaIOSDesign.actionPrimary)
            } footer: {
                Text("等待 Wi-Fi 的任务会保留在队列中，连接 Wi-Fi 后继续。")
            }
            .listRowBackground(PapriaIOSDesign.canvas)

            if !environment.isNetworkAvailable {
                Section {
                    DownloadStatusLine(
                        icon: "wifi.slash",
                        text: "离线：仅显示已缓存内容；下载任务将等待网络",
                        color: PapriaIOSDesign.statusWarning
                    )
                }
                .listRowBackground(PapriaIOSDesign.canvas)
            }

            if tasks.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                        Text("没有下载任务")
                            .font(PapriaDesign.sectionTitle)
                        Text("从 BookOrbit 书籍详情中选择文件下载。")
                            .font(PapriaDesign.metadata)
                            .foregroundStyle(PapriaIOSDesign.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
                    .listRowBackground(PapriaIOSDesign.canvas)
                }
            } else {
                Section("任务") {
                    ForEach(tasks) { item in
                        RemoteFileRow(
                            bookID: item.bookID,
                            file: item.file,
                            waitingQueuePosition: waitingQueuePosition(for: item),
                            completedStatusText: "已完成"
                        )
                        .listRowBackground(PapriaIOSDesign.canvas)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct DownloadTaskToolbarIcon: View {
    let count: Int

    var body: some View {
        Image(systemName: "arrow.down.circle")
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(PapriaDesign.badgeLabel)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(PapriaIOSDesign.actionPrimary)
                        .clipShape(Capsule())
                        .offset(x: 8, y: -7)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct TaskSummaryBanner: View {
    let summary: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
            Text(summary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(PapriaDesign.metadata.weight(.medium))
        .foregroundStyle(PapriaIOSDesign.inkPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(PapriaIOSDesign.raised)
        .overlay(alignment: .top) { Divider().overlay(PapriaIOSDesign.lineSubtle) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared visual components

private enum PapriaIOSDesign {
    static let canvas = Color(red: 247.0 / 255.0, green: 242.0 / 255.0, blue: 232.0 / 255.0)
    static let raised = Color(red: 1, green: 252.0 / 255.0, blue: 246.0 / 255.0)
    static let inkPrimary = Color(red: 32.0 / 255.0, green: 34.0 / 255.0, blue: 31.0 / 255.0)
    static let inkSecondary = Color(red: 111.0 / 255.0, green: 108.0 / 255.0, blue: 99.0 / 255.0)
    static let lineSubtle = Color(red: 216.0 / 255.0, green: 208.0 / 255.0, blue: 195.0 / 255.0)
    static let actionPrimary = Color(red: 183.0 / 255.0, green: 70.0 / 255.0, blue: 50.0 / 255.0)
    static let statusSuccess = Color(red: 45.0 / 255.0, green: 113.0 / 255.0, blue: 104.0 / 255.0)
    static let statusRemote = Color(red: 61.0 / 255.0, green: 102.0 / 255.0, blue: 139.0 / 255.0)
    static let statusWarning = Color(red: 156.0 / 255.0, green: 102.0 / 255.0, blue: 26.0 / 255.0)
    static let statusError = actionPrimary
}

private struct PublicationCover: View {
    let format: String
    let title: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(PapriaIOSDesign.inkPrimary)
            VStack(spacing: 6) {
                Image(systemName: PapriaFileKinds.symbol(for: format))
                    .font(.system(size: min(width, height) * 0.28, weight: .medium))
                Text(format.uppercased())
                    .font(PapriaDesign.badgeLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(PapriaIOSDesign.canvas)
            .padding(4)
        }
        .frame(width: width, height: height)
        .accessibilityLabel("\(format.uppercased()) 封面，\(title)")
    }
}

private struct RemoteCover: View {
    @EnvironmentObject private var environment: AppEnvironment
    let bookID: Int64
    let title: String
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let url = environment.coverURLs[bookID], let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(PapriaIOSDesign.statusRemote)
                    Image(systemName: "book.closed")
                        .font(.system(size: min(width, height) * 0.3, weight: .medium))
                        .foregroundStyle(PapriaIOSDesign.canvas)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(PapriaIOSDesign.lineSubtle, lineWidth: 1)
        }
        .accessibilityLabel("BookOrbit 封面，\(title)")
    }
}

private struct FormatBadge: View {
    let format: String

    var body: some View {
        Text(format.uppercased())
            .font(PapriaDesign.badgeLabel)
            .foregroundStyle(PapriaIOSDesign.statusRemote)
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .background(PapriaIOSDesign.statusRemote.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(PapriaIOSDesign.statusRemote.opacity(0.35), lineWidth: 1)
            }
            .accessibilityLabel("格式 \(format.uppercased())")
    }
}

private enum PapriaFileKinds {
    static func isAudio(_ format: String) -> Bool {
        ["m4b", "m4a", "mp3", "opus", "ogg", "flac"].contains(format.lowercased())
    }

    static func symbol(for format: String) -> String {
        switch format.lowercased() {
        case "pdf": return "doc.richtext"
        case "cbz", "cbr", "cb7": return "rectangle.stack"
        case let value where isAudio(value): return "headphones"
        default: return "book.closed"
        }
    }
}

private func activeDownloadTaskCount(_ states: [Int64: AppEnvironment.DownloadPhase]) -> Int {
    states.values.reduce(into: 0) { count, state in
        switch state {
        case .completed:
            break
        case .waitingForNetwork, .waitingForWiFi, .downloading, .paused, .failed:
            count += 1
        }
    }
}

private func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

private func displayServerName(_ serverURL: String) -> String {
    guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "未配置服务器"
    }
    return URL(string: serverURL)?.host ?? serverURL
}
