import SwiftUI

struct ContentView: View {
    @Environment(CullSession.self) private var session
    @State private var showExportSheet = false
    @FocusState private var isViewerFocused: Bool

    var body: some View {
        Group {
            if session.sourceFolder == nil {
                ImportView()
            } else if session.isImporting {
                VStack(spacing: 16) {
                    Text("Analyzing photos...")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    ProgressView(value: session.importProgress)
                        .frame(width: 300)
                    Text("\(Int(session.importProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No supported photos found")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button("Choose Another Folder") { session.sourceFolder = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cullingView
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
    }

    private var cullingView: some View {
        HStack(spacing: 0) {
            // Left: Groups column
            GroupListView()
                .frame(width: 120)

            Divider()

            // Middle: Photos in selected group
            GroupDetailView()
                .frame(width: 160)

            Divider()

            // Right: Large preview
            PhotoViewer()
        }
        .focusable()
        .focused($isViewerFocused)
        .focusEffectDisabled()
        // Narrative-style: ↑/↓ = photos, ←/→ = scenes/groups
        .onKeyPress(.upArrow) { session.moveToPreviousPhoto(); return .handled }
        .onKeyPress(.downArrow) { session.moveToNextPhoto(); return .handled }
        .onKeyPress(.leftArrow) { session.moveToPreviousGroup(); return .handled }
        .onKeyPress(.rightArrow) { session.moveToNextGroup(); return .handled }
        .onKeyPress(keys: ["p"]) { _ in session.togglePick(); return .handled }
        .onKeyPress(keys: ["x"]) { _ in session.toggleReject(); return .handled }
        .onKeyPress(keys: ["0"]) { _ in session.clearRatingAndFlag(); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            if let digit = Int(press.characters), (1...5).contains(digit) {
                session.setRating(digit)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: ["e"]) { _ in showExportSheet = true; return .handled }
        .onAppear { isViewerFocused = true }
        .onChange(of: session.selectedGroupIndex) { isViewerFocused = true }
        .onChange(of: session.selectedPhotoIndex) { isViewerFocused = true }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Button { session.togglePick() } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .help("Pick (P)")

                    Button { session.toggleReject() } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Reject (X)")
                }
            }

            ToolbarItem(placement: .automatic) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Button { session.setRating(star) } label: {
                            Image(systemName: star <= (session.selectedPhoto?.rating ?? 0) ? "star.fill" : "star")
                                .foregroundStyle(star <= (session.selectedPhoto?.rating ?? 0) ? .yellow : .secondary)
                        }
                        .help("Rate \(star)")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Spacer()
            }

            ToolbarItem(placement: .automatic) {
                Button { showExportSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export (E)")
            }

            ToolbarItem(placement: .automatic) {
                Button { session.sourceFolder = nil } label: {
                    Image(systemName: "folder")
                }
                .help("Open Folder")
            }
        }
    }
}
