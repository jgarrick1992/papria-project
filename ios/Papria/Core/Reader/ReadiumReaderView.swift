import ReadiumAdapterGCDWebServer
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import SwiftUI
import UIKit

/// The production Readium path for EPUB/KEPUB and PDF publications.
///
/// Readium keeps its own `Locator` model while BookOrbit stores an EPUB CFI or
/// a PDF page number. This adapter keeps the BookOrbit payload unchanged and
/// converts only at the UI boundary: incoming EPUB CFIs become Readium partial
/// CFIs, and outgoing partial CFIs are rebuilt as standard, package-rooted
/// EPUB CFIs.
struct ReadiumReaderView: UIViewControllerRepresentable {
    enum Format {
        case epub
        case pdf
    }

    let url: URL
    let format: Format
    @Binding var progressLoaded: Bool
    @Binding var percentage: Double
    @Binding var pageNumber: Int
    @Binding var cfi: String?
    let onProgress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            progressLoaded: $progressLoaded,
            percentage: $percentage,
            pageNumber: $pageNumber,
            cfi: $cfi,
            onProgress: onProgress
        )
    }

    func makeUIViewController(context: Context) -> ReadiumReaderHostViewController {
        ReadiumReaderHostViewController(
            url: url,
            format: format,
            initialPercentage: percentage,
            initialPageNumber: pageNumber,
            initialCFI: cfi,
            onLocation: context.coordinator.receive
        )
    }

    func updateUIViewController(_ uiViewController: ReadiumReaderHostViewController, context: Context) {
        // A navigator owns its pagination state. Recreating it every time the
        // BookOrbit progress binding changes would cause a page jump loop.
    }

    final class Coordinator {
        private let progressLoaded: Binding<Bool>
        private let percentage: Binding<Double>
        private let pageNumber: Binding<Int>
        private let cfi: Binding<String?>
        private let onProgress: () -> Void

        init(
            progressLoaded: Binding<Bool>,
            percentage: Binding<Double>,
            pageNumber: Binding<Int>,
            cfi: Binding<String?>,
            onProgress: @escaping () -> Void
        ) {
            self.progressLoaded = progressLoaded
            self.percentage = percentage
            self.pageNumber = pageNumber
            self.cfi = cfi
            self.onProgress = onProgress
        }

        @MainActor
        func receive(_ location: ReadiumReaderLocation) {
            percentage.wrappedValue = location.percentage
            if let pageNumber = location.pageNumber {
                self.pageNumber.wrappedValue = pageNumber
            }
            if let cfi = location.cfi {
                self.cfi.wrappedValue = cfi
            }
            if progressLoaded.wrappedValue {
                onProgress()
            }
        }
    }
}

struct ReadiumReaderLocation {
    let percentage: Double
    let pageNumber: Int?
    let cfi: String?
}

@MainActor
final class ReadiumReaderHostViewController: UIViewController, EPUBNavigatorDelegate, PDFNavigatorDelegate {
    private enum ReaderError: LocalizedError {
        case invalidFileURL
        case unsupportedPublication

        var errorDescription: String? {
            switch self {
            case .invalidFileURL:
                return "阅读文件路径无效"
            case .unsupportedPublication:
                return "该文件与选择的 Readium 阅读器不匹配"
            }
        }
    }

    private let url: URL
    private let format: ReadiumReaderView.Format
    private let initialPercentage: Double
    private let initialPageNumber: Int
    private let initialCFI: String?
    private let onLocation: @MainActor (ReadiumReaderLocation) -> Void

    private let httpClient: HTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener
    private let httpServer: HTTPServer
    private var navigator: (UIViewController & Navigator)?
    private var openTask: Task<Void, Never>?

    init(
        url: URL,
        format: ReadiumReaderView.Format,
        initialPercentage: Double,
        initialPageNumber: Int,
        initialCFI: String?,
        onLocation: @escaping @MainActor (ReadiumReaderLocation) -> Void
    ) {
        self.url = url
        self.format = format
        self.initialPercentage = initialPercentage
        self.initialPageNumber = max(1, initialPageNumber)
        self.initialCFI = initialCFI
        self.onLocation = onLocation

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.httpClient = httpClient
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        httpServer = GCDHTTPServer(assetRetriever: assetRetriever)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        openTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        showLoading()
        openTask = Task { [weak self] in
            await self?.openPublication()
        }
    }

    private func openPublication() async {
        do {
            guard let fileURL = ReadiumShared.FileURL(url: url) else {
                throw ReaderError.invalidFileURL
            }

            let assetResult = await assetRetriever.retrieve(url: fileURL)
            let asset = try assetResult.get()
            let publicationResult = await publicationOpener.open(
                asset: asset,
                allowUserInteraction: false,
                sender: self
            )
            let publication = try publicationResult.get()

            switch format {
            case .epub:
                guard publication.conforms(to: .epub) else {
                    throw ReaderError.unsupportedPublication
                }
                let navigator = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: await initialEPUBLocation(in: publication)
                )
                navigator.delegate = self
                install(navigator)

            case .pdf:
                guard publication.conforms(to: .pdf) else {
                    throw ReaderError.unsupportedPublication
                }
                let navigator = try PDFNavigatorViewController(
                    publication: publication,
                    initialLocation: initialPDFLocation(in: publication),
                    delegate: self,
                    httpServer: httpServer
                )
                install(navigator)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func install(_ navigator: UIViewController & Navigator) {
        guard self.navigator == nil else { return }
        removeNavigator()
        self.navigator = navigator
        addChild(navigator)
        navigator.view.frame = view.bounds
        navigator.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(navigator.view)
        navigator.didMove(toParent: self)
    }

    private func initialEPUBLocation(in publication: Publication) async -> Locator? {
        if
            let cfi = initialCFI,
            let point = EpubCFILocator.parse(cfi),
            let partialCFI = Self.partialCFI(from: cfi),
            publication.readingOrder.indices.contains(point.spineIndex)
        {
            let link = publication.readingOrder[point.spineIndex]
            return Locator(
                href: link.url(),
                mediaType: link.mediaType ?? .xhtml,
                locations: .init(otherLocations: ["partialCfi": partialCFI])
            )
        }

        let progression = min(max(initialPercentage / 100, 0), 1)
        return await publication.locate(progression: progression)
    }

    private func initialPDFLocation(in publication: Publication) -> Locator? {
        guard let link = publication.readingOrder.first else { return nil }
        return Locator(
            href: link.url(),
            mediaType: link.mediaType ?? .pdf,
            locations: .init(position: initialPageNumber)
        )
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        let percentage = min(max((locator.locations.totalProgression ?? locator.locations.progression ?? 0) * 100, 0), 100)
        let cfi: String?
        switch format {
        case .epub:
            cfi = Self.fullCFI(from: locator, publication: navigator.publication)
        case .pdf:
            cfi = nil
        }
        onLocation(
            ReadiumReaderLocation(
                percentage: percentage,
                pageNumber: locator.locations.position,
                cfi: cfi
            )
        )
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        showError(error.localizedDescription)
    }

    private func showLoading() {
        removeNavigator()
        view.subviews.forEach { $0.removeFromSuperview() }
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func showError(_ message: String) {
        removeNavigator()
        view.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12

        let title = UILabel()
        title.text = "无法打开文件"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        let filename = UILabel()
        filename.text = url.lastPathComponent
        filename.font = .preferredFont(forTextStyle: .subheadline)
        filename.adjustsFontForContentSizeCategory = true
        filename.numberOfLines = 2
        filename.textAlignment = .center

        let reason = UILabel()
        reason.text = readableErrorMessage(message)
        reason.font = .preferredFont(forTextStyle: .footnote)
        reason.adjustsFontForContentSizeCategory = true
        reason.numberOfLines = 0
        reason.textColor = .secondaryLabel
        reason.textAlignment = .center

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        var backConfiguration = UIButton.Configuration.bordered()
        backConfiguration.title = "返回书库"
        let back = UIButton(configuration: backConfiguration)
        back.titleLabel?.font = .preferredFont(forTextStyle: .body)
        back.titleLabel?.adjustsFontForContentSizeCategory = true
        back.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        back.addAction(UIAction { [weak self] _ in self?.returnToLibrary() }, for: .touchUpInside)

        var retryConfiguration = UIButton.Configuration.filled()
        retryConfiguration.title = "重试"
        let retry = UIButton(configuration: retryConfiguration)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        retry.addAction(UIAction { [weak self] _ in self?.retryOpening() }, for: .touchUpInside)

        buttons.addArrangedSubview(back)
        buttons.addArrangedSubview(retry)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(filename)
        stack.addArrangedSubview(reason)
        stack.addArrangedSubview(buttons)
        stack.accessibilityLabel = "无法打开文件：\(url.lastPathComponent)。\(readableErrorMessage(message))"
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func readableErrorMessage(_ message: String) -> String {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty || detail == "The operation couldn’t be completed."
            ? "文件可能已损坏、受保护，或格式与阅读器不匹配。"
            : detail
    }

    private func retryOpening() {
        openTask?.cancel()
        showLoading()
        openTask = Task { [weak self] in
            await self?.openPublication()
        }
    }

    private func returnToLibrary() {
        if let navigationController, navigationController.topViewController === self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func removeNavigator() {
        guard navigator != nil else { return }
        children.forEach { child in
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        navigator = nil
    }

    private static func partialCFI(from cfi: String) -> String? {
        guard cfi.hasPrefix("epubcfi("), cfi.hasSuffix(")") else { return nil }
        let start = cfi.index(cfi.startIndex, offsetBy: "epubcfi(".count)
        let end = cfi.index(before: cfi.endIndex)
        let body = cfi[start..<end]
        guard let separator = body.firstIndex(of: "!") else { return nil }
        let partial = String(body[body.index(after: separator)...])
        return partial.hasPrefix("/") ? partial : nil
    }

    private static func fullCFI(from locator: Locator, publication: Publication) -> String? {
        guard
            let partialCFI = locator.locations.partialCFI,
            let spineIndex = publication.readingOrder.firstIndexWithHREF(locator.href)
        else {
            return nil
        }
        // In an EPUB CFI the OPF spine item-ref is /6/<even step>; the
        // right-hand partial CFI comes directly from Readium's locator.
        let spineStep = 2 * (spineIndex + 2)
        return "epubcfi(/6/\(spineStep)!\(partialCFI))"
    }
}
