import SwiftUI
import PDFKit
import WebKit
import ZIPFoundation

// MARK: - Library

/// Books & audiobooks library.
struct BooksLibraryView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let library: BaseItem
    @State private var items: [BaseItem] = []
    @State private var total = Int.max
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            if let error { ErrorBanner(message: error) { Task { await reload() } } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 108), spacing: 14)], spacing: 20) {
                ForEach(items) { book in
                    NavigationLink(value: book) { PosterCard(item: book, fixedWidth: false) }
                        .buttonStyle(CardPressStyle())
                        .overlay(alignment: .topLeading) {
                            if book.isAudiobook {
                                Image(systemName: "headphones").font(.caption.bold())
                                    .padding(6).background(Theme.gradient, in: Circle()).padding(6)
                            }
                        }
                        .onAppear { if book.id == items.last?.id { Task { await loadMore() } } }
                }
            }
            .padding()
            if loading { ProgressView().padding() }
        }
        .background(TintedBackdrop(color: ArtColor(hue: 0.08, saturation: 0.7, brightness: 0.8)))
        .navigationTitle(library.name ?? "Books")
        .task { if items.isEmpty { await loadMore() } }
        .refreshable { await reload() }
    }

    private func reload() async { items = []; total = Int.max; await loadMore() }

    private func loadMore() async {
        guard let client = app.client, !loading, items.count < total else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await client.browse([
                "parentId": library.id, "includeItemTypes": "Book,AudioBook", "recursive": "true",
                "sortBy": "SortName", "startIndex": String(items.count), "limit": "100",
            ])
            items += r.items
            total = r.totalRecordCount ?? items.count
            error = nil
        } catch {
            self.error = error.localizedDescription
            total = items.count
        }
    }
}

// MARK: - Detail

struct BookDetailView: View {
    @Environment(AppState.self) private var app
    let book: BaseItem
    @State private var color: ArtColor?
    @State private var file: BookFile?
    @State private var downloading = false
    @State private var error: String?
    @State private var reading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { RemoteImage(url: app.client?.posterURL(for: book, width: 700)) }
                    .frame(maxWidth: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: (color?.background ?? .black).opacity(0.8), radius: 24, y: 12)
                    .padding(.top, 12)
                Text(book.name ?? "").font(.title2.weight(.bold)).multilineTextAlignment(.center).padding(.horizontal)
                if let artist = book.artistLine {
                    Text(artist).font(.headline).foregroundStyle(color?.accent ?? Theme.accent)
                }
                Text([book.productionYear.map(String.init), book.runtimeText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if book.isAudiobook {
                        Button { listen() } label: {
                            Label(book.progress != nil ? "Resume" : "Listen", systemImage: "headphones")
                        }
                        .buttonStyle(PlayButtonStyle())
                    } else {
                        Button { Task { await openReader() } } label: {
                            HStack {
                                if downloading { ProgressView().tint(.black) }
                                Label("Read", systemImage: "book.fill")
                            }
                        }
                        .buttonStyle(PlayButtonStyle())
                        .disabled(downloading)
                        if let file {
                            ShareLink(item: file.url) {
                                Label("Open in…", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    if app.client != nil {
                        DownloadButton(item: book)
                    }
                }
                if let p = book.progress { ProgressBar(value: p).frame(maxWidth: 220) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                if let overview = book.overview {
                    Text(overview).font(.callout).foregroundStyle(.white.opacity(0.85)).padding(.horizontal)
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .background(TintedBackdrop(color: color))
        .navigationBarTitleDisplayMode(.inline)
        .artColor(from: app.client?.posterURL(for: book, width: 300), into: $color)
        .fullScreenCover(isPresented: $reading) {
            if let file { BookReaderScreen(book: book, file: file) }
        }
    }

    private func listen() {
        guard let client = app.client else { return }
        Task {
            // Multi-file audiobooks: queue the other parts in the same folder, in order.
            var parts = [book]
            if let parent = book.parentId,
               let siblings = try? await client.browse(["parentId": parent, "includeItemTypes": "AudioBook",
                                                         "sortBy": "SortName"]).items, siblings.count > 1 {
                parts = siblings
            }
            let start = parts.firstIndex { $0.id == book.id } ?? 0
            AudioPlayer.shared.play(parts, startAt: start, client: client)
            AudioPlayer.shared.showNowPlaying = true
        }
    }

    private func openReader() async {
        let client = app.client
        downloading = true
        defer { downloading = false }
        do {
            file = try await BookFile.fetch(book, client: client)
            error = nil
            reading = true
        } catch {
            self.error = "Couldn't open this book: \(error.localizedDescription)"
        }
    }
}

// MARK: - Files

struct BookFile {
    enum Kind { case pdf, epub, comic, other }
    let url: URL
    let kind: Kind

    static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Books")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func kind(for ext: String) -> Kind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "epub": return .epub
        case "cbz", "zip": return .comic
        default: return .other
        }
    }

    /// Downloads the original book file once and keeps it in the cache.
    static func fetch(_ book: BaseItem, client: JellyfinClient?) async throws -> BookFile {
        // Downloaded in the Downloads tab? Read it offline.
        if let local = await MainActor.run(body: { DownloadManager.shared.localFile(for: book.id) }) {
            return BookFile(url: local, kind: kind(for: local.pathExtension))
        }
        guard let client else { throw JellyfinError.noMediaSource }
        if let cached = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            .first(where: { $0.deletingPathExtension().lastPathComponent == book.id && !$0.hasDirectoryPath }) {
            return BookFile(url: cached, kind: kind(for: cached.pathExtension))
        }
        var request = URLRequest(url: client.originalDownloadURL(itemId: book.id))
        request.setValue(client.authorizationHeader, forHTTPHeaderField: "Authorization")
        let (temp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JellyfinError.http(http.statusCode)
        }
        var ext = (response.suggestedFilename as NSString?)?.pathExtension ?? ""
        if ext.isEmpty { ext = "epub" }
        let dest = cacheDir.appendingPathComponent("\(book.id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return BookFile(url: dest, kind: kind(for: ext))
    }

    /// Unzips EPUB/CBZ once into a folder next to the file.
    func unpacked() throws -> URL {
        let dir = url.deletingPathExtension().appendingPathExtension("unzipped")
        if FileManager.default.fileExists(atPath: dir.path) { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: dir)
        return dir
    }
}

/// Remembers reading position per book on this device.
enum ReadingPosition {
    static func get(_ id: String) -> (index: Int, fraction: Double) {
        let d = UserDefaults.standard
        return (d.integer(forKey: "read.\(id).index"), d.double(forKey: "read.\(id).fraction"))
    }
    static func set(_ id: String, index: Int, fraction: Double = 0) {
        UserDefaults.standard.set(index, forKey: "read.\(id).index")
        UserDefaults.standard.set(fraction, forKey: "read.\(id).fraction")
    }
}

// MARK: - Reader shell

struct BookReaderScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let book: BaseItem
    let file: BookFile

    var body: some View {
        NavigationStack {
            Group {
                switch file.kind {
                case .pdf: PDFReader(book: book, url: file.url, onFinished: finished)
                case .epub: EPUBReader(book: book, file: file, onFinished: finished)
                case .comic: ComicReader(book: book, file: file, onFinished: finished)
                case .other:
                    ContentUnavailableView {
                        Label("Can't open this format here", systemImage: "book.closed")
                    } description: {
                        Text("Lumen reads EPUB, PDF and CBZ. Use Open in… to read this \(file.url.pathExtension.uppercased()) in another app.")
                    } actions: {
                        ShareLink(item: file.url) { Label("Open in…", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PlayButtonStyle())
                    }
                }
            }
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            .navigationTitle(book.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Open in another app")
                }
            }
        }
    }

    private func finished() {
        guard let client = app.client else { return }
        Task { await client.markPlayed(book.id) }
    }
}

// MARK: - PDF

struct PDFReader: UIViewRepresentable {
    let book: BaseItem
    let url: URL
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bookId: book.id, onFinished: onFinished) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        view.document = PDFDocument(url: url)
        if let doc = view.document {
            let saved = ReadingPosition.get(book.id).index
            if saved > 0, let page = doc.page(at: min(saved, doc.pageCount - 1)) { view.go(to: page) }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}

    final class Coordinator: NSObject {
        let bookId: String
        let onFinished: () -> Void
        var reportedFinish = false
        init(bookId: String, onFinished: @escaping () -> Void) { self.bookId = bookId; self.onFinished = onFinished }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView, let doc = view.document, let page = view.currentPage else { return }
            let index = doc.index(for: page)
            ReadingPosition.set(bookId, index: index)
            if index >= doc.pageCount - 1, !reportedFinish { reportedFinish = true; onFinished() }
        }
    }
}

// MARK: - EPUB

/// Minimal, fast EPUB reader: unzips the book, follows the OPF spine, shows one chapter at a time in a
/// web view with a dark theme and adjustable text size.
struct EPUBReader: View {
    let book: BaseItem
    let file: BookFile
    let onFinished: () -> Void

    @State private var chapters: [URL] = []
    @State private var root: URL?
    @State private var index = 0
    @State private var restoreFraction: Double = 0
    @State private var fontScale: Double = UserDefaults.standard.double(forKey: "reader.fontScale").nonZero ?? 1.0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                ContentUnavailableView("Couldn't open book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let root, chapters.indices.contains(index) {
                EPUBWebView(chapter: chapters[index], root: root, fontScale: fontScale, restoreFraction: restoreFraction) { fraction in
                    ReadingPosition.set(book.id, index: index, fraction: fraction)
                }
                .id(index)
                controls
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { load() }
    }

    private var controls: some View {
        HStack {
            Button { go(to: index - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
                .accessibilityLabel("Previous chapter")
            Spacer()
            Button { setFont(fontScale - 0.1) } label: { Text("A").font(.footnote.bold()) }
                .accessibilityLabel("Smaller text")
            Text("\(index + 1) / \(chapters.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 70)
            Button { setFont(fontScale + 0.1) } label: { Text("A").font(.title3.bold()) }
                .accessibilityLabel("Larger text")
            Spacer()
            Button { go(to: index + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= chapters.count - 1)
                .accessibilityLabel("Next chapter")
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func setFont(_ v: Double) {
        fontScale = min(2, max(0.7, v))
        UserDefaults.standard.set(fontScale, forKey: "reader.fontScale")
    }

    private func go(to i: Int) {
        guard chapters.indices.contains(i) else { return }
        restoreFraction = 0
        index = i
        ReadingPosition.set(book.id, index: i)
        if i == chapters.count - 1 { onFinished() }
    }

    private func load() {
        guard chapters.isEmpty else { return }
        do {
            let dir = try file.unpacked()
            let spine = try EPUBSpine.chapters(in: dir)
            guard !spine.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            root = dir
            chapters = spine
            let saved = ReadingPosition.get(book.id)
            index = min(saved.index, spine.count - 1)
            restoreFraction = saved.fraction
        } catch {
            self.error = "This EPUB couldn't be read (\(error.localizedDescription)). Try Open in… → Books."
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

enum EPUBSpine {
    /// container.xml → OPF → spine order → chapter file URLs.
    static func chapters(in dir: URL) throws -> [URL] {
        let container = try Data(contentsOf: dir.appendingPathComponent("META-INF/container.xml"))
        let rootPath = XMLAttributeFinder.first(in: container, element: "rootfile", attribute: "full-path") ?? "content.opf"
        let opfURL = dir.appendingPathComponent(rootPath)
        let opf = try Data(contentsOf: opfURL)
        let parser = OPFParser()
        let xml = XMLParser(data: opf)
        xml.delegate = parser
        xml.shouldProcessNamespaces = true
        xml.parse()
        let base = opfURL.deletingLastPathComponent()
        return parser.spine.compactMap { idref in
            guard let href = parser.manifest[idref] else { return nil }
            let clean = href.removingPercentEncoding ?? href
            return base.appendingPathComponent(clean)
        }
    }
}

final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"] != "no" { spine.append(idref) }
        default: break
        }
    }
}

final class XMLAttributeFinder: NSObject, XMLParserDelegate {
    private let element: String
    private let attribute: String
    private(set) var value: String?

    init(element: String, attribute: String) { self.element = element; self.attribute = attribute }

    static func first(in data: Data, element: String, attribute: String) -> String? {
        let finder = XMLAttributeFinder(element: element, attribute: attribute)
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = finder
        p.parse()
        return finder.value
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if value == nil, elementName == element { value = attributes[attribute] }
    }
}

struct EPUBWebView: UIViewRepresentable {
    let chapter: URL
    let root: URL
    let fontScale: Double
    let restoreFraction: Double
    let onScroll: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll, restoreFraction: restoreFraction) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let css = """
        html { background: #0d0d12 !important; }
        body { background: #0d0d12 !important; color: #e9e7ef !important; line-height: 1.65; \
        font-family: -apple-system, Georgia, serif; padding: 12px 20px 60px; max-width: 42em; margin: 0 auto; }
        a { color: #b8a6ff !important; } img, svg { max-width: 100% !important; height: auto !important; }
        p { text-align: justify; hyphens: auto; }
        """
        let js = """
        var s = document.createElement('style'); s.innerHTML = `\(css)`; document.head.appendChild(s);
        document.body.style.fontSize = '\(Int(fontScale * 100))%';
        """
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "scroll")
        config.userContentController.addUserScript(WKUserScript(source: """
        window.addEventListener('scroll', function() {
          var h = document.documentElement.scrollHeight - window.innerHeight;
          window.webkit.messageHandlers.scroll.postMessage(h > 0 ? window.scrollY / h : 0);
        });
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        web.navigationDelegate = context.coordinator
        web.loadFileURL(chapter, allowingReadAccessTo: root)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        web.evaluateJavaScript("document.body.style.fontSize = '\(Int(fontScale * 100))%';")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onScroll: (Double) -> Void
        let restoreFraction: Double
        init(onScroll: @escaping (Double) -> Void, restoreFraction: Double) {
            self.onScroll = onScroll
            self.restoreFraction = restoreFraction
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let f = message.body as? Double { onScroll(f) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard restoreFraction > 0 else { return }
            webView.evaluateJavaScript(
                "window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(restoreFraction));")
        }
    }
}

// MARK: - Comics (CBZ)

struct ComicReader: View {
    let book: BaseItem
    let file: BookFile
    let onFinished: () -> Void
    @State private var pages: [URL] = []
    @State private var page = 0
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Couldn't open comic", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if pages.isEmpty {
                ProgressView()
            } else {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, url in
                        ZoomableImage(url: url).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .bottom) {
                    Text("\(page + 1) / \(pages.count)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12)
                }
            }
        }
        .task { load() }
        .onChange(of: page) { _, p in
            ReadingPosition.set(book.id, index: p)
            if p == pages.count - 1 { onFinished() }
        }
    }

    private func load() {
        guard pages.isEmpty else { return }
        do {
            let dir = try file.unpacked()
            let exts: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
            let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { exts.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") } ?? []
            pages = all.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            page = min(ReadingPosition.get(book.id).index, max(0, pages.count - 1))
            if pages.isEmpty { error = "No pages found in this file." }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ZoomableImage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture()
                        .onChanged { scale = max(1, min(4, base * $0.magnification)) }
                        .onEnded { _ in base = scale })
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) { scale = scale > 1 ? 1 : 2; base = scale }
                    }
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
