import Foundation
import SwiftUI

@Observable
final class CullSession {
    /// Whether XMP sidecars are auto-written on rating/flag changes (mirrors @AppStorage)
    var autoWriteXMP: Bool {
        get { UserDefaults.standard.object(forKey: "autoWriteXMP") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoWriteXMP") }
    }
    var sourceFolder: URL?
    var groups: [PhotoGroup] = []
    var selectedGroupIndex: Int = 0
    var selectedPhotoIndex: Int = 0

    /// Zoom state: nil = fit, -1 = center zoom, 0+ = face index
    var zoomFaceIndex: Int? = nil

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

    func toggleRatingFilter(_ rating: Int) {
        if hiddenRatings.contains(rating) {
            hiddenRatings.remove(rating)
        } else {
            hiddenRatings.insert(rating)
        }
        ensureVisibleSelection()
        scheduleSave()
    }

    func togglePickFilter() {
        hidePicks.toggle()
        ensureVisibleSelection()
        scheduleSave()
    }

    func toggleRejectFilter() {
        hideRejects.toggle()
        ensureVisibleSelection()
        scheduleSave()
    }

    func toggleUnratedFilter() {
        hideUnrated.toggle()
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

    func moveToNextPhoto() {
        guard let group = selectedGroup else { return }
        // Try to find next visible photo in current group
        for i in (selectedPhotoIndex + 1)..<group.photos.count {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Exhausted group, move to next
        moveToNextGroup()
    }

    func moveToPreviousPhoto() {
        guard let group = selectedGroup else { return }
        // Try to find previous visible photo in current group
        for i in stride(from: selectedPhotoIndex - 1, through: 0, by: -1) {
            if !isPhotoFiltered(group.photos[i]) {
                selectedPhotoIndex = i
                return
            }
        }
        // Exhausted group, move to previous
        moveToPreviousGroup()
        // Land on last visible photo in new group
        if let newGroup = selectedGroup {
            for i in stride(from: newGroup.photos.count - 1, through: 0, by: -1) {
                if !isPhotoFiltered(newGroup.photos[i]) {
                    selectedPhotoIndex = i
                    return
                }
            }
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
              let visibleIndex = visible.firstIndex(where: { $0.id == current.id }) else { return [] }
        return (1...min(count, visible.count - 1)).map { i in
            visible[(visibleIndex + i) % visible.count]
        }
    }

    /// Returns the previous N visible (unfiltered) photos from the current position, wrapping around to end
    func photosBehind(_ count: Int) -> [Photo] {
        let visible = allPhotos.filter { !isPhotoFiltered($0) }
        guard !visible.isEmpty, count > 0 else { return [] }
        guard let current = selectedPhoto,
              let visibleIndex = visible.firstIndex(where: { $0.id == current.id }) else { return [] }
        return (1...min(count, visible.count - 1)).map { i in
            visible[(visibleIndex - i + visible.count) % visible.count]
        }
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

    func cycleZoom() {
        guard let photo = selectedPhoto else { return }
        let faces = photo.faceRegions

        switch zoomFaceIndex {
        case nil:
            // Currently fit → zoom to first face or center
            if faces.isEmpty {
                zoomFaceIndex = -1 // center zoom
            } else {
                zoomFaceIndex = 0 // first face
            }
        case -1:
            // Center zoom → back to fit
            zoomFaceIndex = nil
        case let idx?:
            // On a face → next face, or back to fit
            if idx + 1 < faces.count {
                zoomFaceIndex = idx + 1
            } else {
                zoomFaceIndex = nil
            }
        }
    }

    private func resetZoom() {
        zoomFaceIndex = nil
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
            photo.blurScore = saved.blurScore
            photo.faceSharpness = saved.faceSharpness
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

        // Clamp navigation indices
        selectedGroupIndex = min(selectedGroupIndex, groups.count - 1)
        if let group = selectedGroup {
            selectedPhotoIndex = min(selectedPhotoIndex, group.photos.count - 1)
        }

        return WorkspaceResult(newPhotos: newPhotos)
    }
}
