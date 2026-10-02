import SwiftUI

/// Everything downloaded or converted, ready to send to SimplePlayer.
struct LibraryView: View {
    @State private var files: [URL] = []
    @State private var share: ShareItem?

    var body: some View {
        NavigationView {
            List {
                ForEach(files, id: \.self) { file in
                    Button { share = ShareItem(url: file) } label: {
                        HStack {
                            Image(systemName: "music.note").foregroundColor(.orange)
                            Text(file.deletingPathExtension().lastPathComponent)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "square.and.arrow.up").foregroundColor(.pink)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { try? FileManager.default.removeItem(at: files[i]) }
                    reload()
                }
            }
            .listStyle(.plain)
            .overlay {
                if files.isEmpty {
                    Text("Your downloads show up here.\nTap one to send it to SimplePlayer.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Library")
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(item: $share) { ShareSheet(url: $0.url) }
        }
        .navigationViewStyle(.stack)
    }

    private func reload() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: keys)) ?? []
        func date(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
        }
        files = all
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { date($0) > date($1) }
    }
}
