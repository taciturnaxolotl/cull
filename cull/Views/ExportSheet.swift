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

    private var eligibleCount: Int {
        session.allPhotos.filter { photo in
            if pickedOnly && photo.flag != .pick { return false }
            if photo.flag == .reject { return false }
            return photo.rating >= minimumRating
        }.count
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
                    Text("All (unrated included)").tag(0)
                    ForEach(1...5, id: \.self) { rating in
                        HStack(spacing: 1) {
                            ForEach(1...rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                            }
                        }
                        .tag(rating)
                    }
                }

                Toggle("Picked only", isOn: $pickedOnly)

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

            Text("\(eligibleCount) photos will be \(exportMode == .move ? "moved" : "copied")")
                .foregroundStyle(.secondary)

            if let result {
                VStack(spacing: 4) {
                    Text("Exported \(result.exported) files")
                        .foregroundStyle(.green)
                    if !result.errors.isEmpty {
                        Text("\(result.errors.count) errors")
                            .foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Export") { runExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil || isExporting || eligibleCount == 0)
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

        Task {
            let options = ExportOptions(
                destination: destination,
                fileType: fileType,
                mode: exportMode,
                minimumRating: minimumRating,
                includePickedOnly: pickedOnly
            )
            let exportResult = try? await PhotoExporter.export(
                photos: session.allPhotos,
                options: options
            )
            await MainActor.run {
                result = exportResult
                isExporting = false
            }
        }
    }
}
