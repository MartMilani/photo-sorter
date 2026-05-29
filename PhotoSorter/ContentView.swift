import SwiftUI
import AppKit

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
                Text("→  ~/Pictures/")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            }
            if let error = vm.loadError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 420)
            }
        }
        .frame(width: 500, height: 260)
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
                HStack {
                    Spacer()
                    Text(vm.progress)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(12)
                }
                Spacer()
                Text("← bad    ↓ maybe    → good    ⌘Z undo")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startListening() }
        .onDisappear { stopListening() }
    }

    private func startListening() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123: vm.sort(into: "bad");   return nil  // ←
            case 124: vm.sort(into: "good");  return nil  // →
            case 125: vm.sort(into: "maybe"); return nil  // ↓
            case 6 where event.modifierFlags.contains(.command):
                vm.undo(); return nil                      // ⌘Z
            default: return event
            }
        }
    }

    private func stopListening() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
            image = await vm.imageCache.load(url)
            vm.prefetchNext()
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
            }
        }
        .frame(width: 380, height: 260)
    }
}
