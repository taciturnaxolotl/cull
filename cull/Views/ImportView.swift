import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Open a folder of photos to start culling")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button {
                openFolder()
            } label: {
                HStack(spacing: 8) {
                    Text("Open Folder")
                    Text("\u{2318}O")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o")

            Text("or drag a folder here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragging ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.hasDirectoryPath else { return }
                Task { @MainActor in
                    NotificationCenter.default.post(name: .openFolder, object: url)
                }
            }
            return true
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing photos"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        NotificationCenter.default.post(name: .openFolder, object: url)
    }
}
