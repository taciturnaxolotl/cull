import SwiftUI

struct ExportSheet: View {
    @Environment(CullSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var fileType: ExportFileType = .both
    @State private var exportMode: ExportMode = .copy
    @State private var folderStructure: ExportFolderStructure = .flat
    @State private var destination: URL?
    @State private var isExporting: Bool = false
    @State private var result: ExportResult?
    @State private var useCurrentFilters: Bool = true

    private var eligiblePhotos: [Photo] {
        if useCurrentFilters {
            return session.allPhotos.filter { !session.isPhotoFiltered($0) }
        }
        return session.allPhotos
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Export Photos")
                .font(.title2.bold())

            Form {
                Toggle("Export only visible photos", isOn: $useCurrentFilters)

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

                Picker("Folder Structure", selection: $folderStructure) {
                    ForEach(ExportFolderStructure.allCases) { structure in
                        Text(structure.rawValue).tag(structure)
                    }
                }

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
                    Text("Exported \(result.exported) photos")
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

                let canExport = destination != nil && !isExporting && !eligiblePhotos.isEmpty
                Button("Export") { runExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
                    .opacity(canExport ? 1.0 : 0.4)
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
                mode: exportMode,
                folderStructure: folderStructure
            )
            await MainActor.run {
                result = exportResult
                isExporting = false
            }
        }
    }
}
