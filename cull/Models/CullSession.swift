import Foundation
import SwiftUI

@Observable
final class CullSession {
    /// Whether XMP sidecars are auto-written on rating/flag changes (mirrors @AppStorage)
    var autoWriteXMP: Bool {
        get { UserDefaults.standard.object(forKey: "autoWriteXMP") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoWriteXMP") }
    }
    var sourceFolder: URL? {
        didSet {
            // Stop access on old folder
            if let oldValue, sourceFolderAccessActive {
                oldValue.stopAccessingSecurityScopedResource()
                sourceFolderAccessActive = false
            }
        }
    }
    /// Whether we currently hold security-scoped access on sourceFolder
    private var sourceFolderAccessActive = false
    var groups: [PhotoGroup] = []
    var selectedGroupIndex: Int = 0
    var selectedPhotoIndex: Int = 0

    /// Zoom state: nil = fit, -1 = center zoom, 0+ = face index
    var zoomFaceIndex: Int? = nil
    /// Magnification relative to fit. 1 = whole photo visible.
    var zoomScale: CGFloat = 1
    /// Point held at the center of the view, normalized to the image with a top-left origin
    var zoomAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5)

    var importRecursive: Bool = true
    var isImporting: Bool = false
    var importProgress: Double = 0
    var importStatus: String = ""

    var debugCacheOverlay: Bool = false
    var undoManager: UndoManager?
    var workspace: WorkspaceDB?
    private var saveTask: Task<Void, Never>?

    // Remember cursor position per group
    private var groupCursorPositions: [UUID: Int] = [:]

    // Filters: command-click to toggle hiding photos with these attributes
    var hiddenRatings: Set<Int> = []   // ratings to hide (1-5)
    var hideUnrated: Bool = false
    var hidePicks: Bool = false
    var hideRejects: Bool = false
    /// Bumps on every filter change so views can react
    private(set) var filterVersion: Int = 0

    func toggleRatingFilter(_ rating: Int) {
        if hiddenRatings.contains(rating) {
            hiddenRatings.remove(rating)
        } else {
            hiddenRatings.insert(rating)
        }
        filterVersion += 1
        ensureVisibleSelection()
        scheduleSave()
    }

    func togglePickFilter() {
        hidePicks.toggle()
        filterVersion += 1
        ensureVisibleSelection()
        scheduleSave()
    }

    func toggleRejectFilter() {
        hideRejects.toggle()
        filterVersion += 1
        ensureVisibleSelection()
        scheduleSave()
    }

    func toggleUnratedFilter() {
        hideUnrated.toggle()
        filterVersion += 1
        ensureVisibleSelection()
        scheduleSave()
    }

    func isPhotoFiltered(_ photo: Photo) -> Bool {
        if hidePicks && photo.flag == .pick { return true }
        if hideRejects && photo.flag == .reject { return true }
        if hideUnrated && photo.rating == 0 && photo.flag == .none { return true }
        if photo.rating > 0 && hiddenRatings.contains(photo.rating) { return true }
        return false
    }

    var selectedGroup: PhotoGroup? {
        guard groups.indices.contains(selectedGroupIndex) else { return nil }
        return groups[selectedGroupIndex]
    }

    var selectedPhoto: Photo? {
        guard let group = selectedGroup,
              group.photos.indices.contains(selectedPhotoIndex) else { return nil }
        return group.photos[selectedPhotoIndex]
    }

    var allPhotos: [Photo] {
        groups.flatMap(\.photos)
    }

    // MARK: - Navigation

    func moveToNextGroup() {
        guard !groups.isEmpty else { return }
        saveCursorPosition()
        let start = selectedGroupIndex
        for offset in 1...groups.count {
            let idx = (start + offset) % groups.count
            if groupHasVisiblePhotos(idx) {
                selectedGroupIndex = idx
                restoreCursorPosition()
                return
            }
        }
    }

    func moveToPreviousGroup() {
        guard !groups.isEmpty else { return }
        saveCursorPosition()
        let start = selectedGroupIndex
        for offset in 1...groups.count {
            let idx = (start - offset + groups.count) % groups.count
            if groupHasVisiblePhotos(idx) {
                selectedGroupIndex = idx
                restoreCursorPosition()
                return
            }
        }
    }

    /// Step forward one photo, continuing into the next group at its first photo.
    ///
    /// Walking past the end of a group lands on the start of the next one rather than
    /// the cursor remembered there. Remembered positions are for jumping between groups
    /// with the group keys; while stepping through photos in order, skipping ahead to
    /// wherever you last were just loses your place.
    func moveToNextPhoto() {
        guard let group = selectedGroup else { return }
        // Try to find next visible photo in current group
        for i in (selectedPhotoIndex + 1)..<group.photos.count {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Exhausted group, continue at the start of the next one
        moveToNextGroup()
        if let newGroup = selectedGroup,
           let first = newGroup.photos.firstIndex(where: { !isPhotoFiltered($0) }) {
            selectedPhotoIndex = first
        }
    }

    /// Step back one photo, continuing into the previous group at its last photo
    func moveToPreviousPhoto() {
        guard let group = selectedGroup else { return }
        // Try to find previous visible photo in current group
        for i in stride(from: selectedPhotoIndex - 1, through: 0, by: -1) {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Exhausted group, continue at the end of the previous one
        moveToPreviousGroup()
        if let newGroup = selectedGroup,
           let last = newGroup.photos.lastIndex(where: { !isPhotoFiltered($0) }) {
            selectedPhotoIndex = last
        }
    }

    func selectGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        saveCursorPosition()
        selectedGroupIndex = index
        restoreCursorPosition()
    }

    func selectPhoto(at index: Int) {
        guard let group = selectedGroup, group.photos.indices.contains(index) else { return }
        selectedPhotoIndex = index
    }

    private func saveCursorPosition() {
        guard let group = selectedGroup else { return }
        groupCursorPositions[group.id] = selectedPhotoIndex
    }

    private func restoreCursorPosition() {
        guard let group = selectedGroup else { return }
        let saved = groupCursorPositions[group.id] ?? 0
        let clamped = min(saved, group.photos.count - 1)
        selectedPhotoIndex = clamped
        // If restored position is filtered, find nearest visible
        if isPhotoFiltered(group.photos[clamped]) {
            ensureVisibleInGroup()
        }
    }

    private func groupHasVisiblePhotos(_ groupIndex: Int) -> Bool {
        guard groups.indices.contains(groupIndex) else { return false }
        return groups[groupIndex].photos.contains { !isPhotoFiltered($0) }
    }

    /// If current photo is filtered, find nearest visible: forward first, then backward, then next group
    private func ensureVisibleSelection() {
        guard let photo = selectedPhoto else { return }
        guard isPhotoFiltered(photo) else { return }
        ensureVisibleInGroup()
    }

    private func ensureVisibleInGroup() {
        guard let group = selectedGroup else { return }
        // Try forward from current position
        for i in selectedPhotoIndex..<group.photos.count {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Try backward
        for i in stride(from: selectedPhotoIndex - 1, through: 0, by: -1) {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Entire group filtered, move to next group with visible photos
        let start = selectedGroupIndex
        for offset in 1...groups.count {
            let idx = (start + offset) % groups.count
            if groupHasVisiblePhotos(idx) {
                selectedGroupIndex = idx
                selectedPhotoIndex = groups[idx].photos.firstIndex { !isPhotoFiltered($0) } ?? 0
                return
            }
        }
    }

    // MARK: - Lookahead

    /// Returns the next N visible (unfiltered) photos from the current position, wrapping around to start
    func photosAhead(_ count: Int) -> [Photo] {
        let visible = allPhotos.filter { !isPhotoFiltered($0) }
        guard !visible.isEmpty, count > 0 else { return [] }
        guard let current = selectedPhoto,
              let vi = visible.firstIndex(where: { $0.id == current.id }) else { return [] }
        return (1...min(count, visible.count - 1)).map { i in
            visible[(vi + i) % visible.count]
        }
    }

    /// Returns the previous N visible (unfiltered) photos from the current position, wrapping around to end
    func photosBehind(_ count: Int) -> [Photo] {
        let visible = allPhotos.filter { !isPhotoFiltered($0) }
        guard !visible.isEmpty, count > 0 else { return [] }
        guard let current = selectedPhoto,
              let vi = visible.firstIndex(where: { $0.id == current.id }) else { return [] }
        return (1...min(count, visible.count - 1)).map { i in
            visible[(vi - i + visible.count) % visible.count]
        }
    }

    /// Returns the first visible photo from the next and previous `groupCount` groups.
    /// Interleaved closest-first so nearest groups are cached with highest priority.
    func adjacentGroupRepresentatives(groupCount: Int = 15) -> [Photo] {
        guard !groups.isEmpty else { return [] }
        var result: [Photo] = []
        for offset in 1...groupCount {
            let nextIdx = (selectedGroupIndex + offset) % groups.count
            if let first = groups[nextIdx].photos.first(where: { !isPhotoFiltered($0) }) {
                result.append(first)
            }
            let prevIdx = (selectedGroupIndex - offset + groups.count) % groups.count
            if prevIdx != nextIdx,
               let first = groups[prevIdx].photos.first(where: { !isPhotoFiltered($0) }) {
                result.append(first)
            }
        }
        return result
    }

    /// Photos whose full-size previews should stay resident, most urgent first.
    ///
    /// Group representatives are interleaved with linear neighbors so both jumping
    /// between scenes and walking through one feel instant. Entries are deduplicated:
    /// neighbors and representatives overlap heavily once a filter hides photos, and
    /// duplicates used to eat window slots that real photos needed.
    ///
    /// Keep the total comfortably under the preview cache's byte budget. A 24 MP
    /// preview runs ~17 MB, so ~37 entries is roughly 650 MB against a 1 GB budget;
    /// sizing it to the brim just makes the cache evict photos you are about to reach.
    func previewWindow(lookahead: Int = 14, lookbehind: Int = 6, groupCount: Int = 8) -> [Photo] {
        guard let current = selectedPhoto else { return [] }

        let reps = adjacentGroupRepresentatives(groupCount: groupCount)
        let ahead = photosAhead(lookahead)
        let behind = photosBehind(lookbehind)

        var window: [Photo] = [current]
        var seen: Set<UUID> = [current.id]
        func add(_ photo: Photo) {
            guard seen.insert(photo.id).inserted else { return }
            window.append(photo)
        }

        var gi = 0
        var li = 0
        while gi < reps.count || li < max(ahead.count, behind.count) {
            if gi < reps.count { add(reps[gi]); gi += 1 }
            if gi < reps.count { add(reps[gi]); gi += 1 }
            if li < ahead.count { add(ahead[li]) }
            if li < behind.count { add(behind[li]) }
            li += 1
        }
        return window
    }

    // MARK: - Culling Actions

    private func applyPhotoState(_ photo: Photo, rating: Int, flag: PhotoFlag, actionName: String) {
        let oldRating = photo.rating
        let oldFlag = photo.flag
        photo.rating = rating
        photo.flag = flag
        undoManager?.registerUndo(withTarget: self) { session in
            session.applyPhotoState(photo, rating: oldRating, flag: oldFlag, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        scheduleSave()
        if autoWriteXMP {
            XMPSidecar.write(photo)
        }
    }

    func setRating(_ rating: Int) {
        guard (1...5).contains(rating), let photo = selectedPhoto else { return }
        applyPhotoState(photo, rating: rating, flag: photo.flag, actionName: "Set Rating \(rating)")
        ensureVisibleSelection()
    }

    func togglePick() {
        guard let photo = selectedPhoto else { return }
        let newFlag: PhotoFlag = photo.flag == .pick ? .none : .pick
        applyPhotoState(photo, rating: photo.rating, flag: newFlag, actionName: newFlag == .pick ? "Pick" : "Remove Pick")
        ensureVisibleSelection()
    }

    func toggleReject() {
        guard let photo = selectedPhoto else { return }
        let newFlag: PhotoFlag = photo.flag == .reject ? .none : .reject
        applyPhotoState(photo, rating: photo.rating, flag: newFlag, actionName: newFlag == .reject ? "Reject" : "Remove Reject")
        ensureVisibleSelection()
    }

    func clearRatingAndFlag() {
        guard let photo = selectedPhoto else { return }
        applyPhotoState(photo, rating: 0, flag: .none, actionName: "Clear Rating & Flag")
    }

    // MARK: - Zoom

    /// The zoom transform is kept in geometry-free terms — a magnification and a point
    /// in normalized image coordinates to hold at the center of the view — so the model
    /// doesn't need to know the window size. The viewer turns it into an offset and
    /// clamps it against the edges of the photo.
    var zoomedIn: Bool { zoomScale > 1.001 }

    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 12
    static let centerZoomScale: CGFloat = 2.5

    /// Magnification that makes a face fill roughly a third of the frame
    static func zoomScale(forFace rect: CGRect) -> CGFloat {
        min(max(0.35 / max(rect.width, rect.height), 1.5), 5.0)
    }

    /// Face center as a top-left-origin normalized point (Vision boxes are bottom-left)
    static func anchor(forFace rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: 1 - rect.midY)
    }

    func cycleZoom() {
        guard let photo = selectedPhoto else { return }
        let faces = photo.faceRegions

        // A manual zoom isn't one of the presets, so the first press unwinds it
        if zoomFaceIndex == nil && zoomedIn {
            resetZoom()
            return
        }

        switch zoomFaceIndex {
        case nil:
            // Currently fit → zoom to first face or center
            if faces.isEmpty {
                zoomTo(scale: Self.centerZoomScale, anchor: CGPoint(x: 0.5, y: 0.5), faceIndex: -1)
            } else {
                zoomToFace(0, of: photo)
            }
        case -1:
            // Center zoom → back to fit
            resetZoom()
        case let idx?:
            // On a face → next face, or back to fit
            if idx + 1 < faces.count {
                zoomToFace(idx + 1, of: photo)
            } else {
                resetZoom()
            }
        }
    }

    private func zoomToFace(_ index: Int, of photo: Photo) {
        guard photo.faceRegions.indices.contains(index) else { return }
        let rect = photo.faceRegions[index]
        zoomTo(scale: Self.zoomScale(forFace: rect), anchor: Self.anchor(forFace: rect), faceIndex: index)
    }

    private func zoomTo(scale: CGFloat, anchor: CGPoint, faceIndex: Int?) {
        zoomScale = scale
        zoomAnchor = anchor
        zoomFaceIndex = faceIndex
    }

    /// Scale and recenter from a gesture. Leaves any face-follow mode, since the user
    /// is now driving the view themselves.
    func setManualZoom(scale: CGFloat, anchor: CGPoint) {
        zoomScale = min(max(scale, Self.minZoom), Self.maxZoom)
        zoomFaceIndex = nil
        zoomAnchor = zoomedIn ? anchor : CGPoint(x: 0.5, y: 0.5)
    }

    /// Farthest a face can be from where you're looking and still be treated as the same
    /// subject moving. Detection is noisy frame to frame and people leave the shot, so
    /// beyond this the nearest face is somebody else and jumping to them is just a lurch
    /// across the frame. Holding position instead removes the worst tenth of the jumps.
    static let faceFollowRadius: CGFloat = 0.25

    /// While following a face, re-aim at the nearest face in the newly selected photo.
    ///
    /// Face order isn't stable between frames — people turn, detection drops in and out,
    /// and the index that meant one person a moment ago can mean another. Following
    /// position rather than index keeps the same subject framed through a burst. The
    /// magnification is deliberately left alone: re-deriving it from each face's size
    /// made the view breathe in and out on every step.
    func retargetFaceZoom(for photo: Photo) {
        guard let index = zoomFaceIndex, index >= 0, zoomedIn else { return }
        guard !photo.faceRegions.isEmpty else { return }

        let target = zoomAnchor
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (i, rect) in photo.faceRegions.enumerated() {
            let point = Self.anchor(forFace: rect)
            let d = hypot(point.x - target.x, point.y - target.y)
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }

        guard bestDistance <= Self.faceFollowRadius else { return }
        zoomFaceIndex = bestIndex
        zoomAnchor = Self.anchor(forFace: photo.faceRegions[bestIndex])
    }

    /// Recenter on a point without changing magnification
    func panZoom(to anchor: CGPoint) {
        guard zoomedIn else { return }
        zoomFaceIndex = nil
        zoomAnchor = anchor
    }

    func resetZoom() {
        zoomFaceIndex = nil
        zoomScale = 1
        zoomAnchor = CGPoint(x: 0.5, y: 0.5)
    }

    // MARK: - Security-scoped folder access

    /// Open a folder with security-scoped access. Call this instead of setting sourceFolder directly.
    func openSourceFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        sourceFolderAccessActive = true
        sourceFolder = url
    }

    /// Close the current folder, releasing security-scoped access.
    func closeSourceFolder() {
        if let folder = sourceFolder, sourceFolderAccessActive {
            folder.stopAccessingSecurityScopedResource()
            sourceFolderAccessActive = false
        }
        sourceFolder = nil
        groups = []
    }

    // MARK: - Workspace persistence

    /// Debounced auto-save — coalesces rapid changes into a single write
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveWorkspace()
        }
    }

    func saveWorkspace() {
        guard let workspace, let sourceFolder else { return }
        workspace.savePhotosAndGroups(groups, sourceFolder: sourceFolder)
        workspace.saveSettings(session: self)
    }

    struct WorkspaceResult {
        let newPhotos: [Photo]  // photos that need analysis + grouping
        /// Photos already in the workspace whose stored quality scores were produced by
        /// an older, since-corrected analysis. They need re-scoring but not re-grouping.
        let staleAnalysis: [Photo]
    }

    /// Opens workspace, returns nil if no cached data. Returns new photos that need processing.
    func openWorkspace(folder: URL) -> WorkspaceResult? {
        guard let db = WorkspaceDB(folder: folder) else { return nil }
        self.workspace = db

        guard db.hasCachedData else { return nil }

        let savedPhotos = db.loadPhotos()
        let groupOrder = db.loadGroupOrder()
        let savedPaths = Set(savedPhotos.map(\.path))

        // Rebuild photos keyed by relative path
        var photosByPath: [String: Photo] = [:]
        for saved in savedPhotos {
            let url = folder.appendingPathComponent(saved.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let photo = Photo(url: url)
            if let pairedPath = saved.pairedPath {
                let pairedURL = folder.appendingPathComponent(pairedPath)
                if FileManager.default.fileExists(atPath: pairedURL.path) {
                    photo.pairedURL = pairedURL
                }
            }
            photo.rating = saved.rating
            photo.flag = saved.flag
            photo.faceRegions = saved.faceRegions
            photo.pixelWidth = saved.pixelWidth
            photo.pixelHeight = saved.pixelHeight
            photo.fileSize = saved.fileSize
            photo.pairedPixelWidth = saved.pairedPixelWidth
            photo.pairedPixelHeight = saved.pairedPixelHeight
            photo.pairedFileSize = saved.pairedFileSize
            photo.captureDate = saved.captureDate
            photo.eyeAspectRatios = saved.eyeAspectRatios
            photosByPath[saved.path] = photo
        }

        // Scan for new files on disk not in workspace
        var newPhotos: [Photo] = []
        if let importResult = try? PhotoImporter.scanFiles(in: folder, recursive: importRecursive) {
            for (relativePath, photo) in importResult {
                if !savedPaths.contains(relativePath) {
                    newPhotos.append(photo)
                }
            }
        }

        // Rebuild groups in saved order
        var photosByGroup: [String: [Photo]] = [:]
        for saved in savedPhotos {
            guard let groupID = saved.groupID, let photo = photosByPath[saved.path] else { continue }
            photosByGroup[groupID, default: []].append(photo)
        }
        // Photos come back in whatever order SQLite yields them, so restore
        // chronological order to match a fresh import
        for key in photosByGroup.keys {
            photosByGroup[key]?.sort { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
        }

        var rebuiltGroups: [PhotoGroup] = []
        for groupID in groupOrder {
            guard let photos = photosByGroup[groupID], !photos.isEmpty else { continue }
            rebuiltGroups.append(PhotoGroup(photos: photos))
        }

        // Add any ungrouped saved photos
        let groupedPaths = Set(savedPhotos.compactMap { $0.groupID != nil ? $0.path : nil })
        let ungrouped = photosByPath.filter { !groupedPaths.contains($0.key) }.map(\.value)
        if !ungrouped.isEmpty {
            rebuiltGroups.append(PhotoGroup(photos: ungrouped))
        }

        // Add new photos as their own group(s) temporarily
        if !newPhotos.isEmpty {
            rebuiltGroups.append(PhotoGroup(photos: newPhotos))
        }

        guard !rebuiltGroups.isEmpty else { return nil }

        self.groups = rebuiltGroups
        db.loadSettings(into: self)

        // Prefer the remembered photo over the remembered indices: regrouping or a
        // change in sort order leaves the old indices pointing at a different photo.
        var restored = false
        if let savedPath = db.loadSetting("selectedPhotoPath") {
            let savedURL = folder.appendingPathComponent(savedPath)
            for (gi, group) in groups.enumerated() {
                if let pi = group.photos.firstIndex(where: { $0.url == savedURL }) {
                    selectedGroupIndex = gi
                    selectedPhotoIndex = pi
                    restored = true
                    break
                }
            }
        }

        if !restored {
            selectedGroupIndex = min(selectedGroupIndex, groups.count - 1)
            if let group = selectedGroup {
                selectedPhotoIndex = min(selectedPhotoIndex, group.photos.count - 1)
            }
        }

        // Restored filters may hide whatever the cursor landed on. Nothing preloads
        // hidden photos, so leaving the cursor there opens the viewer on a blank frame.
        ensureVisibleSelection()

        // Scores written by an older analysis can't be compared against new ones,
        // so flag them all for re-scoring rather than leaving a mixed set.
        let storedVersion = db.loadSetting("analysisVersion").flatMap(Int.init) ?? 0
        let stale = storedVersion < QualityAnalyzer.analysisVersion
            ? allPhotos.filter { photo in !newPhotos.contains { $0 === photo } }
            : []

        return WorkspaceResult(newPhotos: newPhotos, staleAnalysis: stale)
    }
}
