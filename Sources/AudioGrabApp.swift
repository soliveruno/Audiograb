import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct AudioGrabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.orange)
        }
    }
}

// MARK: - Video picker from Photos (iOS 14+)

struct VideoPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                // The provided file is deleted when this closure returns, so copy it now.
                var copied: URL?
                if let url = url {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { copied = dest }
                }
                DispatchQueue.main.async { self.onPick(copied) }
            }
        }
    }
}

// MARK: - Share sheet (iOS 13+)

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Main screen

struct ContentView: View {
    @State private var showPhotos = false
    @State private var showFileImporter = false
    @State private var showShare = false
    @State private var sourceURL: URL?
    @State private var outputURL: URL?
    @State private var status = "Pick a video to start"
    @State private var working = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: outputURL == nil ? "film" : "waveform")
                    .font(.system(size: 64))
                    .foregroundColor(.orange)
                    .padding(.top, 40)

                Text(sourceURL?.lastPathComponent ?? "No video selected")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if working { ProgressView() }

                Spacer()

                // 1. Pick
                HStack(spacing: 12) {
                    Button { showPhotos = true } label: {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                // 2. Convert
                Button {
                    Task { await convert() }
                } label: {
                    Label("Convert to audio", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(sourceURL == nil || working)

                // 3. Send — the share sheet lists SimplePlayer for audio files
                if outputURL != nil {
                    Button { showShare = true } label: {
                        Label("Send to SimplePlayer", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .controlSize(.large)
                }
            }
            .padding()
            .navigationTitle("AudioGrab")
            .sheet(isPresented: $showPhotos) {
                VideoPicker { url in
                    if let url = url { select(url) } else { status = "Couldn't load that video" }
                }
            }
            .sheet(isPresented: $showShare) {
                if let out = outputURL { ShareSheet(url: out) }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.movie, .video, .audiovisualContent]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    select(dest)
                } else {
                    status = "Couldn't open that file"
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func select(_ url: URL) {
        sourceURL = url
        outputURL = nil
        status = "Ready to convert"
    }

    @MainActor
    private func convert() async {
        guard let src = sourceURL else { return }
        working = true
        status = "Converting…"
        defer { working = false }

        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            status = "This video can't be converted"
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = src.deletingPathExtension().lastPathComponent
        let out = docs.appendingPathComponent(name).appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: out)

        export.outputURL = out
        export.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        if export.status == .completed {
            outputURL = out
            status = "Done! Saved as \(out.lastPathComponent)"
        } else {
            status = "Failed: \(export.error?.localizedDescription ?? "unknown error")"
        }
    }
}
