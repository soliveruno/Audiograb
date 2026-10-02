import SwiftUI
import AVFoundation

// MARK: - Model

struct SongResult: Identifiable {
    let id: String
    let title: String
    let artist: String
    let source: String
    let license: String
    let durationText: String?
    let directURL: URL?     // known up front (Openverse)
    let archiveID: String?  // resolved on tap (Internet Archive)

    var details: String {
        [source, license, durationText ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum SongSearchError: Error { case noPlayableFile }

/// Searches free / openly licensed music sources in parallel.
enum SongSearch {

    static func search(_ query: String) async -> [SongResult] {
        async let ov: [SongResult] = (try? await openverse(query)) ?? []
        async let ia: [SongResult] = (try? await archive(query)) ?? []
        let (a, b) = await (ov, ia)
        // Interleave so both sources show near the top
        var out: [SongResult] = []
        for i in 0..<max(a.count, b.count) {
            if i < a.count { out.append(a[i]) }
            if i < b.count { out.append(b[i]) }
        }
        return out
    }

    // Openverse: aggregates openly licensed audio from Jamendo, Freesound, Wikimedia and more.
    private struct OVResponse: Decodable { let results: [OVItem] }
    private struct OVItem: Decodable {
        let id: String
        let title: String?
        let creator: String?
        let url: String?
        let filetype: String?
        let duration: Int?
        let license: String?
        let source: String?
    }

    static func openverse(_ q: String) async throws -> [SongResult] {
        var c = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "page_size", value: "20")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let r = try JSONDecoder().decode(OVResponse.self, from: data)
        return r.results.compactMap { it in
            guard let s = it.url, let url = URL(string: s) else { return nil }
            let ext = (it.filetype ?? url.pathExtension).lowercased()
            guard audioExtensions.contains(ext) else { return nil }
            return SongResult(
                id: "ov-\(it.id)",
                title: it.title ?? "Untitled",
                artist: it.creator ?? "Unknown artist",
                source: (it.source ?? "openverse").capitalized,
                license: (it.license ?? "").uppercased(),
                durationText: it.duration.map { formatTime(Double($0) / 1000) },
                directURL: url,
                archiveID: nil)
        }
    }

    // Internet Archive: free music collections (netlabels, open-source audio, live concert archive).
    private struct IAResponse: Decodable { let response: IADocs }
    private struct IADocs: Decodable { let docs: [IADoc] }
    private struct IADoc: Decodable {
        let identifier: String
        let title: Flexible?
        let creator: Flexible?
    }
    /// archive.org returns some fields as either a string or an array of strings.
    private struct Flexible: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else { value = (try? c.decode([String].self))?.joined(separator: ", ") ?? "" }
        }
    }

    static func archive(_ q: String) async throws -> [SongResult] {
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [
            .init(name: "q", value: "(\(q)) AND mediatype:(audio) AND collection:(opensource_audio OR netlabels OR etree)"),
            .init(name: "fl[]", value: "identifier"),
            .init(name: "fl[]", value: "title"),
            .init(name: "fl[]", value: "creator"),
            .init(name: "rows", value: "20"),
            .init(name: "output", value: "json")
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        let r = try JSONDecoder().decode(IAResponse.self, from: data)
        return r.response.docs.map { d in
            SongResult(
                id: "ia-\(d.identifier)",
                title: d.title?.value ?? d.identifier,
                artist: d.creator?.value ?? "Unknown artist",
                source: "Internet Archive",
                license: "",
                durationText: nil,
                directURL: nil,
                archiveID: d.identifier)
        }
    }

    private struct IAMeta: Decodable { let files: [IAFile]? }
    private struct IAFile: Decodable { let name: String }

    /// Finds the actual audio file URL for a result.
    static func resolve(_ r: SongResult) async throws -> URL {
        if let u = r.directURL { return u }
        guard let id = r.archiveID,
              let metaURL = URL(string: "https://archive.org/metadata/\(id)") else { throw SongSearchError.noPlayableFile }
        let (data, _) = try await URLSession.shared.data(from: metaURL)
        let meta = try JSONDecoder().decode(IAMeta.self, from: data)
        guard let file = meta.files?.first(where: { $0.name.lowercased().hasSuffix(".mp3") }),
              let path = "\(id)/\(file.name)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://archive.org/download/\(path)") else { throw SongSearchError.noPlayableFile }
        return url
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t > 0 else { return "" }
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - View model

@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SongResult] = []
    @Published var searching = false
    @Published var message: String?
    @Published var previewingID: String?
    @Published var loadingID: String?
    @Published var downloadingID: String?
    @Published var downloaded: [String: URL] = [:]

    private var player: AVPlayer?
    private var resolved: [String: URL] = [:]

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        stopPreview()
        searching = true
        message = nil
        results = []
        results = await SongSearch.search(q)
        searching = false
        if results.isEmpty { message = "No free downloads found for “\(q)”" }
    }

    private func url(for r: SongResult) async throws -> URL {
        if let u = resolved[r.id] { return u }
        let u = try await SongSearch.resolve(r)
        resolved[r.id] = u
        return u
    }

    func togglePreview(_ r: SongResult) async {
        if previewingID == r.id { stopPreview(); return }
        stopPreview()
        loadingID = r.id
        defer { loadingID = nil }
        do {
            let u = try await url(for: r)
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: u)
            p.play()
            player = p
            previewingID = r.id
        } catch {
            message = "Couldn't preview “\(r.title)”"
        }
    }

    func stopPreview() {
        player?.pause()
        player = nil
        previewingID = nil
    }

    func download(_ r: SongResult) async {
        downloadingID = r.id
        defer { downloadingID = nil }
        do {
            let u = try await url(for: r)
            let (tmp, _) = try await URLSession.shared.download(from: u)
            let ext = audioExtensions.contains(u.pathExtension.lowercased()) ? u.pathExtension : "mp3"
            let base = "\(r.artist) - \(r.title)"
                .replacingOccurrences(of: "/", with: "-")
                .prefix(120)
            let dest = documentsDir.appendingPathComponent(String(base)).appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            downloaded[r.id] = dest
        } catch {
            message = "Download failed for “\(r.title)”"
        }
    }
}

// MARK: - Screen

struct SearchView: View {
    @StateObject private var model = SearchModel()
    @State private var share: ShareItem?

    var body: some View {
        NavigationView {
            List {
                if let m = model.message {
                    Text(m).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(model.results) { r in row(r) }
            }
            .listStyle(.plain)
            .overlay {
                if model.searching {
                    ProgressView("Searching…")
                } else if model.results.isEmpty && model.message == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 40))
                        Text("Search free music").font(.headline)
                        Text("Tap ▶ to preview, ↓ to download,\nthen send it to SimplePlayer.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("AudioGrab")
            .searchable(text: $model.query, prompt: "Song, artist or genre")
            .onSubmit(of: .search) { Task { await model.search() } }
            .sheet(item: $share) { ShareSheet(url: $0.url) }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ r: SongResult) -> some View {
        HStack(spacing: 12) {
            // Preview
            Button { Task { await model.togglePreview(r) } } label: {
                ZStack {
                    if model.loadingID == r.id {
                        ProgressView()
                    } else {
                        Image(systemName: model.previewingID == r.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                Text(r.artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                Text(r.details).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            // Download → then Send
            if let file = model.downloaded[r.id] {
                Button { share = ShareItem(url: file) } label: {
                    Image(systemName: "square.and.arrow.up").font(.title2)
                }
                .buttonStyle(.borderless)
                .tint(.pink)
            } else if model.downloadingID == r.id {
                ProgressView()
            } else {
                Button { Task { await model.download(r) } } label: {
                    Image(systemName: "arrow.down.circle").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
