import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    var vm: SorterViewModel

    var body: some View {
        if vm.needsFormatChoice {
            FormatChoiceView(vm: vm)
        } else if vm.photos.isEmpty {
            PickerView(vm: vm)
        } else if vm.isComplete {
            DoneView(vm: vm)
        } else {
            SorterView(vm: vm)
        }
    }
}

// MARK: - RAW + Compressed format choice

struct FormatChoiceView: View {
    var vm: SorterViewModel

    @State private var viewFormat: PhotoFormat = .compressed
    @State private var copyAll: Bool = true

    private var rawLabel: String {
        "RAW" + (vm.detectedRawExts.isEmpty ? "" : " (\(vm.detectedRawExts.joined(separator: ", ")))")
    }
    private var compressedLabel: String {
        "Compressed" + (vm.detectedCompressedExts.isEmpty ? "" : " (\(vm.detectedCompressedExts.joined(separator: ", ")))")
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("RAW + Compressed Pairs")
                    .font(.system(size: 24, weight: .thin))
                Text("Found \(vm.pairCount) photos saved in two formats.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("View while sorting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $viewFormat) {
                    Text(compressedLabel).tag(PhotoFormat.compressed)
                    Text(rawLabel).tag(PhotoFormat.raw)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(width: 380)

            VStack(alignment: .leading, spacing: 8) {
                Text("When sorting, copy")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("", selection: $copyAll) {
                    Text("Both formats").tag(true)
                    Text("Only the viewed format").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(width: 380)

            Button("Start Sorting") {
                vm.applyFormatChoice(view: viewFormat, copyAll: copyAll)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(width: 500, height: 360)
    }
}

// MARK: - Folder Picker

struct PickerView: View {
    var vm: SorterViewModel

    @State private var folderName: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()
    @State private var nameTaken = false
    @State private var sessions: [ResumableSession] = []

    // Re-check the destination on disk periodically so feedback stays accurate
    // even if a folder of the same name appears/disappears outside the app.
    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedName: String {
        folderName.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Photo Sorter")
                .font(.system(size: 28, weight: .thin))
            Text("Choose a folder of photos to sort.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Choose Folder") { pick() }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .disabled(nameTaken || trimmedName.isEmpty)
                Text("→  ~/Pictures/PhotoSorter/")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            feedback
            resumeSection
        }
        .frame(width: 500, height: sessions.isEmpty ? 260 : 460)
        .onAppear { refresh() }
        .onChange(of: folderName) { refresh() }
        .onReceive(pollTimer) { _ in refresh() }
    }

    /// Unfinished sessions offered for resuming, shown only when any exist.
    @ViewBuilder
    private var resumeSection: some View {
        if !sessions.isEmpty {
            Divider().frame(width: 420)
            Text("Resume a session")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.folderName)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(session.sortedCount) / \(session.totalCount) sorted")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { vm.resume(session.folderName) }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.12)))
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: 430, height: 150)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = vm.loadError {
            label(error, color: .red)
        } else if trimmedName.isEmpty {
            label("Enter a name for the destination folder.", color: .secondary)
        } else if nameTaken {
            label("“\(trimmedName)” already exists — choose a different name.", color: .red)
        } else {
            label("“\(trimmedName)” is available.", color: .green)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(width: 420)
    }

    private func refresh() {
        nameTaken = vm.destinationExists(for: folderName)
        sessions = vm.resumableSessions()
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                vm.load(from: url, into: folderName)
            }
        }
    }
}

// MARK: - Sorter

struct SorterView: View {
    var vm: SorterViewModel
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let url = vm.current {
                PhotoView(url: url, vm: vm)
                    .id(url)
            }

            VStack {
                HStack(alignment: .top) {
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(12)
                    Spacer()
                    if let category = vm.category(for: vm.current) {
                        CategoryBadge(category: category)
                            .padding(.top, 12)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(vm.progress)
                        Text(vm.summary)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(12)
                }
                Spacer()
                SortStrip(vm: vm)
                    .padding(.horizontal, 40)
                Text("1 bad    2 maybe    3 good    ←/→ browse    ⌘Z undo")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.top, 8)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startListening()
            // Decode to the screen's longest edge in backing pixels — no point
            // rasterizing larger than the display can show.
            if let screen = NSScreen.main {
                let scale = screen.backingScaleFactor
                let longest = max(screen.frame.width, screen.frame.height) * scale
                vm.maxPixelSize = Int(longest.rounded())
            }
        }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 18: vm.sort(into: .bad);   return nil  // 1
            case 19: vm.sort(into: .maybe); return nil  // 2
            case 20: vm.sort(into: .good);  return nil  // 3
            case 123: vm.goPrev(); return nil           // ←  browse
            case 124: vm.goNext(); return nil           // →  browse
            case 6 where event.modifierFlags.contains(.command):
                vm.undo(); return nil                    // ⌘Z
            default: return event
            }
        }
    }

    private func stopListening() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

extension Category {
    /// Strip / badge colour. good = green, maybe = yellow, bad = red.
    var color: Color {
        switch self {
        case .good:  return .green
        case .maybe: return .yellow
        case .bad:   return .red
        }
    }
}

/// A colored pill naming the current photo's category.
struct CategoryBadge: View {
    let category: Category

    var body: some View {
        Text(category.rawValue.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(category.color))
    }
}

/// One proportional segment per photo, colored by its category (grey =
/// unsorted), with a white cursor at the current index. Drawn with `Canvas`
/// so it scales to thousands of photos without per-segment view overhead and
/// without decoding any thumbnails (keeping memory for the image cache).
struct SortStrip: View {
    var vm: SorterViewModel

    var body: some View {
        // Read observable state here in `body` so SwiftUI tracks it and redraws
        // the Canvas when any of it changes.
        let photos = vm.photos
        let states = vm.sortStates
        let currentIndex = vm.currentIndex

        Canvas { context, size in
            let n = photos.count
            guard n > 0 else { return }
            let w = size.width / CGFloat(n)
            let gap: CGFloat = w > 3 ? 1 : 0

            for (i, url) in photos.enumerated() {
                let color = states[url]?.category.color ?? Color.white.opacity(0.18)
                let rect = CGRect(x: CGFloat(i) * w, y: 0, width: max(w - gap, 0.5), height: size.height)
                context.fill(Path(rect), with: .color(color))
            }

            // Current-position cursor: a thin white bar, clamped on screen.
            let markerW = max(w, 2.5)
            let markerX = min(max(CGFloat(currentIndex) * w + w / 2 - markerW / 2, 0), size.width - markerW)
            context.fill(
                Path(roundedRect: CGRect(x: markerX, y: -1, width: markerW, height: size.height + 2), cornerRadius: 1),
                with: .color(.white)
            )
        }
        .frame(height: 8)
    }
}

struct PhotoView: View {
    let url: URL
    var vm: SorterViewModel
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = await vm.imageCache.load(url, maxPixelSize: vm.maxPixelSize)
            vm.prefetchAround()
        }
    }
}

// MARK: - Done

struct DoneView: View {
    var vm: SorterViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Done")
                .font(.system(size: 28, weight: .thin))
            Text("All \(vm.photos.count) photos sorted.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if vm.canUndo {
                    Button("Undo Last") { vm.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                }
                Button("Sort Another Folder") { vm.reset() }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.large)
            }
        }
        .frame(width: 380, height: 260)
    }
}
