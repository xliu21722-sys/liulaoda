import AppKit
import UniformTypeIdentifiers

/// Images live on the pasteboard. Movies use a private temporary handoff file
/// because file-paste destinations need a URL that survives closing the preview.
@MainActor final class PreviewClipboard {
    static let shared = PreviewClipboard()
    private var movieDirectory: URL?
    private var movieProvider: MoviePasteboardProvider?
    private var pasteboardChangeCount = 0
    private var cleanupTimer: Timer?
    private let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TutorialCaptureClipboard", isDirectory: true)

    private init() { removeExpiredMovies() }

    func copyImage(png: Data) throws {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        try write(item)
        releaseMovie()
    }

    func copyVideo(source: URL, start: Double, end: Double, crop: CGRect, name: String) async throws {
        let directory = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
        let destination = directory.appendingPathComponent(clean.isEmpty ? "未命名" : String(clean.prefix(100))).appendingPathExtension("mp4")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                VideoEditor.export(source: source, to: destination, start: start, end: end, cropRect: crop) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            let item = NSPasteboardItem(), provider = MoviePasteboardProvider(url: destination)
            item.setString(destination.absoluteString, forType: .fileURL)
            item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier)])
            try write(item)
            releaseMovie()
            movieDirectory = directory
            movieProvider = provider
            pasteboardChangeCount = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, NSPasteboard.general.changeCount != self.pasteboardChangeCount else { return }
                    // Clipboard managers may republish the same file. Keep its
                    // handoff alive while the current pasteboard still uses it.
                    if NSPasteboard.general.string(forType: .fileURL) == self.movieProvider?.url.absoluteString {
                        self.pasteboardChangeCount = NSPasteboard.general.changeCount
                        return
                    }
                    self.releaseMovie()
                }
            }
            cleanupTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func write(_ item: NSPasteboardItem) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw NSError(domain: "TutorialCapture.Clipboard", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统剪贴板暂时不可用，请重试"])
        }
    }

    private func releaseMovie() {
        cleanupTimer?.invalidate(); cleanupTimer = nil
        if let movieDirectory { try? FileManager.default.removeItem(at: movieDirectory) }
        movieDirectory = nil; movieProvider = nil
    }

    private func removeExpiredMovies() {
        let fm = FileManager.default
        let currentFile = NSPasteboard.general.string(forType: .fileURL).flatMap(URL.init(string:))
        let currentDirectory = currentFile?.deletingLastPathComponent().standardizedFileURL
        for directory in (try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  directory.standardizedFileURL != currentDirectory,
                  let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  Date().timeIntervalSince(created) > 48 * 3600 else { continue }
            try? fm.removeItem(at: directory)
        }
    }
}

private final class MoviePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL
    init(url: URL) { self.url = url }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) { item.setData(data, forType: type) }
    }
}
