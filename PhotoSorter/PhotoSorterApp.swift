import SwiftUI
import Observation
import AppKit
import ImageIO

/// Decodes and caches *render-ready* `NSImage`s off the main thread. A
/// byte-budgeted LRU keeps as many decoded neighbours as fit under `budget`,
/// so two-way browsing stays instant while memory stays bounded regardless of
/// display size (a screen-sized RAW decode is tens of MB). Images are fully
/// decoded and downsampled to the display size here, so the main thread never
/// pays a decode cost when the image is drawn.
actor ImageCache {
    private struct Entry { let image: NSImage; let bytes: Int }

    private var cache: [URL: Entry] = [:]
    private var order: [URL] = []        // least- to most-recently used
    private var totalBytes = 0

    /// Soft ceiling on resident decoded pixels. ~1 GB leaves a generous window
    /// of neighbours cached on either side while keeping the footprint bounded.
    private let budget = 1_024 * 1_024 * 1_024

    @discardableResult
    func load(_ url: URL, maxPixelSize: Int) -> NSImage? {
        if let existing = cache[url] {
            touch(url)
            return existing.image
        }
        guard let (image, bytes) = Self.decode(url, maxPixelSize: maxPixelSize) else { return nil }
        cache[url] = Entry(image: image, bytes: bytes)
        order.append(url)
        totalBytes += bytes
        trim()
        return image
    }

    /// Decode to a fully-rasterized, screen-sized image. `CreateThumbnail` +
    /// `ShouldCacheImmediately` forces the pixel decode to happen now (off the
    /// main thread), and downsampling a 24MP RAW to screen size is what makes
    /// this fast. Falls back to `NSImage(contentsOf:)` for anything ImageIO
    /// can't read. Returns the image and an estimate of its resident bytes.
    private static func decode(_ url: URL, maxPixelSize: Int) -> (NSImage, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url).map { ($0, estimatedBytes($0)) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url).map { ($0, estimatedBytes($0)) }
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, cg.width * cg.height * 4)   // 4 bytes/pixel (RGBA8)
    }

    private static func estimatedBytes(_ image: NSImage) -> Int {
        Int(image.size.width * image.size.height) * 4
    }

    private func touch(_ url: URL) {
        if let idx = order.firstIndex(of: url) {
            order.remove(at: idx)
            order.append(url)
        }
    }

    /// Evict least-recently-used entries until under budget, but always keep at
    /// least the most recent entry so the visible image is never dropped.
    private func trim() {
        while totalBytes > budget, order.count > 1 {
            let evicted = order.removeFirst()
            totalBytes -= cache.removeValue(forKey: evicted)?.bytes ?? 0
        }
    }
}

/// Which of a RAW+compressed pair the user wants to look at while sorting.
enum PhotoFormat: String, CaseIterable {
    case compressed, raw
}

/// The bucket a photo can be sorted into. Raw value is also the folder name.
enum Category: String, CaseIterable {
    case good, maybe, bad
}

/// What a single sorted photo became on disk: its category and the file(s) the
/// app copied into that category folder (used for re-sort and undo).
struct SortRecord {
    var category: Category
    var destinations: [URL]
}

/// Persisted record of a sorting session, rewritten on every decision and on
/// quit. Lives at `<destination>/manifest.json`. The `view`/`copyAll`/`current`
/// fields are optional so manifests written by older builds still decode.
struct Manifest: Codable {
    var folderName: String
    var sourceFolder: String
    var updated: Date
    var view: String?        // PhotoFormat raw value; nil → .compressed
    var copyAll: Bool?       // nil → false
    var current: String?     // filename of the photo last viewed
    var sorted: [Entry]
    var unsorted: [String]

    struct Entry: Codable {
        var photo: String
        var category: String
        var copies: [String]
    }
}

/// One unfinished session offered on the start screen for resuming.
struct ResumableSession: Identifiable {
    var id: String { folderName }
    var folderName: String
    var sortedCount: Int
    var totalCount: Int
    var updated: Date
}

@main
struct PhotoSorterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView(vm: delegate.vm)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
    }
}

/// Owns the single `SorterViewModel` (shared with the UI) so we can intercept
/// quit — both ⌘Q / the menu and the in-app "Quit" button route through
/// `NSApp.terminate`, so `applicationShouldTerminate` catches every path.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let vm = SorterViewModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        vm.writeManifest()

        let pending = vm.unsortedFilenames
        guard !pending.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "\(pending.count) photo\(pending.count == 1 ? "" : "s") still unsorted"
        alert.informativeText = "These photos haven't been sorted yet. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Review")       // .alertFirstButtonReturn
        alert.addButton(withTitle: "Quit Anyway")  // .alertSecondButtonReturn
        alert.accessoryView = Self.unsortedList(pending)

        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    /// Scrollable list of the unsorted filenames, capped so the alert can't grow
    /// unbounded on a large shoot.
    private static func unsortedList(_ names: [String]) -> NSView {
        let cap = 200
        var shown = names.prefix(cap).joined(separator: "\n")
        if names.count > cap { shown += "\n…and \(names.count - cap) more" }

        let text = NSTextView()
        text.string = shown
        text.isEditable = false
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 160))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }
}

@Observable
@MainActor
final class SorterViewModel {
    var photos: [URL] = []
    var currentIndex: Int = 0
    var isComplete: Bool = false

    /// Per-photo decision: display URL → where it was sorted. Drives the color
    /// strip, the current-photo badge, the counts, and the unsorted list.
    private(set) var sortStates: [URL: SortRecord] = [:]

    /// True once a folder is loaded that looks like RAW+compressed pairs, until
    /// the user picks how to view/copy them. Drives the format-choice screen.
    var needsFormatChoice: Bool = false
    var pairCount: Int = 0
    var detectedRawExts: [String] = []
    var detectedCompressedExts: [String] = []

    /// Set when a folder can't be loaded (e.g. the destination already exists).
    /// Shown to the user; cleared on the next pick.
    var loadError: String?

    let imageCache = ImageCache()

    /// Each entry captures enough to fully reverse one decision: the photo, its
    /// prior record (nil if it was unsorted), and the files just copied.
    private var undoStack: [(photo: URL, previous: SortRecord?, copied: [URL])] = []
    private var destinationFolderName: String = ""
    private var sourceFolderURL: URL?
    private var prefetchTask: Task<Void, Never>?

    /// Display URL → every file that belongs to that photo (for "copy all").
    private var siblings: [URL: [URL]] = [:]
    private var copyAllFiles: Bool = false
    /// The view format chosen for this session; persisted so resume can rebuild
    /// the same display list and siblings.
    private var viewFormat: PhotoFormat = .compressed
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

    /// The category a photo has been sorted into, or nil if still pending.
    func category(for url: URL?) -> Category? {
        guard let url else { return nil }
        return sortStates[url]?.category
    }

    // MARK: Navigation (no file I/O — just moves the cursor)

    func goPrev() { if currentIndex > 0 { currentIndex -= 1 } }
    func goNext() { if currentIndex < photos.count - 1 { currentIndex += 1 } }

    /// Source filenames of every photo that still has no category.
    var unsortedFilenames: [String] {
        photos.filter { sortStates[$0] == nil }.map { $0.lastPathComponent }
    }

    /// Per-category tallies plus how many remain, for the on-screen readout.
    var summary: String {
        var good = 0, maybe = 0, bad = 0
        for url in photos {
            switch sortStates[url]?.category {
            case .good:  good += 1
            case .maybe: maybe += 1
            case .bad:   bad += 1
            case nil:    break
            }
        }
        let left = photos.count - good - maybe - bad
        return "\(good) ✓ · \(maybe) ? · \(bad) ✗ · \(left) left"
    }

    /// Longest edge, in pixels, to decode images at. Sized to the screen so a
    /// 24MP RAW is downsampled instead of fully rasterized. Generous default
    /// covers a Retina full-screen window until the view reports the real size.
    var maxPixelSize: Int = 4096

    /// How many neighbours on each side to warm up. The cache's byte budget is
    /// the real ceiling; this just bounds how far ahead we look.
    private let prefetchRadius = 3

    /// Decode the neighbours around the current photo in the background so
    /// browsing either direction is instant. Loads nearest-first (next, prev,
    /// +2, −2, …) in a single cancellable task, so rapid navigation drops stale
    /// work and always favours where the user is now.
    func prefetchAround() {
        prefetchTask?.cancel()
        let size = maxPixelSize
        let index = currentIndex

        // Build the nearest-first list of valid neighbour URLs.
        var targets: [URL] = []
        for step in 1...prefetchRadius {
            for offset in [step, -step] {
                let i = index + offset
                if photos.indices.contains(i) { targets.append(photos[i]) }
            }
        }
        guard !targets.isEmpty else { return }

        prefetchTask = Task.detached(priority: .utility) { [imageCache] in
            for url in targets {
                if Task.isCancelled { return }
                await imageCache.load(url, maxPixelSize: size)
            }
        }
    }

    var progress: String {
        photos.isEmpty ? "" : "\(currentIndex + 1) / \(photos.count)"
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Root for all sorted output: ~/Pictures/PhotoSorter (created on demand).
    private var rootURL: URL {
        picturesURL.appendingPathComponent("PhotoSorter")
    }

    /// Where sorted photos for this run will be written.
    private func destinationBase(for folderName: String) -> URL {
        folderName.isEmpty ? rootURL : rootURL.appendingPathComponent(folderName)
    }

    /// Whether a destination folder of this name already exists. Used to give
    /// the picker live feedback before the user commits to a name.
    func destinationExists(for folderName: String) -> Bool {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: destinationBase(for: trimmed).path)
    }

    func load(from folder: URL, into folderName: String) {
        loadError = nil
        destinationFolderName = folderName
        sourceFolderURL = folder

        // Never reuse an existing destination — refuse rather than risk mixing
        // new sorted photos into a folder that already has content.
        let base = destinationBase(for: folderName)
        if !folderName.isEmpty, FileManager.default.fileExists(atPath: base.path) {
            loadError = "A folder named “\(folderName)” already exists in ~/Pictures/PhotoSorter. Choose a different name to avoid overwriting it."
            return
        }

        guard let groupList = scanGroups(in: folder) else { return }
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

    /// Scan a folder into groups of files sharing a base name (e.g.
    /// IMG_1234.CR2 + IMG_1234.JPG). Returns nil if the folder can't be read.
    private func scanGroups(in folder: URL) -> [[URL]]? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let supported = contents
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
        let groups = Dictionary(grouping: supported) {
            $0.deletingPathExtension().lastPathComponent.lowercased()
        }
        return groups.values.map { $0 }
    }

    /// Pick the displayed file from each group for the chosen view format and
    /// map it to its full sibling group. Returns the name-sorted display list
    /// plus the siblings lookup.
    private func displayList(from groups: [[URL]], view: PhotoFormat) -> ([URL], [URL: [URL]]) {
        var display: [URL] = []
        var sibs: [URL: [URL]] = [:]
        for group in groups {
            let chosen = group.first { isRaw($0) == (view == .raw) } ?? group.first
            guard let chosen else { continue }
            display.append(chosen)
            sibs[chosen] = group
        }
        return (display.sorted { $0.lastPathComponent < $1.lastPathComponent }, sibs)
    }

    /// Build a fresh sorting queue from grouped files using the chosen view format.
    private func buildPhotos(from groups: [[URL]], view: PhotoFormat, copyAll: Bool) {
        copyAllFiles = copyAll
        viewFormat = view
        let (display, sibs) = displayList(from: groups, view: view)
        photos = display
        siblings = sibs
        currentIndex = 0
        sortStates = [:]
        isComplete = false
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

    func sort(into category: Category) {
        guard let photo = current else { return }
        let previous = sortStates[photo]

        // Already in this category — nothing to do.
        if previous?.category == category { return }

        // Copy into the new category first; only after that succeeds do we delete
        // the old copies, so a failed copy can never destroy an existing file.
        let copied = copyGroup(for: photo, into: category)
        guard !copied.isEmpty else { return }

        if let previous {
            for dest in previous.destinations {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        sortStates[photo] = SortRecord(category: category, destinations: copied)
        undoStack.append((photo: photo, previous: previous, copied: copied))
        recomputeCompletion()
        writeManifest()
        // Stay put — the user navigates with the arrow keys.
    }

    /// Copy a photo's source file(s) into the given category folder, returning
    /// the destination URLs actually created. Shared by sort and undo-restore.
    private func copyGroup(for photo: URL, into category: Category) -> [URL] {
        let folder = destinationBase(for: destinationFolderName)
            .appendingPathComponent(category.rawValue)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let filesToCopy = copyAllFiles ? (siblings[photo] ?? [photo]) : [photo]
        var copied: [URL] = []
        for src in filesToCopy {
            let dest = uniqueDestination(for: src, in: folder)
            if (try? FileManager.default.copyItem(at: src, to: dest)) != nil {
                copied.append(dest)
            }
        }
        return copied
    }

    /// A destination path that does not yet exist, so a copy can never clobber
    /// an existing file. Appends " 2", " 3", … to the stem until one is free.
    private func uniqueDestination(for src: URL, in folder: URL) -> URL {
        let stem = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        var candidate = folder.appendingPathComponent(src.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }

        // Remove the files this decision wrote.
        for dest in entry.copied {
            try? FileManager.default.removeItem(at: dest)
        }

        // Restore the prior state: re-copy into the old category if there was
        // one, otherwise the photo goes back to unsorted.
        if let previous = entry.previous {
            let restored = copyGroup(for: entry.photo, into: previous.category)
            sortStates[entry.photo] = SortRecord(category: previous.category, destinations: restored)
        } else {
            sortStates.removeValue(forKey: entry.photo)
        }

        if let idx = photos.firstIndex(of: entry.photo) {
            currentIndex = idx
        }
        recomputeCompletion()
        writeManifest()
    }

    func reset() {
        photos = []
        currentIndex = 0
        sortStates = [:]
        isComplete = false
        undoStack = []
        siblings = [:]
        fileGroups = []
        needsFormatChoice = false
        loadError = nil
        sourceFolderURL = nil
    }

    /// All photos sorted → trigger the Done screen. Recomputed after every
    /// decision, so undoing one drops back out of "complete".
    private func recomputeCompletion() {
        isComplete = !photos.isEmpty && photos.allSatisfy { sortStates[$0] != nil }
    }

    /// Write the session record next to the sorted output. Rewritten on every
    /// decision and on quit; skipped when no folder is loaded.
    func writeManifest() {
        guard !photos.isEmpty else { return }
        let base = destinationBase(for: destinationFolderName)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let sorted = photos.compactMap { photo -> Manifest.Entry? in
            guard let record = sortStates[photo] else { return nil }
            return Manifest.Entry(
                photo: photo.lastPathComponent,
                category: record.category.rawValue,
                copies: record.destinations.map { $0.lastPathComponent }
            )
        }

        let manifest = Manifest(
            folderName: destinationFolderName,
            sourceFolder: sourceFolderURL?.path ?? "",
            updated: Date(),
            view: viewFormat.rawValue,
            copyAll: copyAllFiles,
            current: current?.lastPathComponent,
            sorted: sorted,
            unsorted: unsortedFilenames
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: base.appendingPathComponent("manifest.json"), options: .atomic)
    }

    // MARK: - Resume

    /// Read and decode the manifest for a destination folder, if present.
    private func readManifest(_ folderName: String) -> Manifest? {
        let url = destinationBase(for: folderName).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// Every unfinished session under the PhotoSorter root, most recent first.
    /// Completed shoots (nothing left unsorted) are not offered.
    func resumableSessions() -> [ResumableSession] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return dirs.compactMap { dir -> ResumableSession? in
            guard let manifest = readManifest(dir.lastPathComponent),
                  !manifest.unsorted.isEmpty else { return nil }
            return ResumableSession(
                folderName: manifest.folderName,
                sortedCount: manifest.sorted.count,
                totalCount: manifest.sorted.count + manifest.unsorted.count,
                updated: manifest.updated
            )
        }
        .sorted { $0.updated > $1.updated }
    }

    /// Reopen a previously-saved session: re-scan its source folder, rebuild the
    /// queue with the same view/copy choices, restore each photo's category, and
    /// land on the photo last viewed.
    func resume(_ folderName: String) {
        loadError = nil

        guard let manifest = readManifest(folderName) else {
            loadError = "Couldn't read the saved session for “\(folderName)”."
            return
        }

        let source = URL(fileURLWithPath: manifest.sourceFolder)
        guard let groups = scanGroups(in: source) else {
            loadError = "The original folder for “\(folderName)” could not be found at \(manifest.sourceFolder)."
            return
        }

        destinationFolderName = manifest.folderName
        sourceFolderURL = source
        viewFormat = PhotoFormat(rawValue: manifest.view ?? "") ?? .compressed
        copyAllFiles = manifest.copyAll ?? false

        let (display, sibs) = displayList(from: groups, view: viewFormat)
        photos = display
        siblings = sibs
        undoStack = []
        fileGroups = []
        needsFormatChoice = false

        // Restore per-photo decisions, matching by filename. Photos in the
        // manifest but no longer in the source are skipped; new photos stay
        // unsorted. Destination URLs are rebuilt so re-sort/undo work.
        let entriesByName = Dictionary(manifest.sorted.map { ($0.photo, $0) }) { first, _ in first }
        var states: [URL: SortRecord] = [:]
        for photo in photos {
            guard let entry = entriesByName[photo.lastPathComponent],
                  let category = Category(rawValue: entry.category) else { continue }
            let folder = destinationBase(for: destinationFolderName)
                .appendingPathComponent(category.rawValue)
            let destinations = entry.copies.map { folder.appendingPathComponent($0) }
            states[photo] = SortRecord(category: category, destinations: destinations)
        }
        sortStates = states

        // Open on the photo last viewed, else the first unsorted, else the start.
        if let name = manifest.current,
           let idx = photos.firstIndex(where: { $0.lastPathComponent == name }) {
            currentIndex = idx
        } else if let idx = photos.firstIndex(where: { sortStates[$0] == nil }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }

        recomputeCompletion()
    }
}
