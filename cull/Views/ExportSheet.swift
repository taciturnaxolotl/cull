import SwiftUI

struct ExportSheet: View {
    @Environment(CullSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var fileType: ExportFileType = .both
    @State private var exportMode: ExportMode = .copy
    @State private var minimumRating: Int = 1
    @State private var pickedOnly: Bool = false
    @State private var destination: URL?
    @State private var isExporting: Bool = false
    @State private var result: ExportResult?

    @State private var excludeRejects: Bool = true

    private var eligiblePhotos: [Photo] {
        session.allPhotos.filter { photo in
            if excludeRejects && photo.flag == .reject { return false }
            if pickedOnly && photo.flag != .pick { return false }
            if minimumRating > 0 && photo.rating < minimumRating { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Photos")
                .font(.title2.bold())

            Form {
                Picker("File Type", selection: $fileType) {
                    ForEach(ExportFileType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }

                Picker("Mode", selection: $exportMode) {
                    ForEach(ExportMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Picker("Minimum Rating", selection: $minimumRating) {
                    Text("Any rating").tag(0)
                    ForEach(1...5, id: \.self) { rating in
                        Text(String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating))
                            .tag(rating)
                    }
                }

                Toggle("Picked only", isOn: $pickedOnly)
                Toggle("Exclude rejected", isOn: $excludeRejects)

                HStack {
                    if let destination {
                        Text(destination.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No destination selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose...") { chooseDestination() }
                }
            }
            .formStyle(.grouped)

            Text("\(eligiblePhotos.count) photos will be \(exportMode == .move ? "moved" : "copied")")
                .foregroundStyle(.secondary)

            if let result {
                VStack(spacing: 4) {
                    Text("Exported \(result.exported) files")
                        .foregroundStyle(.green)
                    if !result.errors.isEmpty {
                        Text("\(result.errors.count) errors")
                            .foregroundStyle(.red)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(result.errors.prefix(10), id: \.self) { error in
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .frame(maxHeight: 80)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Export") { runExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil || isExporting || eligiblePhotos.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose export destination"

        if panel.runModal() == .OK {
            destination = panel.url
        }
    }

    private func runExport() {
        guard let destination else { return }
        isExporting = true
        let photos = eligiblePhotos
        let sourceFolder = session.sourceFolder

        Task {
            // Access security-scoped resources
            let destAccess = destination.startAccessingSecurityScopedResource()
            let srcAccess = sourceFolder?.startAccessingSecurityScopedResource() ?? false
            defer {
                if destAccess { destination.stopAccessingSecurityScopedResource() }
                if srcAccess { sourceFolder?.stopAccessingSecurityScopedResource() }
            }

            let exportResult = await PhotoExporter.export(
                photos: photos,
                destination: destination,
                fileType: fileType,
                mode: exportMode
            )
            await MainActor.run {
                result = exportResult
                isExporting = false
            }
        }
    }
}
