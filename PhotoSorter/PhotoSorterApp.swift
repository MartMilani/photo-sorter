import SwiftUI
import Observation
import AppKit

/// Decodes and caches `NSImage`s off the main thread. A tiny LRU keeps the
/// current image plus the one prefetched image (and the previous, for undo).
actor ImageCache {
    private var cache: [URL: NSImage] = [:]
    private var order: [URL] = []
    private let limit = 3

    @discardableResult
    func load(_ url: URL) -> NSImage? {
        if let existing = cache[url] {
            touch(url)
            return existing
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url] = image
        order.append(url)
        trim()
        return image
    }

    private func touch(_ url: URL) {
        if let idx = order.firstIndex(of: url) {
            order.remove(at: idx)
            order.append(url)
        }
    }

    private func trim() {
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

@main
struct PhotoSorterApp: App {
    @State private var vm = SorterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
    }
}

@Observable
@MainActor
final class SorterViewModel {
    var photos: [URL] = []
    var currentIndex: Int = 0
    var isComplete: Bool = false

    let imageCache = ImageCache()

    private var undoStack: [(source: URL, destination: URL)] = []
    private var destinationFolderName: String = ""
    private var prefetchTask: Task<Void, Never>?

    private let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]

    private static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
    ]

    var current: URL? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    private var nextURL: URL? {
        photos.indices.contains(currentIndex + 1) ? photos[currentIndex + 1] : nil
    }

    /// Decode the next image in the background so it's ready instantly when the
    /// user advances. Only ever one prefetch is in flight at a time.
    func prefetchNext() {
        prefetchTask?.cancel()
        guard let next = nextURL else { return }
        prefetchTask = Task.detached(priority: .utility) { [imageCache] in
            await imageCache.load(next)
        }
    }

    var progress: String {
        photos.isEmpty ? "" : "\(currentIndex + 1) / \(photos.count)"
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func load(from folder: URL, into folderName: String) {
        destinationFolderName = folderName
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return }

        photos = contents
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        currentIndex = 0
        isComplete = photos.isEmpty
        undoStack = []
    }

    func sort(into category: String) {
        guard let photo = current else { return }

        let base = destinationFolderName.isEmpty ? picturesURL : picturesURL.appendingPathComponent(destinationFolderName)
        let folder = base.appendingPathComponent(category)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var dest = folder.appendingPathComponent(photo.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let stem = photo.deletingPathExtension().lastPathComponent
            let ext = photo.pathExtension
            dest = folder.appendingPathComponent("\(stem)_\(Int(Date().timeIntervalSince1970)).\(ext)")
        }

        guard (try? FileManager.default.copyItem(at: photo, to: dest)) != nil else { return }
        undoStack.append((source: photo, destination: dest))
        advance()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        try? FileManager.default.removeItem(at: last.destination)
        if let idx = photos.firstIndex(of: last.source) {
            currentIndex = idx
            isComplete = false
        }
    }

    func reset() {
        photos = []
        currentIndex = 0
        isComplete = false
        undoStack = []
    }

    private func advance() {
        if currentIndex + 1 >= photos.count {
            isComplete = true
        } else {
            currentIndex += 1
        }
    }
}
