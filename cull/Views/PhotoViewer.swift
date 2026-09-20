import SwiftUI

struct PhotoViewer: View {
    @Environment(CullSession.self) private var session
    @Environment(ThumbnailCache.self) private var cache
    @State private var displayImage: NSImage?
    @State private var displayedPhotoID: UUID?
    /// Tracks what quality level is currently displayed: "preview", "thumbnail", or "none"
    @State private var displayQuality: String = "none"
    @FocusState.Binding var isViewerFocused: Bool


    var body: some View {
        ZStack {
            Color.black

            if let displayImage {
                GeometryReader { geo in
                    let imageSize = displayImage.size
                    let fitted = fittedSize(image: imageSize, in: geo.size)
                    let zoomInfo = currentZoomInfo(fittedSize: fitted, containerSize: geo.size)

                    ZStack {
                        Image(nsImage: displayImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .overlay {
                                // Face region overlays (only when not zoomed)
                                if !session.zoomedIn, let photo = session.selectedPhoto, !photo.faceRegions.isEmpty {
                                    faceOverlays(photo: photo, fittedSize: fitted)
                                }
                            }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .scaleEffect(zoomInfo.scale)
                    .offset(zoomInfo.offset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .animation(.easeInOut(duration: 0.3), value: session.zoomFaceIndex)
                    .overlay {
                        ZoomPanCatcher(
                            onZoom: { factor, location in
                                zoom(by: factor, at: location, fitted: fitted, container: geo.size)
                            },
                            onPan: { delta in
                                pan(by: delta, fitted: fitted, container: geo.size)
                            },
                            onClick: { isViewerFocused = true },
                            isPannable: session.zoomedIn
                        )
                    }
                }
            }

            // Debug cache overlay
            if session.debugCacheOverlay, let photo = session.selectedPhoto {
                let _ = cache.cacheGeneration // observe changes
                let s = cache.stats()
                let allPhotos = session.allPhotos
                let currentFlatIndex = allPhotos.firstIndex(where: { $0.id == photo.id })

                HStack(alignment: .top, spacing: 0) {
                    Spacer()

                    // Stats panel
                    VStack(alignment: .leading, spacing: 3) {
                        let hasPreview = cache.cachedPreview(for: photo) != nil
                        let hasThumb = cache.cachedThumbnail(for: photo) != nil

                        Text("Current Photo")
                            .fontWeight(.semibold)
                        HStack(spacing: 4) {
                            Circle().fill(hasPreview ? .green : .red).frame(width: 8, height: 8)
                            Text("Preview")
                        }
                        HStack(spacing: 4) {
                            Circle().fill(hasThumb ? .green : .red).frame(width: 8, height: 8)
                            Text("Thumbnail")
                        }
                        Text("Displaying: \(displayQuality)")

                        Divider().overlay(Color.white.opacity(0.3))

                        Text("Cache")
                            .fontWeight(.semibold)
                        Text("Thumbs: \(s.thumbnailCount)/\(s.thumbnailLimit)")
                        Text("Previews: \(s.previewCount)/\(s.previewLimit)")

                        Divider().overlay(Color.white.opacity(0.3))

                        Text("Session")
                            .fontWeight(.semibold)
                        Text("Groups: \(session.groups.count)")
                        Text("Photos: \(allPhotos.count)")

                        Divider().overlay(Color.white.opacity(0.3))

                        Text("Log")
                            .fontWeight(.semibold)
                        ForEach(Array(cache.debugLog.prefix(8).enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))

                    // Cache minimap — precompute states so SwiftUI can diff
                    let cacheStates: [Int] = allPhotos.map { p in
                        if cache.cachedPreview(for: p) != nil { return 2 }
                        if cache.cachedThumbnail(for: p) != nil { return 1 }
                        return 0
                    }

                    GeometryReader { geo in
                        let totalPhotos = cacheStates.count
                        let height = geo.size.height - 16
                        let rowH = totalPhotos > 0 ? max(height / CGFloat(totalPhotos), 1) : 1

                        Canvas { context, size in
                            let colors: [Color] = [.red, .yellow, .green]
                            for (i, state) in cacheStates.enumerated() {
                                let y = 8 + CGFloat(i) * rowH
                                context.fill(
                                    Path(CGRect(x: 0, y: y, width: size.width, height: max(rowH - 0.5, 0.5))),
                                    with: .color(colors[state].opacity(0.8))
                                )
                            }

                            if let idx = currentFlatIndex {
                                let y = 8 + CGFloat(idx) * rowH
                                context.fill(
                                    Path(CGRect(x: -2, y: y - 1, width: size.width + 4, height: max(rowH + 2, 3))),
                                    with: .color(.white)
                                )
                            }
                        }
                        .frame(width: 14)
                    }
                    .frame(width: 14)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                }
                .padding(8)
            }

            // Bottom bar overlay
            if let photo = session.selectedPhoto {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        if photo.flag == .pick {
                            Label("Pick", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if photo.flag == .reject {
                            Label("Reject", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }

                        // Resolution & file size
                        if photo.pixelWidth > 0 {
                            HStack(spacing: 8) {
                                // Primary file (RAW or standalone)
                                HStack(spacing: 4) {
                                    Text(photo.url.pathExtension.uppercased())
                                        .fontWeight(.medium)
                                    Text("\(photo.pixelWidth)×\(photo.pixelHeight)")
                                    Text(Self.formatFileSize(photo.fileSize))
                                }
                                // Paired file (JPEG sidecar)
                                if photo.pairedURL != nil, photo.pairedPixelWidth > 0 {
                                    Text("·")
                                    HStack(spacing: 4) {
                                        Text(photo.pairedURL!.pathExtension.uppercased())
                                            .fontWeight(.medium)
                                        Text("\(photo.pairedPixelWidth)×\(photo.pairedPixelHeight)")
                                        Text(Self.formatFileSize(photo.pairedFileSize))
                                    }
                                }
                            }
                            .foregroundStyle(.white.opacity(0.5))
                            .font(.caption)
                        }

                        Spacer()

                        // Face count
                        HStack(spacing: 10) {
                            if !photo.faceRegions.isEmpty {
                                HStack(spacing: 3) {
                                    Image(systemName: "person.crop.rectangle")
                                    Text("\(photo.faceRegions.count)")
                                }
                                .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .font(.caption)

                        // Eyes closed badge
                        if photo.eyeAspectRatios.contains(where: { $0 < 0.20 }) {
                            let closedCount = photo.eyeAspectRatios.filter { $0 < 0.20 }.count
                            HStack(spacing: 3) {
                                Image(systemName: "eye.slash")
                                Text("\(closedCount)")
                            }
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        }

                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= photo.rating ? "star.fill" : "star")
                                    .foregroundStyle(star <= photo.rating ? .yellow : .white.opacity(0.3))
                            }
                        }
                        .font(.title3)

                        Spacer()

                        HStack(spacing: 6) {
                            Text(photo.url.lastPathComponent)
                            if let date = photo.captureDate {
                                Text(date, format: .dateTime.month().day().year().hour().minute().second())
                            }
                        }
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .onChange(of: session.selectedPhoto?.id) {
            guard let photo = session.selectedPhoto else {
                displayImage = nil
                displayedPhotoID = nil
                return
            }
            displayedPhotoID = photo.id
            // Following a face: re-aim at the same subject in this photo
            session.retargetFaceZoom(for: photo)
            // Instant: show whatever we have cached synchronously
            if let cached = cache.cachedPreview(for: photo) {
                displayImage = cached
                displayQuality = "preview"
            } else if let thumb = cache.cachedThumbnail(for: photo) {
                displayImage = thumb
                displayQuality = "thumbnail"
            } else {
                displayQuality = "none"
            }
        }
        .task(id: session.selectedPhoto?.id) {
            guard let photo = session.selectedPhoto else { return }
            let photoID = photo.id
            // Claim the photo here rather than trusting onAppear to have run first.
            // SwiftUI can start this task before onAppear, and every staleness guard
            // below compares against this — when it was still nil the task bailed out
            // and the preview never loaded, leaving the first photo stuck on its
            // thumbnail until you navigated away and back.
            displayedPhotoID = photoID
            // Idempotent, and done here as well as in onChange because the two can run
            // in either order and the anchor is needed before the first frame
            session.retargetFaceZoom(for: photo)

            // Track what this task has put on screen locally. The @State flags describe
            // whichever photo ran last, and this task can start before onChange updates
            // them, so reading them back here would make the wrong decision.
            var showing = "none"

            if let cached = cache.cachedPreview(for: photo) {
                displayImage = cached
                displayQuality = "preview"
                showing = "preview"
            }

            // Queue the neighbors before doing anything slow. The loader keeps its place
            // across selection changes, so starting it now means prefetching continues
            // while you walk through a group instead of restarting after every photo.
            // The current photo is dropped from the queue since this task loads it below.
            let window = session.previewWindow()
            cache.preloadPreviews(photos: Array(window.dropFirst()))

            // Nothing cached — pull the thumbnail so the viewer shows something while
            // the preview decodes. Photos a filter hides are never preloaded, so landing
            // on one used to mean staring at a blank frame.
            if showing == "none", let thumb = await cache.thumbnail(for: photo) {
                guard displayedPhotoID == photoID else { return }
                displayImage = thumb
                displayQuality = "thumbnail"
                showing = "thumbnail"
            }

            // Settle briefly so holding an arrow key doesn't decode every photo it passes
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, displayedPhotoID == photoID else { return }

            // Show the full-res preview. Gate on what's on screen, not on what's in the
            // cache: the background loader often caches this photo's preview while we're
            // sleeping, and the old "load it only if uncached" check then skipped the
            // upgrade and left the thumbnail up. previewImage returns the cached copy
            // instantly when there is one.
            if showing != "preview", let full = await cache.previewImage(for: photo) {
                guard displayedPhotoID == photoID else { return }
                displayImage = full
                displayQuality = "preview"
            }

            guard !Task.isCancelled, displayedPhotoID == photoID else { return }
            cache.evictPreviews(keeping: window)
        }
        .onAppear {
            if let photo = session.selectedPhoto {
                displayedPhotoID = photo.id
                if let cached = cache.cachedPreview(for: photo) {
                    displayImage = cached
                    displayQuality = "preview"
                } else if let thumb = cache.cachedThumbnail(for: photo) {
                    displayImage = thumb
                    displayQuality = "thumbnail"
                }
                cache.preloadPreviews(photos: session.previewWindow())
            }
        }
    }

    // MARK: - Formatting

    private static func formatFileSize(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    // MARK: - Zoom calculations

    private struct ZoomInfo {
        let scale: CGFloat
        let offset: CGSize
    }

    private func currentZoomInfo(fittedSize: CGSize, containerSize: CGSize) -> ZoomInfo {
        let scale = session.zoomScale
        guard scale > 1.001 else { return ZoomInfo(scale: 1, offset: .zero) }

        let anchor = clampedAnchor(effectiveAnchor, scale: scale, fitted: fittedSize, container: containerSize)
        return ZoomInfo(scale: scale, offset: offset(for: anchor, scale: scale, fitted: fittedSize))
    }

    /// Where to center: whatever the zoom is currently aimed at. Face presets and
    /// face-follow both write the anchor, so the renderer needs no special case.
    private var effectiveAnchor: CGPoint { session.zoomAnchor }

    /// Offset that brings `anchor` to the center of the container
    private func offset(for anchor: CGPoint, scale: CGFloat, fitted: CGSize) -> CGSize {
        CGSize(
            width: (0.5 - anchor.x) * fitted.width * scale,
            height: (0.5 - anchor.y) * fitted.height * scale
        )
    }

    /// Keep the photo covering the view. Panning past an edge would just reveal
    /// background, so the anchor is confined to the range that still fills the frame —
    /// and pinned to center on any axis where the photo is smaller than the view.
    private func clampedAnchor(_ anchor: CGPoint, scale: CGFloat, fitted: CGSize, container: CGSize) -> CGPoint {
        func limit(fittedLength: CGFloat, containerLength: CGFloat) -> CGFloat {
            let scaled = fittedLength * scale
            guard scaled > containerLength, fittedLength > 0 else { return 0 }
            return (scaled - containerLength) / 2 / (fittedLength * scale)
        }
        let dx = limit(fittedLength: fitted.width, containerLength: container.width)
        let dy = limit(fittedLength: fitted.height, containerLength: container.height)
        return CGPoint(
            x: min(max(anchor.x, 0.5 - dx), 0.5 + dx),
            y: min(max(anchor.y, 0.5 - dy), 0.5 + dy)
        )
    }

    /// Normalized image point currently under a location in view coordinates
    private func imagePoint(at location: CGPoint, fitted: CGSize, container: CGSize) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let scale = max(session.zoomScale, 0.001)
        let anchor = clampedAnchor(effectiveAnchor, scale: scale, fitted: fitted, container: container)
        let currentOffset = offset(for: anchor, scale: scale, fitted: fitted)
        return CGPoint(
            x: ((location.x - container.width / 2 - currentOffset.width) / scale + fitted.width / 2) / fitted.width,
            y: ((location.y - container.height / 2 - currentOffset.height) / scale + fitted.height / 2) / fitted.height
        )
    }

    /// Zoom by `factor` while holding the point under the cursor still
    private func zoom(by factor: CGFloat, at location: CGPoint, fitted: CGSize, container: CGSize) {
        let newScale = min(max(session.zoomScale * factor, CullSession.minZoom), CullSession.maxZoom)
        guard newScale != session.zoomScale else { return }

        guard newScale > 1.001 else {
            session.resetZoom()
            return
        }

        // Solve for the anchor that leaves the pointed-at image point where it is
        let target = imagePoint(at: location, fitted: fitted, container: container)
        let newOffset = CGSize(
            width: location.x - container.width / 2 - (target.x * fitted.width - fitted.width / 2) * newScale,
            height: location.y - container.height / 2 - (target.y * fitted.height - fitted.height / 2) * newScale
        )
        let newAnchor = CGPoint(
            x: 0.5 - newOffset.width / (newScale * fitted.width),
            y: 0.5 - newOffset.height / (newScale * fitted.height)
        )
        session.setManualZoom(
            scale: newScale,
            anchor: clampedAnchor(newAnchor, scale: newScale, fitted: fitted, container: container)
        )
    }

    /// Shift the view by a drag or scroll delta, in view points
    private func pan(by delta: CGSize, fitted: CGSize, container: CGSize) {
        guard session.zoomedIn, fitted.width > 0, fitted.height > 0 else { return }
        let scale = session.zoomScale
        let anchor = clampedAnchor(effectiveAnchor, scale: scale, fitted: fitted, container: container)
        let moved = CGPoint(
            x: anchor.x - delta.width / (fitted.width * scale),
            y: anchor.y - delta.height / (fitted.height * scale)
        )
        session.panZoom(to: clampedAnchor(moved, scale: scale, fitted: fitted, container: container))
    }


    // MARK: - Eye indicator

    /// Draws two small eye shapes that reflect how open/closed the eyes are.
    /// EAR ~0.30 = wide open, ~0.20 = threshold, ~0.05 = shut.
    private struct EyeIndicator: View {
        let ear: Double
        let faceWidth: CGFloat

        var body: some View {
            let eyeW = min(faceWidth * 0.22, 20)
            // Map EAR to openness: 0.05→flat, 0.30→full open
            let openness = CGFloat(max(0, min(1, (ear - 0.05) / 0.25)))
            let eyeH = eyeW * 0.8 * openness
            let color: Color = ear < 0.20 ? .yellow : .white.opacity(0.7)

            EyeShape(openness: openness)
                .fill(color.opacity(0.9))
                .frame(width: eyeW, height: max(eyeH, 1.5))
                .shadow(color: .black.opacity(0.8), radius: 1.5)
        }
    }

    /// Almond-shaped eye that flattens as openness approaches 0.
    private struct EyeShape: Shape {
        let openness: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let midY = rect.midY
            let bulge = rect.height / 2
            let cpInset = rect.width * 0.2

            // Top lid arc (cubic for rounder shape)
            path.move(to: CGPoint(x: rect.minX, y: midY))
            path.addCurve(
                to: CGPoint(x: rect.maxX, y: midY),
                control1: CGPoint(x: rect.minX + cpInset, y: midY - bulge),
                control2: CGPoint(x: rect.maxX - cpInset, y: midY - bulge)
            )
            // Bottom lid arc
            path.addCurve(
                to: CGPoint(x: rect.minX, y: midY),
                control1: CGPoint(x: rect.maxX - cpInset, y: midY + bulge),
                control2: CGPoint(x: rect.minX + cpInset, y: midY + bulge)
            )
            return path
        }
    }

    private func fittedSize(image: CGSize, in container: CGSize) -> CGSize {
        let scaleW = container.width / image.width
        let scaleH = container.height / image.height
        let s = min(scaleW, scaleH)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    // MARK: - Face overlays

    @ViewBuilder
    private func faceOverlays(photo: Photo, fittedSize: CGSize) -> some View {
        ForEach(0..<photo.faceRegions.count, id: \.self) { i in
            let faceRect = photo.faceRegions[i]
            let ear = i < photo.eyeAspectRatios.count ? photo.eyeAspectRatios[i] : 0.3
            let isClosed = ear < 0.20
            // Convert Vision rect (bottom-left origin) to SwiftUI overlay coords (top-left origin)
            let x = faceRect.origin.x * fittedSize.width
            let y = (1 - faceRect.origin.y - faceRect.height) * fittedSize.height
            let w = faceRect.width * fittedSize.width
            let h = faceRect.height * fittedSize.height

            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isClosed ? Color.yellow.opacity(0.8) : Color.white.opacity(0.5), lineWidth: 1.5)
                    .frame(width: w, height: h)

                // Eye openness indicator just under the chin
                EyeIndicator(ear: ear, faceWidth: w)
                    .offset(y: h * 0.55)
            }
            .position(x: x + w / 2, y: y + h / 2)
        }
    }
}

/// Routes pointer input for zoom and pan.
///
/// Built on AppKit because SwiftUI has no scroll-wheel or magnify gesture on macOS, and
/// because putting every pointer event through one responder avoids a SwiftUI drag
/// gesture and an AppKit scroll view fighting over the same pixels.
///
/// Trackpad and mouse expect opposite things from a scroll, so the two are told apart by
/// `hasPreciseScrollingDeltas`: a trackpad swipe pans the way it does in Preview, while a
/// mouse wheel zooms the way it does in Lightroom.
struct ZoomPanCatcher: NSViewRepresentable {
    /// Zoom by a multiplicative factor, holding the given point (view coordinates) still
    var onZoom: (CGFloat, CGPoint) -> Void
    /// Shift the view by a delta in view points
    var onPan: (CGSize) -> Void
    var onClick: () -> Void
    /// Whether panning is possible, which decides the cursor
    var isPannable: Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: CatcherView) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.onClick = onClick
        view.isPannable = isPannable
        view.window?.invalidateCursorRects(for: view)
    }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onPan: ((CGSize) -> Void)?
        var onClick: (() -> Void)?
        var isPannable = false
        private var lastDragPoint: CGPoint?

        /// Keyboard focus belongs to the SwiftUI viewer; this layer only wants the pointer
        override var acceptsFirstResponder: Bool { false }

        private func viewPoint(_ event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            // AppKit's origin is bottom-left; the zoom math works in SwiftUI's top-left space
            return CGPoint(x: local.x, y: bounds.height - local.y)
        }

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            } else {
                // Wheels vary in how much they report per detent, so cap the step
                let steps = min(max(event.scrollingDeltaY, -3), 3)
                guard steps != 0 else { return }
                onZoom?(pow(1.15, steps), viewPoint(event))
            }
        }

        override func magnify(with event: NSEvent) {
            guard event.magnification != 0 else { return }
            onZoom?(1 + event.magnification, viewPoint(event))
        }

        override func mouseDown(with event: NSEvent) {
            lastDragPoint = viewPoint(event)
            onClick?()
            if isPannable { NSCursor.closedHand.set() }
        }

        override func mouseDragged(with event: NSEvent) {
            // Tracked from positions rather than event.deltaY, whose sign convention
            // differs from the top-left space the zoom math works in
            let point = viewPoint(event)
            defer { lastDragPoint = point }
            guard let last = lastDragPoint else { return }
            onPan?(CGSize(width: point.x - last.x, height: point.y - last.y))
        }

        override func mouseUp(with event: NSEvent) {
            lastDragPoint = nil
            if event.clickCount == 2 {
                // Double-click toggles between fit and a close look, like Preview
                onZoom?(isPannable ? 0.01 : 4, viewPoint(event))
            }
            window?.invalidateCursorRects(for: self)
        }

        override func resetCursorRects() {
            if isPannable {
                addCursorRect(bounds, cursor: .openHand)
            }
        }
    }
}
