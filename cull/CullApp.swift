import SwiftUI

@main
struct CullApp: App {
    @State private var session = CullSession()
    @State private var thumbnailCache = ThumbnailCache()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(thumbnailCache)
        }
        .windowStyle(.automatic)
    }
}
