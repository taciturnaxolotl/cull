import SwiftUI

@main
struct CullApp: App {
    @State private var session = CullSession()
    @State private var thumbnailCache = ThumbnailCache()
    @AppStorage("recentFolders") private var recentFoldersData: Data = Data()

    private var recentFolders: [URL] {
        (try? JSONDecoder().decode([String].self, from: recentFoldersData))?.compactMap { URL(fileURLWithPath: $0) } ?? []
    }

    private func addRecentFolder(_ url: URL) {
        var paths = (try? JSONDecoder().decode([String].self, from: recentFoldersData)) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        recentFoldersData = (try? JSONEncoder().encode(paths)) ?? Data()
    }

    var body: some Scene {
        WindowGroup("Cull") {
            ContentView()
                .environment(session)
                .environment(thumbnailCache)
                .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { notification in
                    if let url = notification.object as? URL {
                        addRecentFolder(url)
                    }
                }
        }
        .windowStyle(.automatic)
        .commands {
            // Replace default File menu items
            CommandGroup(replacing: .newItem) {
                Button("Open Folder...") {
                    openFolder()
                }
                .keyboardShortcut("o")

                Toggle("Include Subfolders", isOn: Binding(
                    get: { session.importRecursive },
                    set: { session.importRecursive = $0 }
                ))

                Menu("Open Recent") {
                    ForEach(recentFolders, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            addRecentFolder(url)
                            NotificationCenter.default.post(name: .openFolder, object: url)
                        }
                    }

                    if !recentFolders.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            recentFoldersData = Data()
                        }
                    }
                }
                .disabled(recentFolders.isEmpty)

                Divider()

                Button("Export...") {
                    NotificationCenter.default.post(name: .showExport, object: nil)
                }
                .keyboardShortcut("e")
                .disabled(session.groups.isEmpty)

                Button("Reanalyze Photos") {
                    NotificationCenter.default.post(name: .reimport, object: nil)
                }
                .disabled(session.sourceFolder == nil || session.isImporting)

                Divider()

                Button("Close Folder") {
                    session.sourceFolder = nil
                    session.groups = []
                    thumbnailCache.clearCache()
                }
                .keyboardShortcut("w")
                .disabled(session.sourceFolder == nil)
            }

            // Photo menu
            CommandMenu("Photo") {
                Button("Pick") {
                    session.togglePick()
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(session.selectedPhoto == nil)

                Button("Reject") {
                    session.toggleReject()
                }
                .keyboardShortcut("x", modifiers: [])
                .disabled(session.selectedPhoto == nil)

                Button("Clear Rating & Flag") {
                    session.clearRatingAndFlag()
                }
                .keyboardShortcut("0", modifiers: [])
                .disabled(session.selectedPhoto == nil)

                Divider()

                ForEach(1...5, id: \.self) { star in
                    Button("Rate \(star) Star\(star > 1 ? "s" : "")") {
                        session.setRating(star)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(star)")), modifiers: [])
                    .disabled(session.selectedPhoto == nil)
                }
            }

            // View menu
            CommandMenu("View") {
                Button("Zoom to Face / Center") {
                    session.cycleZoom()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(session.selectedPhoto == nil)
            }

            // Navigate menu
            CommandMenu("Navigate") {
                Button("Next Photo") {
                    session.moveToNextPhoto()
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(session.groups.isEmpty)

                Button("Previous Photo") {
                    session.moveToPreviousPhoto()
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(session.groups.isEmpty)

                Divider()

                Button("Next Group") {
                    session.moveToNextGroup()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(session.groups.isEmpty)

                Button("Previous Group") {
                    session.moveToPreviousGroup()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(session.groups.isEmpty)

            }
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

extension Notification.Name {
    static let openFolder = Notification.Name("openFolder")
    static let showExport = Notification.Name("showExport")
    static let reimport = Notification.Name("reimport")
}
