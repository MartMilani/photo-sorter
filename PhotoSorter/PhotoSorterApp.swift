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

/// Which of a RAW+compressed pair the user wants to look at while sorting.
enum PhotoFormat: String, CaseIterable {
    case compressed, raw
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

    /// True once a folder is loaded that looks like RAW+compressed pairs, until
    /// the user picks how to view/copy them. Drives the format-choice screen.
    var needsFormatChoice: Bool = false
    var pairCount: Int = 0
    var detectedRawExts: [String] = []
    var detectedCompressedExts: [String] = []

    let imageCache = ImageCache()

    private var undoStack: [(source: URL, destinations: [URL])] = []
    private var destinationFolderName: String = ""
    private var prefetchTask: Task<Void, Never>?

    /// Display URL → every file that belongs to that photo (for "copy all").
    private var siblings: [URL: [URL]] = [:]
    private var copyAllFiles: Bool = false
    /// Pending file groups awaiting the user's format choice (one per photo).
    private var fileGroups: [[URL]] = []

    private let picturesURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]

    private static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2",
    ]
    private static let compressedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "hif", "tiff", "tif",
    ]
    private static var supportedExtensions: Set<String> {
        rawExtensions.union(compressedExtensions)
    }

    private func isRaw(_ url: URL) -> Bool {
        Self.rawExtensions.contains(url.pathExtension.lowercased())
    }

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

        let supported = contents
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }

        // Group files that share a base name (e.g. IMG_1234.CR2 + IMG_1234.JPG).
        let groups = Dictionary(grouping: supported) {
            $0.deletingPathExtension().lastPathComponent.lowercased()
        }
        let groupList = groups.values.map { $0 }
        let pairs = groupList.filter { group in
            group.contains(where: isRaw) && group.contains(where: { !isRaw($0) })
        }

        // If most photos exist as a RAW+compressed pair, ask how to handle them.
        if pairs.count >= 2, Double(pairs.count) / Double(groupList.count) >= 0.5 {
            fileGroups = groupList
            pairCount = pairs.count
            detectedRawExts = uniqueExts(pairs.flatMap { $0 }.filter(isRaw))
            detectedCompressedExts = uniqueExts(pairs.flatMap { $0 }.filter { !isRaw($0) })
            needsFormatChoice = true
        } else {
            buildPhotos(from: groupList, view: .compressed, copyAll: false)
        }
    }

    /// Build the sorting queue from grouped files using the chosen view format.
    private func buildPhotos(from groups: [[URL]], view: PhotoFormat, copyAll: Bool) {
        copyAllFiles = copyAll
        var display: [URL] = []
        var sibs: [URL: [URL]] = [:]
        for group in groups {
            let chosen = group.first { isRaw($0) == (view == .raw) } ?? group.first
            guard let chosen else { continue }
            display.append(chosen)
            sibs[chosen] = group
        }
        photos = display.sorted { $0.lastPathComponent < $1.lastPathComponent }
        siblings = sibs
        currentIndex = 0
        isComplete = photos.isEmpty
        undoStack = []
        fileGroups = []
        needsFormatChoice = false
    }

    /// Called from the format-choice screen once the user has decided.
    func applyFormatChoice(view: PhotoFormat, copyAll: Bool) {
        buildPhotos(from: fileGroups, view: view, copyAll: copyAll)
    }

    private func uniqueExts(_ urls: [URL]) -> [String] {
        Array(Set(urls.map { "." + $0.pathExtension.lowercased() })).sorted()
    }

    func sort(into category: String) {
        guard let photo = current else { return }

        let base = destinationFolderName.isEmpty ? picturesURL : picturesURL.appendingPathComponent(destinationFolderName)
        let folder = base.appendingPathComponent(category)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let filesToCopy = copyAllFiles ? (siblings[photo] ?? [photo]) : [photo]
        var copied: [URL] = []
        for src in filesToCopy {
            var dest = folder.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                let stem = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                dest = folder.appendingPathComponent("\(stem)_\(Int(Date().timeIntervalSince1970)).\(ext)")
            }
            if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                copied.append(dest)
            }
        }

        guard !copied.isEmpty else { return }
        undoStack.append((source: photo, destinations: copied))
        advance()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        for dest in last.destinations {
            try? FileManager.default.removeItem(at: dest)
        }
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
        siblings = [:]
        fileGroups = []
        needsFormatChoice = false
    }

    private func advance() {
        if currentIndex + 1 >= photos.count {
            isComplete = true
        } else {
            currentIndex += 1
        }
    }
}
